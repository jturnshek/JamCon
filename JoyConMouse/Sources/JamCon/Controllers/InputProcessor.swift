import Foundation
import CoreGraphics
import QuartzCore

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

    /// Force-set the bias (used when clutch captures a fresh neutral)
    func forceBias(_ bias: (x: Double, y: Double, z: Double)) {
        samples = Array(repeating: bias, count: maxSamples / 2)
        self.bias = bias
    }
}

// MARK: - One Euro Filter (adaptive smoothing)

/// Adaptive low-pass filter that increases smoothing for slow motion and removes it for fast motion.
/// Based on "The One Euro Filter" (Casiez et al.).
final class OneEuroFilter {
    private var previousValue: Double?
    private var previousDerivative: Double = 0
    private var previousTime: TimeInterval?

    /// Base cutoff frequency (higher = less smoothing at low speeds)
    var minCutoff: Double = 1.5
    /// Speed influence on cutoff (higher = less smoothing when moving fast)
    var beta: Double = 0.35
    /// Cutoff for derivative smoothing
    var derivativeCutoff: Double = 1.0
    /// Fallback rate used when timestamps are missing or dt is tiny
    var fallbackRate: Double = 120.0

    private func alpha(cutoff: Double, dt: Double) -> Double {
        let tau = 1.0 / (2.0 * Double.pi * cutoff)
        return 1.0 / (1.0 + tau / dt)
    }

    func filter(value: Double, timestamp: TimeInterval) -> Double {
        let dt: Double
        if let prevTime = previousTime {
            dt = max(1.0 / fallbackRate, timestamp - prevTime)
        } else {
            dt = 1.0 / fallbackRate
        }

        let rawDerivative: Double
        if let prev = previousValue {
            rawDerivative = (value - prev) / dt
        } else {
            rawDerivative = 0
        }

        let alphaDerivative = alpha(cutoff: derivativeCutoff, dt: dt)
        let derivative = alphaDerivative * rawDerivative + (1 - alphaDerivative) * previousDerivative

        let cutoff = minCutoff + beta * abs(derivative)
        let alphaValue = alpha(cutoff: cutoff, dt: dt)
        let filteredValue = alphaValue * value + (1 - alphaValue) * (previousValue ?? value)

        previousTime = timestamp
        previousValue = filteredValue
        previousDerivative = derivative

        return filteredValue
    }

