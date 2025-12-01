import Foundation
import CoreGraphics

// MARK: - Radial Menu State

/// Runtime state for the radial menu overlay
@MainActor
class RadialMenuState: ObservableObject {
    /// Whether the radial menu is currently visible
    @Published var isVisible: Bool = false

    /// Current mouse position where menu is anchored (screen coordinates)
    @Published var anchorPosition: CGPoint = .zero

    /// Currently highlighted slice index (nil = center/none)
    @Published var highlightedIndex: Int? = nil

    /// The active menu configuration
    @Published var activeConfiguration: RadialMenuConfiguration = .arrowKeys

    /// Current joystick angle in radians (-pi to pi, 0 = right)
    @Published var joystickAngle: Double = 0

    /// Current joystick magnitude (0-1)
    @Published var joystickMagnitude: Double = 0

    // MARK: - Computed Properties

    /// Number of slices in the current menu
    var sliceCount: Int {
        activeConfiguration.items.count
    }

    /// Angle span per slice in radians
    var sliceAngle: Double {
        guard sliceCount > 0 else { return 0 }
        return (2 * Double.pi) / Double(sliceCount)
    }

    // MARK: - Methods

    /// Show the menu at the given screen position
    func show(at position: CGPoint, configuration: RadialMenuConfiguration? = nil) {
        if let config = configuration {
            activeConfiguration = config
        }
        anchorPosition = position
        highlightedIndex = nil
        joystickAngle = 0
        joystickMagnitude = 0
        isVisible = true
    }

    /// Hide the menu
    func hide() {
        isVisible = false
        highlightedIndex = nil
    }

    /// Update joystick state and compute highlighted slice
    /// - Parameters:
    ///   - angle: Joystick angle in radians (0 = right, positive = counterclockwise)
    ///   - magnitude: Joystick deflection (0-1)
    ///   - selectionThreshold: Minimum magnitude to highlight a slice (default matches deadzone)
    func updateJoystick(angle: Double, magnitude: Double, selectionThreshold: Double = 0.2) {
        joystickAngle = angle
        joystickMagnitude = magnitude

        guard magnitude >= selectionThreshold, sliceCount > 0 else {
            highlightedIndex = nil
            return
        }

        // Convert angle to slice index
        // Items are arranged: 0 = top, 1 = right, 2 = bottom, 3 = left (for 4 items)
        // Joystick angle: 0 = right, pi/2 = up, pi = left, -pi/2 = down

        // Rotate so 0 degrees points up (add pi/2)
        var normalizedAngle = angle + Double.pi / 2

        // Ensure positive angle (0 to 2*pi)
        while normalizedAngle < 0 {
            normalizedAngle += 2 * Double.pi
        }
        while normalizedAngle >= 2 * Double.pi {
            normalizedAngle -= 2 * Double.pi
        }

        // Calculate which slice this falls into
        let sliceAngleSize = (2 * Double.pi) / Double(sliceCount)
        let index = Int(normalizedAngle / sliceAngleSize)

        highlightedIndex = min(index, sliceCount - 1)
    }

    /// Get the currently highlighted item
    func highlightedItem() -> RadialMenuItem? {
        guard let index = highlightedIndex,
              index >= 0 && index < activeConfiguration.items.count else {
            return nil
        }
        return activeConfiguration.items[index]
    }
}
