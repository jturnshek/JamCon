import XCTest
@testable import JamCon

final class BoundedFileLogTests: XCTestCase {
    func testRotatingLogKeepsRecentEntriesWithinByteLimit() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("JamConFileLogTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let log = BoundedFileLog(
            directoryURL: directory,
            maxFileBytes: 256,
            archiveCount: 2,
            maxPendingEntries: 64
        )

        for index in 0..<40 {
            log.enqueue(
                BoundedFileLog.Entry(
                    timestamp: Date(timeIntervalSince1970: TimeInterval(index)),
                    level: "INFO",
                    category: "Test",
                    message: "event-\(index) " + String(repeating: "x", count: 70)
                )
            )
        }
        log.flush()

        let existingURLs = log.allLogURLs().filter {
            FileManager.default.fileExists(atPath: $0.path)
        }
        XCTAssertFalse(existingURLs.isEmpty)
        XCTAssertLessThanOrEqual(existingURLs.count, 3)

        for url in existingURLs {
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            let size = try XCTUnwrap(attributes[.size] as? NSNumber)
            XCTAssertLessThanOrEqual(size.intValue, 256)
        }

        let current = try String(contentsOf: log.currentLogURL, encoding: .utf8)
        XCTAssertTrue(current.contains("event-39"))
        let retained = try existingURLs.map { try String(contentsOf: $0, encoding: .utf8) }.joined()
        XCTAssertFalse(retained.contains("event-0 "))
    }

    func testLogEscapesEmbeddedNewlines() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("JamConFileLogTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let log = BoundedFileLog(directoryURL: directory, archiveCount: 0)
        log.enqueue(
            BoundedFileLog.Entry(
                timestamp: Date(timeIntervalSince1970: 0),
                level: "ERROR",
                category: "Test",
                message: "first\nsecond"
            )
        )
        log.flush()

        let contents = try String(contentsOf: log.currentLogURL, encoding: .utf8)
        XCTAssertTrue(contents.contains("first\\nsecond"))
        XCTAssertEqual(contents.filter { $0 == "\n" }.count, 1)
        XCTAssertEqual(log.allLogURLs(), [log.currentLogURL])
    }
}
