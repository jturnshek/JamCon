import Foundation
import os

enum HIDTraceStage: String, Codable, Sendable {
    /// Stable byte snapshot delivered from a device adapter to InputEngine.
    /// For G502X this is the adapter's unified button report, not one raw interface frame.
    case engineInput
}

struct HIDReportTraceRecord: Codable, Equatable, Sendable {
    let offsetNanoseconds: UInt64
    let device: ManagedDeviceKey
    let reportID: UInt32
    let stage: HIDTraceStage
    let bytes: [UInt8]
}

struct HIDReportTrace: Codable, Equatable, Sendable {
    static let currentSchemaVersion = 1

    let schemaVersion: Int
    let createdAt: Date
    let records: [HIDReportTraceRecord]

    init(createdAt: Date = Date(), records: [HIDReportTraceRecord]) {
        self.schemaVersion = Self.currentSchemaVersion
        self.createdAt = createdAt
        self.records = records
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
        guard schemaVersion == Self.currentSchemaVersion else {
            throw DecodingError.dataCorruptedError(
                forKey: .schemaVersion,
                in: container,
                debugDescription: "Unsupported HID trace schema version \(schemaVersion)"
            )
        }

        self.schemaVersion = schemaVersion
        self.createdAt = try container.decode(Date.self, forKey: .createdAt)
        self.records = try container.decode([HIDReportTraceRecord].self, forKey: .records)
    }
}

final class HIDReportTraceRecorder: @unchecked Sendable {
    private struct State {
        var firstTimestamp: TimeInterval?
        var records: [HIDReportTraceRecord] = []
    }

    private let lock = OSAllocatedUnfairLock(initialState: State())

    func start() {
        lock.withLock { state in
            state.firstTimestamp = nil
            state.records.removeAll(keepingCapacity: true)
        }
    }

    func record(
        device: ManagedDeviceKey,
        reportID: UInt32,
        stage: HIDTraceStage = .engineInput,
        bytes: [UInt8],
        timestamp: TimeInterval
    ) {
        lock.withLock { state in
            let firstTimestamp = state.firstTimestamp ?? timestamp
            state.firstTimestamp = firstTimestamp
            let elapsed = max(0, timestamp - firstTimestamp)
            state.records.append(
                HIDReportTraceRecord(
                    offsetNanoseconds: UInt64((elapsed * 1_000_000_000).rounded()),
                    device: device,
                    reportID: reportID,
                    stage: stage,
                    bytes: bytes
                )
            )
        }
    }

    func snapshot(createdAt: Date = Date()) -> HIDReportTrace {
        let records = lock.withLock { $0.records }
        return HIDReportTrace(createdAt: createdAt, records: records)
    }

    func clear() {
        start()
    }
}

enum HIDReportTraceCodec {
    static func encode(_ trace: HIDReportTrace, prettyPrinted: Bool = true) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        if prettyPrinted {
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        }
        return try encoder.encode(trace)
    }

    static func decode(_ data: Data) throws -> HIDReportTrace {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(HIDReportTrace.self, from: data)
    }
}

enum HIDReportTraceReplayer {
    /// Replays immediately and deterministically. The callback receives a
    /// synthetic monotonic timestamp preserving each captured offset.
    static func replay(
        _ trace: HIDReportTrace,
        startingAt timestamp: TimeInterval = 0,
        handler: (HIDReportTraceRecord, TimeInterval) throws -> Void
    ) rethrows {
        let ordered = trace.records.enumerated().sorted { lhs, rhs in
            if lhs.element.offsetNanoseconds == rhs.element.offsetNanoseconds {
                return lhs.offset < rhs.offset
            }
            return lhs.element.offsetNanoseconds < rhs.element.offsetNanoseconds
        }

        for entry in ordered {
            let recordTimestamp = timestamp + TimeInterval(entry.element.offsetNanoseconds) / 1_000_000_000
            try handler(entry.element, recordTimestamp)
        }
    }
}
