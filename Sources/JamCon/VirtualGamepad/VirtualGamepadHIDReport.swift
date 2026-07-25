import Foundation

enum VirtualGamepadHIDDescriptor {
    static let vendorID: UInt32 = 0xCAFE
    static let productID: UInt32 = 0x0001
    static let reportID: UInt8 = 0x01
    static let reportLength = 14

    /// Generic Desktop gamepad with 16 buttons, a hat, two signed 16-bit
    /// sticks, and two unsigned 8-bit triggers.
    static let bytes = Data([
        0x05, 0x01,             // Usage Page (Generic Desktop)
        0x09, 0x05,             // Usage (Game Pad)
        0xA1, 0x01,             // Collection (Application)
        0x85, reportID,         //   Report ID (1)

        0x05, 0x09,             //   Usage Page (Button)
        0x19, 0x01,             //   Usage Minimum (Button 1)
        0x29, 0x10,             //   Usage Maximum (Button 16)
        0x15, 0x00,             //   Logical Minimum (0)
        0x25, 0x01,             //   Logical Maximum (1)
        0x75, 0x01,             //   Report Size (1)
        0x95, 0x10,             //   Report Count (16)
        0x81, 0x02,             //   Input (Data, Variable, Absolute)

        0x05, 0x01,             //   Usage Page (Generic Desktop)
        0x09, 0x39,             //   Usage (Hat Switch)
        0x15, 0x00,             //   Logical Minimum (0)
        0x25, 0x07,             //   Logical Maximum (7)
        0x35, 0x00,             //   Physical Minimum (0)
        0x46, 0x3B, 0x01,       //   Physical Maximum (315)
        0x65, 0x14,             //   Unit (Degrees)
        0x75, 0x04,             //   Report Size (4)
        0x95, 0x01,             //   Report Count (1)
        0x81, 0x42,             //   Input (Data, Variable, Absolute, Null)
        0x65, 0x00,             //   Unit (None)
        0x75, 0x04,             //   Report Size (4)
        0x95, 0x01,             //   Report Count (1)
        0x81, 0x03,             //   Input (Constant, Variable, Absolute)

        0x09, 0x30,             //   Usage (X)
        0x09, 0x31,             //   Usage (Y)
        0x09, 0x33,             //   Usage (Rx)
        0x09, 0x34,             //   Usage (Ry)
        0x16, 0x00, 0x80,       //   Logical Minimum (-32768)
        0x26, 0xFF, 0x7F,       //   Logical Maximum (32767)
        0x75, 0x10,             //   Report Size (16)
        0x95, 0x04,             //   Report Count (4)
        0x81, 0x02,             //   Input (Data, Variable, Absolute)

        0x09, 0x32,             //   Usage (Z)
        0x09, 0x35,             //   Usage (Rz)
        0x15, 0x00,             //   Logical Minimum (0)
        0x26, 0xFF, 0x00,       //   Logical Maximum (255)
        0x75, 0x08,             //   Report Size (8)
        0x95, 0x02,             //   Report Count (2)
        0x81, 0x02,             //   Input (Data, Variable, Absolute)

        0xC0,                   // End Collection
    ])
}

enum VirtualGamepadButton: Int, CaseIterable, Sendable {
    // Face buttons are positional so games retain the conventional diamond.
    case south = 0
    case east
    case west
    case north
    case leftShoulder
    case rightShoulder
    case leftStick
    case rightStick
    case select
    case start
    case home
    case capture
    case auxiliary
}

struct VirtualGamepadButtons: OptionSet, Equatable, Sendable {
    let rawValue: UInt16

    init(rawValue: UInt16) {
        self.rawValue = rawValue
    }

    static func button(_ button: VirtualGamepadButton) -> Self {
        Self(rawValue: 1 << UInt16(button.rawValue))
    }
}

enum VirtualGamepadHat: UInt8, Sendable {
    case north = 0
    case northEast = 1
    case east = 2
    case southEast = 3
    case south = 4
    case southWest = 5
    case west = 6
    case northWest = 7
    case neutral = 8
}

struct VirtualGamepadState: Equatable, Sendable {
    var buttons: VirtualGamepadButtons = []
    var hat: VirtualGamepadHat = .neutral
    var leftX: Int16 = 0
    var leftY: Int16 = 0
    var rightX: Int16 = 0
    var rightY: Int16 = 0
    var leftTrigger: UInt8 = 0
    var rightTrigger: UInt8 = 0
}

struct VirtualGamepadHIDReport: Equatable, Sendable {
    let bytes: [UInt8]

    init(state: VirtualGamepadState) {
        var bytes = [UInt8](repeating: 0, count: VirtualGamepadHIDDescriptor.reportLength)
        bytes[0] = VirtualGamepadHIDDescriptor.reportID
        Self.write(state.buttons.rawValue, to: &bytes, at: 1)
        bytes[3] = state.hat.rawValue & 0x0F
        Self.write(UInt16(bitPattern: state.leftX), to: &bytes, at: 4)
        Self.write(UInt16(bitPattern: state.leftY), to: &bytes, at: 6)
        Self.write(UInt16(bitPattern: state.rightX), to: &bytes, at: 8)
        Self.write(UInt16(bitPattern: state.rightY), to: &bytes, at: 10)
        bytes[12] = state.leftTrigger
        bytes[13] = state.rightTrigger
        self.bytes = bytes
    }

    var data: Data {
        Data(bytes)
    }

    /// Controls whose transitions must remain ordered even when analog-only
    /// reports are coalesced by the asynchronous output pump.
    var digitalSignature: UInt64 {
        UInt64(bytes[1])
            | (UInt64(bytes[2]) << 8)
            | (UInt64(bytes[3] & 0x0F) << 16)
            | (UInt64(bytes[12]) << 24)
            | (UInt64(bytes[13]) << 32)
    }

    private static func write(_ value: UInt16, to bytes: inout [UInt8], at offset: Int) {
        bytes[offset] = UInt8(truncatingIfNeeded: value)
        bytes[offset + 1] = UInt8(truncatingIfNeeded: value >> 8)
    }
}
