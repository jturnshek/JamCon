import Foundation
import CoreGraphics

// MARK: - Mouse Button Types

enum MouseButton: String, Codable, CaseIterable, Hashable {
    case left
    case right
    case middle

    var displayName: String {
        switch self {
        case .left: return "Left Click"
        case .right: return "Right Click"
        case .middle: return "Middle Click"
        }
    }
}

// MARK: - System Actions

enum SystemAction: String, Codable, CaseIterable, Hashable {
    case missionControl
    case launchpad
    case showDesktop
    case appSwitcher
    case playPause

    var displayName: String {
        switch self {
        case .missionControl: return "Mission Control"
        case .launchpad: return "Launchpad"
        case .showDesktop: return "Show Desktop"
        case .appSwitcher: return "App Switcher"
        case .playPause: return "Play/Pause"
        }
    }
}

// MARK: - Key Combination

struct KeyCombo: Codable, Hashable {
    let keyCode: UInt16
    let modifiers: UInt64  // CGEventFlags.rawValue

    var eventFlags: CGEventFlags {
        CGEventFlags(rawValue: modifiers)
    }

    init(keyCode: UInt16, modifiers: CGEventFlags = []) {
        self.keyCode = keyCode
        self.modifiers = modifiers.rawValue
    }

    var displayName: String {
        var parts: [String] = []

        let flags = eventFlags
        if flags.contains(.maskControl) { parts.append("⌃") }
        if flags.contains(.maskAlternate) { parts.append("⌥") }
        if flags.contains(.maskShift) { parts.append("⇧") }
        if flags.contains(.maskCommand) { parts.append("⌘") }

        parts.append(keyCodeName)
        return parts.joined()
    }

    private var keyCodeName: String {
        // Common key code mappings
        switch keyCode {
        case 0: return "A"
        case 1: return "S"
        case 2: return "D"
        case 3: return "F"
        case 4: return "H"
        case 5: return "G"
        case 6: return "Z"
        case 7: return "X"
        case 8: return "C"
        case 9: return "V"
        case 11: return "B"
        case 12: return "Q"
        case 13: return "W"
        case 14: return "E"
        case 15: return "R"
        case 16: return "Y"
        case 17: return "T"
        case 18: return "1"
        case 19: return "2"
        case 20: return "3"
        case 21: return "4"
        case 22: return "6"
        case 23: return "5"
        case 24: return "="
        case 25: return "9"
        case 26: return "7"
        case 27: return "-"
        case 28: return "8"
        case 29: return "0"
        case 30: return "]"
        case 31: return "O"
        case 32: return "U"
        case 33: return "["
        case 34: return "I"
        case 35: return "P"
        case 36: return "Return"
        case 37: return "L"
        case 38: return "J"
        case 39: return "'"
        case 40: return "K"
        case 41: return ";"
        case 42: return "\\"
        case 43: return ","
        case 44: return "/"
        case 45: return "N"
        case 46: return "M"
        case 47: return "."
        case 48: return "Tab"
        case 49: return "Space"
        case 50: return "`"
        case 51: return "Delete"
        case 53: return "Escape"
        case 96: return "F5"
        case 97: return "F6"
        case 98: return "F7"
        case 99: return "F3"
        case 100: return "F8"
        case 101: return "F9"
        case 103: return "F11"
        case 105: return "F13"
        case 107: return "F14"
        case 109: return "F10"
        case 111: return "F12"
        case 113: return "F15"
        case 118: return "F4"
        case 119: return "End"
        case 120: return "F2"
        case 121: return "Page Down"
        case 122: return "F1"
        case 123: return "←"
        case 124: return "→"
        case 125: return "↓"
        case 126: return "↑"
        default: return "Key \(keyCode)"
        }
    }
}

// MARK: - Button Action

enum ButtonAction: Codable, Hashable {
    case none
    case mouseClick(MouseButton)
    case keyPress(KeyCombo)
    case systemAction(SystemAction)
    case drag    // Gyro moves cursor only when this button is held
    case scroll  // Gyro scrolls content when this button is held

    var displayName: String {
        switch self {
        case .none:
            return "None"
        case .mouseClick(let button):
            return button.displayName
        case .keyPress(let combo):
            return combo.displayName
        case .systemAction(let action):
            return action.displayName
        case .drag:
            return "Drag (hold to move)"
        case .scroll:
            return "Scroll (hold to scroll)"
        }
    }

    /// Whether this action is a gyro override mode
    var isGyroMode: Bool {
        switch self {
        case .drag, .scroll: return true
        default: return false
        }
    }

    // MARK: - Codable

    private enum CodingKeys: String, CodingKey {
        case type, mouseButton, keyCombo, systemAction
    }

    private enum ActionType: String, Codable {
        case none, mouseClick, keyPress, systemAction, drag, scroll
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(ActionType.self, forKey: .type)

        switch type {
        case .none:
            self = .none
        case .mouseClick:
            let button = try container.decode(MouseButton.self, forKey: .mouseButton)
            self = .mouseClick(button)
        case .keyPress:
            let combo = try container.decode(KeyCombo.self, forKey: .keyCombo)
            self = .keyPress(combo)
        case .systemAction:
            let action = try container.decode(SystemAction.self, forKey: .systemAction)
            self = .systemAction(action)
        case .drag:
            self = .drag
        case .scroll:
            self = .scroll
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)

