import Foundation
import os

/// Thread-safe settings store that the InputEngine reads from
/// UI writes to this via update(), Engine reads via snapshot()
/// This is the ONE-WAY bridge: UI → Engine (settings flow down)
final class SettingsStore: @unchecked Sendable {
    private let lock = OSAllocatedUnfairLock()
    private var _settings = InputSettings.loadFromDefaults()

    /// All settings needed by the input engine
    struct InputSettings {
        // MARK: - Controller Selection
        var isEnabled: Bool = true
        var activeProfile: ControllerProfile = .senseRight

        // MARK: - Per-Type Gyro Settings
        var gyroSettings: [ControllerKind: GyroSettingsState] = [
            .sense: .defaultForKind(.sense),
            .joyCon: .defaultForKind(.joyCon)
        ]

        // MARK: - Per-Profile Button Mappings
        var senseButtonMappings: [ControllerProfile: SenseButtonMappingProfile] = [:]
        var joyConButtonMappings: [ControllerProfile: JoyConButtonMappingProfile] = [:]

        // Global button settings
        var triggerThreshold: UInt8 = 128
        var holdThreshold: Double = 0.3

        // MARK: - Global Joystick Settings
        var joystickScrollEnabled: Bool = true
        var joystickScrollSpeed: Double = 10.0
        var joystickScrollAcceleration: Double = 3.0

        // MARK: - Global Radial Menu
        var radialMenuConfiguration: RadialMenuConfiguration = .load()

        // MARK: - Convenience Accessors

        /// Current gyro settings for the active controller type
        var currentGyroSettings: GyroSettingsState {
            get { gyroSettings[activeProfile.kind] ?? .defaultForKind(activeProfile.kind) }
            set { gyroSettings[activeProfile.kind] = newValue }
        }

        /// Current Sense button mapping for the active profile
        var currentSenseButtonMapping: SenseButtonMappingProfile {
            get { senseButtonMappings[activeProfile] ?? .load(for: activeProfile) }
            set { senseButtonMappings[activeProfile] = newValue }
        }

        /// Current Joy-Con button mapping for the active profile
        var currentJoyConButtonMapping: JoyConButtonMappingProfile {
            get { joyConButtonMappings[activeProfile] ?? .load(for: activeProfile) }
            set { joyConButtonMappings[activeProfile] = newValue }
        }

        // MARK: - Legacy Accessors (for backwards compatibility during migration)

        var isLeftController: Bool {
            get { activeProfile.isLeft }
            set {
                activeProfile = ControllerProfile(kind: activeProfile.kind, isLeft: newValue)
            }
        }

        var activeControllerKind: ControllerKind {
            get { activeProfile.kind }
            set {
                activeProfile = ControllerProfile(kind: newValue, isLeft: activeProfile.isLeft)
            }
        }

        // Flat gyro accessors that read/write to the current type's settings
        var sensitivity: Double {
            get { currentGyroSettings.sensitivity }
            set { gyroSettings[activeProfile.kind]?.sensitivity = newValue }
        }

        var gyroScale: Double {
            get { currentGyroSettings.gyroScale }
            set { gyroSettings[activeProfile.kind]?.gyroScale = newValue }
        }

        var filterEnabled: Bool {
            get { currentGyroSettings.filterEnabled }
            set { gyroSettings[activeProfile.kind]?.filterEnabled = newValue }
        }

        var minCutoff: Double {
            get { currentGyroSettings.minCutoff }
            set { gyroSettings[activeProfile.kind]?.minCutoff = newValue }
        }

        var beta: Double {
            get { currentGyroSettings.beta }
            set { gyroSettings[activeProfile.kind]?.beta = newValue }
        }

        var adaptiveSmoothingMode: AdaptiveSmoothingMode {
            get { currentGyroSettings.adaptiveSmoothingMode }
            set { gyroSettings[activeProfile.kind]?.adaptiveSmoothingMode = newValue }
        }

        var expectedSampleRate: Double {
            get { currentGyroSettings.expectedSampleRate }
            set { gyroSettings[activeProfile.kind]?.expectedSampleRate = newValue }
        }

        var biasMotionThreshold: Double {
            get { currentGyroSettings.biasMotionThreshold }
            set { gyroSettings[activeProfile.kind]?.biasMotionThreshold = newValue }
        }

        var autoTuneSampleRate: Bool {
            get { currentGyroSettings.autoTuneSampleRate }
            set { gyroSettings[activeProfile.kind]?.autoTuneSampleRate = newValue }
        }

        var autoNeutralEnabled: Bool {
            get { currentGyroSettings.autoNeutralEnabled }
            set { gyroSettings[activeProfile.kind]?.autoNeutralEnabled = newValue }
        }

