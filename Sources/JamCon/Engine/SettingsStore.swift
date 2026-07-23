import Foundation
import os

/// Thread-safe settings store that the InputEngine reads from
/// UI writes to this via update(), Engine reads via snapshot()
/// This is the ONE-WAY bridge: UI → Engine (settings flow down)
final class SettingsStore: @unchecked Sendable {
    private let lock = OSAllocatedUnfairLock()
    private var _settings = InputSettings.loadFromDefaults()

    /// All settings needed by the input engine
    struct InputSettings: Sendable {
        var isEnabled: Bool = true

        // MARK: - Per-Type Gyro Settings
        var gyroSettings: [ControllerKind: GyroSettingsState] = [
            .sense: .defaultForKind(.sense),
            .joyCon: .defaultForKind(.joyCon)
        ]

        // MARK: - Per-Profile Button Mappings
        var senseButtonMappings: [ControllerProfile: SenseButtonMappingProfile] = [:]
        var joyConButtonMappings: [ControllerProfile: JoyConButtonMappingProfile] = [:]
        var g502xButtonMappings: [ControllerProfile: G502XButtonMappingProfile] = [:]

        // MARK: - Per-Profile Cursor Control

        /// Whether this controller profile is allowed to emit cursor/scroll output (gyro + stick scroll).
        /// Defaults to true for all non-mouse profiles.
        var cursorControlEnabledByProfile: [ControllerProfile: Bool] = [:]

        // Global button settings
        var triggerThreshold: UInt8 = 128
        var holdThreshold: Double = 0.3

        // MARK: - Global Joystick Settings
        var joystickScrollEnabled: Bool = true
        var joystickScrollSpeed: Double = 10.0
        var joystickScrollAcceleration: Double = 3.0

        // MARK: - Global Radial Menu
        var radialMenuConfiguration: RadialMenuConfiguration = .load()

        // MARK: - Debug (Non-persisted)

        /// Enables expensive debug recording in the engine (runtime only; not stored in UserDefaults).
        var debugRecordingEnabled: Bool = false

        /// Optional debug capture target (runtime only). When set, the engine records debug samples
        /// only for that controller kind.
        var debugRecordingTargetKind: ControllerKind?

        var joyConUseAveragedGyroSamples: Bool {
            get { gyroSettings[.joyCon]?.joyConUseAveragedGyroSamples ?? false }
            set { gyroSettings[.joyCon]?.joyConUseAveragedGyroSamples = newValue }
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
            for profile in [
                ControllerProfile.joyConLeft, .joyConRight,
                .joyCon2Left, .joyCon2Right,
            ] {
                if JoyConButtonMappingProfile.hasPerProfileSettings(for: profile) {
                    settings.joyConButtonMappings[profile] = .load(for: profile)
                } else {
                    settings.joyConButtonMappings[profile] = .defaultProfile(for: profile)
                }
            }

            // Load G502X button mappings
            let mouseProfile = ControllerProfile.mouse
            if G502XButtonMappingProfile.hasPerProfileSettings(for: mouseProfile) {
                settings.g502xButtonMappings[mouseProfile] = .load(for: mouseProfile)
            } else {
                settings.g502xButtonMappings[mouseProfile] = .default
            }

            // Load per-profile cursor control (defaults to true if unset).
            for profile in ControllerProfile.allProfiles where profile.kind != .mouse {
                let key = "cursorControlEnabled.\(profile.persistenceKey)"
                if UserDefaults.standard.object(forKey: key) != nil {
                    settings.cursorControlEnabledByProfile[profile] = UserDefaults.standard.bool(forKey: key)
                } else {
                    settings.cursorControlEnabledByProfile[profile] = true
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

                // Remove obsolete Joy-Con timing preferences. Raw report
                // processing now always uses the directly measured receipt time.
                defaults.removeObject(forKey: "joycon.timerFallbackEnabled")
                defaults.removeObject(forKey: "joycon.timerHybridEnabled")

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
        assert(Thread.isMainThread, "SettingsStore.update must be called from the main thread")
        // UI-only mutation is an intentionally synchronous lock boundary. The
        // closure itself never escapes to another executor.
        lock.withLockUnchecked {
            block(&_settings)
        }
    }

    /// Replace all settings at once
    func replace(with settings: InputSettings) {
        lock.withLock {
            _settings = settings
        }
    }
}