        switch self {
        case .none:
            try container.encode(ActionType.none, forKey: .type)
        case .mouseClick(let button):
            try container.encode(ActionType.mouseClick, forKey: .type)
            try container.encode(button, forKey: .mouseButton)
        case .keyPress(let combo):
            try container.encode(ActionType.keyPress, forKey: .type)
            try container.encode(combo, forKey: .keyCombo)
        case .systemAction(let action):
            try container.encode(ActionType.systemAction, forKey: .type)
            try container.encode(action, forKey: .systemAction)
        case .drag:
            try container.encode(ActionType.drag, forKey: .type)
        case .scroll:
            try container.encode(ActionType.scroll, forKey: .type)
        }
    }
}

// MARK: - Button Actions (Press + Hold)

/// Combined actions for press (tap) and hold (long press) on a button
struct ButtonActions: Codable, Hashable {
    var press: ButtonAction
    var hold: ButtonAction

    init(press: ButtonAction = .none, hold: ButtonAction = .none) {
        self.press = press
        self.hold = hold
    }

    /// Check if any action is configured
    var hasAny: Bool { press != .none || hold != .none }

    /// Whether the press action is a gyro mode (drag/scroll)
    var pressIsGyroMode: Bool { press.isGyroMode }
}

// MARK: - Button Mapping Profile

struct PSVR2ButtonMappingProfile: Codable {
    var mappings: [String: ButtonActions]  // LogicalButton.rawValue -> actions
    var triggerThreshold: UInt8
    var holdThreshold: Double  // Seconds before hold action fires

    static let userDefaultsKey = "PSVR2ButtonMappingProfile_v2"  // New key for new format

    init(mappings: [String: ButtonActions] = [:], triggerThreshold: UInt8 = 128, holdThreshold: Double = 0.3) {
        self.mappings = mappings
        self.triggerThreshold = triggerThreshold
        self.holdThreshold = holdThreshold
    }

    static var `default`: Self {
        var profile = PSVR2ButtonMappingProfile()
        // Default mappings (press only)
        profile.mappings[LogicalButton.bumper.rawValue] = ButtonActions(press: .mouseClick(.right))
        profile.mappings[LogicalButton.trigger.rawValue] = ButtonActions(press: .mouseClick(.left))
        profile.mappings[LogicalButton.stickClick.rawValue] = ButtonActions(press: .mouseClick(.middle))
        profile.mappings[LogicalButton.menuButton.rawValue] = ButtonActions(press: .systemAction(.playPause))
        profile.mappings[LogicalButton.playStation.rawValue] = ButtonActions(press: .systemAction(.missionControl))
        return profile
    }

    func actions(for button: LogicalButton) -> ButtonActions {
        mappings[button.rawValue] ?? ButtonActions()
    }

    mutating func setActions(_ actions: ButtonActions, for button: LogicalButton) {
        mappings[button.rawValue] = actions
    }

    mutating func setPressAction(_ action: ButtonAction, for button: LogicalButton) {
        var current = actions(for: button)
        current.press = action
        // Clear hold if press is a gyro mode
        if action.isGyroMode {
            current.hold = .none
        }
        mappings[button.rawValue] = current
    }

    mutating func setHoldAction(_ action: ButtonAction, for button: LogicalButton) {
        var current = actions(for: button)
        current.hold = action
        mappings[button.rawValue] = current
    }

    /// Check if any button is mapped to drag mode (in press action)
    var hasDragMapping: Bool {
        mappings.values.contains { $0.press == .drag }
    }

    /// Check if any button is mapped to scroll mode (in press action)
    var hasScrollMapping: Bool {
        mappings.values.contains { $0.press == .scroll }
    }

    func save() {
        if let data = try? JSONEncoder().encode(self) {
            UserDefaults.standard.set(data, forKey: Self.userDefaultsKey)
        }
    }

    static func load() -> Self {
        // Try loading new format first
        if let data = UserDefaults.standard.data(forKey: userDefaultsKey),
           let profile = try? JSONDecoder().decode(Self.self, from: data) {
            return profile
        }

        // Try migrating from old format
        let oldKey = "PSVR2ButtonMappingProfile"
        if let oldData = UserDefaults.standard.data(forKey: oldKey),
           let oldProfile = try? JSONDecoder().decode(OldProfile.self, from: oldData) {
            // Migrate old single-action mappings to new press/hold format
            var newProfile = PSVR2ButtonMappingProfile()
            newProfile.triggerThreshold = oldProfile.triggerThreshold
            for (key, action) in oldProfile.mappings {
                newProfile.mappings[key] = ButtonActions(press: action)
            }
            // Save in new format and clean up old
            newProfile.save()
            UserDefaults.standard.removeObject(forKey: oldKey)
            return newProfile
        }

        return .default
    }

    /// Old profile format for migration
    private struct OldProfile: Codable {
        var mappings: [String: ButtonAction]
        var triggerThreshold: UInt8
    }
}
