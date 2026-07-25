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

/// Physical handedness reported by a device backend. Keeping this metadata on
/// ControllerInfo prevents shared UI and profile code from knowing transport-
/// specific product IDs.
enum ControllerHandedness: String, Codable, Sendable {
    case left
    case right
    case none

    var displayName: String {
        switch self {
        case .left: return "Left"
        case .right: return "Right"
        case .none: return ""
        }
    }
}

/// Hardware layout variant within a controller family. This stays separate
/// from ControllerKind so generations that share the same input pipeline can
/// still have independent button profiles.
enum ControllerProfileVariant: String, Codable, Sendable {
    case standard
    case joyCon2
}

/// Identifies a specific controller profile by type and side.
/// Used as the key for per-profile settings like button mappings.
struct ControllerProfile: Hashable, Codable, Sendable {
    let kind: ControllerKind
    let isLeft: Bool
    let variant: ControllerProfileVariant

    /// Key used for UserDefaults persistence, e.g. "sense.left"
    var persistenceKey: String {
        let family = variant == .joyCon2 ? "joyCon2" : kind.rawValue
        return "\(family).\(isLeft ? "left" : "right")"
    }

    /// Human-readable display name, e.g. "Joy-Con Left" or just "G502X"
    var displayName: String {
        if kind.hasSides {
            let sideName = isLeft ? "Left" : "Right"
            let familyName = variant == .joyCon2 ? "Joy-Con 2" : kind.displayName
            return "\(familyName) \(sideName)"
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
    static let joyCon2Left = ControllerProfile(kind: .joyCon, isLeft: true, variant: .joyCon2)
    static let joyCon2Right = ControllerProfile(kind: .joyCon, isLeft: false, variant: .joyCon2)
    static let mouse = ControllerProfile(kind: .mouse, isLeft: false)  // Mouse has no sides

    static let allProfiles: [ControllerProfile] = [
        .senseLeft, .senseRight,
        .joyConLeft, .joyConRight,
        .joyCon2Left, .joyCon2Right,
        .mouse,
    ]

    /// Create a profile from a ControllerInfo
    init(from info: ControllerInfo) {
        self.kind = info.kind
        self.isLeft = info.isLeft
        self.variant = info.kind == .joyCon ? info.profileVariant : .standard
    }

    init(kind: ControllerKind, isLeft: Bool, variant: ControllerProfileVariant = .standard) {
        self.kind = kind
        self.isLeft = isLeft
        self.variant = kind == .joyCon ? variant : .standard
    }

    private enum CodingKeys: String, CodingKey {
        case kind, isLeft, variant
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        kind = try container.decode(ControllerKind.self, forKey: .kind)
        isLeft = try container.decode(Bool.self, forKey: .isLeft)
        let decodedVariant = try container.decodeIfPresent(
            ControllerProfileVariant.self,
            forKey: .variant
        ) ?? .standard
        variant = kind == .joyCon ? decodedVariant : .standard
    }
}

/// UI-safe controller info (no IOHIDDevice reference - safe for SwiftUI)
struct ControllerInfo: Identifiable, Equatable, Sendable {
    let id: String
    let name: String
    let productID: Int
    let kind: ControllerKind
    let handedness: ControllerHandedness
    let profileVariant: ControllerProfileVariant

    init(
        id: String,
        name: String,
        productID: Int,
        kind: ControllerKind,
        handedness: ControllerHandedness,
        profileVariant: ControllerProfileVariant = .standard
    ) {
        self.id = id
        self.name = name
        self.productID = productID
        self.kind = kind
        self.handedness = handedness
        self.profileVariant = kind == .joyCon ? profileVariant : .standard
    }

    /// Stable key for persisting per-device "managed" state.
    /// Includes kind to avoid cross-device ID collisions.
    var managementKey: String {
        "\(kind.rawValue):\(id)"
    }

    var isLeft: Bool { handedness == .left }

    var side: String {
        handedness.displayName
    }

    /// Stable UI identity. Transport names can be generic placeholders (for
    /// example CoreBluetooth's literal "DeviceName"), so profile identity is
    /// always the primary label.
    var displayName: String {
        ControllerProfile(from: self).displayName
    }

    var transportDescription: String {
        switch kind {
        case .sense:
            return "Game Controller"
        case .joyCon:
            return profileVariant == .joyCon2 ? "Bluetooth LE" : "Bluetooth HID"
        case .mouse:
            return "USB Receiver"
        }
    }

    var meaningfulTransportName: String? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalized = trimmed.lowercased()
        let profileAliases: Set<String>
        if kind == .joyCon {
            let family = profileVariant == .joyCon2 ? "joy-con 2" : "joy-con"
            let side = isLeft ? "l" : "r"
            profileAliases = [
                "\(family) (\(side))",
                "\(family) \(side)",
                "\(family) \(handedness.displayName.lowercased())",
            ]
        } else {
            profileAliases = []
        }
        guard !trimmed.isEmpty,
              normalized != "devicename",
              normalized != "device name",
              normalized != "unknown",
              normalized != displayName.lowercased(),
              normalized != transportDescription.lowercased(),
              !profileAliases.contains(normalized) else { return nil }
        return trimmed
    }
}
