import Foundation
import CoreGraphics

// MARK: - Trail Point

/// A point in the ghost cursor trail with timestamp for fading
struct TrailPoint: Identifiable {
    let id: UInt64
    let position: CGPoint
    let timestamp: Date
}

// MARK: - Menu Ring

/// Which ring of the radial menu is currently selected
enum MenuRing: Equatable {
    case none
    case inner
    case outer
}

// MARK: - Radial Menu State

/// Runtime state for the radial menu overlay
/// Thread-safe for updates from HID callback, UI observes on main thread
@MainActor
class RadialMenuState: ObservableObject {

    // MARK: - Published Properties

    /// Whether the radial menu is currently visible
    @Published var isVisible: Bool = false

    /// Current mouse position where menu is anchored (screen coordinates)
    @Published var anchorPosition: CGPoint = .zero

    /// Currently highlighted slice index for inner ring (nil = center/none)
    @Published var highlightedIndex: Int? = nil

    /// Currently highlighted slice index for outer ring (nil = none)
    @Published var outerRingHighlightedIndex: Int? = nil

    /// Which ring is currently selected
    @Published var selectedRing: MenuRing = .none

    /// The active menu configuration
    @Published var activeConfiguration: RadialMenuConfiguration = .arrowKeys

    /// Ghost cursor position relative to menu center
    @Published var ghostPosition: CGPoint = .zero

    /// Trail of recent ghost cursor positions for visual effect
    @Published var trailPoints: [TrailPoint] = []
    private var trailIdCounter: UInt64 = 0

    // MARK: - Constants

    /// Maximum number of trail points to keep
    private let maxTrailPoints = 20

    /// How long trail points remain visible (seconds)
    private let trailLifetime: TimeInterval = 0.3

    /// Sensitivity multiplier for delta movement
    let movementSensitivity: CGFloat = 2.0

    // MARK: - Internal State

    /// Accumulated delta from gyro/mouse movement
    private var accumulatedDelta: CGPoint = .zero

    // MARK: - Computed Properties

    /// Menu visual diameter (dynamic based on configuration)
    var menuSize: CGFloat {
        activeConfiguration.menuDiameter
    }

    /// Number of slices in the current menu
    var sliceCount: Int {
        activeConfiguration.items.count
    }

    /// Angle span per slice in radians
    var sliceAngle: Double {
        guard sliceCount > 0 else { return 0 }
        return (2 * Double.pi) / Double(sliceCount)
    }

    /// Inner radius (deadzone) based on configuration
    var innerRadius: CGFloat {
        activeConfiguration.deadzoneSize
    }

    /// Minimum movement magnitude to highlight a segment (matches visual inner radius)
    var selectionThreshold: CGFloat {
        innerRadius
    }

    /// Outer radius (half of menu size = total menu radius)
    var outerRadius: CGFloat {
        activeConfiguration.menuRadius
    }

    /// Maximum distance ghost cursor can move from center
    var maxGhostRadius: CGFloat {
        outerRadius - 10  // Leave some padding
    }

    /// Radius where outer ring begins (deadzone + inner ring)
    var outerRingInnerRadius: CGFloat {
        activeConfiguration.deadzoneSize + activeConfiguration.innerRingSize
    }

    /// Number of slices in the outer ring
    var outerRingSliceCount: Int {
        activeConfiguration.outerRingItems.count
    }

    // MARK: - Methods

    /// Show the menu at the given screen position
    func show(at position: CGPoint, configuration: RadialMenuConfiguration? = nil) {
        if let config = configuration {
            activeConfiguration = config
        }
        anchorPosition = position
        highlightedIndex = nil
        outerRingHighlightedIndex = nil
        selectedRing = .none
        ghostPosition = .zero
        accumulatedDelta = .zero
        trailPoints.removeAll(keepingCapacity: true)
        isVisible = true
    }

    /// Hide the menu
    func hide() {
        isVisible = false
        highlightedIndex = nil
        outerRingHighlightedIndex = nil
        selectedRing = .none
        ghostPosition = .zero
        accumulatedDelta = .zero
        trailPoints.removeAll(keepingCapacity: true)
    }

