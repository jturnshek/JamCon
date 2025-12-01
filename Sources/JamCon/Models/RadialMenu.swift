import Foundation

// MARK: - Stick Mode

/// Determines what the joystick does
enum StickMode: String, Codable, Hashable, CaseIterable, Sendable {
    case scroll
    case radialMenu

    var displayName: String {
        switch self {
        case .scroll: return "Scroll"
        case .radialMenu: return "Radial Menu"
        }
    }
}

// MARK: - Radial Menu Action

/// Actions that can be triggered by selecting a radial menu item
enum RadialMenuAction: Codable, Equatable, Hashable, Sendable {
    case none
    case keyPress(KeyCombo)
    case mouseClick(MouseButton)
    case systemAction(SystemAction)

    var displayName: String {
        switch self {
        case .none:
            return "None"
        case .keyPress(let combo):
            return combo.displayName
        case .mouseClick(let button):
            switch button {
            case .left: return "Left Click"
            case .right: return "Right Click"
            case .middle: return "Middle Click"
            }
        case .systemAction(let action):
            return action.displayName
        }
    }
}

// MARK: - Radial Menu Item

/// A single item in the radial menu
struct RadialMenuItem: Codable, Identifiable, Equatable, Hashable, Sendable {
    let id: UUID
    var label: String
    var icon: String  // SF Symbol name
    var action: RadialMenuAction

    init(
        id: UUID = UUID(),
        label: String,
        icon: String,
        action: RadialMenuAction
    ) {
        self.id = id
        self.label = label
        self.icon = icon
        self.action = action
    }
}

// MARK: - Radial Menu Configuration

/// Complete configuration for a radial menu
struct RadialMenuConfiguration: Codable, Equatable, Identifiable, Sendable {
    let id: UUID
    var name: String
    var items: [RadialMenuItem]
    var innerRadiusRatio: Double  // 0-1, portion of outer radius

    init(
        id: UUID = UUID(),
        name: String,
        items: [RadialMenuItem],
        innerRadiusRatio: Double = 0.35
    ) {
        self.id = id
        self.name = name
        self.items = items
        self.innerRadiusRatio = innerRadiusRatio
    }

    /// Default 4-direction arrow key menu
    static var arrowKeys: RadialMenuConfiguration {
        RadialMenuConfiguration(
            name: "Arrow Keys",
            items: [
                RadialMenuItem(
                    label: "Up",
                    icon: "arrow.up",
                    action: .keyPress(.arrowUp)
                ),
                RadialMenuItem(
                    label: "Right",
                    icon: "arrow.right",
                    action: .keyPress(.arrowRight)
                ),
                RadialMenuItem(
                    label: "Down",
                    icon: "arrow.down",
                    action: .keyPress(.arrowDown)
                ),
                RadialMenuItem(
                    label: "Left",
                    icon: "arrow.left",
                    action: .keyPress(.arrowLeft)
                ),
            ]
        )
    }
}
