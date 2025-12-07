import Foundation

/// High-level controller types supported by the app.
enum ControllerKind: String, Codable, Sendable {
    case psvr2
    case joyCon
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
