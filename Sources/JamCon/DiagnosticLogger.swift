import Foundation
import os.log
import QuartzCore
import os.lock

/// Simple diagnostic logger for debugging click behavior
class DiagnosticLogger {
    static let shared = DiagnosticLogger()

    private let logger = Logger(subsystem: "com.jamcon.app", category: "trigger")

    private init() {
        log("=== JamCon Trigger Diagnostics Started ===")
    }

    func log(_ message: String) {
        // Use both os_log and NSLog to ensure visibility
        logger.notice("\(message, privacy: .public)")
        NSLog("[JamCon] %@", message)
    }
}

/// Lightweight, opt-in latency probe for the gyro path.
/// Enable by setting environment variable JAMCON_LATENCY_PROBE=1 before launch.
final class DiagnosticLatencyProbe {
    enum Stage: String {
        case hid          // IOHIDValue callback (JoyConSwift sensor handler)
        case postDecode   // After decoding gyro sample
        case preProcess   // Right before processGyro
        case postProcess  // After processGyro math
        case preEvent     // Right before posting CGEvent
        case postEvent    // Immediately after CGEvent post returns
    }

    static let shared = DiagnosticLatencyProbe(
        enabled: ProcessInfo.processInfo.environment["JAMCON_LATENCY_PROBE"] == "1"
    )

    private let enabled: Bool
    private let lock = OSAllocatedUnfairLock(initialState: [UInt64: SampleTimeline]())
    private var counter: UInt64 = 0
    private let maxSamples = 256

    private init(enabled: Bool) {
        self.enabled = enabled
    }

    struct SampleTimeline {
        var hid: TimeInterval?
        var postDecode: TimeInterval?
        var preProcess: TimeInterval?
        var postProcess: TimeInterval?
        var preEvent: TimeInterval?
        var postEvent: TimeInterval?
        var sampleAge: TimeInterval?
    }

    /// Generate a stable ID; callers typically won't need this if they pass the sample timestamp.
    func nextSampleId() -> UInt64 {
        lock.withLock { _ in
            counter &+= 1
            return counter
        }
    }

    /// Use the sample's monotonic timestamp to form a key (exact bit pattern to avoid rounding drift).
    private func key(for sampleTimestamp: TimeInterval) -> UInt64 {
        return sampleTimestamp.bitPattern
    }

    func mark(_ stage: Stage, sampleTimestamp: TimeInterval, now: TimeInterval = CACurrentMediaTime()) {
        guard enabled else { return }
        let key = self.key(for: sampleTimestamp)

        lock.withLock { state in
            var timeline = state[key] ?? SampleTimeline()
            switch stage {
            case .hid:
                timeline.hid = now
                timeline.sampleAge = now - sampleTimestamp
            case .postDecode: timeline.postDecode = now
            case .preProcess: timeline.preProcess = now
            case .postProcess: timeline.postProcess = now
            case .preEvent: timeline.preEvent = now
            case .postEvent: timeline.postEvent = now
            }
            state[key] = timeline

            // Keep map bounded
            if state.count > maxSamples {
                state.remove(at: state.startIndex)
            }

            // When we hit postEvent, emit deltas and drop the sample
            if stage == .postEvent {
                let hid = timeline.hid
                let postDecode = timeline.postDecode
                let preProcess = timeline.preProcess
                let postProcess = timeline.postProcess
                let preEvent = timeline.preEvent ?? now
                let postEvent = timeline.postEvent ?? now

                let hidToDecode = (hid != nil && postDecode != nil) ? postDecode! - hid! : nil
                let decodeToProcess = (postDecode != nil && preProcess != nil) ? preProcess! - postDecode! : nil
                let processToPost = (preProcess != nil && postProcess != nil) ? postProcess! - preProcess! : nil
                let postToEvent = (postProcess != nil) ? preEvent - postProcess! : nil
                let eventDuration = postEvent - preEvent
                let total = (hid != nil) ? postEvent - hid! : nil
                let age = timeline.sampleAge

                func fmt(_ v: TimeInterval?) -> String {
                    guard let v else { return "-" }
                    return String(format: "%.3f", v * 1000.0) // ms
                }

                print("[LatencyProbe] age:\(fmt(age)) hid→decode:\(fmt(hidToDecode)) decode→process:\(fmt(decodeToProcess)) process→post:\(fmt(processToPost)) post→event:\(fmt(postToEvent)) event:\(fmt(eventDuration)) total:\(fmt(total)) ms")

                state.removeValue(forKey: key)
            }
        }
    }
}