    func reset() {
        previousValue = nil
        previousDerivative = 0
        previousTime = nil
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
    var onCalibrationChange: ((_ isCalibrated: Bool) -> Void)?

    // MARK: - Stabilization

    let biasEstimator = GyroBiasEstimator()
    private let yawFilter = OneEuroFilter()
    private let pitchFilter = OneEuroFilter()

    /// Soft cutoff speed - below this, no movement (°/s)
    var cutoffSpeed: Double = 0.5

    /// Tracks the last sample time to compute dt
    private var lastTimestamp: TimeInterval?
    private var lastReportedCalibration: Bool?
    private var lastSmoothThreshold: Double?
    private var lastFilterBeta: Double?

    enum OverrideMode {
        case none
        case clutch
        case scroll
        case zoom
    }
    private var overrideMode: OverrideMode = .none
    private var overrideCounts: [OverrideMode: Int] = [:]

    // MARK: - Cursor Lock State (clutch/scroll/zoom)

    private var cursorLockActive: Bool = false
    private var lockNeutralStart: TimeInterval?
    private var lockNeutralAccumulator: (x: Double, y: Double, z: Double) = (0, 0, 0)
    private var lockNeutralCount: Int = 0
    private var lockBiasUpdatedAt: TimeInterval?
    private var lockRollStart: Double?
    private var rollCompensation: Double = 0  // Radians
    private var currentRoll: Double = 0       // Radians
    private var releaseRampStart: TimeInterval?
    private let releaseRampDuration: TimeInterval = 0.08
    private let lockQuietThreshold: Double = 0.8
    private let lockQuietMinDuration: TimeInterval = 0.35

    /// Queue for hold timers to avoid main-thread jitter
    private let holdQueue = DispatchQueue(label: "InputProcessor.holdQueue", qos: .userInitiated)

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

    private func accelerationGain(for speed: Double, maxExtraGain: Double) -> Double {
        // Gentle acceleration: 1x near rest, up to (1 + maxExtraGain) for fast flicks
        let normalized = max(0, speed / 150.0)
        return 1.0 + min(maxExtraGain, pow(normalized, 1.2) * maxExtraGain)
    }

    private func updateFilters(for smoothThreshold: Double, beta: Double) {
        guard lastSmoothThreshold != smoothThreshold || lastFilterBeta != beta else { return }
        lastSmoothThreshold = smoothThreshold
        lastFilterBeta = beta
        // Map smoothing slider (0-50) to One Euro cutoff range (~0.1 - 4.5 Hz)
        let cutoff = max(0.1, smoothThreshold / 12.0)
        yawFilter.minCutoff = cutoff
        pitchFilter.minCutoff = cutoff
        // Keep derivative cutoff modest to avoid lag in fast motion
        yawFilter.derivativeCutoff = 1.0
        pitchFilter.derivativeCutoff = 1.0
        yawFilter.beta = beta
        pitchFilter.beta = beta
    }

    /// Process gyroscope data and convert to mouse movement
    /// - Parameters:
    ///   - gyro: Gyroscope values (x, y, z) in degrees per second
    ///   - timestamp: Monotonic timestamp for this sample
    ///   - sensitivity: Mouse movement multiplier
    ///   - deadzone: Recovery threshold for soft cutoff (°/s)
    ///   - smoothThreshold: Speed below which smoothing is applied (°/s)
    func processGyro(
        _ gyro: GyroData,
        timestamp: TimeInterval,
        sensitivity: Double,
        deadzone: Double,
        smoothThreshold: Double? = nil,
        filterBeta: Double = 0.35,
        accelerationMaxExtra: Double = 2.0
    ) {
        let now = timestamp

        // Update filter tuning if the user changed smoothing
        if let threshold = smoothThreshold {
            updateFilters(for: threshold, beta: filterBeta)
        }

        // 1. Update bias estimator (runs continuously, learns when stationary)
        biasEstimator.update(gyro: gyro)

        // 2. Apply calibration to remove drift
        let calibrated = biasEstimator.calibratedGyro(gyro)

        // 3. Compute dt and keep roll integration for grip compensation
        let dt: Double
        if let last = lastTimestamp {
            dt = max(1.0 / yawFilter.fallbackRate, now - last)
        } else {
            dt = 1.0 / yawFilter.fallbackRate
        }
        lastTimestamp = now

        // Integrate roll (radians) so we can deskew axes when the controller is canted
        currentRoll += calibrated.x * dt * (.pi / 180.0)

        // While cursor is locked (clutch/scroll/zoom), watch for quiet IMU to refresh neutral/bias
        if cursorLockActive {
            updateLockNeutral(rawGyro: gyro, timestamp: now)
        }

        // 4. Extract axes for pointing-forward grip
        // - Z axis: wrist rotation left/right = horizontal mouse
        // - Y axis: tilting up/down = vertical mouse
        var yaw = calibrated.z
        var pitch = -calibrated.y  // Negated for natural direction

        // 5. Apply soft cutoff (replaces hard deadzone)
        yaw = applySoftCutoff(value: yaw, cutoffSpeed: cutoffSpeed, recoverySpeed: deadzone)
        pitch = applySoftCutoff(value: pitch, cutoffSpeed: cutoffSpeed, recoverySpeed: deadzone)

        // Skip if no movement after cutoff
        if yaw == 0 && pitch == 0 {
            reportCalibrationIfNeeded()
            return
        }

        // 6. Adaptive smoothing (minimal lag for fast motion)
        let filteredYaw = yawFilter.filter(value: yaw, timestamp: now)
        let filteredPitch = pitchFilter.filter(value: pitch, timestamp: now)

        // 7. Deskew axes if the controller was re-gripped with roll (lock)
        let (compensatedYaw, compensatedPitch) = applyRollCompensation(yaw: filteredYaw, pitch: filteredPitch)

        // 8. Apply gentle acceleration curve on angular speed
        let speed = sqrt(compensatedYaw * compensatedYaw + compensatedPitch * compensatedPitch)
        let accelGain = accelerationGain(for: speed, maxExtraGain: accelerationMaxExtra)

        // Scale: sensitivity * 0.1 gives good range with slider
        let baseScale = sensitivity * 0.1
        let ramp = lockRampFactor(now: now)
        let dx = CGFloat(compensatedYaw * dt * baseScale * accelGain * ramp)
        let dy = CGFloat(compensatedPitch * dt * baseScale * accelGain * ramp)

        switch currentOverride() {
        case .clutch:
            reportCalibrationIfNeeded()
            return
        case .scroll:
            onScroll?(dx, dy)
        case .zoom:
            onScroll?(0, dy)
        case .none:
            onMouseMove?(dx, dy)
        }
        reportCalibrationIfNeeded()
    }

    private func reportCalibrationIfNeeded() {
        let calibrated = biasEstimator.isCalibrated
        if calibrated != lastReportedCalibration {
            lastReportedCalibration = calibrated
            onCalibrationChange?(calibrated)
        }
    }

    // MARK: - Button Hold Detection

    /// Tracks button press state for hold detection
    private var buttonState: [LogicalButton: ButtonPressState] = [:]
    private var holdTimers: [LogicalButton: DispatchWorkItem] = [:]

    private struct ButtonPressState {
        let pressTime: Date
        let actions: ButtonActions
        var holdFired: Bool = false
    }

    /// Handle button press with hold detection
    /// - Parameters:
    ///   - button: The logical button pressed
    ///   - actions: The configured actions for press and hold
    ///   - holdThreshold: Time in seconds before hold action fires
    func handleButtonDown(_ button: LogicalButton, actions: ButtonActions, holdThreshold: Double) {
        // Cancel any existing timer for this button
        holdTimers[button]?.cancel()
        holdTimers[button] = nil

        // Track the press
        buttonState[button] = ButtonPressState(pressTime: Date(), actions: actions)

        // If there's a hold action, schedule it
        if actions.hold != .none {
            let workItem = DispatchWorkItem { [weak self] in
                guard let self = self else { return }
                // Mark hold as fired and execute hold down immediately
                if var state = self.buttonState[button] {
                    state.holdFired = true
                    self.buttonState[button] = state
                    self.executeAction(actions.hold, isDown: true)
                }
            }
            holdTimers[button] = workItem
            holdQueue.asyncAfter(deadline: .now() + holdThreshold, execute: workItem)
        }
    }

    /// Handle button release with hold detection
    /// - Parameter button: The logical button released
    func handleButtonUp(_ button: LogicalButton) {
        // Cancel hold timer if still pending
        holdTimers[button]?.cancel()
        holdTimers[button] = nil

        guard let state = buttonState[button] else { return }
        buttonState[button] = nil

        if state.holdFired {
            // Hold action was triggered - release it now
            if state.actions.hold != .none {
                executeAction(state.actions.hold, isDown: false)
            }
        } else {
            // Released before hold threshold - fire press action (down + up)
            if state.actions.press != .none {
                executeAction(state.actions.press, isDown: true)
                executeAction(state.actions.press, isDown: false)
            }
        }
    }

    /// Execute a single action (internal helper)
    private func executeAction(_ action: ButtonAction, isDown: Bool) {
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

    // MARK: - Legacy Button Processing (for simple actions)

    /// Process a button action (called after translating physical button to action)
    func processAction(_ action: ButtonAction, isDown: Bool) {
        executeAction(action, isDown: isDown)
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
    /// Reset filters and calibration state
    func resetFilters() {
        biasEstimator.reset()
        yawFilter.reset()
        pitchFilter.reset()
        lastTimestamp = nil
        lastReportedCalibration = nil
        lastFilterBeta = nil
        lastSmoothThreshold = nil
        overrideMode = .none
        overrideCounts = [:]
        cursorLockActive = false
        lockNeutralStart = nil
        lockNeutralAccumulator = (0, 0, 0)
        lockNeutralCount = 0
        lockBiasUpdatedAt = nil
        lockRollStart = nil
        rollCompensation = 0
        currentRoll = 0
        releaseRampStart = nil
    }

    func beginOverride(_ mode: OverrideMode) {
        let previousMode = currentOverride()
        let wasLocking = isLockingMode(previousMode)
        overrideCounts[mode, default: 0] += 1
        let newMode = currentOverride()
        overrideMode = newMode
        let isLocking = isLockingMode(newMode)
        if !wasLocking && isLocking {
            handleCursorLockStarted()
        }
    }

    func endOverride(_ mode: OverrideMode) {
        if let count = overrideCounts[mode], count > 1 {
            overrideCounts[mode] = count - 1
        } else {
            overrideCounts.removeValue(forKey: mode)
        }
        let previousMode = overrideMode
        let wasLocking = isLockingMode(previousMode)
        let newMode = currentOverride()
        overrideMode = newMode
        let isLocking = isLockingMode(newMode)
        if wasLocking && !isLocking {
            handleCursorLockEnded()
        }
    }

    private func currentOverride() -> OverrideMode {
        if (overrideCounts[.clutch] ?? 0) > 0 { return .clutch }
        if (overrideCounts[.zoom] ?? 0) > 0 { return .zoom }
        if (overrideCounts[.scroll] ?? 0) > 0 { return .scroll }
        return .none
    }

    private func isLockingMode(_ mode: OverrideMode) -> Bool {
        switch mode {
        case .clutch, .scroll, .zoom:
            return true
        case .none:
            return false
        }
    }

    private func handleCursorLockStarted() {
        cursorLockActive = true
        lockNeutralStart = nil
        lockNeutralAccumulator = (0, 0, 0)
        lockNeutralCount = 0
        lockBiasUpdatedAt = nil
        releaseRampStart = nil
        lockRollStart = currentRoll
        yawFilter.reset()
        pitchFilter.reset()
        lastTimestamp = nil
    }

    private func handleCursorLockEnded() {
        cursorLockActive = false
        if let startRoll = lockRollStart {
            let delta = currentRoll - startRoll
            let twoPi = Double.pi * 2.0
            var normalized = delta.truncatingRemainder(dividingBy: twoPi)
            if normalized > Double.pi { normalized -= twoPi }
            if normalized < -Double.pi { normalized += twoPi }
            rollCompensation = normalized
        }
        lockRollStart = nil
        lockNeutralStart = nil
        lockNeutralAccumulator = (0, 0, 0)
        lockNeutralCount = 0
        lockBiasUpdatedAt = nil
        releaseRampStart = CACurrentMediaTime()
    }

    private func lockRampFactor(now: TimeInterval) -> Double {
        guard let start = releaseRampStart else { return 1.0 }
        let progress = max(0, now - start) / releaseRampDuration
        if progress >= 1.0 {
            releaseRampStart = nil
            return 1.0
        }
        return progress
    }

    private func updateLockNeutral(rawGyro: GyroData, timestamp: TimeInterval) {
        let magnitude = sqrt(rawGyro.x * rawGyro.x + rawGyro.y * rawGyro.y + rawGyro.z * rawGyro.z)

        if magnitude < lockQuietThreshold {
            if lockNeutralStart == nil {
                lockNeutralStart = timestamp
                lockNeutralAccumulator = (rawGyro.x, rawGyro.y, rawGyro.z)
                lockNeutralCount = 1
            } else {
                lockNeutralAccumulator.x += rawGyro.x
                lockNeutralAccumulator.y += rawGyro.y
                lockNeutralAccumulator.z += rawGyro.z
                lockNeutralCount += 1
            }

            if let start = lockNeutralStart,
               timestamp - start >= lockQuietMinDuration,
               lockNeutralCount >= 12,
               (lockBiasUpdatedAt == nil || timestamp - (lockBiasUpdatedAt ?? 0) > 0.2) {
                let invCount = 1.0 / Double(lockNeutralCount)
                let avg = (
                    x: lockNeutralAccumulator.x * invCount,
                    y: lockNeutralAccumulator.y * invCount,
                    z: lockNeutralAccumulator.z * invCount
                )
                biasEstimator.forceBias((avg.x, avg.y, avg.z))
                lockBiasUpdatedAt = timestamp
                lockNeutralStart = nil
                lockNeutralAccumulator = (0, 0, 0)
                lockNeutralCount = 0
            }
        } else {
            lockNeutralStart = nil
            lockNeutralAccumulator = (0, 0, 0)
            lockNeutralCount = 0
        }
    }

    private func applyRollCompensation(yaw: Double, pitch: Double) -> (Double, Double) {
        guard rollCompensation != 0 else { return (yaw, pitch) }
        let cosR = cos(rollCompensation)
        let sinR = sin(rollCompensation)
        let compensatedYaw = yaw * cosR + pitch * sinR
        let compensatedPitch = -yaw * sinR + pitch * cosR
        return (compensatedYaw, compensatedPitch)
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
