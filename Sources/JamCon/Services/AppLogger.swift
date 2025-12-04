import Foundation
import os.lock

/// Centralized logging service that captures logs for in-app display
@MainActor
final class AppLogger: ObservableObject {

    // MARK: - Singleton

    static let shared = AppLogger()

    // MARK: - Log Entry

    struct LogEntry: Identifiable {
        let id = UUID()
        let timestamp: Date
        let category: String
        let message: String
        let level: Level

        enum Level: String {
            case debug = "DEBUG"
            case info = "INFO"
            case warning = "WARN"
            case error = "ERROR"

            var color: String {
                switch self {
                case .debug: return "gray"
                case .info: return "blue"
                case .warning: return "orange"
                case .error: return "red"
                }
            }
        }
    }

    // MARK: - State

    @Published private(set) var entries: [LogEntry] = []

    /// Maximum number of entries to keep
    private let maxEntries = 1000

    /// Date formatter for log timestamps
    private let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()

    private init() {}

    // MARK: - Logging Methods

    func debug(_ message: String, category: String = "App") {
        addEntry(message: message, category: category, level: .debug)
    }

    func info(_ message: String, category: String = "App") {
        addEntry(message: message, category: category, level: .info)
    }

    func warning(_ message: String, category: String = "App") {
        addEntry(message: message, category: category, level: .warning)
    }

    func error(_ message: String, category: String = "App") {
        addEntry(message: message, category: category, level: .error)
    }

    func clear() {
        entries.removeAll()
    }

    // MARK: - Private

    private func addEntry(message: String, category: String, level: LogEntry.Level) {
        let entry = LogEntry(
            timestamp: Date(),
            category: category,
            message: message,
            level: level
        )

        entries.append(entry)

        // Trim if over limit
        if entries.count > maxEntries {
            entries.removeFirst(entries.count - maxEntries)
        }

        // Also print to console for debugging
        print("[\(category)] \(level.rawValue): \(message)")
    }

    /// Format a log entry for display
    func format(_ entry: LogEntry) -> String {
        let time = dateFormatter.string(from: entry.timestamp)
        return "\(time) [\(entry.category)] \(entry.message)"
    }
}

// MARK: - Global Logging Functions

/// Log a debug message
func logDebug(_ message: String, category: String = "App") {
    Task { @MainActor in
        AppLogger.shared.debug(message, category: category)
    }
}

/// Log an info message
func logInfo(_ message: String, category: String = "App") {
    Task { @MainActor in
        AppLogger.shared.info(message, category: category)
    }
}

/// Log a warning message
func logWarning(_ message: String, category: String = "App") {
    Task { @MainActor in
        AppLogger.shared.warning(message, category: category)
    }
}

/// Log an error message
func logError(_ message: String, category: String = "App") {
    Task { @MainActor in
        AppLogger.shared.error(message, category: category)
    }
}
