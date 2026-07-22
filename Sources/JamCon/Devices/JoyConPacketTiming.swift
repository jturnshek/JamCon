import Foundation

struct JoyConPacketTimingObservation: Equatable, Sendable {
    let accepted: Bool
    let processingTimestamp: TimeInterval
    let timestampSource: InputTimestampSource
    let callbackIntervalMilliseconds: Double?
    let acceptedIntervalMilliseconds: Double?
    let timerDeltaTicks: Int?
    let timerDiscontinuity: Bool

    var isDuplicate: Bool { !accepted }
}

/// Associates the timer byte contained in the current Joy-Con report with the
/// host receipt time for that same report.
///
/// A separate IOHIDValue callback cannot safely timestamp a raw report: callback
/// ordering is not guaranteed, and in practice the cached value was frequently
/// from the preceding packet. This tracker therefore uses only information that
/// is present in the current report.
struct JoyConPacketTimingTracker: Sendable {
    private static let duplicateHorizon: TimeInterval = 0.050
    private static let maximumValidTimerDelta = 127

    private var lastCallbackReceivedTimestamp: TimeInterval?
    private var lastAcceptedReceivedTimestamp: TimeInterval?
    private var lastAcceptedTimerByte: UInt8?
    private var lastAcceptedBytes: [UInt8]?

    mutating func observe(
        timerByte: UInt8?,
        bytes: [UInt8],
        receivedTimestamp: TimeInterval
    ) -> JoyConPacketTimingObservation {
        let callbackInterval = Self.milliseconds(
            since: lastCallbackReceivedTimestamp,
            until: receivedTimestamp
        )
        lastCallbackReceivedTimestamp = receivedTimestamp

        let acceptedInterval = Self.milliseconds(
            since: lastAcceptedReceivedTimestamp,
            until: receivedTimestamp
        )

        if let timerByte,
           timerByte == lastAcceptedTimerByte,
           bytes == lastAcceptedBytes,
           let lastAcceptedReceivedTimestamp,
           receivedTimestamp - lastAcceptedReceivedTimestamp >= 0,
           receivedTimestamp - lastAcceptedReceivedTimestamp <= Self.duplicateHorizon {
            return JoyConPacketTimingObservation(
                accepted: false,
                processingTimestamp: receivedTimestamp,
                timestampSource: .hostReceipt,
                callbackIntervalMilliseconds: callbackInterval,
                acceptedIntervalMilliseconds: acceptedInterval,
                timerDeltaTicks: 0,
                timerDiscontinuity: false
            )
        }

        let timerDelta: Int? = {
            guard let timerByte, let lastAcceptedTimerByte else { return nil }
            return Int(timerByte &- lastAcceptedTimerByte)
        }()

        // The timer is useful for detecting duplicate and skipped reports, but
        // its tick-to-time behavior is not stable enough to serve as a clock.
        // Signal processing therefore uses the directly measured receipt time.
        let timerDiscontinuity = timerDelta.map { $0 == 0 || $0 > Self.maximumValidTimerDelta } ?? false

        lastAcceptedReceivedTimestamp = receivedTimestamp
        lastAcceptedTimerByte = timerByte
        lastAcceptedBytes = bytes

        return JoyConPacketTimingObservation(
            accepted: true,
            processingTimestamp: receivedTimestamp,
            timestampSource: .hostReceipt,
            callbackIntervalMilliseconds: callbackInterval,
            acceptedIntervalMilliseconds: acceptedInterval,
            timerDeltaTicks: timerDelta,
            timerDiscontinuity: timerDiscontinuity
        )
    }

    mutating func reset() {
        self = JoyConPacketTimingTracker()
    }

    private static func milliseconds(since start: TimeInterval?, until end: TimeInterval) -> Double? {
        guard let start, start.isFinite, end.isFinite, end >= start else { return nil }
        return (end - start) * 1_000
    }
}

struct JoyConTransportSummary: Equatable, Sendable {
    let duration: TimeInterval
    let callbackCount: Int
    let acceptedCount: Int
    let duplicateCount: Int
    let timerDiscontinuityCount: Int
    let callbackRate: Double
    let acceptedRate: Double
    let averageCallbackIntervalMilliseconds: Double?
    let maximumCallbackIntervalMilliseconds: Double?
    let averageAcceptedIntervalMilliseconds: Double?
    let maximumAcceptedIntervalMilliseconds: Double?
    let averageTimerDeltaTicks: Double?
    let minimumTimerDeltaTicks: Int?
    let maximumTimerDeltaTicks: Int?

