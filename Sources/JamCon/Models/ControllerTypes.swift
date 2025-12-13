import Foundation

/// High-level controller types supported by the app.
enum ControllerKind: String, Codable, Sendable, CaseIterable {
    case sense
    case joyCon
    case mouse

    var displayName: String {
        switch self {
        case .sense: return "Sense"
        case .joyCon: return "Joy-Con"
        case .mouse: return "G502X"
        }
    }

    /// Whether this controller type has left/right variants
    var hasSides: Bool {
        switch self {
        case .sense, .joyCon: return true
        case .mouse: return false
        }
    }

    /// Whether this controller type has gyro/accelerometer
    var hasGyro: Bool {
        switch self {
        case .sense, .joyCon: return true
        case .mouse: return false
        }
    }

    /// Whether this controller type has a joystick
    var hasJoystick: Bool {
        switch self {
        case .sense, .joyCon: return true
        case .mouse: return false
        }
    }
}

/// Identifies a specific controller profile by type and side.
/// Used as the key for per-profile settings like button mappings.
struct ControllerProfile: Hashable, Codable, Sendable {
    let kind: ControllerKind
    let isLeft: Bool

    /// Key used for UserDefaults persistence, e.g. "sense.left"
    var persistenceKey: String {
        "\(kind.rawValue).\(isLeft ? "left" : "right")"
    }

    /// Human-readable display name, e.g. "Joy-Con Left" or just "G502X"
    var displayName: String {
        if kind.hasSides {
            let sideName = isLeft ? "Left" : "Right"
            return "\(kind.displayName) \(sideName)"
        } else {
            return kind.displayName
        }
    }

    var side: String {
        kind.hasSides ? (isLeft ? "Left" : "Right") : ""
    }

    // Static convenience accessors for all profiles
    static let senseLeft = ControllerProfile(kind: .sense, isLeft: true)
    static let senseRight = ControllerProfile(kind: .sense, isLeft: false)
    static let joyConLeft = ControllerProfile(kind: .joyCon, isLeft: true)
    static let joyConRight = ControllerProfile(kind: .joyCon, isLeft: false)
    static let mouse = ControllerProfile(kind: .mouse, isLeft: false)  // Mouse has no sides

    static let allProfiles: [ControllerProfile] = [.senseLeft, .senseRight, .joyConLeft, .joyConRight, .mouse]

    /// Create a profile from a ControllerInfo
    init(from info: ControllerInfo) {
        self.kind = info.kind
        self.isLeft = info.isLeft
    }

    init(kind: ControllerKind, isLeft: Bool) {
        self.kind = kind
        self.isLeft = isLeft
    }
}

/// UI-safe controller info (no IOHIDDevice reference - safe for SwiftUI)
struct ControllerInfo: Identifiable, Equatable, Sendable {
    let id: String
    let name: String
    let productID: Int
    let kind: ControllerKind

    /// Stable key for persisting per-device "managed" state.
    /// Includes kind to avoid cross-device ID collisions.
    var managementKey: String {
        "\(kind.rawValue):\(id)"
    }

    var isLeft: Bool {
        switch kind {
        case .sense:
            return productID == SenseHIDProtocol.leftProductID
        case .joyCon:
            return productID == JoyConHIDProtocol.leftProductID
        case .mouse:
            return false  // Mouse has no sides
        }
    }

    var side: String {
        kind.hasSides ? (isLeft ? "Left" : "Right") : ""
    }
}
