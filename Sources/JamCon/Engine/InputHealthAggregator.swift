import Foundation

struct InputHealthSummary: Equatable {
    let device: ManagedDeviceKey
    let duration: TimeInterval
    let reportCount: Int
    let reportRate: Double
    let inputAgeSampleCount: Int
    let invalidInputTimestampCount: Int
    let averageInputAgeMilliseconds: Double?
    let maximumInputAgeMilliseconds: Double?
    let averageQueueDelayMilliseconds: Double
    let maximumQueueDelayMilliseconds: Double
    let averageProcessingMilliseconds: Double
    let maximumProcessingMilliseconds: Double
    let timestampSourceCounts: [InputTimestampSource: Int]

    var logMessage: String {
        let inputAge: String
        if let averageInputAgeMilliseconds, let maximumInputAgeMilliseconds {
            inputAge = "inputAge.avg=\(Self.number(averageInputAgeMilliseconds))ms "
                + "inputAge.max=\(Self.number(maximumInputAgeMilliseconds))ms "
                + "inputAge.samples=\(inputAgeSampleCount)"
        } else {
            inputAge = "inputAge=n/a inputAge.samples=0"
        }
        let sources = InputTimestampSource.allCases.compactMap { source -> String? in
            guard let count = timestampSourceCounts[source], count > 0 else { return nil }
            return "\(source.rawValue):\(count)"
        }.joined(separator: ",")
        let sourceDescription = sources.isEmpty ? "none" : sources

        return "device=\(device.kind.rawValue):\(device.id) "
            + "window=\(Self.number(duration, decimals: 1))s "
            + "reports=\(reportCount) rate=\(Self.number(reportRate, decimals: 1))/s "
            + "\(inputAge) invalidInputTimestamps=\(invalidInputTimestampCount) "
            + "queue.avg=\(Self.number(averageQueueDelayMilliseconds))ms "
            + "queue.max=\(Self.number(maximumQueueDelayMilliseconds))ms "
            + "processing.avg=\(Self.number(averageProcessingMilliseconds))ms "
            + "processing.max=\(Self.number(maximumProcessingMilliseconds))ms "
            + "timestampSources=\(sourceDescription)"
    }

    private static func number(_ value: Double, decimals: Int = 2) -> String {
        String(format: "%.*f", decimals, value)
    }
}

/// Engine-queue-owned report health accumulator.
///
/// Per-report work is constant-time arithmetic. Only one aggregate per active
/// device is emitted at the configured interval; raw reports never become logs.
struct InputHealthAggregator {
    private struct Window {
        let startedAt: TimeInterval
        var reportCount = 0
        var inputAgeTotal = 0.0
        var inputAgeMaximum = 0.0
        var inputAgeSampleCount = 0
        var invalidInputTimestampCount = 0
        var queueDelayTotal = 0.0
        var queueDelayMaximum = 0.0
        var processingTotal = 0.0
        var processingMaximum = 0.0
        var timestampSourceCounts: [InputTimestampSource: Int] = [:]

        mutating func record(
            inputTimestamp: TimeInterval?,
            timestampSource: InputTimestampSource,
            receivedTimestamp: TimeInterval,
            engineStartTimestamp: TimeInterval,
            engineEndTimestamp: TimeInterval
        ) {
            let queueDelay = Self.milliseconds(engineStartTimestamp - receivedTimestamp)
            let processing = Self.milliseconds(engineEndTimestamp - engineStartTimestamp)

            reportCount += 1
            timestampSourceCounts[timestampSource, default: 0] += 1
            if let inputTimestamp {
                let ageSeconds = engineEndTimestamp - inputTimestamp
                if inputTimestamp.isFinite,
                   ageSeconds.isFinite,
                   ageSeconds >= 0,
                   ageSeconds <= 10 {
                    let inputAge = ageSeconds * 1_000
                    inputAgeTotal += inputAge
                    inputAgeMaximum = max(inputAgeMaximum, inputAge)
                    inputAgeSampleCount += 1
                } else {
                    invalidInputTimestampCount += 1
                }
            }
            queueDelayTotal += queueDelay
            queueDelayMaximum = max(queueDelayMaximum, queueDelay)
            processingTotal += processing
            processingMaximum = max(processingMaximum, processing)
        }

