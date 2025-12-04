import Foundation

// MARK: - Configurable Device Type

/// Device types that can be configured with their own settings profiles.
/// Settings are stored per (slot, deviceType) combination.
enum ConfigurableDeviceType: String, CaseIterable, Codable, Identifiable, Sendable {
    case leftJoyCon = "Joy-Con (L)"
    case rightJoyCon = "Joy-Con (R)"
    case proController = "Pro Controller"
    case dinostrike = "Dinostrike"
    case airMouseBasic = "Air Mouse"

    var id: String { rawValue }

    /// Human-readable display name
    var displayName: String { rawValue }

    /// Icon for this device type
    var icon: String {
        switch self {
        case .leftJoyCon, .rightJoyCon, .proController:
            return "gamecontroller"
        case .dinostrike:
            return "gamecontroller"
        case .airMouseBasic:
            return "computermouse"
        }
    }

    /// What settings categories are available for this device type
    var availableSettings: [SettingsCategory] {
        switch self {
        case .leftJoyCon, .rightJoyCon, .proController:
            return [.calibration, .pointer, .stick, .buttons]
        case .dinostrike:
            return []  // Empty for now - user will define settings later
        case .airMouseBasic:
            return [.pointer, .buttons]
        }
    }

    /// Whether this device type has a gyroscope that needs calibration
    var hasGyro: Bool {
        switch self {
        case .leftJoyCon, .rightJoyCon, .proController:
            return true
        case .dinostrike, .airMouseBasic:
            return false
        }
    }

    /// Whether this device type has an analog stick
    var hasStick: Bool {
        switch self {
        case .leftJoyCon, .rightJoyCon, .proController:
            return true
        case .dinostrike, .airMouseBasic:
            return false
        }
    }

    /// Available buttons for this device type
    var availableButtons: [LogicalButton] {
        switch self {
        case .leftJoyCon, .rightJoyCon, .proController:
            return LogicalButton.allCases
        case .dinostrike:
            return []  // Empty for now
        case .airMouseBasic:
            // Air mice typically have: left, right, middle, back, forward
            return [.trigger, .shoulder, .stick, .faceLeft, .faceRight]
        }
    }

    /// Suggested device type based on InputDeviceType detection
    static func suggested(for inputType: InputDeviceType) -> ConfigurableDeviceType {
        switch inputType {
        case .leftJoyCon:
            return .leftJoyCon
        case .rightJoyCon:
            return .rightJoyCon
        case .proController:
            return .proController
        case .dinostrike:
            return .dinostrike
        case .airMouse, .genericMouse:
            return .airMouseBasic
        case .none:
            return .rightJoyCon  // Default
        }
    }
}

// MARK: - Settings Category

/// Categories of settings available for device configuration
enum SettingsCategory: String, CaseIterable, Codable, Identifiable {
    case calibration = "Calibration"
    case pointer = "Pointer"
    case stick = "Stick"
    case buttons = "Buttons"

    var id: String { rawValue }

    var displayName: String { rawValue }

    var icon: String {
        switch self {
        case .calibration:
            return "scope"
        case .pointer:
            return "cursorarrow.motionlines"
        case .stick:
            return "dpad"
        case .buttons:
            return "button.horizontal"
        }
    }

    var description: String {
        switch self {
        case .calibration:
            return "Gyro calibration settings"
        case .pointer:
            return "Sensitivity, smoothing, acceleration"
        case .stick:
            return "Stick mode, scroll, radial menu"
        case .buttons:
            return "Button mappings and overrides"
        }
    }
}