    /// Update from gyro/mouse delta movement
    /// - Parameters:
    ///   - dx: Horizontal delta (positive = right)
    ///   - dy: Vertical delta (positive = down in screen coordinates)
    func updateFromDelta(dx: CGFloat, dy: CGFloat) {
        // Accumulate movement with sensitivity
        accumulatedDelta.x += dx * movementSensitivity
        accumulatedDelta.y += dy * movementSensitivity

        // Calculate magnitude (distance from center)
        let magnitude = sqrt(accumulatedDelta.x * accumulatedDelta.x + accumulatedDelta.y * accumulatedDelta.y)

        // Calculate angle for segment selection
        // In screen coords: Y+ is down, so atan2(y, x) gives angle where down is positive
        // We use this directly since our segment layout matches screen coordinates
        let angle = atan2(accumulatedDelta.y, accumulatedDelta.x)

        // Clamp ghost cursor to max radius
        let clampedMagnitude = min(magnitude, maxGhostRadius)
        let newGhostPosition = CGPoint(
            x: cos(angle) * clampedMagnitude,
            y: sin(angle) * clampedMagnitude  // Y+ is down in screen coords, matches SwiftUI
        )

        ghostPosition = newGhostPosition

        // Determine which ring is selected based on magnitude
        let outerRingEnabled = activeConfiguration.outerRingEnabled && outerRingSliceCount > 0

        if magnitude < selectionThreshold {
            // Inside inner deadzone - no selection
            selectedRing = .none
            highlightedIndex = nil
            outerRingHighlightedIndex = nil
        } else if !outerRingEnabled || magnitude < outerRingInnerRadius {
            // In inner ring zone (or outer ring disabled)
            selectedRing = .inner
            highlightedIndex = sliceCount > 0
                ? angleToSegmentIndex(angle, sliceCount: sliceCount, rotationDegrees: activeConfiguration.innerRingRotation)
                : nil
            outerRingHighlightedIndex = nil
        } else {
            // In outer ring zone
            selectedRing = .outer
            highlightedIndex = nil
            outerRingHighlightedIndex = angleToSegmentIndex(
                angle,
                sliceCount: outerRingSliceCount,
                rotationDegrees: activeConfiguration.outerRingRotation
            )
        }
    }

    /// Get the currently highlighted inner ring item
    func highlightedItem() -> RadialMenuItem? {
        guard let index = highlightedIndex,
              index >= 0 && index < activeConfiguration.items.count else {
            return nil
        }
        return activeConfiguration.items[index]
    }

    /// Get the currently highlighted outer ring item
    func outerRingHighlightedItem() -> RadialMenuItem? {
        guard let index = outerRingHighlightedIndex,
              index >= 0 && index < activeConfiguration.outerRingItems.count else {
            return nil
        }
        return activeConfiguration.outerRingItems[index]
    }

    /// Reset accumulated movement (call when menu is shown)
    func resetMovement() {
        accumulatedDelta = .zero
        ghostPosition = .zero
        highlightedIndex = nil
        outerRingHighlightedIndex = nil
        selectedRing = .none
        trailPoints.removeAll()
    }

    // MARK: - Private Helpers

    /// Convert angle to segment index
    /// - Parameters:
    ///   - angle: Angle in radians (0 = right, positive = clockwise in screen coords)
    ///   - sliceCount: Number of slices in the ring
    ///   - rotationDegrees: Ring-specific rotation in degrees
    /// - Returns: Segment index (0 = top, then clockwise)
    private func angleToSegmentIndex(_ angle: Double, sliceCount: Int, rotationDegrees: Double) -> Int {
        guard sliceCount > 0 else { return 0 }

        // Items are arranged: 0 = top, 1 = right, 2 = bottom, 3 = left (for 4 items)
        // Input angle (screen coords): 0 = right, pi/2 = down, pi = left, -pi/2 = up

        // Convert rotation offset from degrees to radians (negative for clockwise)
        let rotationRadians = -rotationDegrees * Double.pi / 180.0

        // Rotate so 0 degrees points up (subtract pi/2, since up is -pi/2 in screen coords)
        // Also subtract the user's rotation offset
        var normalizedAngle = angle + Double.pi / 2 - rotationRadians

        // Ensure angle is in [0, 2*pi)
        let twoPi = Double.pi * 2.0
        normalizedAngle = fmod(normalizedAngle, twoPi)
        if normalizedAngle < 0 { normalizedAngle += twoPi }

        // Calculate which slice this falls into
        let sliceAngleSize = (2 * Double.pi) / Double(sliceCount)
        let index = Int(normalizedAngle / sliceAngleSize)

        return min(index, sliceCount - 1)
    }

    /// Add a point to the trail
    private func addTrailPoint(_ position: CGPoint, timestamp: Date) {
        let point = TrailPoint(id: trailIdCounter, position: position, timestamp: timestamp)
        trailIdCounter &+= 1
        trailPoints.append(point)

        // Limit trail length
        if trailPoints.count > maxTrailPoints {
            trailPoints.removeFirst()
        }
    }

    /// Remove old trail points
    private func pruneTrailPoints(now: Date) {
        let cutoff = now.addingTimeInterval(-trailLifetime)
        trailPoints.removeAll { $0.timestamp < cutoff }
    }
}
