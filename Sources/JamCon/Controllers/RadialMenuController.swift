import Foundation
import CoreGraphics
import AppKit

/// Controller for radial menu activation and selection
/// Note: This is called from the HID input queue, not the main thread
class RadialMenuController {

    // MARK: - Callbacks

    /// Called when menu should show (provides current mouse position)
    var onShowMenu: ((_ position: CGPoint) -> Void)?

    /// Called when menu should hide
    var onHideMenu: (() -> Void)?

    /// Called when joystick position updates (angle in radians, magnitude 0-1)
    var onJoystickUpdate: ((_ angle: Double, _ magnitude: Double) -> Void)?

    // MARK: - State

    private var menuActive: Bool = false
    private var requireRearm: Bool = false  // Must return to deadzone before next activation

    // MARK: - Joystick Processing

    /// Process joystick input in radial menu mode
    /// - Parameters:
    ///   - x: Joystick X position (-1 to 1, positive = right)
    ///   - y: Joystick Y position (-1 to 1, positive = up)
    ///   - deadzone: Deadzone threshold
    func processStick(x: Double, y: Double, deadzone: Double) {
        // Apply deadzone
        var adjustedX = x
        var adjustedY = y

        if abs(x) < deadzone { adjustedX = 0 }
        if abs(y) < deadzone { adjustedY = 0 }

        // Calculate magnitude
        let magnitude = sqrt(adjustedX * adjustedX + adjustedY * adjustedY)
        let clampedMagnitude = min(1.0, magnitude)

        // Check for menu activation/deactivation based on deadzone
        if clampedMagnitude < deadzone {
            // Joystick returned to center - allow next activation
            requireRearm = false
            if menuActive {
                deactivateMenu()
                return
            }
        } else if !menuActive && !requireRearm {
            activateMenu()
        }

        // Update joystick state if menu is active
        if menuActive && clampedMagnitude > 0 {
            // Negate Y to match screen coordinates (stick up = screen up = negative Y in view)
            let angle = atan2(-adjustedY, adjustedX)
            onJoystickUpdate?(angle, clampedMagnitude)
        }
    }

    // MARK: - Private Methods

    private func activateMenu() {
        menuActive = true
        let mouseLocation = NSEvent.mouseLocation
        onShowMenu?(mouseLocation)
    }

    private func deactivateMenu() {
        menuActive = false
        onHideMenu?()
    }

    /// Reset state (call when stick mode changes or controller disconnects)
    func reset() {
        if menuActive {
            deactivateMenu()
        }
        requireRearm = true  // Require joystick to return to center before next activation
    }

    /// Whether the radial menu is currently active
    var isActive: Bool {
        menuActive
    }
}