        func summary(device: ManagedDeviceKey, endingAt timestamp: TimeInterval) -> InputHealthSummary? {
            guard reportCount > 0 else { return nil }
            let duration = max(0.001, timestamp - startedAt)
            let count = Double(reportCount)
            return InputHealthSummary(
                device: device,
                duration: duration,
                reportCount: reportCount,
                reportRate: count / duration,
                inputAgeSampleCount: inputAgeSampleCount,
                invalidInputTimestampCount: invalidInputTimestampCount,
                averageInputAgeMilliseconds: inputAgeSampleCount > 0
                    ? inputAgeTotal / Double(inputAgeSampleCount)
                    : nil,
                maximumInputAgeMilliseconds: inputAgeSampleCount > 0 ? inputAgeMaximum : nil,
                averageQueueDelayMilliseconds: queueDelayTotal / count,
                maximumQueueDelayMilliseconds: queueDelayMaximum,
                averageProcessingMilliseconds: processingTotal / count,
                maximumProcessingMilliseconds: processingMaximum,
                timestampSourceCounts: timestampSourceCounts
            )
        }

        private static func milliseconds(_ seconds: TimeInterval) -> Double {
            guard seconds.isFinite else { return 0 }
            return max(0, seconds * 1_000)
        }
    }

    let interval: TimeInterval
    private var windows: [ManagedDeviceKey: Window] = [:]

    init(interval: TimeInterval = 5) {
        self.interval = max(0.1, interval)
    }

    mutating func record(
        device: ManagedDeviceKey,
        inputTimestamp: TimeInterval?,
        timestampSource: InputTimestampSource,
        receivedTimestamp: TimeInterval,
        engineStartTimestamp: TimeInterval,
        engineEndTimestamp: TimeInterval
    ) -> InputHealthSummary? {
        var window = windows[device] ?? Window(startedAt: engineEndTimestamp)
        window.record(
            inputTimestamp: inputTimestamp,
            timestampSource: timestampSource,
            receivedTimestamp: receivedTimestamp,
            engineStartTimestamp: engineStartTimestamp,
            engineEndTimestamp: engineEndTimestamp
        )

        guard engineEndTimestamp - window.startedAt >= interval else {
            windows[device] = window
            return nil
        }

        windows.removeValue(forKey: device)
        return window.summary(device: device, endingAt: engineEndTimestamp)
    }

    mutating func flush(at timestamp: TimeInterval) -> [InputHealthSummary] {
        let summaries = windows.compactMap { device, window in
            window.summary(device: device, endingAt: timestamp)
        }
        windows.removeAll(keepingCapacity: true)
        return summaries.sorted {
            if $0.device.kind.rawValue == $1.device.kind.rawValue {
                return $0.device.id < $1.device.id
            }
            return $0.device.kind.rawValue < $1.device.kind.rawValue
        }
    }

    mutating func reset() {
        windows.removeAll(keepingCapacity: true)
    }
}

// MARK: - Gyro response health

/// One inexpensive snapshot of the gyro algorithm's response to an input
/// report. These values are aggregated before logging; individual samples are
/// never written to disk.
struct GyroResponseSample: Equatable {
    let deltaTime: TimeInterval
    let rawSpeed: Double
    let filteredSpeed: Double
    let accelerationSpeed: Double
    let accelerationGain: Double
    let computedCursorSpeed: Double
    let biasX: Double
    let biasY: Double
    let biasZ: Double
    let filterEnabled: Bool
    let didAutoNeutralUpdate: Bool
}

struct GyroResponseSummary: Equatable {
    let device: ManagedDeviceKey
    let duration: TimeInterval
    let sampleCount: Int
    let activeSampleCount: Int
    let filterEnabledSampleCount: Int
    let filterDisabledSampleCount: Int
    let averageDeltaTimeMilliseconds: Double
    let maximumDeltaTimeMilliseconds: Double
    let averageRawSpeed: Double?
    let maximumRawSpeed: Double?
    let averageFilteredSpeed: Double?
    let maximumFilteredSpeed: Double?
    let averageAccelerationSpeed: Double?
    let averageAccelerationGain: Double?
    let maximumAccelerationGain: Double?
    let averageComputedCursorSpeed: Double?
    let maximumComputedCursorSpeed: Double?
    let endingBiasMagnitude: Double
    let biasChangeMagnitude: Double
    let autoNeutralUpdateCount: Int

