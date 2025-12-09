import Foundation
import CoreGraphics

// MARK: - Gyro Processor

/// Converts raw gyroscope data to mouse movement using professional-grade signal processing.
///
/// Processing Pipeline:
/// ```
/// Raw Gyro → Bias Calibration → One Euro Filter → Acceleration Curve → Sensitivity Scale → Mouse Delta
/// ```
final class GyroProcessor: @unchecked Sendable {

    // MARK: - Bias Estimation

    private var biasX: Double = 0
    private var biasY: Double = 0
    private var biasZ: Double = 0
    private var biasBuffer: [(x: Double, y: Double, z: Double)]
    private var biasCount: Int = 0
    private var biasIndex: Int = 0
    private var biasSum: (x: Double, y: Double, z: Double) = (0, 0, 0)
    private let maxBiasSamples = 64

    // MARK: - Filtering

    private let yawFilter = OneEuroFilter()
    private let pitchFilter = OneEuroFilter()
    private var lastTimestamp: TimeInterval?

    // MARK: - Adaptive Smoothing State

    private var lastSpeed: Double = 0
    private var lastSpeedEMA: Double = 0
    private var lastJerkEMA: Double = 0

    /// Current smoothed speed (°/s) for UI visualization
    private(set) var currentSpeed: Double = 0

    // Sample rate auto-tune
    private var observedDtEMA: Double = 0
    private let observedAlpha = 0.05  // slow EMA to avoid reacting to transient stalls

    // Auto-neutral detection (very still → refresh bias)
    private var neutralStart: TimeInterval?
    private var neutralAccumulator: (x: Double, y: Double, z: Double) = (0, 0, 0)
    private var neutralSumSquares: (x: Double, y: Double, z: Double) = (0, 0, 0)
    private var neutralCount: Int = 0
    private var lastNeutralUpdate: TimeInterval?

    // Debug state snapshot
    struct DebugState {
        let biasX: Double
        let biasY: Double
        let biasZ: Double
        let calibrated: Bool
        let observedSampleRate: Double
        let lastNeutralUpdate: TimeInterval?
    }
    private(set) var lastDebugState: DebugState?

    init() {
        biasBuffer = Array(repeating: (0, 0, 0), count: maxBiasSamples)
    }

    // MARK: - Processing

    /// Process raw gyro data and return mouse deltas
    /// - Parameters:
    ///   - rawX: Raw X-axis gyro value (pitch)
    ///   - rawY: Raw Y-axis gyro value (roll)
    ///   - rawZ: Raw Z-axis gyro value (yaw)
    ///   - timestamp: Monotonic timestamp (seconds)
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

        // 2. Calculate dt with clamping to reduce jitter impact
        var expectedRate = max(1.0, settings.expectedSampleRate)

        if settings.autoTuneSampleRate {
            let observedDt = max(0.001, timestamp - (lastTimestamp ?? timestamp))
            if observedDtEMA == 0 {
                observedDtEMA = observedDt
            } else {
                observedDtEMA = observedAlpha * observedDt + (1 - observedAlpha) * observedDtEMA
            }
            let observedRate = 1.0 / max(0.001, observedDtEMA)
            let clampedRate = min(100.0, max(40.0, observedRate))
            expectedRate = clampedRate
        }

        let expectedDt = 1.0 / expectedRate
        let maxDt = expectedDt * 4.0  // tolerate brief stalls but cap spikes
        let dt: Double
        if let last = lastTimestamp {
            let rawDt = timestamp - last
            dt = min(max(0.001, rawDt), maxDt)
            // If we clamped heavily, reset filters to avoid smearing after a stall
            if rawDt > maxDt {
                yawFilter.reset()
                pitchFilter.reset()
            }
        } else {
            dt = 1.0 / 60.0
        }
        lastTimestamp = timestamp

        // 3. Update bias estimation when stationary
        updateBias(x: x, y: y, z: z, threshold: settings.biasMotionThreshold)
        if settings.autoNeutralEnabled {
            updateAutoNeutral(
                rawX: x,
                rawY: y,
                rawZ: z,
                gyroScale: settings.gyroScale,
                timestamp: timestamp
            )
        }

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
        let yaw = -degreesYaw    // Invert for natural left/right
        let pitch = -degreesPitch  // Invert for natural up/down

