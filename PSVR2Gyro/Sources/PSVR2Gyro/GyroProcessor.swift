import Foundation
import CoreGraphics

// MARK: - Gyro Processor

/// Converts raw gyroscope data to mouse movement using professional-grade signal processing.
///
/// Processing Pipeline:
/// ```
/// Raw Gyro → Bias Calibration → Soft Cutoff → One Euro Filter → Acceleration Curve → Sensitivity Scale → Mouse Delta
/// ```
final class GyroProcessor: @unchecked Sendable {

    // MARK: - Bias Estimation

    private var biasX: Double = 0
    private var biasY: Double = 0
    private var biasZ: Double = 0
    private var biasSamples: [(x: Double, y: Double, z: Double)] = []
    private let maxBiasSamples = 64
    private let motionThreshold: Double = 50.0  // Raw units

    // MARK: - Filtering

    private let yawFilter = OneEuroFilter()
    private let pitchFilter = OneEuroFilter()
    private var lastTimestamp: TimeInterval?

    // MARK: - Adaptive Smoothing State

    private var lastSpeed: Double = 0
    private var lastSpeedEMA: Double = 0
    private var lastJerkEMA: Double = 0

    // MARK: - Processing

    /// Process raw gyro data and return mouse deltas
    /// - Parameters:
    ///   - rawX: Raw X-axis gyro value (pitch)
    ///   - rawY: Raw Y-axis gyro value (roll)
    ///   - rawZ: Raw Z-axis gyro value (yaw)
    ///   - timestamp: Monotonic timestamp
    ///   - settings: Thread-safe settings snapshot
    /// - Returns: (dx, dy) mouse movement, or nil if no movement
    func process(
        rawX: Int16,
        rawY: Int16,
        rawZ: Int16,
        timestamp: TimeInterval,
        settings: GyroSettingsState
    ) -> (dx: CGFloat, dy: CGFloat)? {

        // 1. Convert to doubles
        let x = Double(rawX)
        let y = Double(rawY)
        let z = Double(rawZ)

        // 2. Calculate dt
        let dt: Double
        if let last = lastTimestamp {
            dt = max(0.001, timestamp - last)
        } else {
            dt = 1.0 / 60.0
        }
        lastTimestamp = timestamp

        // 3. Update bias estimation when stationary
        updateBias(x: x, y: y, z: z)

        // 4. Apply bias correction
        let calibratedX = x - biasX
        let calibratedY = y - biasY
        _ = z - biasZ  // Z (roll) not used for mouse control

        // 5. Convert to degrees/second
        // Based on PSVR2 Sense controller characteristics:
        // Y axis = left/right pointing (yaw), X axis = up/down tilting (pitch)
        let degreesYaw = calibratedY * settings.gyroScale
        let degreesPitch = calibratedX * settings.gyroScale

        // Apply axis inversions for natural direction
        var yaw = -degreesYaw    // Invert for natural left/right
        var pitch = -degreesPitch  // Invert for natural up/down

        // 6. Apply soft cutoff (smooth deadzone)
        yaw = applySoftCutoff(
            value: yaw,
            cutoff: settings.softCutoffThreshold,
            recovery: settings.recoveryThreshold
        )
        pitch = applySoftCutoff(
            value: pitch,
            cutoff: settings.softCutoffThreshold,
            recovery: settings.recoveryThreshold
        )

        // Skip if no movement after cutoff
        if yaw == 0 && pitch == 0 {
            return nil
        }

        // 7. Apply One Euro filter (if enabled)
        var filteredYaw = yaw
        var filteredPitch = pitch

        if settings.filterEnabled {
            // Update filter parameters
            let adaptiveBeta = computeAdaptiveBeta(
                yaw: yaw,
                pitch: pitch,
                baseBeta: settings.beta,
                dt: dt,
                mode: settings.adaptiveSmoothingMode
            )

            yawFilter.minCutoff = settings.minCutoff
            yawFilter.beta = adaptiveBeta
            pitchFilter.minCutoff = settings.minCutoff
            pitchFilter.beta = adaptiveBeta

            filteredYaw = yawFilter.filter(value: yaw, timestamp: timestamp)
            filteredPitch = pitchFilter.filter(value: pitch, timestamp: timestamp)
        }

        // 8. Calculate speed for acceleration curve
        let speed = sqrt(filteredYaw * filteredYaw + filteredPitch * filteredPitch)
        let smoothedSpeed = smoothSpeed(speed)

        // 9. Apply acceleration curve
        let accelGain = computeAccelerationGain(
            speed: smoothedSpeed,
            curve: settings.accelerationCurve,
            strength: settings.accelerationStrength,
            cap: settings.sensitivityCap
        )

        // 10. Convert to mouse deltas
        let scale = settings.sensitivity * 0.1
        let dx = CGFloat(filteredYaw * dt * scale * accelGain)
        let dy = CGFloat(filteredPitch * dt * scale * accelGain)

        return (dx, dy)
    }

    // MARK: - Bias Estimation

    private func updateBias(x: Double, y: Double, z: Double) {
        let magnitude = sqrt(x * x + y * y + z * z)

        if magnitude < motionThreshold {
            biasSamples.append((x, y, z))
            if biasSamples.count > maxBiasSamples {
                biasSamples.removeFirst()
            }
            if biasSamples.count >= maxBiasSamples / 2 {
                biasX = biasSamples.map { $0.x }.reduce(0, +) / Double(biasSamples.count)
                biasY = biasSamples.map { $0.y }.reduce(0, +) / Double(biasSamples.count)
                biasZ = biasSamples.map { $0.z }.reduce(0, +) / Double(biasSamples.count)
            }
        } else {
            biasSamples.removeAll()
        }
    }

