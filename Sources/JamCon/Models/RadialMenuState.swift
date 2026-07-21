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

    /// How pointer movement is represented (ghost dot vs system cursor).
    @Published var pointerStyle: RadialMenuPointerStyle = .ghostCursor

    /// Current mouse position where menu is anchored (AppKit global screen coordinates)
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

    /// Sensitivity multiplier for delta movement (shared with engine)
    var movementSensitivity: CGFloat {
        if pointerStyle == .systemCursor {
            // Mouse selection uses the system cursor directly; don't apply gyro-style scaling.
            return 1.0
        }
        return max(0.1, activeConfiguration.radialMovementScale)
    }

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

    /// Show the menu at the given AppKit global screen position
    func show(at position: CGPoint, configuration: RadialMenuConfiguration? = nil, pointerStyle: RadialMenuPointerStyle = .ghostCursor) {
        if let config = configuration {
            activeConfiguration = config
        }
        self.pointerStyle = pointerStyle
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
        accumulatedDelta.x += dx * movementSensitivity
        accumulatedDelta.y += dy * movementSensitivity
        applyResolvedOffset(accumulatedDelta)
    }

    /// Set position directly from absolute offset (for mouse input)
    /// Unlike updateFromDelta, this sets the position absolutely rather than accumulating
    /// - Parameters:
    ///   - dx: Horizontal offset from center (positive = right)
    ///   - dy: Vertical offset from center (positive = down in screen coordinates)
    func setAbsolutePosition(dx: CGFloat, dy: CGFloat) {
        applyResolvedOffset(CGPoint(x: dx * movementSensitivity, y: dy * movementSensitivity))
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

    private func applyResolvedOffset(_ offset: CGPoint) {
        let result = RadialMenuGeometry.resolve(offset: offset, configuration: activeConfiguration)
        accumulatedDelta = result.clampedOffset
        ghostPosition = result.clampedOffset

        switch result.selection {
        case .inner(let index):
            selectedRing = .inner
            highlightedIndex = index
            outerRingHighlightedIndex = nil
        case .outer(let index):
            selectedRing = .outer
            highlightedIndex = nil
            outerRingHighlightedIndex = index
        case nil:
            selectedRing = .none
            highlightedIndex = nil
            outerRingHighlightedIndex = nil
        }
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
