import Foundation
import CoreGraphics
import QuartzCore

// MARK: - Gyro Bias Estimator

/// Automatically calibrates gyro bias when controller is stationary.
/// Uses a ring buffer with O(1) operations and preserves the last valid bias
/// when motion is detected (backported from PSVR2Gyro for improved responsiveness).
class GyroBiasEstimator {
    // Ring buffer storage (O(1) operations)
    private var biasBuffer: [(x: Double, y: Double, z: Double)]
    private var biasIndex: Int = 0
    private var biasCount: Int = 0
    private var biasSum: (x: Double, y: Double, z: Double) = (0, 0, 0)
    private let maxSamples = 64  // ~0.24s at 266Hz (Joy-Con bundled rate)
    private let motionThreshold = 3.0  // °/s - if magnitude exceeds this, we're moving

    /// Current estimated bias (PRESERVED when motion detected)
    private(set) var bias: (x: Double, y: Double, z: Double) = (0, 0, 0)

    init() {
        biasBuffer = Array(repeating: (0, 0, 0), count: maxSamples)
    }

    /// Whether we have a valid calibration
    var isCalibrated: Bool {
        return biasCount >= maxSamples / 2
    }

    /// Update bias estimate with new gyro sample
    func update(gyro: GyroData) {
        let magnitude = sqrt(gyro.x * gyro.x + gyro.y * gyro.y + gyro.z * gyro.z)

        if magnitude < motionThreshold {
            // Stationary: update ring buffer with O(1) rolling sum
            let old = biasBuffer[biasIndex]
            biasBuffer[biasIndex] = (gyro.x, gyro.y, gyro.z)
            biasIndex = (biasIndex + 1) % maxSamples

            if biasCount < maxSamples {
                // Still filling buffer
                biasCount += 1
                biasSum.x += gyro.x
                biasSum.y += gyro.y
                biasSum.z += gyro.z
            } else {
                // Rolling sum: subtract oldest, add newest
                biasSum.x += gyro.x - old.x
                biasSum.y += gyro.y - old.y
                biasSum.z += gyro.z - old.z
            }

            // Update bias estimate if we have enough samples
            if biasCount >= maxSamples / 2 {
                let count = Double(biasCount)
                bias = (biasSum.x / count, biasSum.y / count, biasSum.z / count)
            }
        } else {
            // Moving: reset accumulation BUT PRESERVE CURRENT BIAS
            // This is the key fix - we don't clear the bias, only the accumulation state
            biasCount = 0
            biasIndex = 0
            biasSum = (0, 0, 0)
            // NOTE: bias is intentionally NOT reset here!
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
        biasBuffer = Array(repeating: (0, 0, 0), count: maxSamples)
        biasCount = 0
        biasIndex = 0
        biasSum = (0, 0, 0)
        bias = (0, 0, 0)
    }

    /// Force-set the bias (used when clutch captures a fresh neutral)
    func forceBias(_ newBias: (x: Double, y: Double, z: Double)) {
        // Fill buffer with new bias value to establish baseline
        for i in 0..<maxSamples {
            biasBuffer[i] = newBias
        }
        biasCount = maxSamples / 2  // Mark as calibrated
        biasIndex = 0
        let count = Double(biasCount)
        biasSum = (newBias.x * count, newBias.y * count, newBias.z * count)
        bias = newBias
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
    var onZoom: ((_ magnification: CGFloat) -> Void)?
    var onKeyDown: ((_ keyCombo: KeyCombo) -> Void)?
    var onKeyUp: ((_ keyCombo: KeyCombo) -> Void)?
    var onSystemAction: ((_ action: SystemAction) -> Void)?
    var onCalibrationChange: ((_ isCalibrated: Bool) -> Void)?

    // MARK: - Stabilization

    let biasEstimator = GyroBiasEstimator()
    private let yawFilter = OneEuroFilter()
    private let pitchFilter = OneEuroFilter()

    /// Tracks the last sample time to compute dt
    private var lastTimestamp: TimeInterval?
    private var lastReportedCalibration: Bool?
    private var lastSmoothThreshold: Double?
    private var lastFilterBeta: Double?
    private var lastInstantSpeed: Double = 0
    private var lastSpeedEMA: Double = 0
    private var lastJerkEMA: Double = 0
    private var lastBetaSpeed: Double = 0

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

    /// Parametric acceleration curve (backported from PSVR2Gyro)
    /// - Parameters:
    ///   - speed: Current angular velocity (°/s)
    ///   - rampSpeed: Speed at which gain reaches cap (°/s)
    ///   - exponent: Curve shape (<1 concave, 1 linear, >1 convex)
    ///   - cap: Maximum gain multiplier
    /// - Returns: Gain multiplier (1.0 to cap)
    private func computeParametricGain(
        speed: Double,
        rampSpeed: Double,
        exponent: Double,
        cap: Double
    ) -> Double {
        let effectiveCap = max(1.0, cap)
        let effectiveRamp = max(1.0, rampSpeed)
        let normalized = min(1.0, speed / effectiveRamp)
        let curved = pow(normalized, exponent)
        return 1.0 + curved * (effectiveCap - 1.0)
    }

    private func updateFilters(minCutoff: Double, beta: Double) {
        guard lastSmoothThreshold != minCutoff || lastFilterBeta != beta else { return }
        lastSmoothThreshold = minCutoff
        lastFilterBeta = beta
        yawFilter.minCutoff = minCutoff
        pitchFilter.minCutoff = minCutoff
        // Keep derivative cutoff modest to avoid lag in fast motion
        yawFilter.derivativeCutoff = 1.0
        pitchFilter.derivativeCutoff = 1.0
        yawFilter.beta = beta
        pitchFilter.beta = beta
        // Use Joy-Con effective gyro sample rate (~200 Hz bundled into 66 Hz packets)
        yawFilter.fallbackRate = 200.0
        pitchFilter.fallbackRate = 200.0
    }

    private func smoothedSpeed(_ instantaneous: Double) -> Double {
        // Short EMA to stabilize acceleration curve selection
        let alpha = 0.15
        lastInstantSpeed = instantaneous
        lastSpeedEMA = alpha * instantaneous + (1 - alpha) * lastSpeedEMA
        return lastSpeedEMA
    }

    private func dynamicFilterBeta(forYaw yaw: Double, pitch: Double, baseBeta: Double, dt: Double, mode: AdaptiveSmoothingMode) -> Double {
        switch mode {
        case .off:
            return baseBeta
        case .speed, .speedAndJerk:
            let speed = sqrt(yaw * yaw + pitch * pitch)
            let jerk = abs(speed - lastBetaSpeed) / max(dt, 0.001)
            lastBetaSpeed = speed
            let jerkAlpha = 0.25
            lastJerkEMA = jerkAlpha * jerk + (1 - jerkAlpha) * lastJerkEMA

            let speedTerm = min(1.0, speed / 150.0)
            let jerkTerm = mode == .speedAndJerk ? min(1.0, lastJerkEMA / 200.0) : 0
            let boost = max(speedTerm, jerkTerm) * 0.2  // cap boost to 0.2
            return min(1.0, baseBeta + boost)
        }
    }

    /// Process gyroscope data and convert to mouse movement
    /// - Parameters:
    ///   - gyro: Gyroscope values (x, y, z) in degrees per second
    ///   - timestamp: Monotonic timestamp for this sample
    ///   - sensitivity: Mouse movement multiplier
    ///   - filterEnabled: Whether to apply One Euro filtering
    ///   - filterMinCutoff: Base cutoff frequency for smoothing (Hz)
    ///   - filterBeta: Speed coefficient for adaptive smoothing
    ///   - accelRampSpeed: Speed at which acceleration reaches cap (°/s)
    ///   - accelExponent: Acceleration curve shape (<1 concave, 1 linear, >1 convex)
    ///   - accelCap: Maximum acceleration gain multiplier
    ///   - adaptiveSmoothingMode: Whether to dynamically adjust beta
    ///   - autoNeutralRefresh: Whether to recalibrate during quiet periods
    func processGyro(
        _ gyro: GyroData,
        timestamp: TimeInterval,
        sensitivity: Double,
        filterEnabled: Bool = true,
        filterMinCutoff: Double = 1.0,
        filterBeta: Double = 1.0,
        accelRampSpeed: Double = 150.0,
        accelExponent: Double = 1.0,
        accelCap: Double = 3.0,
        adaptiveSmoothingMode: AdaptiveSmoothingMode = .off,
        autoNeutralRefresh: Bool = true
    ) {
        let now = timestamp

        // Update filter tuning
        updateFilters(minCutoff: filterMinCutoff, beta: filterBeta)

        // 1. Update bias estimator (runs continuously, learns when stationary)
        biasEstimator.update(gyro: gyro)

        // 2. Apply calibration to remove drift
        let calibrated = biasEstimator.calibratedGyro(gyro)

        // 3. Compute dt with stall detection (backported from PSVR2Gyro)
        // Joy-Con delivers ~200Hz gyro samples (bundled into 66Hz packets)
        let expectedDt = 1.0 / 200.0
        let maxDt = expectedDt * 6.0  // tolerate short Bluetooth stalls without smearing
        let dt: Double
        if let last = lastTimestamp {
            let rawDt = now - last
            dt = min(max(0.001, rawDt), maxDt)
            // Reset filters on Bluetooth stall to prevent smearing
            if rawDt > maxDt {
                yawFilter.reset()
                pitchFilter.reset()
            }
        } else {
            dt = expectedDt
        }
        lastTimestamp = now

        // Integrate roll (radians) so we can deskew axes when the controller is canted
        currentRoll += calibrated.x * dt * (.pi / 180.0)

        // While cursor is locked (clutch/scroll/zoom), watch for quiet IMU to refresh neutral/bias
        if cursorLockActive || autoNeutralRefresh {
            updateLockNeutral(rawGyro: gyro, timestamp: now)
        }

        // 4. Extract axes for pointing-forward grip
        // - Z axis: wrist rotation left/right = horizontal mouse
        // - Y axis: tilting up/down = vertical mouse
        let yaw = calibrated.z
        let pitch = -calibrated.y  // Negated for natural direction

        // 5. Apply One Euro filter (if enabled)
        var filteredYaw = yaw
        var filteredPitch = pitch

        if filterEnabled {
            // Adaptive smoothing: adjust beta based on motion
            let adaptiveBeta = dynamicFilterBeta(forYaw: yaw, pitch: pitch, baseBeta: filterBeta, dt: dt, mode: adaptiveSmoothingMode)
            yawFilter.beta = adaptiveBeta
            pitchFilter.beta = adaptiveBeta

            filteredYaw = yawFilter.filter(value: yaw, timestamp: now)
            filteredPitch = pitchFilter.filter(value: pitch, timestamp: now)
        }

        // 6. Deskew axes if the controller was re-gripped with roll (lock)
        let (compensatedYaw, compensatedPitch) = applyRollCompensation(
            yaw: filteredYaw,
            pitch: filteredPitch
        )

        // 7. Apply parametric acceleration curve
        let speed = sqrt(compensatedYaw * compensatedYaw + compensatedPitch * compensatedPitch)
        let accelGain = computeParametricGain(
            speed: smoothedSpeed(speed),
            rampSpeed: accelRampSpeed,
            exponent: accelExponent,
            cap: accelCap
        )

        // Scale: sensitivity * 0.1 gives good range with slider
        let baseScale = sensitivity * 0.1
        let ramp = lockRampFactor(now: now)
        let dx = CGFloat(compensatedYaw * dt * baseScale * accelGain * ramp)
        let dy = CGFloat(compensatedPitch * dt * baseScale * accelGain * ramp)

        DiagnosticLatencyProbe.shared.mark(.postProcess, sampleTimestamp: timestamp)

        switch currentOverride() {
        case .clutch:
            DiagnosticLatencyProbe.shared.mark(.preEvent, sampleTimestamp: timestamp)
            onMouseMove?(dx, dy)
            DiagnosticLatencyProbe.shared.mark(.postEvent, sampleTimestamp: timestamp)
        case .scroll:
            DiagnosticLatencyProbe.shared.mark(.preEvent, sampleTimestamp: timestamp)
            onScroll?(dx, dy)
            DiagnosticLatencyProbe.shared.mark(.postEvent, sampleTimestamp: timestamp)
        case .zoom:
            // Convert vertical motion to magnification gesture
            // Scale factor to make zoom feel natural (negative dy = tilt down = zoom out)
            let zoomScale: CGFloat = 0.01
            DiagnosticLatencyProbe.shared.mark(.preEvent, sampleTimestamp: timestamp)
            onZoom?(dy * zoomScale)
            DiagnosticLatencyProbe.shared.mark(.postEvent, sampleTimestamp: timestamp)
        case .none:
            reportCalibrationIfNeeded()
            return
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
        // Log trigger button events
        if button == .trigger {
            DiagnosticLogger.shared.log("TRIGGER DOWN - press:\(actions.press.displayName) hold:\(actions.hold.displayName) threshold:\(holdThreshold)s")
        }

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
        } else if actions.press != .none {
            // No hold action - fire press immediately for sustained hold
            executeAction(actions.press, isDown: true)
        }
    }

    /// Handle button release with hold detection
    /// - Parameter button: The logical button released
    func handleButtonUp(_ button: LogicalButton) {
        // Log trigger button events
        if button == .trigger {
            let state = buttonState[button]
            DiagnosticLogger.shared.log("TRIGGER UP - hadState:\(state != nil) holdFired:\(state?.holdFired ?? false)")
        }

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
        } else if state.actions.hold != .none {
            // Has hold action but released before threshold - fire press as tap
            if state.actions.press != .none {
                executeAction(state.actions.press, isDown: true)
                executeAction(state.actions.press, isDown: false)
            }
        } else {
            // No hold action - release the sustained press
            if state.actions.press != .none {
                executeAction(state.actions.press, isDown: false)
            }
        }
    }

    /// Execute a single action (internal helper)
    private func executeAction(_ action: ButtonAction, isDown: Bool) {
        // Log mouse click executions
        if case .mouseClick(let btn) = action {
            DiagnosticLogger.shared.log("EXECUTE mouseClick(\(btn)) isDown:\(isDown)")
        }

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
        case .systemAction(let systemAction):
            // System actions only trigger on button down (not release)
            if isDown {
                onSystemAction?(systemAction)
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
        lastInstantSpeed = 0
        lastSpeedEMA = 0
        lastJerkEMA = 0
        lastBetaSpeed = 0
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
