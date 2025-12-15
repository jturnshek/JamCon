import Foundation
import os
import os.lock
import Dispatch

enum JamLog {
    enum Category: String {
        case app = "App"
        case ui = "UI"
        case engine = "Engine"
        case sense = "Sense"
        case joyCon = "JoyCon"
        case g502x = "G502X"
    }

    private static let subsystem: String = Bundle.main.bundleIdentifier ?? "com.jamcon.app"

    private static let appLogger = Logger(subsystem: subsystem, category: Category.app.rawValue)
    private static let uiLogger = Logger(subsystem: subsystem, category: Category.ui.rawValue)
    private static let engineLogger = Logger(subsystem: subsystem, category: Category.engine.rawValue)
    private static let senseLogger = Logger(subsystem: subsystem, category: Category.sense.rawValue)
    private static let joyConLogger = Logger(subsystem: subsystem, category: Category.joyCon.rawValue)
    private static let g502xLogger = Logger(subsystem: subsystem, category: Category.g502x.rawValue)

    private struct MirrorState {
        var debugBuffer: DebugBuffer?
        var enabled: Bool = true
    }

    private static let mirrorLock = OSAllocatedUnfairLock(initialState: MirrorState())

    private struct ThrottleState {
        var lastByKey: [String: UInt64] = [:]
    }

    private static let throttleLock = OSAllocatedUnfairLock(initialState: ThrottleState())

    static func setMirror(_ debugBuffer: DebugBuffer?) {
        mirrorLock.withLock { state in
            state.debugBuffer = debugBuffer
        }
    }

    static func setMirrorEnabled(_ enabled: Bool) {
        mirrorLock.withLock { state in
            state.enabled = enabled
        }
    }

    static func debug(_ category: Category, _ message: @autoclosure () -> String) {
        log(category, type: .debug, message())
    }

    static func info(_ category: Category, _ message: @autoclosure () -> String) {
        log(category, type: .info, message())
    }

    static func error(_ category: Category, _ message: @autoclosure () -> String) {
        log(category, type: .error, message())
    }

    static func debugThrottled(_ category: Category, key: String, interval: TimeInterval, _ message: @autoclosure () -> String) {
        guard shouldLog(throttleKey: "\(category.rawValue).debug.\(key)", interval: interval) else { return }
        debug(category, message())
    }

    static func infoThrottled(_ category: Category, key: String, interval: TimeInterval, _ message: @autoclosure () -> String) {
        guard shouldLog(throttleKey: "\(category.rawValue).info.\(key)", interval: interval) else { return }
        info(category, message())
    }

    static func errorThrottled(_ category: Category, key: String, interval: TimeInterval, _ message: @autoclosure () -> String) {
        guard shouldLog(throttleKey: "\(category.rawValue).error.\(key)", interval: interval) else { return }
        error(category, message())
    }

    // MARK: - Internals

    private static func logger(for category: Category) -> Logger {
        switch category {
        case .app: return appLogger
        case .ui: return uiLogger
        case .engine: return engineLogger
        case .sense: return senseLogger
        case .joyCon: return joyConLogger
        case .g502x: return g502xLogger
        }
    }

    private static func log(_ category: Category, type: OSLogType, _ message: String) {
        logger(for: category).log(level: type, "\(message, privacy: .public)")

        let mirror: (DebugBuffer?, Bool) = mirrorLock.withLock { state in
            (state.debugBuffer, state.enabled)
        }
        guard mirror.1, let buffer = mirror.0 else { return }
        buffer.log("[\(category.rawValue)] \(message)")
    }

    private static func shouldLog(throttleKey: String, interval: TimeInterval) -> Bool {
        let now = DispatchTime.now().uptimeNanoseconds
        let nsDouble = max(0, interval) * 1_000_000_000
        let intervalNs = UInt64(min(nsDouble, Double(UInt64.max)))

        return throttleLock.withLock { state in
            if let last = state.lastByKey[throttleKey], now &- last < intervalNs {
                return false
            }
            state.lastByKey[throttleKey] = now
            return true
        }
    }
}

