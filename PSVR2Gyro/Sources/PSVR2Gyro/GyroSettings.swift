import Foundation
import os.lock

// MARK: - Acceleration Mode

/// Simple vs Advanced acceleration configuration mode
enum AccelerationMode: String, CaseIterable, Codable {
    case simple
    case advanced

    var displayName: String {
        switch self {
        case .simple: return "Simple"
        case .advanced: return "Advanced"
        }
    }
}

// MARK: - Acceleration Curve

/// Preset acceleration curve types for gyro-to-mouse translation
enum AccelerationCurve: String, CaseIterable, Codable {
    /// No acceleration - linear 1:1 mapping
    case off
    /// Smooth concave curve approaching cap (most comfortable for most users)
    case natural
    /// Straight-line increase from 1.0 to cap
    case linear
    /// Aggressive curve - accelerates more at high speeds
    case power
    /// Traditional 3-zone approach (precision/ramp/ballistic)
    case classic

    var displayName: String {
        switch self {
        case .off: return "Off"
        case .natural: return "Natural"
        case .linear: return "Linear"
        case .power: return "Power"
        case .classic: return "Classic"
        }
    }

    var description: String {
        switch self {
        case .off:
            return "No acceleration curve applied. Pure 1:1 linear mapping between controller rotation speed and cursor speed. What you physically do is exactly what you get."
        case .natural:
            return "Smooth exponential curve that asymptotically approaches the sensitivity cap. Feels comfortable and predictable. The curve is concave - most of the acceleration happens in the lower speed range, then levels off. Best for general use."
        case .linear:
            return "Straight-line acceleration from 1.0x at zero speed to the sensitivity cap at maximum speed. Very predictable and easy to build muscle memory with, but the transition points can feel abrupt."
        case .power:
            return "Power-law curve (speed^1.2) that accelerates more aggressively at higher speeds. The curve is convex - gentle at low speeds, steep at high speeds. Good for fast-paced gaming where you need big flicks."
        case .classic:
            return "Traditional 3-zone acceleration similar to macOS/Windows pointer ballistics. Zone 1 (0-20°/s): Precision zone with no acceleration. Zone 2 (20-90°/s): Gentle ramp. Zone 3 (90-180°/s): Ballistic zone with full acceleration."
        }
    }
}

// MARK: - Gyro Settings State

/// All gyro processing settings in a single struct for atomic access
struct GyroSettingsState: Equatable {
    // MARK: Core
    var sensitivity: Double = 40.0
    var gyroScale: Double = 1.0 / 16.0

    // MARK: Filtering
    var filterEnabled: Bool = true
    var minCutoff: Double = 2.5           // One Euro: base smoothing (Hz)
    var beta: Double = 1.0                // One Euro: speed reactivity
    var adaptiveSmoothingMode: AdaptiveSmoothingMode = .speedAndJerk

    // MARK: Timing
    /// Expected sample rate (Hz) used for dt clamping and stall detection
    var expectedSampleRate: Double = 60.0
    /// Whether to auto-tune the expected sample rate based on observed dt
    var autoTuneSampleRate: Bool = false
    /// Whether to refresh bias when the controller is very still
    var autoNeutralEnabled: Bool = true

    // MARK: Joy-Con Specific Timing
    /// When device timestamps aren't available, use packet timer to smooth dt
    var joyConTimerFallbackEnabled: Bool = true
    /// Prefer packet timer even when device timestamps are present
    var joyConTimerHybridEnabled: Bool = false

    // MARK: Acceleration
    var accelerationMode: AccelerationMode = .simple
    var simpleAcceleration: Double = 5.0     // 1-10 slider for simple mode

    // Advanced mode parameters (custom parametric curve)
    var curveExponent: Double = 1.0          // < 1 = concave, 1 = linear, > 1 = convex
    var rampSpeed: Double = 150.0            // Speed at which gain reaches cap (°/s)
    var sensitivityCap: Double = 20.0        // Max gain multiplier

    // Legacy (kept for compatibility but not used in new parametric curve)
    var accelerationCurve: AccelerationCurve = .power
    var accelerationStrength: Double = 10.0

    /// Direct curve parameters (simple mode removed)
    var effectiveCurveExponent: Double { curveExponent }
    var effectiveRampSpeed: Double { rampSpeed }
    var effectiveSensitivityCap: Double { sensitivityCap }

    // MARK: Deadzone (kept for backwards compatibility, but not used in processing)
    var softCutoffThreshold: Double = 0.5
    var recoveryThreshold: Double = 1.5

