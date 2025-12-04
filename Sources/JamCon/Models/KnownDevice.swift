import Foundation

/// Known device types that can be identified by vendor/product ID
enum KnownDeviceType: String, CaseIterable, Codable, Sendable {
    case dinostrike = "Dinostrike"

    /// Try to identify a device by its HID info
    static func identify(vendorId: Int, productId: Int) -> KnownDeviceType? {
        for type in allCases {
            if type.matches(vendorId: vendorId, productId: productId) {
                return type
            }
        }
        return nil
    }

    /// Check if this device type matches the given IDs
    func matches(vendorId: Int, productId: Int) -> Bool {
        switch self {
        case .dinostrike:
            // ZY.Ltd "ZY RMC" air mouse
            return vendorId == 0x25A7 && productId == 0x1048
        }
    }

    /// Human-readable display name
    var displayName: String { rawValue }

    /// Icon for this device type
    var icon: String {
        switch self {
        case .dinostrike:
            return "gamecontroller"
        }
    }
}
