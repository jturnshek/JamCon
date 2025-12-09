import Foundation

/// Logical buttons for Joy-Con controllers
/// Note: Left and Right Joy-Con have different button sets
enum JoyConLogicalButton: String, CaseIterable, Codable {
    // Face buttons (Right Joy-Con only when standalone)
    case a
    case b
    case x
    case y

    // D-pad buttons (Left Joy-Con only when standalone)
    case dpadUp
    case dpadDown
    case dpadLeft
    case dpadRight

    // Shoulder buttons
    case l      // Left Joy-Con
    case r      // Right Joy-Con
    case zl     // Left Joy-Con
    case zr     // Right Joy-Con

    // System buttons
    case plus   // Right Joy-Con (or both in grip mode)
    case minus  // Left Joy-Con (or both in grip mode)
    case home   // Right Joy-Con
    case capture // Left Joy-Con

    // Stick click
    case stickClick  // L3 (left) or R3 (right)

    // Side rail buttons (both Joy-Cons have these)
    case sl
    case sr

    /// Stable index for array-backed hot-path storage
    var index: Int {
        switch self {
        case .a: return 0
        case .b: return 1
        case .x: return 2
        case .y: return 3
        case .l: return 4
        case .r: return 5
        case .zl: return 6
        case .zr: return 7
        case .plus: return 8
        case .minus: return 9
        case .home: return 10
        case .capture: return 11
        case .stickClick: return 12
        case .sl: return 13
        case .sr: return 14
        case .dpadUp: return 15
        case .dpadDown: return 16
        case .dpadLeft: return 17
        case .dpadRight: return 18
        }
    }

    /// Human-readable display name
    var displayName: String {
        switch self {
        case .a: return "A"
        case .b: return "B"
        case .x: return "X"
        case .y: return "Y"
        case .dpadUp: return "Up"
        case .dpadDown: return "Down"
        case .dpadLeft: return "Left"
        case .dpadRight: return "Right"
        case .l: return "L"
        case .r: return "R"
        case .zl: return "ZL"
        case .zr: return "ZR"
        case .plus: return "+"
        case .minus: return "−"
        case .home: return "Home"
        case .capture: return "Capture"
        case .stickClick: return "Stick"
        case .sl: return "SL"
        case .sr: return "SR"
        }
    }

    /// Number of buttons for array allocation
    static var count: Int { 19 }

    /// Buttons available on Right Joy-Con
    static var rightButtons: [JoyConLogicalButton] {
        [.a, .b, .x, .y, .r, .zr, .plus, .home, .stickClick, .sl, .sr]
    }

    /// Buttons available on Left Joy-Con
    static var leftButtons: [JoyConLogicalButton] {
        [.dpadUp, .dpadDown, .dpadLeft, .dpadRight, .l, .zl, .minus, .capture, .stickClick, .sl, .sr]
    }

    /// Check if this button exists on the given controller side
    func isAvailable(isLeft: Bool) -> Bool {
        if isLeft {
            return Self.leftButtons.contains(self)
        } else {
            return Self.rightButtons.contains(self)
        }
    }
}

/// Calibration data for a Joy-Con stick
struct JoyConStickCalibration {
    var centerX: Double = 2048.0
    var centerY: Double = 2048.0
    var sampleCount: Int = 0
    var isCalibrated: Bool = false

    /// Number of samples to collect for calibration
    static let requiredSamples = 30

    /// Accumulate a sample for calibration (call when stick is at rest on connection)
    mutating func addSample(rawX: UInt16, rawY: UInt16) {
        guard !isCalibrated else { return }

        let count = Double(sampleCount)
        // Running average
        centerX = (centerX * count + Double(rawX)) / (count + 1)
        centerY = (centerY * count + Double(rawY)) / (count + 1)
        sampleCount += 1

        if sampleCount >= Self.requiredSamples {
            isCalibrated = true
        }
    }

    /// Reset calibration (e.g., on reconnect)
    mutating func reset() {
        centerX = 2048.0
        centerY = 2048.0
        sampleCount = 0
        isCalibrated = false
    }
}

