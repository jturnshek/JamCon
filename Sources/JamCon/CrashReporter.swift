import Foundation
import Darwin

// Keep signal-handler state in globals so the handler doesn't need to touch Swift/ObjC runtime state.
private var crashLogFD: Int32 = -1
private var crashLogDidWrite: sig_atomic_t = 0

@inline(__always)
private func writeStatic(_ fd: Int32, _ s: StaticString) {
    _ = Darwin.write(fd, s.utf8Start, s.utf8CodeUnitCount)
}

@inline(__always)
private func writeSignalCrashMarker(_ signal: Int32) {
    // Best-effort: avoid re-entrant writes if we crash while handling a signal.
    if crashLogDidWrite != 0 { return }
    crashLogDidWrite = 1

    let fd: Int32 = crashLogFD >= 0 ? crashLogFD : STDERR_FILENO

    writeStatic(fd, "\n=== JamCon Crash ===\n")
    switch signal {
    case SIGSEGV: writeStatic(fd, "signal: SIGSEGV (11)\n")
    case SIGABRT: writeStatic(fd, "signal: SIGABRT (6)\n")
    case SIGBUS: writeStatic(fd, "signal: SIGBUS (10)\n")
    case SIGFPE: writeStatic(fd, "signal: SIGFPE (8)\n")
    case SIGILL: writeStatic(fd, "signal: SIGILL (4)\n")
    case SIGTRAP: writeStatic(fd, "signal: SIGTRAP (5)\n")
    default: writeStatic(fd, "signal: UNKNOWN\n")
    }
}

// Global signal handler function (required because C function pointers cannot capture context)
private func crashSignalHandler(_ sig: Int32) {
    // Async-signal-safe: only write() + restore/re-raise.
    writeSignalCrashMarker(sig)
    Darwin.signal(sig, SIG_DFL)
    Darwin.raise(sig)
    Darwin._exit(sig)
}

// Global exception handler function
private func crashExceptionHandler(_ exception: NSException) {
    CrashReporter.handleException(exception)
}

/// Simple crash reporter that catches fatal signals and logs crash info
enum CrashReporter {
    private static let logDirectory = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs/JamCon")
    private static let crashLogPath = logDirectory.appendingPathComponent("crash.log")

    /// Install signal handlers to catch crashes
    static func install() {
        crashLogDidWrite = 0

        // Create log directory if needed
        try? FileManager.default.createDirectory(at: logDirectory, withIntermediateDirectories: true)

        // Open a crash log fd up front so the signal handler can use async-signal-safe write().
        crashLogFD = crashLogPath.path.withCString {
            Darwin.open($0, O_WRONLY | O_CREAT | O_APPEND, S_IRUSR | S_IWUSR)
        }

        // Install handlers for common crash signals
        signal(SIGSEGV, crashSignalHandler)
        signal(SIGABRT, crashSignalHandler)
        signal(SIGBUS, crashSignalHandler)
        signal(SIGFPE, crashSignalHandler)
        signal(SIGILL, crashSignalHandler)
        signal(SIGTRAP, crashSignalHandler)

        // Set uncaught exception handler for Objective-C exceptions
        NSSetUncaughtExceptionHandler(crashExceptionHandler)
    }

    /// Check if there was a crash on the previous run
    static func checkForPreviousCrash() -> String? {
        guard FileManager.default.fileExists(atPath: crashLogPath.path) else { return nil }

        do {
            let content = try String(contentsOf: crashLogPath, encoding: .utf8)
            // Delete the crash log after reading
            try FileManager.default.removeItem(at: crashLogPath)
            return content
        } catch {
            return nil
        }
    }

    static func handleException(_ exception: NSException) {
        let timestamp = ISO8601DateFormatter().string(from: Date())

        var crashInfo = """
        === JamCon Crash Report ===
        Time: \(timestamp)
        Exception: \(exception.name.rawValue)
        Reason: \(exception.reason ?? "Unknown")

        Stack Trace:
        """

        for (index, frame) in exception.callStackSymbols.enumerated() {
            crashInfo += "\n\(index): \(frame)"
        }

        crashInfo += "\n\n"

        writeCrashLog(crashInfo)
    }

    private static func writeCrashLog(_ content: String) {
        // Create directory if needed
        try? FileManager.default.createDirectory(at: logDirectory, withIntermediateDirectories: true)

        // Append to crash log
        if let data = content.data(using: .utf8) {
            if FileManager.default.fileExists(atPath: crashLogPath.path) {
                if let handle = try? FileHandle(forWritingTo: crashLogPath) {
                    handle.seekToEndOfFile()
                    handle.write(data)
                    handle.closeFile()
                }
            } else {
                try? data.write(to: crashLogPath)
            }
        }
    }
}
