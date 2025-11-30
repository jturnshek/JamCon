import Foundation
import Carbon.HIToolbox

// MARK: - Key Modifiers

struct KeyModifiers: OptionSet, Codable, Hashable, Sendable {
    let rawValue: UInt

    static let shift   = KeyModifiers(rawValue: 1 << 0)
    static let control = KeyModifiers(rawValue: 1 << 1)
    static let option  = KeyModifiers(rawValue: 1 << 2)
    static let command = KeyModifiers(rawValue: 1 << 3)

    var displayString: String {
        var parts: [String] = []
        if contains(.control) { parts.append("⌃") }
        if contains(.option)  { parts.append("⌥") }
        if contains(.shift)   { parts.append("⇧") }
        if contains(.command) { parts.append("⌘") }
        return parts.joined()
    }
}

// MARK: - Key Combo

struct KeyCombo: Codable, Equatable, Hashable, Sendable {
    var keyCode: UInt16
    var modifiers: KeyModifiers

    var displayName: String {
        let modString = modifiers.displayString
        let keyString = KeyCombo.keyCodeToString(keyCode)
        return modString + keyString
    }

    // Convert key code to human-readable string
    static func keyCodeToString(_ keyCode: UInt16) -> String {
        switch Int(keyCode) {
        // Letters
        case kVK_ANSI_A: return "A"
        case kVK_ANSI_B: return "B"
        case kVK_ANSI_C: return "C"
        case kVK_ANSI_D: return "D"
        case kVK_ANSI_E: return "E"
        case kVK_ANSI_F: return "F"
        case kVK_ANSI_G: return "G"
        case kVK_ANSI_H: return "H"
        case kVK_ANSI_I: return "I"
        case kVK_ANSI_J: return "J"
        case kVK_ANSI_K: return "K"
        case kVK_ANSI_L: return "L"
        case kVK_ANSI_M: return "M"
        case kVK_ANSI_N: return "N"
        case kVK_ANSI_O: return "O"
        case kVK_ANSI_P: return "P"
        case kVK_ANSI_Q: return "Q"
        case kVK_ANSI_R: return "R"
        case kVK_ANSI_S: return "S"
        case kVK_ANSI_T: return "T"
        case kVK_ANSI_U: return "U"
        case kVK_ANSI_V: return "V"
        case kVK_ANSI_W: return "W"
        case kVK_ANSI_X: return "X"
        case kVK_ANSI_Y: return "Y"
        case kVK_ANSI_Z: return "Z"

        // Numbers
        case kVK_ANSI_0: return "0"
        case kVK_ANSI_1: return "1"
        case kVK_ANSI_2: return "2"
        case kVK_ANSI_3: return "3"
        case kVK_ANSI_4: return "4"
        case kVK_ANSI_5: return "5"
        case kVK_ANSI_6: return "6"
        case kVK_ANSI_7: return "7"
        case kVK_ANSI_8: return "8"
        case kVK_ANSI_9: return "9"

        // Function keys
        case kVK_F1: return "F1"
        case kVK_F2: return "F2"
        case kVK_F3: return "F3"
        case kVK_F4: return "F4"
        case kVK_F5: return "F5"
        case kVK_F6: return "F6"
        case kVK_F7: return "F7"
        case kVK_F8: return "F8"
        case kVK_F9: return "F9"
        case kVK_F10: return "F10"
        case kVK_F11: return "F11"
        case kVK_F12: return "F12"

        // Special keys
        case kVK_Return: return "↩"
        case kVK_Tab: return "⇥"
        case kVK_Space: return "Space"
        case kVK_Delete: return "⌫"
        case kVK_Escape: return "⎋"
        case kVK_ForwardDelete: return "⌦"

        // Arrow keys
        case kVK_LeftArrow: return "←"
        case kVK_RightArrow: return "→"
        case kVK_UpArrow: return "↑"
        case kVK_DownArrow: return "↓"

        // Navigation
        case kVK_Home: return "↖"
        case kVK_End: return "↘"
        case kVK_PageUp: return "⇞"
        case kVK_PageDown: return "⇟"

        default: return "Key\(keyCode)"
        }
    }

