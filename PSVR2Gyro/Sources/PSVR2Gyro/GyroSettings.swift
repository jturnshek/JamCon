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

    mutating func resetToDefaults() {
        self = .default
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
    }

    // MARK: - Save/Load

    /// Save current settings to UserDefaults
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
        defaults.set(state.accelerationMode.rawValue, forKey: Keys.accelerationMode)
        defaults.set(state.simpleAcceleration, forKey: Keys.simpleAcceleration)
        defaults.set(state.accelerationCurve.rawValue, forKey: Keys.accelerationCurve)
        defaults.set(state.accelerationStrength, forKey: Keys.accelerationStrength)
        defaults.set(state.sensitivityCap, forKey: Keys.sensitivityCap)
        defaults.set(state.curveExponent, forKey: Keys.curveExponent)
        defaults.set(state.rampSpeed, forKey: Keys.rampSpeed)
        defaults.set(state.softCutoffThreshold, forKey: Keys.softCutoffThreshold)
        defaults.set(state.recoveryThreshold, forKey: Keys.recoveryThreshold)
    }

    /// Load settings from UserDefaults
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
