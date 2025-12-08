import Foundation

/// Logical buttons for Joy-Con controllers
/// Note: Left and Right Joy-Con have different button sets
enum JoyConLogicalButton: String, CaseIterable, Codable {
    // Face buttons (Right Joy-Con only when standalone)
    case a
    case b
    case x
    case y

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
        }
    }

    /// Human-readable display name
    var displayName: String {
        switch self {
        case .a: return "A"
        case .b: return "B"
        case .x: return "X"
        case .y: return "Y"
        case .l: return "L"
        case .r: return "R"
        case .zl: return "ZL"
        case .zr: return "ZR"
        case .plus: return "+"
        case .minus: return "−"
        case .home: return "Home"
        case .capture: return "Capture"
        case .stickClick: return "Stick"
        }
    }

    /// Number of buttons for array allocation
    static var count: Int { 13 }

    /// Buttons available on Right Joy-Con
    static var rightButtons: [JoyConLogicalButton] {
        [.a, .b, .x, .y, .r, .zr, .plus, .home, .stickClick]
    }

    /// Buttons available on Left Joy-Con
    static var leftButtons: [JoyConLogicalButton] {
        [.l, .zl, .minus, .capture, .stickClick]
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

/// Button mapping for Joy-Con controllers
struct JoyConButtonMapping {
    let isLeftController: Bool

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

        // Buttons not on Right Joy-Con
        case .l, .zl, .minus, .capture:
            return nil
        }
    }

    // MARK: - Left Joy-Con Button Locations

    private func leftButtonLocation(for button: JoyConLogicalButton) -> ButtonLocation? {
        switch button {
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

        // Buttons not on Left Joy-Con (face buttons are on Right)
        case .a, .b, .x, .y, .r, .zr, .plus, .home:
            return nil
        }
    }
}