    var logMessage: String {
        let response: String
        if let averageRawSpeed,
           let maximumRawSpeed,
           let averageFilteredSpeed,
           let maximumFilteredSpeed,
           let averageAccelerationSpeed,
           let averageAccelerationGain,
           let maximumAccelerationGain,
           let averageComputedCursorSpeed,
           let maximumComputedCursorSpeed {
            response = "rawSpeed.avg=\(Self.number(averageRawSpeed))deg/s "
                + "rawSpeed.max=\(Self.number(maximumRawSpeed))deg/s "
                + "filteredSpeed.avg=\(Self.number(averageFilteredSpeed))deg/s "
                + "filteredSpeed.max=\(Self.number(maximumFilteredSpeed))deg/s "
                + "gainSpeed.avg=\(Self.number(averageAccelerationSpeed))deg/s "
                + "gain.avg=\(Self.number(averageAccelerationGain))x "
                + "gain.max=\(Self.number(maximumAccelerationGain))x "
                + "computedCursorSpeed.avg=\(Self.number(averageComputedCursorSpeed))pt/s "
                + "computedCursorSpeed.max=\(Self.number(maximumComputedCursorSpeed))pt/s"
        } else {
            response = "motion=n/a"
        }

        return "device=\(device.kind.rawValue):\(device.id) gyroResponse "
            + "window=\(Self.number(duration, decimals: 1))s "
            + "samples=\(sampleCount) active=\(activeSampleCount) "
            + "filter.on=\(filterEnabledSampleCount) filter.off=\(filterDisabledSampleCount) "
            + "dt.avg=\(Self.number(averageDeltaTimeMilliseconds))ms "
            + "dt.max=\(Self.number(maximumDeltaTimeMilliseconds))ms "
            + "\(response) "
            + "bias.end=\(Self.number(endingBiasMagnitude))deg/s "
            + "bias.change=\(Self.number(biasChangeMagnitude))deg/s "
            + "autoNeutralUpdates=\(autoNeutralUpdateCount)"
    }

    private static func number(_ value: Double, decimals: Int = 2) -> String {
        String(format: "%.*f", decimals, value)
    }
}

/// Engine-queue-owned gyro response accumulator. It adds constant-time
/// arithmetic to the input path and emits at most one line per active device
/// per interval.
struct GyroResponseAggregator {
    private struct Vector {
        let x: Double
        let y: Double
        let z: Double

        var magnitude: Double {
            sqrt(x * x + y * y + z * z)
        }

        func distance(to other: Vector) -> Double {
            let dx = other.x - x
            let dy = other.y - y
            let dz = other.z - z
            return sqrt(dx * dx + dy * dy + dz * dz)
        }
    }

    private struct Window {
        private static let activeSpeedThreshold = 1.0

        let startedAt: TimeInterval
        var sampleCount = 0
        var activeSampleCount = 0
        var filterEnabledSampleCount = 0
        var deltaTimeTotal = 0.0
        var deltaTimeMaximum = 0.0
        var rawSpeedTotal = 0.0
        var rawSpeedMaximum = 0.0
        var filteredSpeedTotal = 0.0
        var filteredSpeedMaximum = 0.0
        var accelerationSpeedTotal = 0.0
        var accelerationGainTotal = 0.0
        var accelerationGainMaximum = 0.0
        var computedCursorSpeedTotal = 0.0
        var computedCursorSpeedMaximum = 0.0
        var startingBias: Vector?
        var endingBias: Vector?
        var autoNeutralUpdateCount = 0

        mutating func record(_ sample: GyroResponseSample) {
            let deltaTime = Self.finiteNonnegative(sample.deltaTime)
            let bias = Vector(x: sample.biasX, y: sample.biasY, z: sample.biasZ)

            sampleCount += 1
            filterEnabledSampleCount += sample.filterEnabled ? 1 : 0
            deltaTimeTotal += deltaTime
            deltaTimeMaximum = max(deltaTimeMaximum, deltaTime)
            startingBias = startingBias ?? bias
            endingBias = bias
            autoNeutralUpdateCount += sample.didAutoNeutralUpdate ? 1 : 0

            guard sample.rawSpeed >= Self.activeSpeedThreshold else { return }
            activeSampleCount += 1
            rawSpeedTotal += Self.finiteNonnegative(sample.rawSpeed)
            rawSpeedMaximum = max(rawSpeedMaximum, Self.finiteNonnegative(sample.rawSpeed))
            filteredSpeedTotal += Self.finiteNonnegative(sample.filteredSpeed)
            filteredSpeedMaximum = max(filteredSpeedMaximum, Self.finiteNonnegative(sample.filteredSpeed))
            accelerationSpeedTotal += Self.finiteNonnegative(sample.accelerationSpeed)
            accelerationGainTotal += Self.finiteNonnegative(sample.accelerationGain)
            accelerationGainMaximum = max(accelerationGainMaximum, Self.finiteNonnegative(sample.accelerationGain))
            computedCursorSpeedTotal += Self.finiteNonnegative(sample.computedCursorSpeed)
            computedCursorSpeedMaximum = max(
                computedCursorSpeedMaximum,
                Self.finiteNonnegative(sample.computedCursorSpeed)
            )
        }