    // Common presets
    static let escape = KeyCombo(keyCode: UInt16(kVK_Escape), modifiers: [])
    static let enter = KeyCombo(keyCode: UInt16(kVK_Return), modifiers: [])
    static let space = KeyCombo(keyCode: UInt16(kVK_Space), modifiers: [])
    static let tab = KeyCombo(keyCode: UInt16(kVK_Tab), modifiers: [])
    static let backspace = KeyCombo(keyCode: UInt16(kVK_Delete), modifiers: [])

    static let arrowUp = KeyCombo(keyCode: UInt16(kVK_UpArrow), modifiers: [])
    static let arrowDown = KeyCombo(keyCode: UInt16(kVK_DownArrow), modifiers: [])
    static let arrowLeft = KeyCombo(keyCode: UInt16(kVK_LeftArrow), modifiers: [])
    static let arrowRight = KeyCombo(keyCode: UInt16(kVK_RightArrow), modifiers: [])

    static let copy = KeyCombo(keyCode: UInt16(kVK_ANSI_C), modifiers: .command)
    static let paste = KeyCombo(keyCode: UInt16(kVK_ANSI_V), modifiers: .command)
    static let cut = KeyCombo(keyCode: UInt16(kVK_ANSI_X), modifiers: .command)
    static let undo = KeyCombo(keyCode: UInt16(kVK_ANSI_Z), modifiers: .command)
    static let redo = KeyCombo(keyCode: UInt16(kVK_ANSI_Z), modifiers: [.command, .shift])
    static let selectAll = KeyCombo(keyCode: UInt16(kVK_ANSI_A), modifiers: .command)
}

// MARK: - Button Action

enum ButtonAction: Codable, Equatable, Hashable, Sendable {
    case none
    case mouseClick(MouseButton)
    case keyPress(KeyCombo)

    var displayName: String {
        switch self {
        case .none:
            return "None"
        case .mouseClick(let button):
            switch button {
            case .left: return "Left Click"
            case .right: return "Right Click"
            case .middle: return "Middle Click"
            }
        case .keyPress(let combo):
            return combo.displayName
        }
    }
}

// MARK: - Button Mapping Profile

struct ButtonMappingProfile: Codable, Equatable {
    var mappings: [String: ButtonAction]  // JoyConButton.rawValue -> ButtonAction

    init(mappings: [JoyConButton: ButtonAction] = [:]) {
        self.mappings = Dictionary(uniqueKeysWithValues: mappings.map { ($0.key.rawValue, $0.value) })
    }

    subscript(button: JoyConButton) -> ButtonAction {
        get { mappings[button.rawValue] ?? .none }
        set { mappings[button.rawValue] = newValue }
    }

    // Default profile for primary controller
    static var defaultPrimary: ButtonMappingProfile {
        ButtonMappingProfile(mappings: [
            .zr: .mouseClick(.left),
            .r: .mouseClick(.right),
            .zl: .mouseClick(.left),
            .l: .mouseClick(.right),
        ])
    }

    // Default profile for secondary controller
    static var defaultSecondary: ButtonMappingProfile {
        ButtonMappingProfile(mappings: [
            .zr: .mouseClick(.left),
            .r: .mouseClick(.right),
            .zl: .mouseClick(.left),
            .l: .mouseClick(.right),
        ])
    }

    // All buttons that can be mapped
    static var allButtons: [JoyConButton] {
        [
            // Triggers
            .zr, .r, .zl, .l,
            // Face buttons
            .a, .b, .x, .y,
            // D-pad
            .up, .down, .left, .right,
            // Other
            .plus, .minus, .home, .capture,
            .rightStick, .leftStick,
            // Side buttons (when held sideways)
            .sr_r, .sl_r, .sr_l, .sl_l,
        ]
    }

    // Grouped buttons for UI
    static var buttonGroups: [(name: String, buttons: [JoyConButton])] {
        [
            ("Triggers", [.zr, .r, .zl, .l]),
            ("Face Buttons", [.a, .b, .x, .y]),
            ("D-Pad", [.up, .down, .left, .right]),
            ("Other", [.plus, .minus, .rightStick, .leftStick]),
        ]
    }
}

// MARK: - Persistence Helpers

extension ButtonMappingProfile {
    static func load(from key: String) -> ButtonMappingProfile? {
        guard let data = UserDefaults.standard.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(ButtonMappingProfile.self, from: data)
    }

    func save(to key: String) {
        if let data = try? JSONEncoder().encode(self) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }
}