    // MARK: Bias estimation
    /// Motion magnitude threshold (raw units) before bias accumulation resets
    var biasMotionThreshold: Double = 50.0

    // MARK: Defaults

    static let `default` = GyroSettingsState()

    /// Default settings optimized for a specific controller type
    static func defaultForKind(_ kind: ControllerKind) -> GyroSettingsState {
        var state = GyroSettingsState()
        switch kind {
        case .psvr2:
            state.expectedSampleRate = 60.0
            state.biasMotionThreshold = 50.0
        case .joyCon:
            state.expectedSampleRate = 66.0
            state.biasMotionThreshold = 30.0
        }
        return state
    }

    mutating func resetToDefaults() {
        self = .default
    }

    mutating func resetToDefaults(for kind: ControllerKind) {
        self = .defaultForKind(kind)
    }
}

// MARK: - Thread-Safe Settings Container

/// Thread-safe container for gyro settings, accessible from HID callback thread
/// without blocking the main thread.
final class GyroSettings: @unchecked Sendable {

    private let lock = OSAllocatedUnfairLock(initialState: GyroSettingsState())

    // MARK: - Access

    /// Read current settings atomically
    func read() -> GyroSettingsState {
        lock.withLock { $0 }
    }

    /// Update settings atomically
    func update(_ transform: (inout GyroSettingsState) -> Void) {
        lock.withLock { transform(&$0) }
    }

    // MARK: - Persistence Keys

    private enum Keys {
        static let sensitivity = "gyro.sensitivity"
        static let gyroScale = "gyro.gyroScale"
        static let filterEnabled = "gyro.filterEnabled"
        static let minCutoff = "gyro.minCutoff"
        static let beta = "gyro.beta"
        static let adaptiveSmoothingMode = "gyro.adaptiveSmoothingMode"
        static let accelerationMode = "gyro.accelerationMode"
        static let simpleAcceleration = "gyro.simpleAcceleration"
        static let curveExponent = "gyro.curveExponent"
        static let rampSpeed = "gyro.rampSpeed"
        static let accelerationCurve = "gyro.accelerationCurve"
        static let accelerationStrength = "gyro.accelerationStrength"
        static let sensitivityCap = "gyro.sensitivityCap"
        static let softCutoffThreshold = "gyro.softCutoffThreshold"
        static let recoveryThreshold = "gyro.recoveryThreshold"

        /// Generate a per-type key, e.g. "gyro.psvr2.sensitivity"
        static func perType(_ base: String, kind: ControllerKind) -> String {
            "gyro.\(kind.rawValue).\(base)"
        }
    }

    // MARK: - Save/Load (Legacy Global)

    /// Save current settings to UserDefaults (legacy global keys)
    func save() {
        let state = read()
        let defaults = UserDefaults.standard

        defaults.set(state.sensitivity, forKey: Keys.sensitivity)
        defaults.set(state.gyroScale, forKey: Keys.gyroScale)
        defaults.set(state.filterEnabled, forKey: Keys.filterEnabled)
        defaults.set(state.minCutoff, forKey: Keys.minCutoff)
        defaults.set(state.beta, forKey: Keys.beta)
        defaults.set(state.adaptiveSmoothingMode.rawValue, forKey: Keys.adaptiveSmoothingMode)
        defaults.set(state.expectedSampleRate, forKey: "gyro.expectedSampleRate")
        defaults.set(state.biasMotionThreshold, forKey: "gyro.biasMotionThreshold")
        defaults.set(state.autoNeutralEnabled, forKey: "gyro.autoNeutralEnabled")
        defaults.set(state.accelerationMode.rawValue, forKey: Keys.accelerationMode)
        defaults.set(state.simpleAcceleration, forKey: Keys.simpleAcceleration)
        defaults.set(state.accelerationCurve.rawValue, forKey: Keys.accelerationCurve)
        defaults.set(state.accelerationStrength, forKey: Keys.accelerationStrength)
        defaults.set(state.sensitivityCap, forKey: Keys.sensitivityCap)
        defaults.set(state.curveExponent, forKey: Keys.curveExponent)
        defaults.set(state.rampSpeed, forKey: Keys.rampSpeed)
        defaults.set(state.softCutoffThreshold, forKey: Keys.softCutoffThreshold)
        defaults.set(state.recoveryThreshold, forKey: Keys.recoveryThreshold)
        defaults.set(state.autoTuneSampleRate, forKey: "gyro.autoTuneSampleRate")
    }

