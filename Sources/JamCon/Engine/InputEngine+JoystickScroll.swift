import Foundation
import CoreGraphics
import os

struct JoystickScrollTiming {
    private(set) var previousTimestamp: TimeInterval?

    mutating func frameScale(at timestamp: TimeInterval, nominalRate: Double) -> CGFloat {
        guard timestamp.isFinite, nominalRate > 0 else { return 0 }
        guard let previousTimestamp else {
            self.previousTimestamp = timestamp
            return 1
        }

        let elapsed = timestamp - previousTimestamp
        guard elapsed > 0 else { return 0 }
        self.previousTimestamp = timestamp

        // Prevent a reconnect or debugger pause from producing one enormous
        // scroll event while preserving normal report-rate independence.
        let boundedElapsed = min(elapsed, 0.05)
        return CGFloat(boundedElapsed * nominalRate)
    }

    mutating func reset() {
        previousTimestamp = nil
    }
}

extension InputEngine {

    // MARK: - Joystick Scroll

    func processJoystickScroll(
        bytes: [UInt8],
        mapping: SenseButtonMapping,
        timestamp: TimeInterval,
        timing: inout JoystickScrollTiming,
        settings: SettingsStore.InputSettings
    ) {
        let joystickPos = mapping.joystickPosition(in: bytes)
        let deadzone: Double = 20.0
        let center: Double = 128.0
        let maxDelta: Double = 127.0

        let deltaX = Double(joystickPos.x) - center
        let deltaY = Double(joystickPos.y) - center
        let frameScale = timing.frameScale(at: timestamp, nominalRate: 60)

        if frameScale > 0, abs(deltaX) > deadzone || abs(deltaY) > deadzone {
            let speed = settings.joystickScrollSpeed
            let accel = settings.joystickScrollAcceleration

            func scaled(_ delta: Double) -> CGFloat {
                let sign = delta >= 0 ? 1.0 : -1.0
                let normalized = min(1.0, abs(delta) / maxDelta)
                // Quadratic base curve for smooth feel
                let curved = normalized * normalized
                // Acceleration multiplies the output: higher accel = faster at full deflection
                // Interpolate from 1x at low deflection to accel× at full deflection
                let accelGain = 1.0 + (accel - 1.0) * normalized
                return CGFloat(sign * curved * accelGain * speed * 2.0) * frameScale
            }

            let scrollX = scaled(deltaX)
            let scrollY = scaled(deltaY)
            mouseController.scroll(dx: scrollX, dy: scrollY)
        }
    }

    func processJoyConJoystickScroll(bytes: [UInt8], mapping: JoyConButtonMapping, settings: SettingsStore.InputSettings) {
        let joystickPos = mapping.joystickPosition(in: bytes)
        let deadzone: Double = 20.0
        let center: Double = 128.0
        let maxDelta: Double = 127.0

        let deltaX = Double(joystickPos.x) - center
        let deltaY = -(Double(joystickPos.y) - center)  // Invert Y for natural scroll direction

        if abs(deltaX) > deadzone || abs(deltaY) > deadzone {
            let speed = settings.joystickScrollSpeed
            let accel = settings.joystickScrollAcceleration

            func scaled(_ delta: Double) -> CGFloat {
                let sign = delta >= 0 ? 1.0 : -1.0
                let normalized = min(1.0, abs(delta) / maxDelta)
                // Quadratic base curve for smooth feel
                let curved = normalized * normalized
                // Acceleration multiplies the output: higher accel = faster at full deflection
                // At normalized=1.0: output = 1 * accel
                // Interpolate from 1x at low deflection to accel× at full deflection
                let accelGain = 1.0 + (accel - 1.0) * normalized
                return CGFloat(sign * curved * accelGain * speed * 2.0)
            }

            let scrollX = scaled(deltaX)
            let scrollY = scaled(deltaY)
            mouseController.scroll(dx: scrollX, dy: scrollY)
        }
    }
}