        func summary(device: ManagedDeviceKey, endingAt timestamp: TimeInterval) -> GyroResponseSummary? {
            guard sampleCount > 0 else { return nil }
            let duration = max(0.001, timestamp - startedAt)
            let sampleDivisor = Double(sampleCount)
            let activeDivisor = Double(activeSampleCount)
            let firstBias = startingBias ?? Vector(x: 0, y: 0, z: 0)
            let lastBias = endingBias ?? firstBias

            return GyroResponseSummary(
                device: device,
                duration: duration,
                sampleCount: sampleCount,
                activeSampleCount: activeSampleCount,
                filterEnabledSampleCount: filterEnabledSampleCount,
                filterDisabledSampleCount: sampleCount - filterEnabledSampleCount,
                averageDeltaTimeMilliseconds: deltaTimeTotal * 1_000 / sampleDivisor,
                maximumDeltaTimeMilliseconds: deltaTimeMaximum * 1_000,
                averageRawSpeed: activeSampleCount > 0 ? rawSpeedTotal / activeDivisor : nil,
                maximumRawSpeed: activeSampleCount > 0 ? rawSpeedMaximum : nil,
                averageFilteredSpeed: activeSampleCount > 0 ? filteredSpeedTotal / activeDivisor : nil,
                maximumFilteredSpeed: activeSampleCount > 0 ? filteredSpeedMaximum : nil,
                averageAccelerationSpeed: activeSampleCount > 0 ? accelerationSpeedTotal / activeDivisor : nil,
                averageAccelerationGain: activeSampleCount > 0 ? accelerationGainTotal / activeDivisor : nil,
                maximumAccelerationGain: activeSampleCount > 0 ? accelerationGainMaximum : nil,
                averageComputedCursorSpeed: activeSampleCount > 0 ? computedCursorSpeedTotal / activeDivisor : nil,
                maximumComputedCursorSpeed: activeSampleCount > 0 ? computedCursorSpeedMaximum : nil,
                endingBiasMagnitude: lastBias.magnitude,
                biasChangeMagnitude: firstBias.distance(to: lastBias),
                autoNeutralUpdateCount: autoNeutralUpdateCount
            )
        }

        private static func finiteNonnegative(_ value: Double) -> Double {
            guard value.isFinite else { return 0 }
            return max(0, value)
        }
    }

    let interval: TimeInterval
    private var windows: [ManagedDeviceKey: Window] = [:]

    init(interval: TimeInterval = 5) {
        self.interval = max(0.1, interval)
    }

    mutating func record(
        device: ManagedDeviceKey,
        timestamp: TimeInterval,
        sample: GyroResponseSample
    ) -> GyroResponseSummary? {
        var window = windows[device] ?? Window(startedAt: timestamp)
        window.record(sample)

        guard timestamp - window.startedAt >= interval else {
            windows[device] = window
            return nil
        }

        windows.removeValue(forKey: device)
        return window.summary(device: device, endingAt: timestamp)
    }

    mutating func flush(at timestamp: TimeInterval) -> [GyroResponseSummary] {
        let summaries = windows.compactMap { device, window in
            window.summary(device: device, endingAt: timestamp)
        }
        windows.removeAll(keepingCapacity: true)
        return summaries.sorted {
            if $0.device.kind.rawValue == $1.device.kind.rawValue {
                return $0.device.id < $1.device.id
            }
            return $0.device.kind.rawValue < $1.device.kind.rawValue
        }
    }

    mutating func reset() {
        windows.removeAll(keepingCapacity: true)
    }
}
