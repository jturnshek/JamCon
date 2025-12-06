import Foundation
import os.lock

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
    var sensitivity: Double = 50.0
    var gyroScale: Double = 1.0 / 16.0

    // MARK: Filtering
    var filterEnabled: Bool = true
    var minCutoff: Double = 0.5           // One Euro: base smoothing (Hz)
    var beta: Double = 1.0                // One Euro: speed reactivity
    var adaptiveSmoothingMode: AdaptiveSmoothingMode = .speed

    // MARK: Acceleration
    var accelerationCurve: AccelerationCurve = .power
    var accelerationStrength: Double = 10.0  // 0-20 multiplier
    var sensitivityCap: Double = 20.0        // Max gain (1.0 = no acceleration)

    // MARK: Deadzone
    var softCutoffThreshold: Double = 0.5    // Below this = zero (°/s)
    var recoveryThreshold: Double = 1.5      // Above this = full sensitivity (°/s)

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
        defaults.set(state.accelerationCurve.rawValue, forKey: Keys.accelerationCurve)
        defaults.set(state.accelerationStrength, forKey: Keys.accelerationStrength)
        defaults.set(state.sensitivityCap, forKey: Keys.sensitivityCap)
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
            if let v = defaults.string(forKey: Keys.adaptiveSmoothingMode),
               let mode = AdaptiveSmoothingMode(rawValue: v) {
                state.adaptiveSmoothingMode = mode
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