    /// Load settings from UserDefaults (legacy global keys)
    static func load() -> GyroSettings {
        let settings = GyroSettings()
        let defaults = UserDefaults.standard

        settings.update { state in
            if let v = defaults.object(forKey: Keys.sensitivity) as? Double {
                state.sensitivity = v
            }
            if let v = defaults.object(forKey: Keys.gyroScale) as? Double {
                state.gyroScale = v
            }
            if let v = defaults.object(forKey: Keys.filterEnabled) as? Bool {
                state.filterEnabled = v
            }
            if let v = defaults.object(forKey: Keys.minCutoff) as? Double {
                state.minCutoff = v
            }
            if let v = defaults.object(forKey: Keys.beta) as? Double {
                state.beta = v
            }
            if let v = defaults.object(forKey: "gyro.expectedSampleRate") as? Double, v > 0 {
                state.expectedSampleRate = v
            }
            if let v = defaults.object(forKey: "gyro.biasMotionThreshold") as? Double, v > 0 {
                state.biasMotionThreshold = v
            }
            if let v = defaults.object(forKey: "gyro.autoNeutralEnabled") as? Bool {
                state.autoNeutralEnabled = v
            }
            if let v = defaults.object(forKey: "gyro.autoTuneSampleRate") as? Bool {
                state.autoTuneSampleRate = v
            }
            if let v = defaults.string(forKey: Keys.adaptiveSmoothingMode),
               let mode = AdaptiveSmoothingMode(rawValue: v) {
                state.adaptiveSmoothingMode = mode
            }
            if let v = defaults.string(forKey: Keys.accelerationMode),
               let mode = AccelerationMode(rawValue: v) {
                state.accelerationMode = mode
            }
            if let v = defaults.object(forKey: Keys.simpleAcceleration) as? Double {
                state.simpleAcceleration = v
            }
            if let v = defaults.string(forKey: Keys.accelerationCurve),
               let curve = AccelerationCurve(rawValue: v) {
                state.accelerationCurve = curve
            }
            if let v = defaults.object(forKey: Keys.accelerationStrength) as? Double {
                state.accelerationStrength = v
            }
            if let v = defaults.object(forKey: Keys.sensitivityCap) as? Double {
                state.sensitivityCap = v
            }
            if let v = defaults.object(forKey: Keys.curveExponent) as? Double {
                state.curveExponent = v
            }
            if let v = defaults.object(forKey: Keys.rampSpeed) as? Double {
                state.rampSpeed = v
            }
            if let v = defaults.object(forKey: Keys.softCutoffThreshold) as? Double {
                state.softCutoffThreshold = v
            }
            if let v = defaults.object(forKey: Keys.recoveryThreshold) as? Double {
                state.recoveryThreshold = v
            }
        }

        return settings
    }

    /// Reset to defaults and save
    func resetToDefaults() {
        update { $0.resetToDefaults() }
        save()
    }
}

// MARK: - Per-Type Gyro Settings Persistence

extension GyroSettingsState {
    /// Save this state to UserDefaults for a specific controller type
    func save(for kind: ControllerKind) {
        let defaults = UserDefaults.standard
        let prefix = "gyro.\(kind.rawValue)"

        defaults.set(sensitivity, forKey: "\(prefix).sensitivity")
        defaults.set(gyroScale, forKey: "\(prefix).gyroScale")
        defaults.set(filterEnabled, forKey: "\(prefix).filterEnabled")
        defaults.set(minCutoff, forKey: "\(prefix).minCutoff")
        defaults.set(beta, forKey: "\(prefix).beta")
        defaults.set(adaptiveSmoothingMode.rawValue, forKey: "\(prefix).adaptiveSmoothingMode")
        defaults.set(expectedSampleRate, forKey: "\(prefix).expectedSampleRate")
        defaults.set(biasMotionThreshold, forKey: "\(prefix).biasMotionThreshold")
        defaults.set(autoNeutralEnabled, forKey: "\(prefix).autoNeutralEnabled")
        defaults.set(autoTuneSampleRate, forKey: "\(prefix).autoTuneSampleRate")
        defaults.set(accelerationMode.rawValue, forKey: "\(prefix).accelerationMode")
        defaults.set(simpleAcceleration, forKey: "\(prefix).simpleAcceleration")
        defaults.set(accelerationCurve.rawValue, forKey: "\(prefix).accelerationCurve")
        defaults.set(accelerationStrength, forKey: "\(prefix).accelerationStrength")
        defaults.set(sensitivityCap, forKey: "\(prefix).sensitivityCap")
        defaults.set(curveExponent, forKey: "\(prefix).curveExponent")
        defaults.set(rampSpeed, forKey: "\(prefix).rampSpeed")
        defaults.set(softCutoffThreshold, forKey: "\(prefix).softCutoffThreshold")
        defaults.set(recoveryThreshold, forKey: "\(prefix).recoveryThreshold")

        // Joy-Con specific
        if kind == .joyCon {
            defaults.set(joyConTimerFallbackEnabled, forKey: "\(prefix).timerFallbackEnabled")
            defaults.set(joyConTimerHybridEnabled, forKey: "\(prefix).timerHybridEnabled")
        }
    }

