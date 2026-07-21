import Foundation

// MARK: - One Euro Filter (Adaptive Low-Pass)

/// Adaptive low-pass filter that increases smoothing for slow motion and removes it for fast motion.
/// Based on "The One Euro Filter" (Casiez et al., CHI 2012).
///
/// Key insight: Use a low cutoff for slow movements (reduces jitter) and a high cutoff for
/// fast movements (reduces lag). The cutoff frequency adapts based on the rate of change.
///
/// References:
/// - Paper: https://hal.inria.fr/hal-00670496/document
/// - Demo: https://cristal.univ-lille.fr/~casiez/1euro/
final class OneEuroFilter: @unchecked Sendable {

    // MARK: - Configuration

    /// Base cutoff frequency in Hz (higher = less smoothing at low speeds)
    /// Range: 0.1 - 10.0, Default: 1.5
    var minCutoff: Double = 1.5

    /// Speed coefficient (higher = less smoothing when moving fast)
    /// Range: 0.0 - 2.0, Default: 0.35
    var beta: Double = 0.35

    /// Cutoff frequency for derivative smoothing (fixed, rarely needs tuning)
    var derivativeCutoff: Double = 1.0

    /// Fallback sample rate when timestamps are missing or invalid
    var fallbackRate: Double = 120.0

    // MARK: - State

    private var previousRawValue: Double?
    private var previousFilteredValue: Double?
    private var previousDerivative: Double = 0
    private var previousTime: TimeInterval?
    private static let twoPi: Double = 2.0 * Double.pi

    // MARK: - Core Algorithm

    /// Compute smoothing factor alpha for a given cutoff frequency and time delta
    /// α = 1 / (1 + τ/dt) where τ = 1/(2πf)
    private func alpha(cutoff: Double, dt: Double) -> Double {
        let safeCutoff = max(0.001, cutoff)
        let safeDt = max(0.000_001, dt)
        let tau = 1.0 / (Self.twoPi * safeCutoff)
        return 1.0 / (1.0 + tau / safeDt)
    }

    /// Filter a value with adaptive smoothing
    /// - Parameters:
    ///   - value: The raw input value
    ///   - timestamp: Monotonic timestamp for this sample
    /// - Returns: Filtered value with reduced jitter and minimal lag
    func filter(value: Double, timestamp: TimeInterval) -> Double {
        // Compute time delta
        let fallbackDt = 1.0 / max(1.0, fallbackRate)
        let hasMonotonicTimestamp = timestamp.isFinite
            && (previousTime == nil || timestamp > (previousTime ?? timestamp))
        let dt: Double
        if let prevTime = previousTime, hasMonotonicTimestamp {
            dt = timestamp - prevTime
        } else {
            dt = fallbackDt
        }

        // Compute derivative (rate of change)
        let rawDerivative: Double
        if let prev = previousRawValue {
            rawDerivative = (value - prev) / dt
        } else {
            rawDerivative = 0
        }

        // Smooth the derivative to avoid noise amplification
        let alphaD = alpha(cutoff: derivativeCutoff, dt: dt)
        let derivative = alphaD * rawDerivative + (1 - alphaD) * previousDerivative

        // Adaptive cutoff: increase when moving fast
        let cutoff = minCutoff + beta * abs(derivative)

        // Apply low-pass filter with adaptive cutoff
        let alphaV = alpha(cutoff: cutoff, dt: dt)
        let filteredValue = alphaV * value
            + (1 - alphaV) * (previousFilteredValue ?? value)

        // Update state
        if hasMonotonicTimestamp {
            previousTime = timestamp
        }
        previousRawValue = value
        previousFilteredValue = filteredValue
        previousDerivative = derivative

        return filteredValue
    }

    /// Reset filter state (call when input source changes or after a pause)
    func reset() {
        previousRawValue = nil
        previousFilteredValue = nil
        previousDerivative = 0
        previousTime = nil
    }
}

// MARK: - Adaptive Smoothing Mode

/// Mode for dynamic filter adjustment based on motion characteristics
enum AdaptiveSmoothingMode: String, CaseIterable, Codable {
    /// Static beta value (no adaptation)
    case off
    /// Beta increases with angular velocity
    case speed
    /// Beta increases with both velocity and jerk (rate of velocity change)
    case speedAndJerk

    var displayName: String {
        switch self {
        case .off: return "Off"
        case .speed: return "Speed"
        case .speedAndJerk: return "Speed + Jerk"
        }
    }
}
