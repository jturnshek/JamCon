import Foundation

/// Logical buttons that work the same on both controllers
enum LogicalButton: String, CaseIterable {
    case faceTop      // Triangle (L) / Circle (R) - top face button
    case faceBottom   // Square (L) / X (R) - bottom face button
    case bumper       // L1 / R1
    case trigger      // L2 / R2
    case stickClick   // L3 / R3
    case menuButton   // Create (L) / Options (R)
    case playStation

    /// PlayStation name for left controller
    func leftName() -> String {
        switch self {
        case .faceTop: return "Triangle"
        case .faceBottom: return "Square"
        case .bumper: return "L1"
        case .trigger: return "L2"
        case .stickClick: return "L3"
        case .menuButton: return "Create"
        case .playStation: return "PS"
        }
    }

    /// PlayStation name for right controller
    func rightName() -> String {
        switch self {
        case .faceTop: return "Circle"
        case .faceBottom: return "X"
        case .bumper: return "R1"
        case .trigger: return "R2"
        case .stickClick: return "R3"
        case .menuButton: return "Options"
        case .playStation: return "PS"
        }
    }

    /// Get name based on controller side
    func name(isLeft: Bool) -> String {
        isLeft ? leftName() : rightName()
    }
}

/// Physical button locations in HID report
struct ButtonLocation {
    let byte: Int
    let bit: Int
    var mask: UInt8 { 1 << bit }
}

/// Button mapping for PSVR2 Sense Controllers
struct PSVR2ButtonMapping {
    let isLeftController: Bool

    // Face buttons (byte 9) differ by controller side
    var faceTopButton: ButtonLocation {
        isLeftController
            ? ButtonLocation(byte: 9, bit: 3)  // Triangle = 0x08
            : ButtonLocation(byte: 9, bit: 2)  // Circle = 0x04
    }

    var faceBottomButton: ButtonLocation {
        isLeftController
            ? ButtonLocation(byte: 9, bit: 0)  // Square = 0x01
            : ButtonLocation(byte: 9, bit: 1)  // X = 0x02
    }

    // Bumper (L1/R1) differs by side
    var bumperButton: ButtonLocation {
        isLeftController
            ? ButtonLocation(byte: 9, bit: 4)  // L1 = 0x10
            : ButtonLocation(byte: 9, bit: 5)  // R1 = 0x20
    }

    // System buttons (byte 10) also differ by side
    var stickClickButton: ButtonLocation {
        isLeftController
            ? ButtonLocation(byte: 10, bit: 2)  // L3 = 0x04
            : ButtonLocation(byte: 10, bit: 3)  // R3 = 0x08
    }

    var menuButton: ButtonLocation {
        isLeftController
            ? ButtonLocation(byte: 10, bit: 0)  // Create = 0x01
            : ButtonLocation(byte: 10, bit: 1)  // Options = 0x02
    }

    let playstationButton = ButtonLocation(byte: 10, bit: 4)  // Same on both = 0x10

    // Analog inputs (same on both)
    let joystickXByte = 2
    let joystickYByte = 3
    let triggerByte = 4
    let triggerProximityByte = 5
    let gripTouchByte = 6

    // Capacitive touch states (byte 11)
    // These may differ by controller - needs verification
    var primaryTouch: ButtonLocation {
        isLeftController
            ? ButtonLocation(byte: 11, bit: 0)  // Triangle touch
            : ButtonLocation(byte: 11, bit: 2)  // Circle touch (needs verify)
    }

    var secondaryTouch: ButtonLocation {
        isLeftController
            ? ButtonLocation(byte: 11, bit: 1)  // Square touch
            : ButtonLocation(byte: 11, bit: 1)  // X touch (needs verify)
    }

    let joystickTouch = ButtonLocation(byte: 11, bit: 2)  // Needs verify on left
    let gripTouch = ButtonLocation(byte: 11, bit: 3)      // Needs verify on left

    /// Initialize with controller product ID
    init(productID: Int) {
        self.isLeftController = (productID == 0x0E45)
    }

    /// Initialize with explicit side
    init(isLeft: Bool) {
        self.isLeftController = isLeft
    }

    /// Read a button state from report bytes
    func isPressed(_ button: LogicalButton, in report: [UInt8]) -> Bool {
        let location = buttonLocation(for: button)
        guard location.byte < report.count else { return false }
        return (report[location.byte] & location.mask) != 0
    }

    /// Get the physical button location for a logical button
    func buttonLocation(for button: LogicalButton) -> ButtonLocation {
        switch button {
        case .faceTop: return faceTopButton
        case .faceBottom: return faceBottomButton
        case .bumper: return bumperButton
        case .trigger: return ButtonLocation(byte: triggerByte, bit: 0) // Analog, not bit
        case .stickClick: return stickClickButton
        case .menuButton: return menuButton
        case .playStation: return playstationButton
        }
    }

    /// Get trigger analog value (0-255)
    func triggerValue(in report: [UInt8]) -> UInt8 {
        guard triggerByte < report.count else { return 0 }
        return report[triggerByte]
    }

    /// Get joystick position (0-255, center ~128)
    func joystickPosition(in report: [UInt8]) -> (x: UInt8, y: UInt8) {
        guard joystickYByte < report.count else { return (128, 128) }
        return (report[joystickXByte], report[joystickYByte])
    }
}

// MARK: - Button State Tracking

/// Tracks button states and detects press/release events
class ButtonStateTracker {
    private var previousState: [LogicalButton: Bool] = [:]
    private let mapping: PSVR2ButtonMapping

    init(mapping: PSVR2ButtonMapping) {
        self.mapping = mapping
        // Initialize all buttons as not pressed
        for button in LogicalButton.allCases {
            previousState[button] = false
        }
    }

    /// Update state and return buttons that just changed
    func update(with report: [UInt8]) -> (pressed: [LogicalButton], released: [LogicalButton]) {
        var pressed: [LogicalButton] = []
        var released: [LogicalButton] = []

        for button in LogicalButton.allCases {
            let isNowPressed = mapping.isPressed(button, in: report)
            let wasPrevPressed = previousState[button] ?? false

            if isNowPressed && !wasPrevPressed {
                pressed.append(button)
            } else if !isNowPressed && wasPrevPressed {
                released.append(button)
            }

            previousState[button] = isNowPressed
        }

        return (pressed, released)
    }

    /// Check if a button is currently pressed
    func isPressed(_ button: LogicalButton) -> Bool {
        return previousState[button] ?? false
    }
}
