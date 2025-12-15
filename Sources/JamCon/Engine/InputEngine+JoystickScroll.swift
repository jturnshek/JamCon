import Foundation
import CoreGraphics
import os

extension InputEngine {

    // MARK: - Joystick Scroll

    func processJoystickScroll(bytes: [UInt8], mapping: SenseButtonMapping, settings: SettingsStore.InputSettings) {
        let joystickPos = mapping.joystickPosition(in: bytes)
        let deadzone: Double = 20.0
        let center: Double = 128.0
        let maxDelta: Double = 127.0

        let deltaX = Double(joystickPos.x) - center
        let deltaY = Double(joystickPos.y) - center

        if abs(deltaX) > deadzone || abs(deltaY) > deadzone {
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
                return CGFloat(sign * curved * accelGain * speed * 2.0)
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

