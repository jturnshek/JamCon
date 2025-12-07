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
        var isLeftController: Bool = false
        var activeControllerKind: ControllerKind = .psvr2

        // MARK: - Gyro Settings
        var sensitivity: Double = 40.0
        var gyroScale: Double = 1.0 / 16.0
        var filterEnabled: Bool = true
        var minCutoff: Double = 2.5
        var beta: Double = 1.0
        var adaptiveSmoothingMode: AdaptiveSmoothingMode = .speedAndJerk

        // MARK: - Acceleration (matches GyroSettingsState order)
        var accelerationMode: AccelerationMode = .simple
        var simpleAcceleration: Double = 5.0
        var curveExponent: Double = 1.0
        var rampSpeed: Double = 150.0
        var sensitivityCap: Double = 20.0
        var accelerationCurve: AccelerationCurve = .power
        var accelerationStrength: Double = 10.0
        var softCutoffThreshold: Double = 0.5
        var recoveryThreshold: Double = 1.5

        // MARK: - Button Mappings
        var buttonMappingProfile: PSVR2ButtonMappingProfile = .load()
        var triggerThreshold: UInt8 = 128
        var holdThreshold: Double = 0.3

        // MARK: - Joystick
        var joystickScrollEnabled: Bool = false
        var joystickScrollSpeed: Double = 5.0
        var joystickScrollAcceleration: Double = 1.0

        // MARK: - Radial Menu
        var radialMenuConfiguration: RadialMenuConfiguration = .load()

        // MARK: - Persistence

        static func loadFromDefaults() -> InputSettings {
            var settings = InputSettings()

            // Load gyro settings from GyroSettings (existing persistence)
            let gyroSettings = GyroSettings.load()
            let gyroState = gyroSettings.read()
            settings.sensitivity = gyroState.sensitivity
            settings.gyroScale = gyroState.gyroScale
            settings.filterEnabled = gyroState.filterEnabled
            settings.minCutoff = gyroState.minCutoff
            settings.beta = gyroState.beta
            settings.adaptiveSmoothingMode = gyroState.adaptiveSmoothingMode
            settings.accelerationMode = gyroState.accelerationMode
            settings.simpleAcceleration = gyroState.simpleAcceleration
            settings.accelerationCurve = gyroState.accelerationCurve
            settings.accelerationStrength = gyroState.accelerationStrength
            settings.sensitivityCap = gyroState.sensitivityCap
            settings.curveExponent = gyroState.curveExponent
            settings.rampSpeed = gyroState.rampSpeed
            settings.softCutoffThreshold = gyroState.softCutoffThreshold
            settings.recoveryThreshold = gyroState.recoveryThreshold

            // Load button mapping
            settings.buttonMappingProfile = .load()
            settings.triggerThreshold = settings.buttonMappingProfile.triggerThreshold
            settings.holdThreshold = settings.buttonMappingProfile.holdThreshold

            // Load joystick settings
            settings.joystickScrollEnabled = UserDefaults.standard.bool(forKey: "joystick.scrollEnabled")
            let savedSpeed = UserDefaults.standard.double(forKey: "joystick.scrollSpeed")
            settings.joystickScrollSpeed = savedSpeed > 0 ? savedSpeed : 5.0
            let savedAccel = UserDefaults.standard.double(forKey: "joystick.scrollAcceleration")
            settings.joystickScrollAcceleration = savedAccel > 0 ? savedAccel : 1.0

            // Load radial menu
            settings.radialMenuConfiguration = .load()

            return settings
        }

        /// Convert to GyroSettingsState for the GyroProcessor
        func toGyroSettingsState() -> GyroSettingsState {
            var state = GyroSettingsState()
            state.sensitivity = sensitivity
            state.gyroScale = gyroScale
            state.filterEnabled = filterEnabled
            state.minCutoff = minCutoff
            state.beta = beta
            state.adaptiveSmoothingMode = adaptiveSmoothingMode
            state.accelerationMode = accelerationMode
            state.simpleAcceleration = simpleAcceleration
            state.curveExponent = curveExponent
            state.rampSpeed = rampSpeed
            state.sensitivityCap = sensitivityCap
            state.accelerationCurve = accelerationCurve
            state.accelerationStrength = accelerationStrength
            state.softCutoffThreshold = softCutoffThreshold
            state.recoveryThreshold = recoveryThreshold
            return state
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

    var isLeftController: Bool {
        get { lock.withLock { _settings.isLeftController } }
        set { lock.withLock { _settings.isLeftController = newValue } }
    }

    var activeControllerKind: ControllerKind {
        get { lock.withLock { _settings.activeControllerKind } }
        set { lock.withLock { _settings.activeControllerKind = newValue } }
    }
}
