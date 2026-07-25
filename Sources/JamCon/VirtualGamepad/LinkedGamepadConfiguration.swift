import Foundation
import Security

struct LinkedJoyConSelection: Codable, Equatable, Sendable, Identifiable {
    let deviceID: String
    let displayName: String
    let profileVariant: ControllerProfileVariant

    var id: String { deviceID }
    var managementKey: String { "\(ControllerKind.joyCon.rawValue):\(deviceID)" }

    init(controller: ControllerInfo) {
        precondition(controller.kind == .joyCon)
        deviceID = controller.id
        displayName = controller.displayName
        profileVariant = controller.profileVariant
    }
}

struct LinkedGamepadConfiguration: Codable, Equatable, Sendable {
    var isEnabled = false
    var left: LinkedJoyConSelection?
    var right: LinkedJoyConSelection?

    var isComplete: Bool {
        guard let left, let right else { return false }
        return left.deviceID != right.deviceID
    }

    func contains(deviceID: String) -> Bool {
        left?.deviceID == deviceID || right?.deviceID == deviceID
    }

    func side(for deviceID: String) -> LinkedJoyConSide? {
        if left?.deviceID == deviceID { return .left }
        if right?.deviceID == deviceID { return .right }
        return nil
    }
}

struct LinkedGamepadConfigurationStore {
    static let defaultsKey = "linkedGamepad.configuration.v1"

    let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func load() -> LinkedGamepadConfiguration {
        guard let data = defaults.data(forKey: Self.defaultsKey),
              let configuration = try? JSONDecoder().decode(
                  LinkedGamepadConfiguration.self,
                  from: data
              ) else {
            return LinkedGamepadConfiguration()
        }
        return configuration
    }

    func save(_ configuration: LinkedGamepadConfiguration) {
        guard let data = try? JSONEncoder().encode(configuration) else { return }
        defaults.set(data, forKey: Self.defaultsKey)
    }
}

enum VirtualGamepadAvailability: Equatable, Sendable {
    case available
    case unsupportedOperatingSystem
    case missingEntitlement

    static var current: Self {
        guard #available(macOS 15, *) else {
            return .unsupportedOperatingSystem
        }
        guard let task = SecTaskCreateFromSelf(nil),
              SecTaskCopyValueForEntitlement(
                  task,
                  "com.apple.developer.hid.virtual.device" as CFString,
                  nil
              ) as? Bool == true else {
            return .missingEntitlement
        }
        return .available
    }

    var isAvailable: Bool {
        self == .available
    }

    var title: String {
        switch self {
        case .available:
            return "Available"
        case .unsupportedOperatingSystem:
            return "Requires macOS 15"
        case .missingEntitlement:
            return "Awaiting Apple Approval"
        }
    }

    var explanation: String? {
        switch self {
        case .available:
            return nil
        case .unsupportedOperatingSystem:
            return "Virtual gamepads require macOS 15 or later."
        case .missingEntitlement:
            return "This build is intentionally signed without Apple’s Virtual HID entitlement. "
                + "Pair selections are saved, but activation remains disabled."
        }
    }
}

enum VirtualGamepadRuntimeStatus: Equatable, Sendable {
    case unavailable(VirtualGamepadAvailability)
    case disabled
    case needsControllers
    case waitingForControllers
    case activating
    case active
    case failed(String)

    var title: String {
        switch self {
        case let .unavailable(availability):
            return availability.title
        case .disabled:
            return "Off"
        case .needsControllers:
            return "Choose Two Controllers"
        case .waitingForControllers:
            return "Waiting for Controllers"
        case .activating:
            return "Starting"
        case .active:
            return "Gamepad Active"
        case .failed:
            return "Couldn’t Start"
        }
    }
}
