import XCTest
@testable import JamCon

final class DebugBufferTests: XCTestCase {
    func testStoresFullSenseReportByDefault() {
        let buffer = DebugBuffer()
        buffer.startRecording()
        let bytes = (0..<SenseHIDProtocol.reportLength).map(UInt8.init)

        buffer.record(
            bytes: bytes,
            length: bytes.count,
            rawGyro: (0, 0, 0),
            remappedGyro: (0, 0, 0),
            normalizedGyro: (0, 0, 0),
            accel: (0, 0, 0),
            buttonStates: [],
            controllerKind: .sense
        )

        XCTAssertEqual(buffer.latest()?.reportBytes, bytes)
        XCTAssertEqual(buffer.latest()?.reportLength, SenseHIDProtocol.reportLength)
    }

    func testPipelineTimingUsesMonotonicBoundaries() {
        let timing = DebugBuffer.PipelineTiming(
            reportTimestamp: 10.000,
            receivedTimestamp: 10.001,
            engineStartTimestamp: 10.003,
            engineEndTimestamp: 10.007
        )

        XCTAssertEqual(timing.inputAgeMilliseconds, 7, accuracy: 0.000_1)
        XCTAssertEqual(timing.queueDelayMilliseconds, 2, accuracy: 0.000_1)
        XCTAssertEqual(timing.processingMilliseconds, 4, accuracy: 0.000_1)
    }
}
