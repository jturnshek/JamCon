import XCTest
@testable import JamCon

final class HIDReportDecoderTests: XCTestCase {
    func testSenseDecoderReadsSignedLittleEndianMotion() throws {
        var bytes = [UInt8](repeating: 0, count: SenseHIDProtocol.reportLength)
        write(-1_234, to: &bytes, at: SenseHIDProtocol.Offset.gyroXLow)
        write(2_345, to: &bytes, at: SenseHIDProtocol.Offset.gyroYLow)
        write(-3_456, to: &bytes, at: SenseHIDProtocol.Offset.gyroZLow)
        write(4_096, to: &bytes, at: SenseHIDProtocol.Offset.accelXLow)
        write(-4_096, to: &bytes, at: SenseHIDProtocol.Offset.accelYLow)
        write(512, to: &bytes, at: SenseHIDProtocol.Offset.accelZLow)

        let decoded = try SenseInputReportDecoder.decode(bytes)

        XCTAssertEqual(decoded.motion, IMUSample(
            accelX: 4_096,
            accelY: -4_096,
            accelZ: 512,
            gyroX: -1_234,
            gyroY: 2_345,
            gyroZ: -3_456
        ))
    }

    func testJoyConDecoderPreservesAllThreeIMUSamplesAndAverage() throws {
        var bytes = [UInt8](repeating: 0, count: JoyConHIDProtocol.reportLength)
        let bases = [
            JoyConHIDProtocol.Offset.imuSample0,
            JoyConHIDProtocol.Offset.imuSample1,
            JoyConHIDProtocol.Offset.imuSample2,
        ]

        for (index, base) in bases.enumerated() {
            let value = Int16((index + 1) * 100)
            write(value, to: &bytes, at: base)
            write(-value, to: &bytes, at: base + 2)
            write(value / 2, to: &bytes, at: base + 4)
            write(value, to: &bytes, at: base + 6)
            write(value * 2, to: &bytes, at: base + 8)
            write(-value, to: &bytes, at: base + 10)
        }

        let decoded = try JoyConInputReportDecoder.decode(bytes)

        XCTAssertEqual(decoded.motionSamples.count, 3)
        XCTAssertEqual(decoded.latest.gyroX, 300)
        XCTAssertEqual(decoded.latest.accelY, -300)
        XCTAssertEqual(decoded.averagedGyro.x, 200)
        XCTAssertEqual(decoded.averagedGyro.y, 400)
        XCTAssertEqual(decoded.averagedGyro.z, -200)
    }

    func testShortReportsAreRejectedInsteadOfProducingZeroMotion() {
        XCTAssertThrowsError(try SenseInputReportDecoder.decode([0, 1, 2]))
        XCTAssertThrowsError(try JoyConInputReportDecoder.decode([0, 1, 2]))
    }

    private func write(_ value: Int16, to bytes: inout [UInt8], at offset: Int) {
        let bits = UInt16(bitPattern: value)
        bytes[offset] = UInt8(bits & 0xFF)
        bytes[offset + 1] = UInt8(bits >> 8)
    }
}