    // MARK: - Soft Cutoff (Smooth Deadzone)

    /// Apply soft cutoff: gradual transition instead of hard deadzone
    /// - Parameters:
    ///   - value: Input angular velocity
    ///   - cutoff: Speed below which output is zero
    ///   - recovery: Speed above which output is full
    /// - Returns: Scaled value with smooth transition
    private func applySoftCutoff(value: Double, cutoff: Double, recovery: Double) -> Double {
        let absValue = abs(value)

        if absValue <= cutoff {
            return 0  // Below cutoff - no movement
        } else if absValue >= recovery {
            return value  // Above recovery - full movement
        } else {
            // Linear interpolation in transition zone
            let t = (absValue - cutoff) / (recovery - cutoff)
            return value * t
        }
    }

    // MARK: - Adaptive Smoothing

    /// Compute adaptive beta based on motion characteristics
    private func computeAdaptiveBeta(
        yaw: Double,
        pitch: Double,
        baseBeta: Double,
        dt: Double,
        mode: AdaptiveSmoothingMode
    ) -> Double {
        switch mode {
        case .off:
            return baseBeta

        case .speed:
            let speed = sqrt(yaw * yaw + pitch * pitch)
            let speedTerm = min(1.0, speed / 150.0)
            let boost = speedTerm * 0.2
            return min(1.0, baseBeta + boost)

        case .speedAndJerk:
            let speed = sqrt(yaw * yaw + pitch * pitch)
            let jerk = abs(speed - lastSpeed) / max(dt, 0.001)
            lastSpeed = speed

            // Smooth jerk with EMA
            let jerkAlpha = 0.25
            lastJerkEMA = jerkAlpha * jerk + (1 - jerkAlpha) * lastJerkEMA

            let speedTerm = min(1.0, speed / 150.0)
            let jerkTerm = min(1.0, lastJerkEMA / 200.0)
            let boost = max(speedTerm, jerkTerm) * 0.2
            return min(1.0, baseBeta + boost)
        }
    }

    /// Smooth speed with EMA for stable acceleration curve selection
    private func smoothSpeed(_ instantaneous: Double) -> Double {
        let alpha = 0.15
        lastSpeedEMA = alpha * instantaneous + (1 - alpha) * lastSpeedEMA
        return lastSpeedEMA
    }

    // MARK: - Acceleration Curves

    /// Compute acceleration gain based on curve type
    private func computeAccelerationGain(
        speed: Double,
        curve: AccelerationCurve,
        strength: Double,
        cap: Double
    ) -> Double {
        // Ensure cap is at least 1.0
        let effectiveCap = max(1.0, cap)
        let maxExtra = effectiveCap - 1.0

        switch curve {
        case .off:
            return 1.0

        case .natural:
            // Smooth concave curve: gain = 1 + (cap - 1) * (1 - exp(-speed * strength / 50))
            // Approaches cap asymptotically - most comfortable for most users
            let normalized = speed * strength / 50.0
            let factor = 1.0 - exp(-normalized)
            return 1.0 + maxExtra * factor

        case .linear:
            // Straight line: gain = 1 + min(cap - 1, speed * strength / 150)
            // Predictable, consistent ramp
            let normalized = speed * strength / 150.0
            return 1.0 + min(maxExtra, normalized * maxExtra)

        case .power:
            // Power curve: gain = 1 + min(cap - 1, pow(speed / 150, 1.2) * (cap - 1) * strength)
            // More aggressive at high speeds
            let normalized = max(0, speed / 150.0)
            let powered = pow(normalized, 1.2)
            return 1.0 + min(maxExtra, powered * maxExtra * strength)

        case .classic:
            // Traditional 3-zone approach (precision/ramp/ballistic)
            // Zone A: 0-20°/s = precision (no acceleration)
            // Zone B: 20-90°/s = gentle ramp
            // Zone C: 90-180°/s = ballistic ramp to cap
            let speedA = 20.0
            let speedB = 90.0
            let speedC = 180.0

            if speed <= speedA {
                return 1.0  // Precision zone
            } else if speed <= speedB {
                let t = (speed - speedA) / (speedB - speedA)
                let midGain = maxExtra * 0.5 * strength
                return 1.0 + t * midGain
            } else {
                let clamped = min(speed, speedC)
                let t = (clamped - speedB) / (speedC - speedB)
                let midGain = maxExtra * 0.5 * strength
                let fullGain = maxExtra * strength
                return 1.0 + midGain + t * (fullGain - midGain)
            }
        }
    }

    // MARK: - Reset

    /// Reset the processor state
    func reset() {
        biasX = 0
        biasY = 0
        biasZ = 0
        biasSamples.removeAll()
        lastTimestamp = nil
        yawFilter.reset()
        pitchFilter.reset()
        lastSpeed = 0
        lastSpeedEMA = 0
        lastJerkEMA = 0
    }

    /// Whether bias calibration is complete
    var isCalibrated: Bool {
        biasSamples.count >= maxBiasSamples / 2
    }
}
