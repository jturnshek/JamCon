import Foundation
import os

/// Thread-safe ring buffer for debug/visualization data
/// Engine writes samples, UI polls when needed
/// This is the ONE-WAY bridge: Engine → UI (debug data flows up via polling)
final class DebugBuffer: @unchecked Sendable {
    private let lock = OSAllocatedUnfairLock()
    private let traceRecorder = HIDReportTraceRecorder()

    // MARK: - Types

    /// A single debug sample from the controller with all pipeline stages
    struct Sample {
        let timestamp: Date
        let reportBytes: [UInt8]
        let reportLength: Int

        // Pipeline Stage 1: Raw (direct from HID)
        let rawGyro: (x: Int16, y: Int16, z: Int16)

        // Pipeline Stage 2: Remapped (semantic axes)
        let remappedGyro: (pitch: Int16, yaw: Int16, roll: Int16)

        // Pipeline Stage 3: Normalized (degrees per second)
        let normalizedGyro: (pitch: Double, yaw: Double, roll: Double)

        let accel: (x: Int16, y: Int16, z: Int16)
        let buttonStates: [Bool]
        let controllerKind: ControllerKind
        let gyroDebug: GyroDebug?

        // Backwards compatibility alias
        var gyro: (x: Int16, y: Int16, z: Int16) { rawGyro }

        static let empty = Sample(
            timestamp: .distantPast,
            reportBytes: [],
            reportLength: 0,
            rawGyro: (0, 0, 0),
            remappedGyro: (0, 0, 0),
            normalizedGyro: (0, 0, 0),
            accel: (0, 0, 0),
            buttonStates: [],
            controllerKind: .sense,
            gyroDebug: nil
        )
    }

    struct GyroDebug {
        let biasX: Double
        let biasY: Double
        let biasZ: Double
        let calibrated: Bool
        let observedSampleRate: Double
        let lastNeutralUpdate: TimeInterval?
    }

    /// Monotonic timing captured at the input pipeline boundaries.
    struct PipelineTiming {
        let inputAgeMilliseconds: Double?
        let timestampSource: InputTimestampSource
        let queueDelayMilliseconds: Double
        let processingMilliseconds: Double

        init(
            inputTimestamp: TimeInterval?,
            timestampSource: InputTimestampSource,
            receivedTimestamp: TimeInterval,
            engineStartTimestamp: TimeInterval,
            engineEndTimestamp: TimeInterval
        ) {
            if let inputTimestamp {
                let age = engineEndTimestamp - inputTimestamp
                inputAgeMilliseconds = inputTimestamp.isFinite && age.isFinite && age >= 0 && age <= 10
                    ? age * 1_000
                    : nil
            } else {
                inputAgeMilliseconds = nil
            }
            self.timestampSource = timestampSource
            queueDelayMilliseconds = Self.milliseconds(engineStartTimestamp - receivedTimestamp)
            processingMilliseconds = Self.milliseconds(engineEndTimestamp - engineStartTimestamp)
        }

        private static func milliseconds(_ seconds: TimeInterval) -> Double {
            guard seconds.isFinite else { return 0 }
            return max(0, seconds * 1_000)
        }
    }

    struct MetricSummary {
        let latest: Double
        let average: Double
        let p95: Double
        let maximum: Double
    }

    struct PipelineTimingSummary {
        let sampleCount: Int
        let inputAge: MetricSummary?
        let timestampSourceCounts: [InputTimestampSource: Int]
        let queueDelay: MetricSummary
        let processing: MetricSummary
    }

    /// Aggregated statistics for display
    struct Stats {
        var reportCount: Int = 0
        var lastReportTime: Date = .distantPast
        var reportsPerSecond: Double = 0
        var timing: PipelineTimingSummary?
    }

    // MARK: - State

    /// Ring buffer of samples
    private var samples: [Sample]
    private var writeIndex: Int = 0
    private let capacity: Int

    /// Byte change tracking for visualization
    private var byteLastChanged: [Date]
    private var bitLastChanged: [[Date]]
    private var previousBytes: [UInt8]

    /// Statistics
    private var _stats = Stats()
    private var reportTimestamps: [Date] = []
    private var timingSamples: [PipelineTiming] = []
    private var timingWriteIndex: Int = 0
    private let timingCapacity = 512

    /// Whether recording is enabled (UI can disable to save CPU)
    private var _isRecording: Bool = false

    // MARK: - Initialization

    init(capacity: Int = 120, maxReportLength: Int = 256) {
        self.capacity = capacity
        self.samples = []
        self.samples.reserveCapacity(capacity)

        self.byteLastChanged = Array(repeating: .distantPast, count: maxReportLength)
        self.bitLastChanged = Array(repeating: Array(repeating: .distantPast, count: 8), count: maxReportLength)
        self.previousBytes = Array(repeating: 0, count: maxReportLength)
    }

