import Foundation

/// Logical buttons for G502X mouse
/// These map to the physical buttons on the Logitech G502X
/// Button naming follows official Logitech G HUB numbering
enum G502XLogicalButton: String, CaseIterable, Codable {
    // Standard mouse buttons (G1-G3)
    case left           // G1 - Primary click
    case right          // G2 - Secondary click
    case middle         // G3 - Wheel click

    // Side buttons - thumb area (G4-G5)
    case back           // G4 - Back button
    case forward        // G5 - Forward button

    // DPI Shift - sniper button on left side (G6)
    case dpiShift       // G6 - DPI Shift (sniper button)

    // DPI control buttons - behind scroll wheel (G7-G8)
    case dpiDown        // G7 - DPI down (lower button behind wheel)
    case dpiUp          // G8 - DPI up (upper button behind wheel)

    // Profile button - top of mouse (G9)
    case g9             // G9 - Profile cycling / radial menu trigger

    // Scroll wheel tilt
    case scrollTiltLeft   // Tilt wheel left
    case scrollTiltRight  // Tilt wheel right

    /// Stable index for array-backed hot-path storage
    var index: Int {
        switch self {
        case .left: return 0
        case .right: return 1
        case .middle: return 2
        case .back: return 3
        case .forward: return 4
        case .dpiShift: return 5
        case .dpiDown: return 6
        case .dpiUp: return 7
        case .g9: return 8
        case .scrollTiltLeft: return 9
        case .scrollTiltRight: return 10
        }
    }

    /// Human-readable display name
    var displayName: String {
        switch self {
        case .left: return "Left Click"
        case .right: return "Right Click"
        case .middle: return "Middle Click"
        case .back: return "Back (G4)"
        case .forward: return "Forward (G5)"
        case .dpiShift: return "DPI Shift (G6)"
        case .dpiDown: return "DPI Down (G7)"
        case .dpiUp: return "DPI Up (G8)"
        case .g9: return "G9"
        case .scrollTiltLeft: return "Scroll Tilt Left"
        case .scrollTiltRight: return "Scroll Tilt Right"
        }
    }

    /// Number of buttons for array allocation
    static var count: Int { 11 }

    /// Buttons that should pass through when not mapped
    /// These are the standard mouse buttons that users expect to work normally
    static var passthroughButtons: Set<G502XLogicalButton> {
        [.left, .right, .middle, .back, .forward]
    }

    /// Whether this button should pass through to the system when unmapped
    var shouldPassthroughWhenUnmapped: Bool {
        Self.passthroughButtons.contains(self)
    }

    /// The CGEvent button number for passthrough (nil for non-standard buttons)
    var cgEventButtonNumber: Int32? {
        switch self {
        case .left: return 0        // kCGMouseButtonLeft
        case .right: return 1       // kCGMouseButtonRight
        case .middle: return 2      // kCGMouseButtonCenter
        case .back: return 3        // Button 4 (back)
        case .forward: return 4     // Button 5 (forward)
        case .scrollTiltLeft, .scrollTiltRight:
            return nil  // Scroll tilts are handled via scroll events, not button events
        default: return nil
        }
    }

    /// Whether this is a scroll tilt button (handled differently)
    var isScrollTilt: Bool {
        self == .scrollTiltLeft || self == .scrollTiltRight
    }
}

/// Button mapping for G502X mouse
/// Reads button states from HID reports
/// Verified byte/bit layout from actual G502X Lightspeed device testing
struct G502XButtonMapping {
    /// Read a button state from report bytes
    func isPressed(_ button: G502XLogicalButton, in report: [UInt8]) -> Bool {
        guard let location = buttonLocation(for: button) else { return false }
        guard location.byte < report.count else { return false }
        return (report[location.byte] & (1 << location.bit)) != 0
    }

    /// Get the physical button location for a logical button
    /// Verified via HID report testing on G502X Lightspeed
    func buttonLocation(for button: G502XLogicalButton) -> ButtonLocation? {
        switch button {
        // Byte 0: Standard mouse buttons + G4-G6 + scroll tilt
        case .left:
            return ButtonLocation(byte: 0, bit: 0)  // 0x01
        case .right:
            return ButtonLocation(byte: 0, bit: 1)  // 0x02
        case .middle:
            return ButtonLocation(byte: 0, bit: 2)  // 0x04
        case .back:
            return ButtonLocation(byte: 0, bit: 3)  // 0x08 - G4
        case .forward:
            return ButtonLocation(byte: 0, bit: 4)  // 0x10 - G5
        case .dpiShift:
            return ButtonLocation(byte: 0, bit: 5)  // 0x20 - G6 (sniper button)
        case .scrollTiltLeft:
            return ButtonLocation(byte: 0, bit: 6)  // 0x40
        case .scrollTiltRight:
            return ButtonLocation(byte: 0, bit: 7)  // 0x80

        // Byte 1: G7-G9
        case .g9:
            return ButtonLocation(byte: 1, bit: 0)  // 0x01 - top button
        case .dpiUp:
            return ButtonLocation(byte: 1, bit: 1)  // 0x02 - G8
        case .dpiDown:
            return ButtonLocation(byte: 1, bit: 2)  // 0x04 - G7
        }
    }
}