    /// Load state from UserDefaults for a specific controller type
    static func load(for kind: ControllerKind) -> GyroSettingsState {
        var state = GyroSettingsState.defaultForKind(kind)
        let defaults = UserDefaults.standard
        let prefix = "gyro.\(kind.rawValue)"

        if let v = defaults.object(forKey: "\(prefix).sensitivity") as? Double {
            state.sensitivity = v
        }
        if let v = defaults.object(forKey: "\(prefix).gyroScale") as? Double {
            state.gyroScale = v
        }
        if let v = defaults.object(forKey: "\(prefix).filterEnabled") as? Bool {
            state.filterEnabled = v
        }
        if let v = defaults.object(forKey: "\(prefix).minCutoff") as? Double {
            state.minCutoff = v
        }
        if let v = defaults.object(forKey: "\(prefix).beta") as? Double {
            state.beta = v
        }
        if let v = defaults.string(forKey: "\(prefix).adaptiveSmoothingMode"),
           let mode = AdaptiveSmoothingMode(rawValue: v) {
            state.adaptiveSmoothingMode = mode
        }
        if let v = defaults.object(forKey: "\(prefix).expectedSampleRate") as? Double, v > 0 {
            state.expectedSampleRate = v
        }
        if let v = defaults.object(forKey: "\(prefix).biasMotionThreshold") as? Double, v > 0 {
            state.biasMotionThreshold = v
        }
        if let v = defaults.object(forKey: "\(prefix).autoNeutralEnabled") as? Bool {
            state.autoNeutralEnabled = v
        }
        if let v = defaults.object(forKey: "\(prefix).autoTuneSampleRate") as? Bool {
            state.autoTuneSampleRate = v
        }
        if let v = defaults.string(forKey: "\(prefix).accelerationMode"),
           let mode = AccelerationMode(rawValue: v) {
            state.accelerationMode = mode
        }
        if let v = defaults.object(forKey: "\(prefix).simpleAcceleration") as? Double {
            state.simpleAcceleration = v
        }
        if let v = defaults.string(forKey: "\(prefix).accelerationCurve"),
           let curve = AccelerationCurve(rawValue: v) {
            state.accelerationCurve = curve
        }
        if let v = defaults.object(forKey: "\(prefix).accelerationStrength") as? Double {
            state.accelerationStrength = v
        }
        if let v = defaults.object(forKey: "\(prefix).sensitivityCap") as? Double {
            state.sensitivityCap = v
        }
        if let v = defaults.object(forKey: "\(prefix).curveExponent") as? Double {
            state.curveExponent = v
        }
        if let v = defaults.object(forKey: "\(prefix).rampSpeed") as? Double {
            state.rampSpeed = v
        }
        if let v = defaults.object(forKey: "\(prefix).softCutoffThreshold") as? Double {
            state.softCutoffThreshold = v
        }
        if let v = defaults.object(forKey: "\(prefix).recoveryThreshold") as? Double {
            state.recoveryThreshold = v
        }

        // Joy-Con specific
        if kind == .joyCon {
            if let v = defaults.object(forKey: "\(prefix).timerFallbackEnabled") as? Bool {
                state.joyConTimerFallbackEnabled = v
            }
            if let v = defaults.object(forKey: "\(prefix).timerHybridEnabled") as? Bool {
                state.joyConTimerHybridEnabled = v
            }
        }

        return state
    }

    /// Check if per-type settings exist for this controller kind
    static func hasPerTypeSettings(for kind: ControllerKind) -> Bool {
        let prefix = "gyro.\(kind.rawValue)"
        return UserDefaults.standard.object(forKey: "\(prefix).sensitivity") != nil
    }
}
