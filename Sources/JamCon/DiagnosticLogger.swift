import Foundation
import os.log

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