// MARK: - G502X Button Mapping Profile

struct G502XButtonMappingProfile: Codable {
    private(set) var mappings: [String: ButtonActions]  // G502XLogicalButton.rawValue -> actions
    private var actionsCache: [ButtonActions] = Array(repeating: ButtonActions(), count: G502XLogicalButton.count)
    var holdThreshold: Double  // Seconds before hold action fires

    // Cached gyro-mode mapping flags
    private(set) var dragMapped: Bool = false
    private(set) var scrollMapped: Bool = false
    private(set) var radialMenuMapped: Bool = false

    static let userDefaultsKey = "G502XButtonMappingProfile"

    private enum CodingKeys: String, CodingKey {
        case mappings
        case holdThreshold
    }

    init(mappings: [String: ButtonActions] = [:], holdThreshold: Double = 0.3) {
        self.mappings = mappings
        self.holdThreshold = holdThreshold
        rebuildActionsCache()
        recomputeMappingFlags()
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.mappings = try container.decodeIfPresent([String: ButtonActions].self, forKey: .mappings) ?? [:]
        self.holdThreshold = try container.decodeIfPresent(Double.self, forKey: .holdThreshold) ?? 0.3
        rebuildActionsCache()
        recomputeMappingFlags()
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(mappings, forKey: .mappings)
        try container.encode(holdThreshold, forKey: .holdThreshold)
    }

    /// Default profile - only G9 triggers radial menu, all other buttons pass through or are unmapped
    static var `default`: Self {
        var profile = G502XButtonMappingProfile()
        // G9 opens radial menu (user's preferred trigger)
        profile.mappings[G502XLogicalButton.g9.rawValue] = ButtonActions(press: .radialMenu)
        profile.rebuildActionsCache()
        profile.recomputeMappingFlags()
        return profile
    }

    func actions(for button: G502XLogicalButton) -> ButtonActions {
        actionsCache[button.index]
    }

    mutating func setActions(_ actions: ButtonActions, for button: G502XLogicalButton) {
        mappings[button.rawValue] = actions
        actionsCache[button.index] = actions
        recomputeMappingFlags()
    }

    mutating func setPressAction(_ action: ButtonAction, for button: G502XLogicalButton) {
        var current = actions(for: button)
        current.press = action
        if action.isGyroMode {
            current.hold = .none
        }
        mappings[button.rawValue] = current
        actionsCache[button.index] = current
        recomputeMappingFlags()
    }

    mutating func setHoldAction(_ action: ButtonAction, for button: G502XLogicalButton) {
        var current = actions(for: button)
        current.hold = action
        mappings[button.rawValue] = current
        actionsCache[button.index] = current
        recomputeMappingFlags()
    }

    var hasDragMapping: Bool { dragMapped }
    var hasScrollMapping: Bool { scrollMapped }
    var hasRadialMenuMapping: Bool { radialMenuMapped }

    func save() {
        if let data = try? JSONEncoder().encode(self) {
            UserDefaults.standard.set(data, forKey: Self.userDefaultsKey)
        }
    }

    /// Save this profile for a specific controller profile
    func save(for profile: ControllerProfile) {
        guard profile.kind == .mouse else { return }
        let key = "buttons.\(profile.persistenceKey)"
        if let data = try? JSONEncoder().encode(self) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }

    static func load() -> Self {
        if let data = UserDefaults.standard.data(forKey: userDefaultsKey),
           let profile = try? JSONDecoder().decode(Self.self, from: data) {
            return profile
        }
        return .default
    }

    /// Load profile for a specific controller profile
    static func load(for profile: ControllerProfile) -> Self {
        guard profile.kind == .mouse else { return .default }
        let key = "buttons.\(profile.persistenceKey)"

        // Try loading per-profile settings
        if let data = UserDefaults.standard.data(forKey: key),
           let loaded = try? JSONDecoder().decode(Self.self, from: data) {
            return loaded
        }

        // Fall back to global profile
        return load()
    }

    /// Check if per-profile settings exist
    static func hasPerProfileSettings(for profile: ControllerProfile) -> Bool {
        guard profile.kind == .mouse else { return false }
        let key = "buttons.\(profile.persistenceKey)"
        return UserDefaults.standard.data(forKey: key) != nil
    }

    private mutating func rebuildActionsCache() {
        for button in G502XLogicalButton.allCases {
            actionsCache[button.index] = mappings[button.rawValue] ?? ButtonActions()
        }
    }

    private mutating func recomputeMappingFlags() {
        var drag = false
        var scroll = false
        var radial = false

        for actions in mappings.values {
            switch actions.press {
            case .drag: drag = true
            case .scroll: scroll = true
            case .radialMenu: radial = true
            default: break
            }
            if drag && scroll && radial { break }
        }

        dragMapped = drag
        scrollMapped = scroll
        radialMenuMapped = radial
    }
}
