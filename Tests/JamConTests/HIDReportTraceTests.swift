import XCTest
@testable import JamCon

final class HIDReportTraceTests: XCTestCase {
    func testTraceRoundTripsThroughVersionedJSON() throws {
        let trace = HIDReportTrace(
            createdAt: Date(timeIntervalSince1970: 0),
            records: [
                HIDReportTraceRecord(
                    offsetNanoseconds: 12_000_000,
                    device: ManagedDeviceKey(kind: .joyCon, id: "right"),
                    reportID: JoyConHIDProtocol.inputReportID,
                    stage: .engineInput,
                    bytes: [0x30, 0x01, 0x02]
                ),
            ]
        )

        let data = try HIDReportTraceCodec.encode(trace)
        XCTAssertEqual(try HIDReportTraceCodec.decode(data), trace)
    }

    func testUnsupportedTraceVersionIsRejected() {
        let json = #"{"schemaVersion":99,"createdAt":"1970-01-01T00:00:00Z","records":[]}"#

        XCTAssertThrowsError(try HIDReportTraceCodec.decode(Data(json.utf8)))
    }

    func testRecorderPreservesRelativeMonotonicTiming() {
        let recorder = HIDReportTraceRecorder()
        let device = ManagedDeviceKey(kind: .sense, id: "right")
        recorder.start()
        recorder.record(device: device, reportID: 0x31, bytes: [1], timestamp: 100.0)
        recorder.record(device: device, reportID: 0x31, bytes: [2], timestamp: 100.025)

        let trace = recorder.snapshot(createdAt: Date(timeIntervalSince1970: 0))

        XCTAssertEqual(trace.records.map(\.offsetNanoseconds), [0, 25_000_000])
    }

    func testReplayIsStableAndCanDrivePureDecoder() throws {
        var senseBytes = [UInt8](repeating: 0, count: SenseHIDProtocol.reportLength)
        write(321, to: &senseBytes, at: SenseHIDProtocol.Offset.gyroXLow)
        let device = ManagedDeviceKey(kind: .sense, id: "right")
        let trace = HIDReportTrace(
            records: [
                HIDReportTraceRecord(
                    offsetNanoseconds: 20,
                    device: device,
                    reportID: 0x31,
                    stage: .engineInput,
                    bytes: senseBytes
                ),
                HIDReportTraceRecord(
                    offsetNanoseconds: 10,
                    device: device,
                    reportID: 0x31,
                    stage: .engineInput,
                    bytes: senseBytes
                ),
            ]
        )
        var timestamps: [TimeInterval] = []
        var gyroValues: [Int16] = []

        try HIDReportTraceReplayer.replay(trace, startingAt: 5) { record, timestamp in
            timestamps.append(timestamp)
            gyroValues.append(try SenseInputReportDecoder.decode(record.bytes).motion.gyroX)
        }

        XCTAssertEqual(timestamps, [5.000_000_01, 5.000_000_02])
        XCTAssertEqual(gyroValues, [321, 321])
    }

    private func write(_ value: Int16, to bytes: inout [UInt8], at offset: Int) {
        let bits = UInt16(bitPattern: value)
        bytes[offset] = UInt8(bits & 0xFF)
        bytes[offset + 1] = UInt8(bits >> 8)
    }
}
