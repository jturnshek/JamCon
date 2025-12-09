import Foundation

/// High-level controller types supported by the app.
enum ControllerKind: String, Codable, Sendable, CaseIterable {
    case psvr2
    case joyCon

    var displayName: String {
        switch self {
        case .psvr2: return "PSVR2"
        case .joyCon: return "Joy-Con"
        }
    }
}

/// Identifies a specific controller profile by type and side.
/// Used as the key for per-profile settings like button mappings.
struct ControllerProfile: Hashable, Codable, Sendable {
    let kind: ControllerKind
    let isLeft: Bool

    /// Key used for UserDefaults persistence, e.g. "psvr2.left"
    var persistenceKey: String {
        "\(kind.rawValue).\(isLeft ? "left" : "right")"
    }

    /// Human-readable display name, e.g. "Joy-Con Left"
    var displayName: String {
        let sideName = isLeft ? "Left" : "Right"
        return "\(kind.displayName) \(sideName)"
    }

    var side: String { isLeft ? "Left" : "Right" }

    // Static convenience accessors for all 4 profiles
    static let psvr2Left = ControllerProfile(kind: .psvr2, isLeft: true)
    static let psvr2Right = ControllerProfile(kind: .psvr2, isLeft: false)
    static let joyConLeft = ControllerProfile(kind: .joyCon, isLeft: true)
    static let joyConRight = ControllerProfile(kind: .joyCon, isLeft: false)

    static let allProfiles: [ControllerProfile] = [.psvr2Left, .psvr2Right, .joyConLeft, .joyConRight]

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

    var isLeft: Bool {
        switch kind {
        case .psvr2:
            return productID == PSVR2HIDProtocol.leftProductID
        case .joyCon:
            return productID == JoyConHIDProtocol.leftProductID
        }
    }

    var side: String { isLeft ? "Left" : "Right" }
}