    // MARK: - Recording Control

    var isRecording: Bool {
        get { lock.withLock { _isRecording } }
        set { lock.withLock { _isRecording = newValue } }
    }

    func startRecording() {
        traceRecorder.start()
        lock.withLock {
            _isRecording = true
        }
    }

    func stopRecording() {
        lock.withLock {
            _isRecording = false
        }
    }

    // MARK: - Writing (Called from HID thread)

    func recordTrace(
        device: ManagedDeviceKey,
        reportID: UInt32,
        bytes: [UInt8],
        timestamp: TimeInterval
    ) {
        guard isRecording else { return }
        traceRecorder.record(
            device: device,
            reportID: reportID,
            bytes: bytes,
            timestamp: timestamp
        )
    }

    func hidTraceSnapshot(createdAt: Date = Date()) -> HIDReportTrace {
        traceRecorder.snapshot(createdAt: createdAt)
    }

    func encodedHIDTrace(prettyPrinted: Bool = true) throws -> Data {
        try HIDReportTraceCodec.encode(hidTraceSnapshot(), prettyPrinted: prettyPrinted)
    }

    /// Record a new sample with all pipeline stages - fast, non-blocking write
    func record(
        bytes: [UInt8],
        length: Int,
        rawGyro: (x: Int16, y: Int16, z: Int16),
        remappedGyro: (pitch: Int16, yaw: Int16, roll: Int16),
        normalizedGyro: (pitch: Double, yaw: Double, roll: Double),
        accel: (x: Int16, y: Int16, z: Int16),
        buttonStates: [Bool],
        controllerKind: ControllerKind,
        gyroDebug: GyroDebug? = nil,
        pipelineTiming: PipelineTiming? = nil
    ) {
        lock.withLock {
            guard _isRecording else { return }
            let now = Date()

            // Track byte/bit changes
            let maxIndex = min(length, previousBytes.count, bytes.count)
            for i in 0..<maxIndex {
                if bytes[i] != previousBytes[i] {
                    byteLastChanged[i] = now

                    // Track individual bit changes
                    let changedBits = bytes[i] ^ previousBytes[i]
                    for bit in 0..<8 where (changedBits >> bit) & 1 == 1 {
                        bitLastChanged[i][bit] = now
                    }
                    previousBytes[i] = bytes[i]
                }
            }

            // Create sample with all pipeline stages
            let sample = Sample(
                timestamp: now,
                reportBytes: Array(bytes.prefix(maxIndex)),
                reportLength: length,
                rawGyro: rawGyro,
                remappedGyro: remappedGyro,
                normalizedGyro: normalizedGyro,
                accel: accel,
                buttonStates: buttonStates,
                controllerKind: controllerKind,
                gyroDebug: gyroDebug
            )

            // Write to ring buffer
            if samples.count < capacity {
                samples.append(sample)
            } else {
                samples[writeIndex] = sample
            }
            writeIndex = (writeIndex + 1) % capacity

            // Update statistics
            _stats.reportCount += 1
            _stats.lastReportTime = now

            // Track reports per second (rolling window)
            reportTimestamps.append(now)
            let cutoff = now.addingTimeInterval(-1.0)
            reportTimestamps.removeAll { $0 < cutoff }
            _stats.reportsPerSecond = Double(reportTimestamps.count)

            if let pipelineTiming {
                if timingSamples.count < timingCapacity {
                    timingSamples.append(pipelineTiming)
                } else {
                    timingSamples[timingWriteIndex] = pipelineTiming
                }
                timingWriteIndex = (timingWriteIndex + 1) % timingCapacity
            }
        }
    }

    // MARK: - Reading (Called from main thread)

    /// Get the most recent sample
    func latest() -> Sample? {
        lock.withLock {
            guard !samples.isEmpty else { return nil }
            let index = (writeIndex - 1 + samples.count) % samples.count
            return samples[index]
        }
    }

    /// Get the latest gyro debug snapshot (if available)
    func latestGyroDebug() -> GyroDebug? {
        lock.withLock {
            guard !samples.isEmpty else { return nil }
            let index = (writeIndex - 1 + samples.count) % samples.count
            return samples[index].gyroDebug
        }
    }