/// Button mapping for Joy-Con controllers
struct JoyConButtonMapping {
    let isLeftController: Bool

    /// Calibration for this controller's stick
    var calibration = JoyConStickCalibration()

    /// Initialize with controller product ID
    init(productID: Int) {
        self.isLeftController = (productID == JoyConHIDProtocol.leftProductID)
    }

    /// Initialize with explicit side
    init(isLeft: Bool) {
        self.isLeftController = isLeft
    }

    /// Read a button state from report bytes
    func isPressed(_ button: JoyConLogicalButton, in report: [UInt8]) -> Bool {
        guard let location = buttonLocation(for: button) else { return false }
        guard location.byte < report.count else { return false }
        return (report[location.byte] & (1 << location.bit)) != 0
    }

    /// Get the physical button location for a logical button
    /// Returns nil if the button doesn't exist on this controller side
    func buttonLocation(for button: JoyConLogicalButton) -> ButtonLocation? {
        if isLeftController {
            return leftButtonLocation(for: button)
        } else {
            return rightButtonLocation(for: button)
        }
    }

    // MARK: - Right Joy-Con Button Locations

    private func rightButtonLocation(for button: JoyConLogicalButton) -> ButtonLocation? {
        switch button {
        // Face buttons (byte 3)
        case .a:
            let loc = JoyConHIDProtocol.RightButton.a
            return ButtonLocation(byte: loc.byte, bit: loc.bit)
        case .b:
            let loc = JoyConHIDProtocol.RightButton.b
            return ButtonLocation(byte: loc.byte, bit: loc.bit)
        case .x:
            let loc = JoyConHIDProtocol.RightButton.x
            return ButtonLocation(byte: loc.byte, bit: loc.bit)
        case .y:
            let loc = JoyConHIDProtocol.RightButton.y
            return ButtonLocation(byte: loc.byte, bit: loc.bit)

        // Shoulder buttons
        case .r:
            let loc = JoyConHIDProtocol.RightButton.r
            return ButtonLocation(byte: loc.byte, bit: loc.bit)
        case .zr:
            let loc = JoyConHIDProtocol.RightButton.zr
            return ButtonLocation(byte: loc.byte, bit: loc.bit)

        // System buttons (byte 4)
        case .plus:
            let loc = JoyConHIDProtocol.RightButton.plus
            return ButtonLocation(byte: loc.byte, bit: loc.bit)
        case .home:
            let loc = JoyConHIDProtocol.RightButton.home
            return ButtonLocation(byte: loc.byte, bit: loc.bit)
        case .stickClick:
            let loc = JoyConHIDProtocol.RightButton.rStick
            return ButtonLocation(byte: loc.byte, bit: loc.bit)

        // Side rail buttons
        case .sl:
            let loc = JoyConHIDProtocol.RightButton.sl
            return ButtonLocation(byte: loc.byte, bit: loc.bit)
        case .sr:
            let loc = JoyConHIDProtocol.RightButton.sr
            return ButtonLocation(byte: loc.byte, bit: loc.bit)

        // Buttons not on Right Joy-Con
        case .l, .zl, .minus, .capture, .dpadUp, .dpadDown, .dpadLeft, .dpadRight:
            return nil
        }
    }

    // MARK: - Left Joy-Con Button Locations

