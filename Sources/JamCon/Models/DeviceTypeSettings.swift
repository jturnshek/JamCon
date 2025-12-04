import Foundation

// MARK: - Device Type Settings

/// Settings for a specific (slot, deviceType) combination.
/// Each slot + device type pair has its own independent configuration.
struct DeviceTypeSettings: Codable, Sendable {
    // MARK: - Pointer Settings

    /// Gyro/motion sensitivity (1-200)
    var pointerSensitivity: Double = 50.0

    /// Acceleration gain for fast movements (0-500)
    var accelerationGain: Double = 175.0

    /// Jitter filter threshold (0-50, 0 = off)
    var smoothThreshold: Double = 0.0

    /// One Euro filter beta (0-1)
    var filterBeta: Double = 0.0

    /// Adaptive smoothing mode
    var adaptiveSmoothingMode: AdaptiveSmoothingMode = .speedAndJerk

    /// Whether precision zone (slow cursor at low speeds) is enabled
    var precisionZoneEnabled: Bool = true

    /// Whether early ramp (reach top acceleration sooner) is enabled
    var earlyRampEnabled: Bool = true

    /// Gyro deadzone
    var gyroDeadzone: Double = 1.0

    // MARK: - Stick Settings (Joy-Con only)

    /// Stick mode (scroll or radial menu)
    var stickMode: StickMode = .radialMenu

    /// Scroll sensitivity when stick mode is scroll
    var scrollSensitivity: Double = 10.0

    /// Stick deadzone (0-1)
    var stickDeadzone: Double = 0.15

    /// Radial menu items
    var radialMenuItems: [RadialMenuItem] = RadialMenuConfiguration.arrowKeys.items

    // MARK: - Button Settings

    /// Button mapping profile
    var buttonMappings: ButtonMappingProfile = .defaultPrimary

    /// Buttons that activate clutch mode (freeze cursor for repositioning)
    var clutchButtons: Set<LogicalButton> = [.faceTop]

    /// Buttons that activate scroll mode (motion becomes scroll)
    var scrollButtons: Set<LogicalButton> = [.faceBottom]

    /// Buttons that activate zoom mode (vertical motion becomes zoom)
    var zoomButtons: Set<LogicalButton> = []

    /// Hold threshold in seconds
    var holdThreshold: Double = 0.6

    /// Whether to mirror face buttons (D-pad acts as face buttons)
    var mirrorFaceButtons: Bool = false

    // MARK: - Storage

    /// Storage key for this settings combination
    static func storageKey(slot: DeviceSlot, deviceType: ConfigurableDeviceType) -> String {
        "\(slot.rawValue)_\(deviceType.rawValue.lowercased().replacingOccurrences(of: " ", with: "_"))_settings"
    }

    /// Load settings for a slot/type combination, or return defaults
    static func load(slot: DeviceSlot, deviceType: ConfigurableDeviceType) -> DeviceTypeSettings {
        let key = storageKey(slot: slot, deviceType: deviceType)
        guard let data = UserDefaults.standard.data(forKey: key),
              let settings = try? JSONDecoder().decode(DeviceTypeSettings.self, from: data) else {
            return defaultSettings(for: deviceType, slot: slot)
        }
        return settings
    }

    /// Save settings for a slot/type combination
    func save(slot: DeviceSlot, deviceType: ConfigurableDeviceType) {
        let key = DeviceTypeSettings.storageKey(slot: slot, deviceType: deviceType)
        if let data = try? JSONEncoder().encode(self) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }

    /// Default settings based on device type and slot
    static func defaultSettings(for deviceType: ConfigurableDeviceType, slot: DeviceSlot) -> DeviceTypeSettings {
        var settings = DeviceTypeSettings()

        switch deviceType {
        case .leftJoyCon, .rightJoyCon, .proController:
            // Joy-Con defaults
            settings.pointerSensitivity = 15.0
            settings.accelerationGain = 175.0
            settings.stickMode = .scroll
            settings.clutchButtons = [.faceTop]
            settings.scrollButtons = [.faceBottom]

        case .dinostrike:
            // Dinostrike defaults - no settings defined yet
            settings.pointerSensitivity = 30.0
            settings.accelerationGain = 100.0

        case .airMouseBasic:
            // Air mouse defaults - typically need different sensitivity
            settings.pointerSensitivity = 30.0
            settings.accelerationGain = 100.0
            // Air mice don't have sticks
            settings.stickMode = .radialMenu
            settings.stickDeadzone = 0
            // Different default button mappings for fewer buttons
            settings.clutchButtons = [.trigger]
            settings.scrollButtons = []
        }

        // Secondary slot typically doesn't control pointer, just sends button events
        if slot == .secondary {
            settings.clutchButtons = []
            settings.scrollButtons = []
            settings.zoomButtons = []
            settings.buttonMappings = .defaultSecondary
        }

        return settings
    }
}

// MARK: - Slot Assignment

/// Tracks which device is assigned to a slot and what type it's configured as
struct SlotAssignment: Codable {
    /// The UUID of the assigned physical device (nil if no device assigned)
    var deviceId: UUID?

    /// The display name of the assigned device (stable identifier from Bluetooth/USB)
    var deviceName: String?

    /// The device type this slot is configured as
    var deviceType: ConfigurableDeviceType

    /// Whether a device is currently assigned
    var hasDevice: Bool { deviceName != nil }

    init(deviceId: UUID? = nil, deviceName: String? = nil, deviceType: ConfigurableDeviceType = .rightJoyCon) {
        self.deviceId = deviceId
        self.deviceName = deviceName
        self.deviceType = deviceType
    }

    // MARK: - Storage

    static func storageKey(slot: DeviceSlot) -> String {
        "\(slot.rawValue)_slot_assignment"
    }

    static func load(slot: DeviceSlot) -> SlotAssignment {
        let key = storageKey(slot: slot)
        guard let data = UserDefaults.standard.data(forKey: key),
              let assignment = try? JSONDecoder().decode(SlotAssignment.self, from: data) else {
            return SlotAssignment()
        }
        return assignment
    }

    func save(slot: DeviceSlot) {
        let key = SlotAssignment.storageKey(slot: slot)
        if let data = try? JSONEncoder().encode(self) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }
}
