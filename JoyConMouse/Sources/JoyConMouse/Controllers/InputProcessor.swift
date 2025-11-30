import Foundation
import CoreGraphics

/// Processes Joy-Con input and converts it to mouse actions
class InputProcessor {

    // MARK: - Callbacks

    var onMouseMove: ((_ dx: CGFloat, _ dy: CGFloat) -> Void)?
    var onMouseClick: ((_ button: MouseButton, _ isDown: Bool) -> Void)?
    var onScroll: ((_ dx: CGFloat, _ dy: CGFloat) -> Void)?

    // MARK: - Gyro Processing

    /// Process gyroscope data and convert to mouse movement
    /// - Parameters:
    ///   - gyro: Gyroscope values (x, y, z) in degrees per second
    ///   - sensitivity: Mouse movement multiplier
    ///   - deadzone: Minimum threshold to register movement
    func processGyro(_ gyro: GyroData, sensitivity: Double, deadzone: Double) {
        // Axis mapping for right Joy-Con held pointing forward like a TV remote:
        // - Buttons facing user, IR end pointing at screen
        // - Z axis: rotation around controller's long axis = turning wrist left/right = horizontal mouse
        // - Y axis: tilting controller up/down = vertical mouse movement

        var yaw = gyro.z      // Turning wrist left/right -> horizontal
        var pitch = -gyro.y   // Tilting up/down -> vertical (negated for natural direction)

        // Apply deadzone to filter gyro noise
        if abs(yaw) < deadzone {
            yaw = 0
        }
        if abs(pitch) < deadzone {
            pitch = 0
        }

        // Skip if no movement
        if yaw == 0 && pitch == 0 {
            return
        }

        // Convert degrees/sec to mouse delta
        // JoyConSwift reports at ~66Hz (every 15ms)
        // Scale: sensitivity * 0.1 gives good range with slider 1-50
        let scale = sensitivity * 0.1
        let dx = CGFloat(yaw * scale)
        let dy = CGFloat(pitch * scale)

        onMouseMove?(dx, dy)
    }

    // MARK: - Button Processing

    /// Process button press event
    func processButtonPress(_ button: JoyConButton, controllerType: ControllerType) {
        let mouseButton = mapButtonToMouse(button, controllerType: controllerType)
        if let mouseButton {
            onMouseClick?(mouseButton, true)
        }
    }

    /// Process button release event
    func processButtonRelease(_ button: JoyConButton, controllerType: ControllerType) {
        let mouseButton = mapButtonToMouse(button, controllerType: controllerType)
        if let mouseButton {
            onMouseClick?(mouseButton, false)
        }
    }

    /// Map Joy-Con button to mouse button based on controller type
    private func mapButtonToMouse(_ button: JoyConButton, controllerType: ControllerType) -> MouseButton? {
        switch controllerType {
        case .rightJoyCon, .proController:
            // Right Joy-Con: ZR = left click, R = right click
            switch button {
            case .zr:
                return .left
            case .r:
                return .right
            default:
                return nil
            }

        case .leftJoyCon:
            // Left Joy-Con: ZL = left click, L = right click
            switch button {
            case .zl:
                return .left
            case .l:
                return .right
            default:
                return nil
            }

        case .none:
            return nil
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
