import Foundation

// Global signal handler function (required because C function pointers cannot capture context)
private func crashSignalHandler(_ sig: Int32) {
    CrashReporter.handleSignal(sig)
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
        // Create log directory if needed
        try? FileManager.default.createDirectory(at: logDirectory, withIntermediateDirectories: true)

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

    static func handleSignal(_ signal: Int32) {
        let signalName = signalName(for: signal)
        let timestamp = ISO8601DateFormatter().string(from: Date())

        var crashInfo = """
        === JamCon Crash Report ===
        Time: \(timestamp)
        Signal: \(signalName) (\(signal))

        Stack Trace:
        """

        // Get stack trace
        let callStack = Thread.callStackSymbols
        for (index, frame) in callStack.enumerated() {
            crashInfo += "\n\(index): \(frame)"
        }

        crashInfo += "\n\n"

        // Write to file
        writeCrashLog(crashInfo)

        // Re-raise signal to get default behavior (terminate)
        Darwin.signal(signal, SIG_DFL)
        Darwin.raise(signal)
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

    private static func signalName(for signal: Int32) -> String {
        switch signal {
        case SIGSEGV: return "SIGSEGV (Segmentation Fault)"
        case SIGABRT: return "SIGABRT (Abort)"
        case SIGBUS: return "SIGBUS (Bus Error)"
        case SIGFPE: return "SIGFPE (Floating Point Exception)"
        case SIGILL: return "SIGILL (Illegal Instruction)"
        case SIGTRAP: return "SIGTRAP (Trace Trap)"
        default: return "Unknown Signal"
        }
    }
}