    private func leftButtonLocation(for button: JoyConLogicalButton) -> ButtonLocation? {
        switch button {
        // D-pad buttons (byte 4)
        case .dpadUp:
            let loc = JoyConHIDProtocol.LeftButton.up
            return ButtonLocation(byte: loc.byte, bit: loc.bit)
        case .dpadDown:
            let loc = JoyConHIDProtocol.LeftButton.down
            return ButtonLocation(byte: loc.byte, bit: loc.bit)
        case .dpadLeft:
            let loc = JoyConHIDProtocol.LeftButton.left
            return ButtonLocation(byte: loc.byte, bit: loc.bit)
        case .dpadRight:
            let loc = JoyConHIDProtocol.LeftButton.right
            return ButtonLocation(byte: loc.byte, bit: loc.bit)

        // Shoulder buttons (byte 4)
        case .l:
            let loc = JoyConHIDProtocol.LeftButton.l
            return ButtonLocation(byte: loc.byte, bit: loc.bit)
        case .zl:
            let loc = JoyConHIDProtocol.LeftButton.zl
            return ButtonLocation(byte: loc.byte, bit: loc.bit)

        // System buttons (byte 5)
        case .minus:
            let loc = JoyConHIDProtocol.LeftButton.minus
            return ButtonLocation(byte: loc.byte, bit: loc.bit)
        case .capture:
            let loc = JoyConHIDProtocol.LeftButton.capture
            return ButtonLocation(byte: loc.byte, bit: loc.bit)
        case .stickClick:
            let loc = JoyConHIDProtocol.LeftButton.lStick
            return ButtonLocation(byte: loc.byte, bit: loc.bit)

        // Side rail buttons
        case .sl:
            let loc = JoyConHIDProtocol.LeftButton.sl
            return ButtonLocation(byte: loc.byte, bit: loc.bit)
        case .sr:
            let loc = JoyConHIDProtocol.LeftButton.sr
            return ButtonLocation(byte: loc.byte, bit: loc.bit)

        // Buttons not on Left Joy-Con (face buttons are on Right)
        case .a, .b, .x, .y, .r, .zr, .plus, .home:
            return nil
        }
    }

    // MARK: - Joystick Position

    /// Deadzone radius in raw 12-bit units (applies around calibrated center)
    static let deadzoneRadius: Double = 150.0

    /// Read joystick position from report bytes
    /// Joy-Con sticks are 12-bit values packed into 3 bytes
    /// Returns values normalized to 0-255 range with 128 as center (matching PSVR2 format)
    func joystickPosition(in report: [UInt8]) -> (x: UInt8, y: UInt8) {
        let raw = joystickPositionRaw(in: report)

        // Use calibrated center (auto-detected on connection) or fallback to 2048
        let centerX = calibration.centerX
        let centerY = calibration.centerY
        let effectiveRange: Double = 1400.0  // Typical max deflection from center
        let deadzone = Self.deadzoneRadius

        func normalize(_ raw: UInt16, center: Double) -> UInt8 {
            let delta = Double(raw) - center

            // Apply deadzone: if within deadzone radius, report as center
            if abs(delta) < deadzone {
                return 128
            }

            // Subtract deadzone from delta to eliminate jump when leaving deadzone
            let adjusted = delta - (delta > 0 ? deadzone : -deadzone)
            let adjustedRange = effectiveRange - deadzone
            let scaled = (adjusted / adjustedRange) * 127.0
            let clamped = max(-127.0, min(127.0, scaled))
            return UInt8(clamping: Int(128.0 + clamped))
        }

        return (normalize(raw.x, center: centerX), normalize(raw.y, center: centerY))
    }

    /// Read raw 12-bit joystick values (0-4095 range, center ~2048)
    func joystickPositionRaw(in report: [UInt8]) -> (x: UInt16, y: UInt16) {
        let startByte = isLeftController
            ? JoyConHIDProtocol.Offset.leftStickStart
            : JoyConHIDProtocol.Offset.rightStickStart

        guard startByte + 2 < report.count else { return (2048, 2048) }

        // Joy-Con sticks are packed as 12-bit values:
        // byte0: X[7:0]
        // byte1: Y[3:0] | X[11:8]
        // byte2: Y[11:4]
        let byte0 = UInt16(report[startByte])
        let byte1 = UInt16(report[startByte + 1])
        let byte2 = UInt16(report[startByte + 2])

        let rawX = byte0 | ((byte1 & 0x0F) << 8)  // 12-bit, 0-4095
        let rawY = (byte1 >> 4) | (byte2 << 4)    // 12-bit, 0-4095

        return (rawX, rawY)
    }
}