        var joyConTimerFallbackEnabled: Bool {
            get { gyroSettings[.joyCon]?.joyConTimerFallbackEnabled ?? true }
            set { gyroSettings[.joyCon]?.joyConTimerFallbackEnabled = newValue }
        }

        var joyConTimerHybridEnabled: Bool {
            get { gyroSettings[.joyCon]?.joyConTimerHybridEnabled ?? false }
            set { gyroSettings[.joyCon]?.joyConTimerHybridEnabled = newValue }
        }

        var accelerationMode: AccelerationMode {
            get { currentGyroSettings.accelerationMode }
            set { gyroSettings[activeProfile.kind]?.accelerationMode = newValue }
        }

        var simpleAcceleration: Double {
            get { currentGyroSettings.simpleAcceleration }
            set { gyroSettings[activeProfile.kind]?.simpleAcceleration = newValue }
        }

        var curveExponent: Double {
            get { currentGyroSettings.curveExponent }
            set { gyroSettings[activeProfile.kind]?.curveExponent = newValue }
        }

        var rampSpeed: Double {
            get { currentGyroSettings.rampSpeed }
            set { gyroSettings[activeProfile.kind]?.rampSpeed = newValue }
        }

        var sensitivityCap: Double {
            get { currentGyroSettings.sensitivityCap }
            set { gyroSettings[activeProfile.kind]?.sensitivityCap = newValue }
        }

        var accelerationCurve: AccelerationCurve {
            get { currentGyroSettings.accelerationCurve }
            set { gyroSettings[activeProfile.kind]?.accelerationCurve = newValue }
        }

        var accelerationStrength: Double {
            get { currentGyroSettings.accelerationStrength }
            set { gyroSettings[activeProfile.kind]?.accelerationStrength = newValue }
        }

        var softCutoffThreshold: Double {
            get { currentGyroSettings.softCutoffThreshold }
            set { gyroSettings[activeProfile.kind]?.softCutoffThreshold = newValue }
        }

        var recoveryThreshold: Double {
            get { currentGyroSettings.recoveryThreshold }
            set { gyroSettings[activeProfile.kind]?.recoveryThreshold = newValue }
        }

        // Legacy button mapping accessors
        var buttonMappingProfile: SenseButtonMappingProfile {
            get { currentSenseButtonMapping }
            set { senseButtonMappings[activeProfile] = newValue }
        }

        var joyConButtonMappingProfile: JoyConButtonMappingProfile {
            get { currentJoyConButtonMapping }
            set { joyConButtonMappings[activeProfile] = newValue }
        }

        // MARK: - Persistence

        private static let settingsVersionKey = "settings.version"
        private static let currentVersion = 3

        static func loadFromDefaults() -> InputSettings {
            var settings = InputSettings()

            // Check if we need to migrate
            let version = UserDefaults.standard.integer(forKey: settingsVersionKey)
            if version < currentVersion {
                migrateSettings(from: version)
                UserDefaults.standard.set(currentVersion, forKey: settingsVersionKey)
            }

            // Load per-type gyro settings
            for kind in ControllerKind.allCases {
                if GyroSettingsState.hasPerTypeSettings(for: kind) {
                    settings.gyroSettings[kind] = .load(for: kind)
                } else {
                    // Fall back to defaults with type-specific tuning
                    settings.gyroSettings[kind] = .defaultForKind(kind)
                }
            }

            // Load per-profile button mappings for Sense
            for profile in [ControllerProfile.senseLeft, .senseRight] {
                settings.senseButtonMappings[profile] = .load(for: profile)
            }

            // Load per-profile button mappings for Joy-Con
            for profile in [ControllerProfile.joyConLeft, .joyConRight] {
                if JoyConButtonMappingProfile.hasPerProfileSettings(for: profile) {
                    settings.joyConButtonMappings[profile] = .load(for: profile)
                } else {
                    settings.joyConButtonMappings[profile] = .defaultProfile(for: profile)
                }
            }

            // Load global trigger/hold thresholds
            let senseProfile = settings.senseButtonMappings[.senseRight] ?? .load()
            settings.triggerThreshold = senseProfile.triggerThreshold
            settings.holdThreshold = senseProfile.holdThreshold

            // Load global joystick settings
            // Use object(forKey:) to check if the key exists; default to true for new installs
            if UserDefaults.standard.object(forKey: "joystick.scrollEnabled") != nil {
                settings.joystickScrollEnabled = UserDefaults.standard.bool(forKey: "joystick.scrollEnabled")
            } else {
                settings.joystickScrollEnabled = true
            }
            let savedSpeed = UserDefaults.standard.double(forKey: "joystick.scrollSpeed")
            settings.joystickScrollSpeed = savedSpeed > 0 ? savedSpeed : 10.0
            let savedAccel = UserDefaults.standard.double(forKey: "joystick.scrollAcceleration")
            settings.joystickScrollAcceleration = savedAccel > 0 ? savedAccel : 3.0

            // Load global radial menu
            settings.radialMenuConfiguration = .load()

            return settings
        }

