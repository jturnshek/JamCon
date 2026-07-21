import Foundation
import Dispatch
import os.lock

/// A low-priority, bounded rotating text log.
///
/// Callers enqueue semantic events or periodic aggregates. File I/O is kept off
/// input-processing threads, pending entries are bounded, and old files rotate
/// away so diagnostics cannot grow without limit.
final class BoundedFileLog: @unchecked Sendable {
    struct Entry: Sendable {
        let timestamp: Date
        let level: String
        let category: String
        let message: String
    }

    private struct PendingState {
        var entries: [Entry] = []
        var droppedEntryCount = 0
        var drainScheduled = false
    }

    let currentLogURL: URL
    let maxFileBytes: Int
    let archiveCount: Int

    private let directoryURL: URL
    private let maxPendingEntries: Int
    private let ioQueue = DispatchQueue(label: "com.jamcon.file-log", qos: .utility)
    private let pendingLock = OSAllocatedUnfairLock(initialState: PendingState())
    private let dateFormatter: ISO8601DateFormatter

    init(
        directoryURL: URL,
        fileName: String = "JamCon.log",
        maxFileBytes: Int = 512 * 1024,
        archiveCount: Int = 2,
        maxPendingEntries: Int = 512
    ) {
        self.directoryURL = directoryURL
        self.currentLogURL = directoryURL.appendingPathComponent(fileName, isDirectory: false)
        self.maxFileBytes = max(256, maxFileBytes)
        self.archiveCount = max(0, archiveCount)
        self.maxPendingEntries = max(1, maxPendingEntries)

        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        self.dateFormatter = formatter
    }

    func enqueue(_ entry: Entry) {
        let shouldSchedule = pendingLock.withLock { state -> Bool in
            if state.entries.count >= maxPendingEntries {
                // Keep the most recent diagnostics if producers temporarily
                // outrun the utility queue.
                state.entries.removeFirst()
                state.droppedEntryCount += 1
            }
            state.entries.append(entry)

            guard !state.drainScheduled else { return false }
            state.drainScheduled = true
            return true
        }

        guard shouldSchedule else { return }
        ioQueue.async { [self] in
            drainPendingEntries()
        }
    }

    /// Wait until every entry already submitted has reached the filesystem.
    /// Intended for orderly shutdown and deterministic tests, not HID paths.
    func flush() {
        ioQueue.sync {}
    }

    func allLogURLs() -> [URL] {
        guard archiveCount > 0 else { return [currentLogURL] }
        return [currentLogURL] + (1...archiveCount).map(archiveURL)
    }

    private func drainPendingEntries() {
        while true {
            let batch = pendingLock.withLock { state -> ([Entry], Int)? in
                guard !state.entries.isEmpty || state.droppedEntryCount > 0 else {
                    state.drainScheduled = false
                    return nil
                }

                let entries = state.entries
                let dropped = state.droppedEntryCount
                state.entries.removeAll(keepingCapacity: true)
                state.droppedEntryCount = 0
                return (entries, dropped)
            }

            guard let batch else { return }

            if batch.1 > 0 {
                write(
                    Entry(
                        timestamp: Date(),
                        level: "WARN",
                        category: "Log",
                        message: "Dropped \(batch.1) pending log entries; retained the newest entries"
                    )
                )
            }
            for entry in batch.0 {
                write(entry)
            }
        }
    }

    private func write(_ entry: Entry) {
        do {
            try FileManager.default.createDirectory(
                at: directoryURL,
                withIntermediateDirectories: true
            )

            let data = boundedData(for: render(entry))
            let currentSize = fileSize(at: currentLogURL)
            if currentSize > 0, currentSize + data.count > maxFileBytes {
                try rotate()
            }

            if !FileManager.default.fileExists(atPath: currentLogURL.path) {
                _ = FileManager.default.createFile(atPath: currentLogURL.path, contents: nil)
            }

            let handle = try FileHandle(forWritingTo: currentLogURL)
            try handle.seekToEnd()
            try handle.write(contentsOf: data)
            try handle.close()
        } catch {
            // Unified Logging remains the fallback. Do not recursively log a
            // failure from the file-log sink itself.
        }
    }

    private func render(_ entry: Entry) -> String {
        let singleLineMessage = entry.message
            .replacingOccurrences(of: "\r", with: "\\r")
            .replacingOccurrences(of: "\n", with: "\\n")
        return "\(dateFormatter.string(from: entry.timestamp)) [\(entry.level)] [\(entry.category)] \(singleLineMessage)\n"
    }

    private func boundedData(for line: String) -> Data {
        let data = Data(line.utf8)
        guard data.count > maxFileBytes else { return data }

        let marker = Data("… [truncated]\n".utf8)
        guard marker.count < maxFileBytes else {
            return Data(data.prefix(maxFileBytes))
        }
        var result = Data(data.prefix(maxFileBytes - marker.count))
        result.append(marker)
        return result
    }

    private func rotate() throws {
        let manager = FileManager.default

        guard archiveCount > 0 else {
            try? manager.removeItem(at: currentLogURL)
            return
        }

        try? manager.removeItem(at: archiveURL(archiveCount))
        if archiveCount > 1 {
            for index in stride(from: archiveCount, through: 2, by: -1) {
                let source = archiveURL(index - 1)
                guard manager.fileExists(atPath: source.path) else { continue }
                try? manager.removeItem(at: archiveURL(index))
                try manager.moveItem(at: source, to: archiveURL(index))
            }
        }

        if manager.fileExists(atPath: currentLogURL.path) {
            try? manager.removeItem(at: archiveURL(1))
            try manager.moveItem(at: currentLogURL, to: archiveURL(1))
        }
    }

    private func archiveURL(_ index: Int) -> URL {
        URL(fileURLWithPath: currentLogURL.path + ".\(index)")
    }

    private func fileSize(at url: URL) -> Int {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attributes[.size] as? NSNumber else {
            return 0
        }
        return size.intValue
    }
}