        // 6. Apply One Euro filter (if enabled)
        var filteredYaw = yaw
        var filteredPitch = pitch

        if settings.filterEnabled {
            // Update filter parameters
            let speedSquared = yaw * yaw + pitch * pitch
            let speed = sqrt(speedSquared)
            let adaptiveBeta = computeAdaptiveBeta(
                speed: speed,
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
        let filteredSpeed = sqrt(filteredYaw * filteredYaw + filteredPitch * filteredPitch)
        let smoothedSpeed = smoothSpeed(filteredSpeed)
        currentSpeed = smoothedSpeed  // Store for UI visualization

        // 9. Apply acceleration curve (parametric formula)
        let accelGain = computeParametricGain(
            speed: smoothedSpeed,
            rampSpeed: settings.effectiveRampSpeed,
            exponent: settings.effectiveCurveExponent,
            cap: settings.effectiveSensitivityCap
        )

        // 10. Convert to mouse deltas
        let scale = settings.sensitivity * 0.1
        let dx = CGFloat(filteredYaw * dt * scale * accelGain)
        let dy = CGFloat(filteredPitch * dt * scale * accelGain)

        // Capture debug snapshot
        let observedRate = observedDtEMA > 0 ? (1.0 / observedDtEMA) : expectedRate
        lastDebugState = DebugState(
            biasX: biasX * settings.gyroScale,
            biasY: biasY * settings.gyroScale,
            biasZ: biasZ * settings.gyroScale,
            calibrated: biasCount >= maxBiasSamples / 2,
            observedSampleRate: observedRate,
            lastNeutralUpdate: lastNeutralUpdate
        )

        return (dx, dy)
    }

    // MARK: - Bias Estimation

    private func updateBias(x: Double, y: Double, z: Double, threshold: Double) {
        let magnitudeSquared = x * x + y * y + z * z
        if magnitudeSquared < threshold * threshold {
            let old = biasBuffer[biasIndex]
            biasBuffer[biasIndex] = (x, y, z)
            biasIndex = (biasIndex + 1) % maxBiasSamples
            if biasCount < maxBiasSamples {
                biasCount += 1
                biasSum.x += x
                biasSum.y += y
                biasSum.z += z
            } else {
                // Rolling sum: subtract old, add new
                biasSum.x += x - old.x
                biasSum.y += y - old.y
                biasSum.z += z - old.z
            }

            if biasCount >= maxBiasSamples / 2 {
                let count = Double(biasCount)
                biasX = biasSum.x / count
                biasY = biasSum.y / count
                biasZ = biasSum.z / count
            }
        } else {
            // Clear buffer when motion exceeds threshold
            biasCount = 0
            biasIndex = 0
            biasSum = (0, 0, 0)
        }
    }

    private func updateAutoNeutral(
        rawX: Double,
        rawY: Double,
        rawZ: Double,
        gyroScale: Double,
        timestamp: TimeInterval
    ) {
        // Use variance-based stillness detection so a constant bias doesn't block calibration
        let degX = rawX * gyroScale
        let degY = rawY * gyroScale
        let degZ = rawZ * gyroScale

        let minDuration: TimeInterval = 0.6
        let minSamples: Int = 20
        let cooldown: TimeInterval = 2.0
        let motionBreak: Double = 80.0  // deg/s instantaneous motion that cancels accumulation

        // If there's a sudden spike of motion, abandon accumulation
        if abs(degX) > motionBreak || abs(degY) > motionBreak || abs(degZ) > motionBreak {
            neutralStart = nil
            neutralAccumulator = (0, 0, 0)
            neutralSumSquares = (0, 0, 0)
            neutralCount = 0
            return
        }

        if neutralStart == nil {
            neutralStart = timestamp
            neutralAccumulator = (rawX, rawY, rawZ)
            neutralSumSquares = (rawX * rawX, rawY * rawY, rawZ * rawZ)
            neutralCount = 1
        } else {
            neutralAccumulator.x += rawX
            neutralAccumulator.y += rawY
            neutralAccumulator.z += rawZ
            neutralSumSquares.x += rawX * rawX
            neutralSumSquares.y += rawY * rawY
            neutralSumSquares.z += rawZ * rawZ
            neutralCount += 1
        }

        if let start = neutralStart,
           timestamp - start >= minDuration,
           neutralCount >= minSamples,
           (lastNeutralUpdate == nil || timestamp - (lastNeutralUpdate ?? 0) >= cooldown) {
            let inv = 1.0 / Double(neutralCount)
            let avgX = neutralAccumulator.x * inv
            let avgY = neutralAccumulator.y * inv
            let avgZ = neutralAccumulator.z * inv
            let varX = max(0, neutralSumSquares.x * inv - avgX * avgX)
            let varY = max(0, neutralSumSquares.y * inv - avgY * avgY)
            let varZ = max(0, neutralSumSquares.z * inv - avgZ * avgZ)
            let stdThreshold: Double = 0.6  // deg/s
            let stillnessPass =
                sqrt(varX) * gyroScale < stdThreshold &&
                sqrt(varY) * gyroScale < stdThreshold &&
                sqrt(varZ) * gyroScale < stdThreshold

            if stillnessPass {
                // Force bias to the observed quiet average
                biasX = avgX
                biasY = avgY
                biasZ = avgZ
                for i in 0..<maxBiasSamples {
                    biasBuffer[i] = (avgX, avgY, avgZ)
                }
                biasCount = maxBiasSamples
                biasIndex = 0
                biasSum = (avgX * Double(maxBiasSamples), avgY * Double(maxBiasSamples), avgZ * Double(maxBiasSamples))
                lastNeutralUpdate = timestamp
            }
            neutralStart = nil
            neutralAccumulator = (0, 0, 0)
            neutralSumSquares = (0, 0, 0)
            neutralCount = 0
        }
    }

    // MARK: - Adaptive Smoothing

    /// Compute adaptive beta based on motion characteristics
    private func computeAdaptiveBeta(
        speed: Double,
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
            let speedTerm = min(1.0, speed / 150.0)
            let boost = speedTerm * 0.2
            return min(1.0, baseBeta + boost)

        case .speedAndJerk:
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

    // MARK: - Acceleration Curve

    /// Compute acceleration gain using parametric curve formula
    /// - Parameters:
    ///   - speed: Current angular velocity (°/s)
    ///   - rampSpeed: Speed at which gain reaches cap (°/s)
    ///   - exponent: Curve shape (< 1 = concave, 1 = linear, > 1 = convex)
    ///   - cap: Maximum gain multiplier
    /// - Returns: Gain multiplier (1.0 to cap)
    private func computeParametricGain(
        speed: Double,
        rampSpeed: Double,
        exponent: Double,
        cap: Double
    ) -> Double {
        // Ensure valid parameters
        let effectiveCap = max(1.0, cap)
        let effectiveRamp = max(1.0, rampSpeed)

        // Normalize speed to 0-1 range (0 to rampSpeed)
        let normalized = min(1.0, speed / effectiveRamp)

        // Apply power curve
        let curved = pow(normalized, exponent)

        // Scale to gain range
        return 1.0 + curved * (effectiveCap - 1.0)
    }

    // MARK: - Reset

    /// Reset the processor state
    func reset() {
        biasX = 0
        biasY = 0
        biasZ = 0
        biasBuffer = Array(repeating: (0, 0, 0), count: maxBiasSamples)
        biasCount = 0
        biasIndex = 0
        biasSum = (0, 0, 0)
        lastTimestamp = nil
        yawFilter.reset()
        pitchFilter.reset()
        lastSpeed = 0
        lastSpeedEMA = 0
        lastJerkEMA = 0
    }

    /// Whether bias calibration is complete
    var isCalibrated: Bool {
        biasCount >= maxBiasSamples / 2
    }
}