    var logMessage: String {
        "callbacks=\(callbackCount) callbackRate=\(Self.number(callbackRate, decimals: 1))/s "
            + "accepted=\(acceptedCount) acceptedRate=\(Self.number(acceptedRate, decimals: 1))/s "
            + "duplicates=\(duplicateCount) timerDiscontinuities=\(timerDiscontinuityCount) "
            + "callbackInterval.avg=\(Self.metric(averageCallbackIntervalMilliseconds)) "
            + "callbackInterval.max=\(Self.metric(maximumCallbackIntervalMilliseconds)) "
            + "acceptedInterval.avg=\(Self.metric(averageAcceptedIntervalMilliseconds)) "
            + "acceptedInterval.max=\(Self.metric(maximumAcceptedIntervalMilliseconds)) "
            + "timerTicks.avg=\(Self.numberOrNA(averageTimerDeltaTicks)) "
            + "timerTicks.min=\(Self.integerOrNA(minimumTimerDeltaTicks)) "
            + "timerTicks.max=\(Self.integerOrNA(maximumTimerDeltaTicks))"
    }

    private static func metric(_ value: Double?) -> String {
        value.map { "\(number($0))ms" } ?? "n/a"
    }

    private static func numberOrNA(_ value: Double?) -> String {
        value.map { number($0) } ?? "n/a"
    }

    private static func integerOrNA(_ value: Int?) -> String {
        value.map(String.init) ?? "n/a"
    }

    private static func number(_ value: Double, decimals: Int = 2) -> String {
        String(format: "%.*f", decimals, value)
    }
}

/// HID-thread-owned, constant-space transport diagnostics. It emits one summary
/// per interval and never logs individual reports.
struct JoyConTransportAggregator: Sendable {
    private struct Window: Sendable {
        let startedAt: TimeInterval
        var callbackCount = 0
        var acceptedCount = 0
        var duplicateCount = 0
        var timerDiscontinuityCount = 0
        var callbackIntervalTotal = 0.0
        var callbackIntervalCount = 0
        var callbackIntervalMaximum = 0.0
        var acceptedIntervalTotal = 0.0
        var acceptedIntervalCount = 0
        var acceptedIntervalMaximum = 0.0
        var timerDeltaTotal = 0
        var timerDeltaCount = 0
        var timerDeltaMinimum: Int?
        var timerDeltaMaximum: Int?

        mutating func record(_ observation: JoyConPacketTimingObservation) {
            callbackCount += 1
            if let interval = observation.callbackIntervalMilliseconds {
                callbackIntervalTotal += interval
                callbackIntervalCount += 1
                callbackIntervalMaximum = max(callbackIntervalMaximum, interval)
            }

            guard observation.accepted else {
                duplicateCount += 1
                return
            }

            acceptedCount += 1
            timerDiscontinuityCount += observation.timerDiscontinuity ? 1 : 0

            if let interval = observation.acceptedIntervalMilliseconds {
                acceptedIntervalTotal += interval
                acceptedIntervalCount += 1
                acceptedIntervalMaximum = max(acceptedIntervalMaximum, interval)
            }
            if let delta = observation.timerDeltaTicks, delta > 0 {
                timerDeltaTotal += delta
                timerDeltaCount += 1
                timerDeltaMinimum = min(timerDeltaMinimum ?? delta, delta)
                timerDeltaMaximum = max(timerDeltaMaximum ?? delta, delta)
            }
        }

        func summary(endingAt timestamp: TimeInterval) -> JoyConTransportSummary? {
            guard callbackCount > 0 else { return nil }
            let duration = max(0.001, timestamp - startedAt)
            return JoyConTransportSummary(
                duration: duration,
                callbackCount: callbackCount,
                acceptedCount: acceptedCount,
                duplicateCount: duplicateCount,
                timerDiscontinuityCount: timerDiscontinuityCount,
                callbackRate: Double(callbackCount) / duration,
                acceptedRate: Double(acceptedCount) / duration,
                averageCallbackIntervalMilliseconds: Self.average(callbackIntervalTotal, callbackIntervalCount),
                maximumCallbackIntervalMilliseconds: callbackIntervalCount > 0 ? callbackIntervalMaximum : nil,
                averageAcceptedIntervalMilliseconds: Self.average(acceptedIntervalTotal, acceptedIntervalCount),
                maximumAcceptedIntervalMilliseconds: acceptedIntervalCount > 0 ? acceptedIntervalMaximum : nil,
                averageTimerDeltaTicks: timerDeltaCount > 0 ? Double(timerDeltaTotal) / Double(timerDeltaCount) : nil,
                minimumTimerDeltaTicks: timerDeltaMinimum,
                maximumTimerDeltaTicks: timerDeltaMaximum
            )
        }

        private static func average(_ total: Double, _ count: Int) -> Double? {
            count > 0 ? total / Double(count) : nil
        }
    }

    let interval: TimeInterval
    private var window: Window?

    init(interval: TimeInterval = 5) {
        self.interval = max(0.1, interval)
    }

    mutating func record(
        _ observation: JoyConPacketTimingObservation,
        at timestamp: TimeInterval
    ) -> JoyConTransportSummary? {
        var current = window ?? Window(startedAt: timestamp)
        current.record(observation)
        guard timestamp - current.startedAt >= interval else {
            window = current
            return nil
        }
        window = nil
        return current.summary(endingAt: timestamp)
    }

    mutating func flush(at timestamp: TimeInterval) -> JoyConTransportSummary? {
        defer { window = nil }
        return window?.summary(endingAt: timestamp)
    }
}
