import Foundation
import CoreGraphics

/// Minimal gyro processor for converting raw IMU data to mouse movement
class GyroProcessor {

    // MARK: - Configuration

    /// Mouse sensitivity multiplier
    var sensitivity: Double = 15.0

    /// Scale factor to convert raw gyro units to degrees/second (tune this)
    /// PSVR2 Sense likely uses a similar scale to other Sony controllers
    var gyroScale: Double = 1.0 / 16.0  // Initial guess, will need tuning

    /// Deadzone in degrees/second
    var deadzone: Double = 2.0

    // MARK: - Bias Estimation

    private var biasX: Double = 0
    private var biasY: Double = 0
    private var biasZ: Double = 0
    private var biasSamples: [(x: Double, y: Double, z: Double)] = []
    private let maxBiasSamples = 64
    private let motionThreshold: Double = 50.0  // Raw units

    // MARK: - Filtering

    private var lastTimestamp: TimeInterval?

    // Simple exponential moving average for smoothing
    private var smoothedX: Double = 0
    private var smoothedY: Double = 0
    private let smoothingFactor: Double = 0.3

    // MARK: - Processing

    /// Process raw gyro data and return mouse deltas
    /// - Returns: (dx, dy) mouse movement, or nil if no movement
    func process(rawX: Int16, rawY: Int16, rawZ: Int16, timestamp: TimeInterval) -> (dx: CGFloat, dy: CGFloat)? {

        // Convert to doubles
        let x = Double(rawX)
        let y = Double(rawY)
        let z = Double(rawZ)

        // Calculate dt
        let dt: Double
        if let last = lastTimestamp {
            dt = max(0.001, timestamp - last)
        } else {
            dt = 1.0 / 60.0  // Assume 60Hz initially
        }
        lastTimestamp = timestamp

        // Update bias estimation when stationary
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

        // Apply bias correction
        let calibratedX = x - biasX
        let calibratedY = y - biasY
        let calibratedZ = z - biasZ

        // Convert to degrees/second
        _ = calibratedX * gyroScale  // X not used for 2D mouse
        let degreesY = calibratedY * gyroScale
        let degreesZ = calibratedZ * gyroScale

        // Apply smoothing
        smoothedX = smoothingFactor * degreesZ + (1 - smoothingFactor) * smoothedX  // Z = yaw
        smoothedY = smoothingFactor * degreesY + (1 - smoothingFactor) * smoothedY  // Y = pitch

        // Apply deadzone
        var yaw = smoothedX
        var pitch = -smoothedY  // Invert for natural direction

        if abs(yaw) < deadzone { yaw = 0 }
        if abs(pitch) < deadzone { pitch = 0 }

        // Skip if no movement
        if yaw == 0 && pitch == 0 {
            return nil
        }

        // Convert to mouse deltas
        let scale = sensitivity * 0.1
        let dx = CGFloat(yaw * dt * scale)
        let dy = CGFloat(pitch * dt * scale)

        return (dx, dy)
    }

    /// Reset the processor state
    func reset() {
        biasX = 0
        biasY = 0
        biasZ = 0
        biasSamples.removeAll()
        lastTimestamp = nil
        smoothedX = 0
        smoothedY = 0
    }

    /// Whether bias calibration is complete
    var isCalibrated: Bool {
        biasSamples.count >= maxBiasSamples / 2
    }
}