    /// Get all recent samples (for visualization)
    func recentSamples() -> [Sample] {
        lock.withLock {
            // Return samples in chronological order
            guard !samples.isEmpty else { return [] }

            if samples.count < capacity {
                return samples
            }

            // Ring buffer is full - reconstruct order
            var result: [Sample] = []
            result.reserveCapacity(capacity)
            for i in 0..<capacity {
                let index = (writeIndex + i) % capacity
                result.append(samples[index])
            }
            return result
        }
    }

    /// Get current statistics
    func stats() -> Stats {
        let snapshot = lock.withLock { () -> (Stats, [PipelineTiming], PipelineTiming?) in
            let latest: PipelineTiming?
            if timingSamples.isEmpty {
                latest = nil
            } else {
                let index = (timingWriteIndex - 1 + timingSamples.count) % timingSamples.count
                latest = timingSamples[index]
            }
            return (_stats, timingSamples, latest)
        }

        var result = snapshot.0
        if let latest = snapshot.2 {
            let inputAges = snapshot.1.compactMap(\.inputAgeMilliseconds)
            let sourceCounts = snapshot.1.reduce(into: [InputTimestampSource: Int]()) { counts, timing in
                counts[timing.timestampSource, default: 0] += 1
            }
            result.timing = PipelineTimingSummary(
                sampleCount: snapshot.1.count,
                inputAge: inputAges.isEmpty
                    ? nil
                    : Self.summarize(inputAges, latest: latest.inputAgeMilliseconds ?? inputAges[inputAges.count - 1]),
                timestampSourceCounts: sourceCounts,
                queueDelay: Self.summarize(snapshot.1.map(\.queueDelayMilliseconds), latest: latest.queueDelayMilliseconds),
                processing: Self.summarize(snapshot.1.map(\.processingMilliseconds), latest: latest.processingMilliseconds)
            )
        }
        return result
    }

    /// Get byte change timestamps (for heat map visualization)
    func getByteLastChanged() -> [Date] {
        lock.withLock { byteLastChanged }
    }

    /// Get bit change timestamps (for detailed visualization)
    func getBitLastChanged() -> [[Date]] {
        lock.withLock { bitLastChanged }
    }

    /// Get current report bytes (for byte inspector)
    func getCurrentBytes() -> [UInt8] {
        lock.withLock { previousBytes }
    }

    // MARK: - Log Messages

    private var logMessages: [String] = []
    private var logWriteIndex: Int = 0
    private let logCapacity: Int = 500

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()

    /// Add a log message (thread-safe, called from any thread)
    func log(_ message: String) {
        lock.withLock {
            let timestamped = "[\(Self.timeFormatter.string(from: Date()))] \(message)"

            if logMessages.count < logCapacity {
                logMessages.append(timestamped)
            } else if !logMessages.isEmpty {
                logMessages[logWriteIndex] = timestamped
                logWriteIndex = (logWriteIndex + 1) % logCapacity
            }
        }
    }

    /// Get all log messages (thread-safe, called from main thread)
    func getLogMessages() -> [String] {
        lock.withLock {
            guard !logMessages.isEmpty else { return [] }
            if logMessages.count < logCapacity {
                return logMessages
            }

            // Ring buffer is full - reconstruct chronological order
            var result: [String] = []
            result.reserveCapacity(logCapacity)
            for i in 0..<logCapacity {
                let index = (logWriteIndex + i) % logCapacity
                result.append(logMessages[index])
            }
            return result
        }
    }

    /// Clear all log messages
    func clearLog() {
        lock.withLock {
            logMessages.removeAll(keepingCapacity: true)
            logWriteIndex = 0
        }
    }

    // MARK: - Utility

    /// Clear all recorded data
    func clear() {
        lock.withLock {
            samples.removeAll(keepingCapacity: true)
            writeIndex = 0
            _stats = Stats()
            reportTimestamps.removeAll()
            timingSamples.removeAll(keepingCapacity: true)
            timingWriteIndex = 0
            byteLastChanged = Array(repeating: .distantPast, count: byteLastChanged.count)
            bitLastChanged = Array(repeating: Array(repeating: .distantPast, count: 8), count: bitLastChanged.count)
            previousBytes = Array(repeating: 0, count: previousBytes.count)
        }
        traceRecorder.clear()
    }

    private static func summarize(_ values: [Double], latest: Double) -> MetricSummary {
        guard !values.isEmpty else {
            return MetricSummary(latest: latest, average: latest, p95: latest, maximum: latest)
        }

        let sorted = values.sorted()
        let percentileIndex = min(Int(ceil(Double(sorted.count) * 0.95)) - 1, sorted.count - 1)
        return MetricSummary(
            latest: latest,
            average: values.reduce(0, +) / Double(values.count),
            p95: sorted[max(0, percentileIndex)],
            maximum: sorted.last ?? latest
        )
    }
}
