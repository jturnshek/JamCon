import XCTest
@testable import JamCon

final class HIDButtonMappingTests: XCTestCase {
    func testRightSensePhysicalButtonAndTriggerOffsets() {
        var bytes = [UInt8](repeating: 0, count: SenseHIDProtocol.reportLength)
        bytes[SenseHIDProtocol.Offset.faceButtons] = SenseHIDProtocol.FaceButtonMask.circleButton
            | SenseHIDProtocol.FaceButtonMask.rightGrip
        bytes[SenseHIDProtocol.Offset.systemButtons] = SenseHIDProtocol.SystemButtonMask.optionsButton
            | SenseHIDProtocol.SystemButtonMask.rightStickClick
        bytes[SenseHIDProtocol.Offset.triggerAnalog] = 201
        let mapping = SenseButtonMapping(isLeft: false)

        XCTAssertTrue(mapping.isPressed(.faceTop, in: bytes))
        XCTAssertTrue(mapping.isPressed(.bumper, in: bytes))
        XCTAssertTrue(mapping.isPressed(.menuButton, in: bytes))
        XCTAssertTrue(mapping.isPressed(.stickClick, in: bytes))
        XCTAssertEqual(mapping.triggerValue(in: bytes), 201)
        XCTAssertFalse(mapping.isPressed(.faceBottom, in: bytes))
    }

    func testJoyConSideSpecificButtonsDoNotAlias() {
        var rightBytes = [UInt8](repeating: 0, count: JoyConHIDProtocol.reportLength)
        rightBytes[3] = 0x08 | 0x80 // A + ZR
        rightBytes[4] = 0x10       // Home
        let right = JoyConButtonMapping(isLeft: false)

        XCTAssertTrue(right.isPressed(.a, in: rightBytes))
        XCTAssertTrue(right.isPressed(.zr, in: rightBytes))
        XCTAssertTrue(right.isPressed(.home, in: rightBytes))
        XCTAssertFalse(right.isPressed(.b, in: rightBytes))

        var leftBytes = [UInt8](repeating: 0, count: JoyConHIDProtocol.reportLength)
        leftBytes[4] = 0x20        // Capture
        leftBytes[5] = 0x02 | 0x40 // Up + L
        let left = JoyConButtonMapping(isLeft: true)

        XCTAssertTrue(left.isPressed(.dpadUp, in: leftBytes))
        XCTAssertTrue(left.isPressed(.l, in: leftBytes))
        XCTAssertTrue(left.isPressed(.capture, in: leftBytes))
        XCTAssertFalse(left.isPressed(.dpadDown, in: leftBytes))
    }

    func testJoyConPackedStickDecoding() {
        var bytes = [UInt8](repeating: 0, count: JoyConHIDProtocol.reportLength)
        writePackedStick(x: 0xABC, y: 0x123, to: &bytes, at: JoyConHIDProtocol.Offset.leftStickStart)

        let raw = JoyConButtonMapping(isLeft: true).joystickPositionRaw(in: bytes)

        XCTAssertEqual(raw.x, 0xABC)
        XCTAssertEqual(raw.y, 0x123)
    }

    func testG502StableButtonBytesDecodeKnownControls() {
        let mapping = G502XButtonMapping()
        let bytes: [UInt8] = [0b1010_1001, 0b0000_0101]

        XCTAssertTrue(mapping.isPressed(.left, in: bytes))
        XCTAssertTrue(mapping.isPressed(.back, in: bytes))
        XCTAssertTrue(mapping.isPressed(.dpiShift, in: bytes))
        XCTAssertTrue(mapping.isPressed(.scrollTiltRight, in: bytes))
        XCTAssertTrue(mapping.isPressed(.g9, in: bytes))
        XCTAssertTrue(mapping.isPressed(.dpiDown, in: bytes))
        XCTAssertFalse(mapping.isPressed(.right, in: bytes))
        XCTAssertFalse(mapping.isPressed(.dpiUp, in: bytes))
    }

    private func writePackedStick(x: Int, y: Int, to bytes: inout [UInt8], at offset: Int) {
        bytes[offset] = UInt8(x & 0xFF)
        bytes[offset + 1] = UInt8(((x >> 8) & 0x0F) | ((y & 0x0F) << 4))
        bytes[offset + 2] = UInt8((y >> 4) & 0xFF)
    }
}