        /// Migrate settings from an older version
        private static func migrateSettings(from version: Int) {
            let defaults = UserDefaults.standard

            if version < 3 {
                // Migrate global gyro settings to per-type
                let legacyGyro = GyroSettings.load().read()

                // Copy legacy settings to both controller types
                for kind in ControllerKind.allCases {
                    var state = GyroSettingsState.defaultForKind(kind)
                    state.sensitivity = legacyGyro.sensitivity
                    state.gyroScale = legacyGyro.gyroScale
                    state.filterEnabled = legacyGyro.filterEnabled
                    state.minCutoff = legacyGyro.minCutoff
                    state.beta = legacyGyro.beta
                    state.adaptiveSmoothingMode = legacyGyro.adaptiveSmoothingMode
                    state.autoTuneSampleRate = legacyGyro.autoTuneSampleRate
                    state.autoNeutralEnabled = legacyGyro.autoNeutralEnabled
                    state.accelerationMode = legacyGyro.accelerationMode
                    state.simpleAcceleration = legacyGyro.simpleAcceleration
                    state.curveExponent = legacyGyro.curveExponent
                    state.rampSpeed = legacyGyro.rampSpeed
                    state.sensitivityCap = legacyGyro.sensitivityCap
                    state.accelerationCurve = legacyGyro.accelerationCurve
                    state.accelerationStrength = legacyGyro.accelerationStrength
                    state.softCutoffThreshold = legacyGyro.softCutoffThreshold
                    state.recoveryThreshold = legacyGyro.recoveryThreshold
                    state.save(for: kind)
                }

                // Migrate Joy-Con timing from legacy keys
                if let v = defaults.object(forKey: "joycon.timerFallbackEnabled") as? Bool {
                    var joyConState = GyroSettingsState.load(for: .joyCon)
                    joyConState.joyConTimerFallbackEnabled = v
                    joyConState.save(for: .joyCon)
                    defaults.removeObject(forKey: "joycon.timerFallbackEnabled")
                }
                if let v = defaults.object(forKey: "joycon.timerHybridEnabled") as? Bool {
                    var joyConState = GyroSettingsState.load(for: .joyCon)
                    joyConState.joyConTimerHybridEnabled = v
                    joyConState.save(for: .joyCon)
                    defaults.removeObject(forKey: "joycon.timerHybridEnabled")
                }

                // Migrate button mappings to per-profile
                let legacySense = SenseButtonMappingProfile.load()
                legacySense.save(for: .senseLeft)
                legacySense.save(for: .senseRight)

                let legacyJoyCon = JoyConButtonMappingProfile.load()
                // For Joy-Con, create side-specific defaults
                JoyConButtonMappingProfile.defaultProfile(for: .joyConLeft).save(for: .joyConLeft)
                legacyJoyCon.save(for: .joyConRight)
            }
        }

        /// Convert current gyro settings to GyroSettingsState for the GyroProcessor
        func toGyroSettingsState() -> GyroSettingsState {
            currentGyroSettings
        }
    }

    // MARK: - Thread-Safe Access

    /// Read current settings - called from HID thread
    /// This is a fast, lock-protected read
    func snapshot() -> InputSettings {
        lock.withLock { _settings }
    }

    /// Update settings - called from main thread
    /// The block receives a mutable copy of settings
    func update(_ block: (inout InputSettings) -> Void) {
        lock.withLock {
            block(&_settings)
        }
    }

    /// Replace all settings at once
    func replace(with settings: InputSettings) {
        lock.withLock {
            _settings = settings
        }
    }

    // MARK: - Convenience Accessors (for UI binding)

    var isEnabled: Bool {
        get { lock.withLock { _settings.isEnabled } }
        set { lock.withLock { _settings.isEnabled = newValue } }
    }

    var activeProfile: ControllerProfile {
        get { lock.withLock { _settings.activeProfile } }
        set { lock.withLock { _settings.activeProfile = newValue } }
    }

    var isLeftController: Bool {
        get { lock.withLock { _settings.isLeftController } }
        set { lock.withLock { _settings.isLeftController = newValue } }
    }

    var activeControllerKind: ControllerKind {
        get { lock.withLock { _settings.activeControllerKind } }
        set { lock.withLock { _settings.activeControllerKind = newValue } }
    }
}
