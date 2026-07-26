import Foundation
import CoreGraphics

/// How the radial menu should represent pointer movement.
/// - `ghostCursor`: Controller-style selection using the on-screen dot.
/// - `systemCursor`: Mouse-style selection using the system cursor.
enum RadialMenuPointerStyle: Equatable, Sendable {
    case ghostCursor
    case systemCursor
}

/// Ordered presentation events emitted by InputEngine's serial queue and
/// consumed by AppState on the main queue.
enum RadialMenuPresentationEvent: Equatable, Sendable {
    case show(
        position: CGPoint,
        configuration: RadialMenuConfiguration,
        pointerStyle: RadialMenuPointerStyle
    )
    case hide
    case update(delta: CGPoint)
    case setPosition(offset: CGPoint)
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
            return button.displayName
        case .systemAction(let action):
            return action.displayName
        }
    }

    // MARK: - Codable

    private enum CodingKeys: String, CodingKey {
        case type, keyCombo, mouseButton, systemAction
    }

    private enum ActionType: String, Codable {
        case none, keyPress, mouseClick, systemAction
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(ActionType.self, forKey: .type)

        switch type {
        case .none:
            self = .none
        case .keyPress:
            let combo = try container.decode(KeyCombo.self, forKey: .keyCombo)
            self = .keyPress(combo)
        case .mouseClick:
            let button = try container.decode(MouseButton.self, forKey: .mouseButton)
            self = .mouseClick(button)
        case .systemAction:
            let action = try container.decode(SystemAction.self, forKey: .systemAction)
            self = .systemAction(action)
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)

        switch self {
        case .none:
            try container.encode(ActionType.none, forKey: .type)
        case .keyPress(let combo):
            try container.encode(ActionType.keyPress, forKey: .type)
            try container.encode(combo, forKey: .keyCombo)
        case .mouseClick(let button):
            try container.encode(ActionType.mouseClick, forKey: .type)
            try container.encode(button, forKey: .mouseButton)
        case .systemAction(let action):
            try container.encode(ActionType.systemAction, forKey: .type)
            try container.encode(action, forKey: .systemAction)
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
        icon: String = "circle",
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

    // Pixel-based sizes for each region
    var deadzoneSize: CGFloat       // Center hole radius in pixels
    var innerRingSize: CGFloat      // Inner ring thickness in pixels
    var innerRingRotation: Double   // Inner ring rotation in degrees

    // Outer ring configuration
    var outerRingEnabled: Bool
    var outerRingItems: [RadialMenuItem]
    var outerRingSize: CGFloat      // Outer ring thickness in pixels
    var outerRingRotation: Double   // Outer ring rotation in degrees (independent from inner)
    var radialMovementScale: CGFloat  // Multiplier for gyro deltas while radial menu is active

    // MARK: - Computed Properties

    /// Total menu radius (sum of all enabled regions)
    var menuRadius: CGFloat {
        if outerRingEnabled {
            return deadzoneSize + innerRingSize + outerRingSize
        } else {
            return deadzoneSize + innerRingSize
        }
    }

    /// Menu diameter for view sizing
    var menuDiameter: CGFloat { menuRadius * 2 }

    /// Inner radius ratio (for compatibility with existing rendering code)
    var innerRadiusRatio: Double {
        guard menuRadius > 0 else { return 0.35 }
        return Double(deadzoneSize / menuRadius)
    }

    /// Outer ring threshold ratio (for compatibility with existing rendering code)
    var outerRingThreshold: Double {
        guard menuRadius > 0 else { return 0.65 }
        return Double((deadzoneSize + innerRingSize) / menuRadius)
    }

    // Coding keys for persistence and backwards compatibility
    private enum CodingKeys: String, CodingKey {
        case id, name, items
        case deadzoneSize, innerRingSize
        case innerRingRotation = "rotationOffset"  // Map old key to new property
        case outerRingEnabled, outerRingItems, outerRingSize, outerRingRotation
        case radialMovementScale
        // Legacy keys for migration
        case innerRadiusRatio, outerRingThreshold
    }

    init(
        id: UUID = UUID(),
        name: String,
        items: [RadialMenuItem],
        deadzoneSize: CGFloat = 50,
        innerRingSize: CGFloat = 50,
        innerRingRotation: Double = 0,
        outerRingEnabled: Bool = false,
        outerRingItems: [RadialMenuItem] = [],
        outerRingSize: CGFloat = 50,
        outerRingRotation: Double = 0,
        radialMovementScale: CGFloat = 2.0
    ) {
        self.id = id
        self.name = name
        self.items = items
        self.deadzoneSize = deadzoneSize
        self.innerRingSize = innerRingSize
        self.innerRingRotation = innerRingRotation
        self.outerRingEnabled = outerRingEnabled
        self.outerRingItems = outerRingItems
        self.outerRingSize = outerRingSize
        self.outerRingRotation = outerRingRotation
        self.radialMovementScale = radialMovementScale
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        items = try container.decode([RadialMenuItem].self, forKey: .items)

        // Try to load new pixel-based sizes first, then migrate from ratios if needed
        if let deadzone = try container.decodeIfPresent(CGFloat.self, forKey: .deadzoneSize),
           let innerRing = try container.decodeIfPresent(CGFloat.self, forKey: .innerRingSize) {
            // New format
            deadzoneSize = deadzone
            innerRingSize = innerRing
        } else {
            // Migrate from old ratio-based format
            let oldInnerRatio = try container.decodeIfPresent(Double.self, forKey: .innerRadiusRatio) ?? 0.35
            let oldOuterThreshold = try container.decodeIfPresent(Double.self, forKey: .outerRingThreshold) ?? 0.65
            let oldMenuRadius: CGFloat = 150  // Old fixed menu radius (300px / 2)

            deadzoneSize = CGFloat(oldInnerRatio) * oldMenuRadius
            innerRingSize = CGFloat(oldOuterThreshold - oldInnerRatio) * oldMenuRadius
        }

        innerRingRotation = try container.decodeIfPresent(Double.self, forKey: .innerRingRotation) ?? 0
        outerRingEnabled = try container.decodeIfPresent(Bool.self, forKey: .outerRingEnabled) ?? false
        outerRingItems = try container.decodeIfPresent([RadialMenuItem].self, forKey: .outerRingItems) ?? []
        outerRingSize = try container.decodeIfPresent(CGFloat.self, forKey: .outerRingSize) ?? 50
        outerRingRotation = try container.decodeIfPresent(Double.self, forKey: .outerRingRotation) ?? 0
        radialMovementScale = try container.decodeIfPresent(CGFloat.self, forKey: .radialMovementScale) ?? 2.0
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encode(items, forKey: .items)
        try container.encode(deadzoneSize, forKey: .deadzoneSize)
        try container.encode(innerRingSize, forKey: .innerRingSize)
        try container.encode(innerRingRotation, forKey: .innerRingRotation)
        try container.encode(outerRingEnabled, forKey: .outerRingEnabled)
        try container.encode(outerRingItems, forKey: .outerRingItems)
        try container.encode(outerRingSize, forKey: .outerRingSize)
        try container.encode(outerRingRotation, forKey: .outerRingRotation)
        try container.encode(radialMovementScale, forKey: .radialMovementScale)
    }

    /// Production default captured from the proven day-to-day configuration.
    static var `default`: RadialMenuConfiguration {
        RadialMenuConfiguration(
            name: "Arrow Keys",
            items: [
                RadialMenuItem(
                    label: "Up",
                    icon: "arrow.up",
                    action: .keyPress(KeyCombo(keyCode: 126))  // Up arrow
                ),
                RadialMenuItem(
                    label: "Right",
                    icon: "arrow.right",
                    action: .keyPress(KeyCombo(keyCode: 124))  // Right arrow
                ),
                RadialMenuItem(
                    label: "Down",
                    icon: "arrow.down",
                    action: .keyPress(KeyCombo(keyCode: 125))  // Down arrow
                ),
                RadialMenuItem(
                    label: "Left",
                    icon: "arrow.left",
                    action: .keyPress(KeyCombo(keyCode: 123))  // Left arrow
                ),
            ],
            deadzoneSize: 30,
            innerRingSize: 35,
            innerRingRotation: 45,
            outerRingEnabled: true,
            outerRingItems: [
                RadialMenuItem(
                    label: "1",
                    action: .systemAction(.missionControl)
                ),
                RadialMenuItem(
                    label: "2",
                    action: .keyPress(KeyCombo(
                        keyCode: 17,
                        modifiers: .maskCommand
                    ))
                ),
                RadialMenuItem(
                    label: "3",
                    action: .keyPress(KeyCombo(
                        keyCode: 123,
                        modifiers: .maskControl
                    ))
                ),
                RadialMenuItem(
                    label: "4",
                    action: .keyPress(KeyCombo(
                        keyCode: 48,
                        modifiers: .maskShift
                    ))
                ),
                RadialMenuItem(
                    label: "New",
                    action: .keyPress(KeyCombo(
                        keyCode: 13,
                        modifiers: .maskCommand
                    ))
                ),
                RadialMenuItem(
                    label: "New",
                    action: .systemAction(.playPause)
                ),
                RadialMenuItem(
                    label: "New",
                    action: .keyPress(KeyCombo(
                        keyCode: 124,
                        modifiers: .maskControl
                    ))
                ),
                RadialMenuItem(
                    label: "New",
                    action: .keyPress(KeyCombo(
                        keyCode: 17,
                        modifiers: [.maskCommand, .maskShift]
                    ))
                ),
            ],
            outerRingSize: 50,
            outerRingRotation: 22.5,
            radialMovementScale: 2
        )
    }

    /// Kept as a source-compatible name for callers that predate the outer
    /// production ring.
    static var arrowKeys: RadialMenuConfiguration {
        .default
    }

    // MARK: - Mutating Methods

    mutating func addItem(_ item: RadialMenuItem) {
        items.append(item)
    }

    mutating func removeItem(at index: Int) {
        guard index >= 0 && index < items.count else { return }
        items.remove(at: index)
    }

    mutating func updateItem(at index: Int, with item: RadialMenuItem) {
        guard index >= 0 && index < items.count else { return }
        items[index] = item
    }

    // MARK: - Outer Ring Mutating Methods

    mutating func addOuterRingItem(_ item: RadialMenuItem) {
        outerRingItems.append(item)
    }

    mutating func removeOuterRingItem(at index: Int) {
        guard index >= 0 && index < outerRingItems.count else { return }
        outerRingItems.remove(at: index)
    }

    mutating func updateOuterRingItem(at index: Int, with item: RadialMenuItem) {
        guard index >= 0 && index < outerRingItems.count else { return }
        outerRingItems[index] = item
    }
}

// MARK: - Persistence

extension RadialMenuConfiguration {
    static let storageKey = "JamConRadialMenuConfiguration"

    static func load(defaults: UserDefaults = .standard) -> RadialMenuConfiguration {
        guard let data = defaults.data(forKey: storageKey),
              let config = try? JSONDecoder().decode(RadialMenuConfiguration.self, from: data)
        else { return .default }
        guard !config.isLegacyStockDefault else {
            let migrated = RadialMenuConfiguration.default
            migrated.save(defaults: defaults)
            return migrated
        }
        return config
    }

    func save(defaults: UserDefaults = .standard) {
        if let data = try? JSONEncoder().encode(self) {
            defaults.set(data, forKey: Self.storageKey)
        }
    }

    private var isLegacyStockDefault: Bool {
        let legacyItems: [(String, String, RadialMenuAction)] = [
            ("Up", "arrow.up", .keyPress(KeyCombo(keyCode: 126))),
            ("Right", "arrow.right", .keyPress(KeyCombo(keyCode: 124))),
            ("Down", "arrow.down", .keyPress(KeyCombo(keyCode: 125))),
            ("Left", "arrow.left", .keyPress(KeyCombo(keyCode: 123))),
        ]
        return name == "Arrow Keys"
            && items.count == legacyItems.count
            && zip(items, legacyItems).allSatisfy { item, legacy in
                item.label == legacy.0
                    && item.icon == legacy.1
                    && item.action == legacy.2
            }
            && deadzoneSize == 50
            && innerRingSize == 50
            && innerRingRotation == 0
            && !outerRingEnabled
            && outerRingItems.isEmpty
            && outerRingSize == 50
            && outerRingRotation == 0
            && radialMovementScale == 2
    }
}
