import Foundation
import CoreGraphics

// MARK: - Gyro Bias Estimator

/// Automatically calibrates gyro bias when controller is stationary
class GyroBiasEstimator {
    private var samples: [(x: Double, y: Double, z: Double)] = []
    private let maxSamples = 64  // ~1 second at 66Hz
    private let motionThreshold = 3.0  // °/s - if magnitude exceeds this, we're moving

    /// Current estimated bias (subtract from raw readings)
    private(set) var bias: (x: Double, y: Double, z: Double) = (0, 0, 0)

    /// Whether we have a valid calibration
    var isCalibrated: Bool {
        return samples.count >= maxSamples / 2
    }

    /// Update bias estimate with new gyro sample
    func update(gyro: GyroData) {
        // Only collect samples when controller appears stationary
        let magnitude = sqrt(gyro.x * gyro.x + gyro.y * gyro.y + gyro.z * gyro.z)

        if magnitude < motionThreshold {
            samples.append((gyro.x, gyro.y, gyro.z))
            if samples.count > maxSamples {
                samples.removeFirst()
            }

            // Update bias estimate if we have enough samples
            if samples.count >= maxSamples / 2 {
                let avgX = samples.map { $0.x }.reduce(0, +) / Double(samples.count)
                let avgY = samples.map { $0.y }.reduce(0, +) / Double(samples.count)
                let avgZ = samples.map { $0.z }.reduce(0, +) / Double(samples.count)
                bias = (avgX, avgY, avgZ)
            }
        } else {
            // Moving - clear samples to avoid contamination
            samples.removeAll()
        }
    }

    /// Apply calibration to remove bias
    func calibratedGyro(_ gyro: GyroData) -> GyroData {
        return GyroData(
            x: gyro.x - bias.x,
            y: gyro.y - bias.y,
            z: gyro.z - bias.z
        )
    }

    /// Reset calibration (for manual recalibration)
    func reset() {
        samples.removeAll()
        bias = (0, 0, 0)
    }
}

// MARK: - Gyro Smoother

/// Applies threshold-based smoothing: slow movements are smoothed, fast movements pass through
class GyroSmoother {
    private var buffer: [(yaw: Double, pitch: Double)] = []
    private let updateRate: Double = 66.0  // Hz

    /// Smoothing window size in seconds
    var smoothTime: Double = 0.125

    /// Speed threshold below which smoothing is applied (°/s)
    var smoothThreshold: Double = 20.0

    private var bufferSize: Int {
        return max(1, Int(smoothTime * updateRate))
    }

    func smooth(yaw: Double, pitch: Double) -> (yaw: Double, pitch: Double) {
        // Add to buffer
        buffer.append((yaw, pitch))
        if buffer.count > bufferSize {
            buffer.removeFirst()
        }

        // Calculate current angular speed
        let speed = sqrt(yaw * yaw + pitch * pitch)

        // Calculate smoothing factor (0 = no smoothing, 1 = full smoothing)
        let smoothFactor: Double
        if speed >= smoothThreshold {
            smoothFactor = 0.0  // Fast movement - no smoothing (no lag!)
        } else if speed <= 0 {
            smoothFactor = 1.0  // Stationary - full smoothing
        } else {
            // Interpolate: slower = more smoothing
            smoothFactor = 1.0 - (speed / smoothThreshold)
        }

        // If no smoothing needed or buffer too small, return raw
        if smoothFactor == 0 || buffer.count < 2 {
            return (yaw, pitch)
        }

        // Calculate smoothed value (simple moving average)
        let avgYaw = buffer.map { $0.yaw }.reduce(0, +) / Double(buffer.count)
        let avgPitch = buffer.map { $0.pitch }.reduce(0, +) / Double(buffer.count)

        // Blend between raw and smoothed based on speed
        return (
            yaw: yaw * (1 - smoothFactor) + avgYaw * smoothFactor,
            pitch: pitch * (1 - smoothFactor) + avgPitch * smoothFactor
        )
    }

    func reset() {
        buffer.removeAll()
    }
}

// MARK: - Input Processor

/// Processes Joy-Con input and converts it to mouse actions
class InputProcessor {

    // MARK: - Callbacks

    var onMouseMove: ((_ dx: CGFloat, _ dy: CGFloat) -> Void)?
    var onMouseClick: ((_ button: MouseButton, _ isDown: Bool) -> Void)?
    var onScroll: ((_ dx: CGFloat, _ dy: CGFloat) -> Void)?
    var onKeyDown: ((_ keyCombo: KeyCombo) -> Void)?
    var onKeyUp: ((_ keyCombo: KeyCombo) -> Void)?

    // MARK: - Stabilization

    let biasEstimator = GyroBiasEstimator()
    let smoother = GyroSmoother()

    /// Soft cutoff speed - below this, no movement (°/s)
    var cutoffSpeed: Double = 0.5

    // MARK: - Gyro Processing

