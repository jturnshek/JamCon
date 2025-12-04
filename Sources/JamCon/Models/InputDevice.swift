import Foundation

// MARK: - Input Device Type

/// Represents the type of any input device (Joy-Con or generic mouse)
enum InputDeviceType: String, Codable, CaseIterable, Sendable {
    case none = "None"
    case leftJoyCon = "Joy-Con (L)"
    case rightJoyCon = "Joy-Con (R)"
    case proController = "Pro Controller"
    case dinostrike = "Dinostrike"
    case airMouse = "Air Mouse"
    case genericMouse = "Mouse"

    var displayName: String { rawValue }

    /// Whether this device type provides gyro data
    var hasGyro: Bool {
        switch self {
        case .leftJoyCon, .rightJoyCon, .proController:
            return true
        case .dinostrike, .airMouse, .genericMouse, .none:
            return false
        }
    }

    /// Whether this device type has a joystick
    var hasStick: Bool {
        switch self {
        case .leftJoyCon, .rightJoyCon, .proController:
            return true
        case .dinostrike, .airMouse, .genericMouse, .none:
            return false
        }
    }

    /// Whether this is a Joy-Con type device
    var isJoyCon: Bool {
        switch self {
        case .leftJoyCon, .rightJoyCon, .proController:
            return true
        case .dinostrike, .airMouse, .genericMouse, .none:
            return false
        }
    }

    /// Whether this is a mouse type device
    var isMouse: Bool {
        switch self {
        case .dinostrike, .airMouse, .genericMouse:
            return true
        case .leftJoyCon, .rightJoyCon, .proController, .none:
            return false
        }
    }

    /// Convert from legacy ControllerType
    init(from controllerType: ControllerType) {
        switch controllerType {
        case .none: self = .none
        case .leftJoyCon: self = .leftJoyCon
        case .rightJoyCon: self = .rightJoyCon
        case .proController: self = .proController
        }
    }

    /// Convert to legacy ControllerType (returns .none for mouse types)
    var asControllerType: ControllerType {
        switch self {
        case .none: return .none
        case .leftJoyCon: return .leftJoyCon
        case .rightJoyCon: return .rightJoyCon
        case .proController: return .proController
        case .dinostrike, .airMouse, .genericMouse: return .none
        }
    }
}

// MARK: - Device Capabilities

/// Describes what capabilities an input device has
struct DeviceCapabilities: OptionSet, Sendable {
    let rawValue: UInt

    /// Device provides gyroscope data (Joy-Cons)
    static let gyro = DeviceCapabilities(rawValue: 1 << 0)

    /// Device has an analog stick (Joy-Cons)
    static let stick = DeviceCapabilities(rawValue: 1 << 1)

    /// Device has multiple programmable buttons (Joy-Cons have many, mice typically 2-5)
    static let multipleButtons = DeviceCapabilities(rawValue: 1 << 2)

    /// Device provides mouse delta values directly (air mice)
    static let mouseDeltas = DeviceCapabilities(rawValue: 1 << 3)

    /// Standard Joy-Con capabilities
    static let joyCon: DeviceCapabilities = [.gyro, .stick, .multipleButtons]

    /// Standard air mouse capabilities
    static let airMouse: DeviceCapabilities = [.mouseDeltas, .multipleButtons]

    /// Standard mouse capabilities (fewer buttons typically)
    static let genericMouse: DeviceCapabilities = [.mouseDeltas]
}

// MARK: - Motion Data

/// Unified motion data from any input device
enum MotionData: Sendable {
    /// Gyroscope data from Joy-Cons (degrees per second)
    case gyro(GyroData)

    /// Mouse delta movement from air mice (pixels)
    case mouseDeltas(dx: Double, dy: Double)
}

// MARK: - Input Device Protocol

/// Protocol for any input device that can control the mouse
protocol InputDevice: AnyObject, Identifiable, Sendable {
    /// Unique identifier for this device instance
    var id: UUID { get }

    /// The type of device
    var deviceType: InputDeviceType { get }

    /// Human-readable name for display
    var displayName: String { get }

    /// Current battery level
    var batteryLevel: BatteryLevel { get }

    /// Whether the device is currently connected
    var isConnected: Bool { get }

    /// What this device can do
    var capabilities: DeviceCapabilities { get }
}

// MARK: - HID Device Info

/// Information about an available HID device (not yet connected/seized)
struct HIDDeviceInfo: Identifiable, Hashable, Sendable {
    let id: UUID
    let vendorId: Int
    let productId: Int
    let productName: String
    let manufacturerName: String
    let serialNumber: String?
    let transport: String  // "Bluetooth" or "USB"

    /// Identified known device type, if recognized
    var knownType: KnownDeviceType? {
        KnownDeviceType.identify(vendorId: vendorId, productId: productId)
    }

    /// Human-readable display name (uses native device name, not type name)
    var displayName: String {
        if !productName.isEmpty {
            return productName
        }
        return "Unknown Device (\(String(format: "%04X:%04X", vendorId, productId)))"
    }

    /// Whether this is likely a wireless device (air mouse candidate)
    var isWireless: Bool {
        transport.lowercased() == "bluetooth"
    }

    /// Unique identifier string for matching
    var deviceIdentifier: String {
        if let serial = serialNumber, !serial.isEmpty {
            return serial
        }
        return "\(vendorId):\(productId):\(productName)"
    }

    /// Key for grouping multiple interfaces of the same physical device
    var groupKey: String {
        "\(vendorId):\(productId):\(transport)"
    }
}

// MARK: - Available Device (Grouped)

/// Represents a physical device with potentially multiple HID interfaces
struct AvailableDevice: Identifiable, Sendable {
    let id: String  // groupKey
    let vendorId: Int
    let productId: Int
    let productName: String
    let manufacturerName: String
    let transport: String
    let interfaceCount: Int

    var displayName: String {
        if !productName.isEmpty {
            return productName
        }
        return "Unknown Device (\(String(format: "%04X:%04X", vendorId, productId)))"
    }

    var isUSB: Bool {
        transport.uppercased() == "USB"
    }

    var isBluetooth: Bool {
        transport.lowercased() == "bluetooth"
    }

    /// Identified known device type, if recognized
    var knownType: KnownDeviceType? {
        KnownDeviceType.identify(vendorId: vendorId, productId: productId)
    }
}