    /// Apply soft cutoff: gradual transition to zero instead of hard deadzone
    private func applySoftCutoff(value: Double, cutoffSpeed: Double, recoverySpeed: Double) -> Double {
        let absValue = abs(value)

        if absValue <= cutoffSpeed {
            return 0  // Below cutoff - no movement
        } else if absValue >= recoverySpeed {
            return value  // Above recovery - full movement
        } else {
            // Interpolate between cutoff and recovery for smooth transition
            let t = (absValue - cutoffSpeed) / (recoverySpeed - cutoffSpeed)
            return value * t
        }
    }

    /// Process gyroscope data and convert to mouse movement
    /// - Parameters:
    ///   - gyro: Gyroscope values (x, y, z) in degrees per second
    ///   - sensitivity: Mouse movement multiplier
    ///   - deadzone: Recovery threshold for soft cutoff (°/s)
    ///   - smoothThreshold: Speed below which smoothing is applied (°/s)
    func processGyro(_ gyro: GyroData, sensitivity: Double, deadzone: Double, smoothThreshold: Double? = nil) {
        // 1. Update bias estimator (runs continuously, learns when stationary)
        biasEstimator.update(gyro: gyro)

        // 2. Apply calibration to remove drift
        let calibrated = biasEstimator.calibratedGyro(gyro)

        // 3. Extract axes for pointing-forward grip
        // - Z axis: wrist rotation left/right = horizontal mouse
        // - Y axis: tilting up/down = vertical mouse
        var yaw = calibrated.z
        var pitch = -calibrated.y  // Negated for natural direction

        // 4. Apply soft cutoff (replaces hard deadzone)
        yaw = applySoftCutoff(value: yaw, cutoffSpeed: cutoffSpeed, recoverySpeed: deadzone)
        pitch = applySoftCutoff(value: pitch, cutoffSpeed: cutoffSpeed, recoverySpeed: deadzone)

        // Skip if no movement after cutoff
        if yaw == 0 && pitch == 0 {
            return
        }

        // 5. Apply threshold-based smoothing (only smooths slow movements)
        if let threshold = smoothThreshold {
            smoother.smoothThreshold = threshold
        }
        let (smoothedYaw, smoothedPitch) = smoother.smooth(yaw: yaw, pitch: pitch)

        // 6. Convert degrees/sec to mouse delta
        // Scale: sensitivity * 0.1 gives good range with slider 1-50
        let scale = sensitivity * 0.1
        let dx = CGFloat(smoothedYaw * scale)
        let dy = CGFloat(smoothedPitch * scale)

        onMouseMove?(dx, dy)
    }

    // MARK: - Button Processing

    /// Process a button action (called after translating physical button to action)
    func processAction(_ action: ButtonAction, isDown: Bool) {
        switch action {
        case .none:
            break
        case .mouseClick(let mouseButton):
            onMouseClick?(mouseButton, isDown)
        case .keyPress(let keyCombo):
            if isDown {
                onKeyDown?(keyCombo)
            } else {
                onKeyUp?(keyCombo)
            }
        }
    }

    // MARK: - Stick Processing

    /// Process analog stick input for scrolling
    /// - Parameters:
    ///   - position: Stick position (-1 to 1 for each axis)
    ///   - sensitivity: Scroll units per full stick deflection
    ///   - deadzone: Minimum threshold to register scrolling
    func processStick(_ position: StickPosition, sensitivity: Double, deadzone: Double) {
        var x = position.x
        var y = position.y

        // Apply deadzone
        if abs(x) < deadzone {
            x = 0
        }
        if abs(y) < deadzone {
            y = 0
        }

        // Skip if no movement
        if x == 0 && y == 0 {
            return
        }

        // Apply non-linear scaling for finer control at low deflections
        // Using a simple power curve
        let xSign = x >= 0 ? 1.0 : -1.0
        let ySign = y >= 0 ? 1.0 : -1.0

        x = xSign * pow(abs(x), 1.5)
        y = ySign * pow(abs(y), 1.5)

        // Convert to scroll amount
        // Positive Y on stick = scroll up (positive in scroll coords)
        // Positive X on stick = scroll right (positive in scroll coords)
        let scrollX = CGFloat(x * sensitivity)
        let scrollY = CGFloat(y * sensitivity)

        onScroll?(scrollX, scrollY)
    }
}

// MARK: - Supporting Types

struct GyroData {
    let x: Double  // Pitch (tilt forward/backward)
    let y: Double  // Roll (tilt left/right)
    let z: Double  // Yaw (rotation around vertical)
}

struct StickPosition {
    let x: Double  // -1 (left) to 1 (right)
    let y: Double  // -1 (down) to 1 (up)
}

enum JoyConButton: String {
    // Right Joy-Con buttons
    case a, b, x, y
    case r, zr
    case plus
    case rightStick
    case sr_r = "sr_right"
    case sl_r = "sl_right"
    case home

    // Left Joy-Con buttons
    case up, down, left, right  // D-pad
    case l, zl
    case minus
    case leftStick
    case sr_l = "sr_left"
    case sl_l = "sl_left"
    case capture
}
