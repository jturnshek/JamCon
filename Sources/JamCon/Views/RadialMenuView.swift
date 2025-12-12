import SwiftUI
import AppKit

// MARK: - Colors Helper

/// Rainbow spectrum colors for radial menu segments
enum RadialMenuColors {
    static let red = Color(red: 1.0, green: 0.23, blue: 0.19)
    static let orange = Color(red: 1.0, green: 0.58, blue: 0.0)
    static let yellow = Color(red: 1.0, green: 0.80, blue: 0.0)
    static let green = Color(red: 0.20, green: 0.78, blue: 0.35)
    static let cyan = Color(red: 0.0, green: 0.78, blue: 0.75)
    static let blue = Color(red: 0.0, green: 0.48, blue: 1.0)
    static let purple = Color(red: 0.69, green: 0.32, blue: 0.87)
    static let magenta = Color(red: 1.0, green: 0.18, blue: 0.33)

    static let rainbow: [Color] = [red, orange, yellow, green, cyan, blue, purple, magenta]

    static func rainbow(at index: Int, count: Int) -> Color {
        let normalizedIndex = count > 0 ? index % count : 0
        let colorIndex = Int(Double(normalizedIndex) / Double(max(count, 1)) * Double(rainbow.count))
        return rainbow[min(colorIndex, rainbow.count - 1)]
    }
}

// MARK: - Radial Menu View

/// The visual representation of the radial menu with ghost cursor trail
struct RadialMenuView: View {
    @ObservedObject var state: RadialMenuState

    /// Dynamic menu size from configuration
    private var menuSize: CGFloat { state.menuSize }

    var body: some View {
        ZStack {
            // Inner ring pie slices - stroke-based design with rainbow colors
            ForEach(Array(state.activeConfiguration.items.enumerated()), id: \.element.id) { index, item in
                let isHighlighted = state.highlightedIndex == index
                let sliceColor = RadialMenuColors.rainbow(at: index, count: state.sliceCount)

                // Glass background for each slice (macOS 26+)
                sliceGlassBackground(index: index, isOuterRing: false)

                // Subtle fill only when highlighted
                PieSlice(
                    index: index,
                    total: state.sliceCount,
                    innerRadiusRatio: state.activeConfiguration.innerRadiusRatio,
                    outerRadiusRatio: innerRingOuterRatio,
                    rotationOffset: innerRingRotationRadians
                )
                .fill(isHighlighted ? sliceColor.opacity(0.2) : Color.clear)

                // Stroke border - the main visual element
                PieSlice(
                    index: index,
                    total: state.sliceCount,
                    innerRadiusRatio: state.activeConfiguration.innerRadiusRatio,
                    outerRadiusRatio: innerRingOuterRatio,
                    rotationOffset: innerRingRotationRadians
                )
                .strokeBorder(
                    isHighlighted ? sliceColor : sliceColor.opacity(0.6),
                    lineWidth: isHighlighted ? 2 : 1
                )

                // Label for each slice
                sliceLabel(item: item, index: index, isHighlighted: isHighlighted, color: sliceColor, isOuterRing: false)
            }

            // Outer ring pie slices (if enabled)
            if state.activeConfiguration.outerRingEnabled && state.outerRingSliceCount > 0 {
                ForEach(Array(state.activeConfiguration.outerRingItems.enumerated()), id: \.element.id) { index, item in
                    let isHighlighted = state.outerRingHighlightedIndex == index
                    let sliceColor = RadialMenuColors.rainbow(at: index, count: state.outerRingSliceCount)

                    // Glass background for outer ring slice
                    sliceGlassBackground(index: index, isOuterRing: true)

                    // Subtle fill only when highlighted
                    PieSlice(
                        index: index,
                        total: state.outerRingSliceCount,
                        innerRadiusRatio: state.activeConfiguration.outerRingThreshold,
                        outerRadiusRatio: 1.0,
                        rotationOffset: outerRingRotationRadians
                    )
                    .fill(isHighlighted ? sliceColor.opacity(0.2) : Color.clear)

                    // Stroke border
                    PieSlice(
                        index: index,
                        total: state.outerRingSliceCount,
                        innerRadiusRatio: state.activeConfiguration.outerRingThreshold,
                        outerRadiusRatio: 1.0,
                        rotationOffset: outerRingRotationRadians
                    )
                    .strokeBorder(
                        isHighlighted ? sliceColor : sliceColor.opacity(0.6),
                        lineWidth: isHighlighted ? 2 : 1
                    )

                    // Label for outer ring slice
                    sliceLabel(item: item, index: index, isHighlighted: isHighlighted, color: sliceColor, isOuterRing: true)
                }

                // Divider circle between inner and outer ring
                Circle()
                    .strokeBorder(Color.primary.opacity(0.15), lineWidth: 1)
                    .frame(
                        width: state.outerRingInnerRadius * 2,
                        height: state.outerRingInnerRadius * 2
                    )
            }

            // Center hole border
            Circle()
                .strokeBorder(Color.primary.opacity(0.2), lineWidth: 1)
                .frame(
                    width: state.innerRadius * 2,
                    height: state.innerRadius * 2
                )

            // Ghost cursor dot (controller mode only; mouse uses system cursor)
            if state.pointerStyle == .ghostCursor {
                ghostCursorDot
            }
        }
        .frame(width: menuSize, height: menuSize)
        .shadow(color: .black.opacity(0.25), radius: 16, x: 0, y: 6)
    }

    /// Inner ring outer edge ratio (depends on whether outer ring is enabled)
    private var innerRingOuterRatio: Double {
        state.activeConfiguration.outerRingEnabled && state.outerRingSliceCount > 0
            ? state.activeConfiguration.outerRingThreshold
            : 1.0
    }

    // MARK: - Ghost Cursor

    /// Trail of fading dots following the cursor
    private var ghostCursorTrail: some View {
        let now = Date()
        let trailLifetime: TimeInterval = 0.3

        return ForEach(state.trailPoints) { point in
            let age = now.timeIntervalSince(point.timestamp)
            let progress = min(age / trailLifetime, 1.0)
            let opacity = 1.0 - progress
            let size = 6.0 - progress * 4.0  // 6px → 2px

            Circle()
                .fill(Color.white.opacity(opacity * 0.6))
                .frame(width: size, height: size)
                .position(
                    x: menuSize / 2 + point.position.x,
                    y: menuSize / 2 + point.position.y
                )
        }
    }

    /// Main ghost cursor dot
    private var ghostCursorDot: some View {
        let dotColor: Color = {
            switch state.selectedRing {
            case .inner:
                if let index = state.highlightedIndex {
                    return RadialMenuColors.rainbow(at: index, count: state.sliceCount)
                }
            case .outer:
                if let index = state.outerRingHighlightedIndex {
                    return RadialMenuColors.rainbow(at: index, count: state.outerRingSliceCount)
                }
            case .none:
                break
            }
            return Color.white
        }()

        return ZStack {
            // Glow effect
            Circle()
                .fill(dotColor.opacity(0.3))
                .frame(width: 16, height: 16)
                .blur(radius: 4)

            // Main dot
            Circle()
                .fill(dotColor)
                .frame(width: 10, height: 10)

            // Inner highlight
            Circle()
                .fill(Color.white.opacity(0.5))
                .frame(width: 4, height: 4)
                .offset(x: -1, y: -1)
        }
        .position(
            x: menuSize / 2 + state.ghostPosition.x,
            y: menuSize / 2 + state.ghostPosition.y
        )
    }

    // MARK: - Helpers

    /// Glass background for individual pie slice (macOS 26+)
    @ViewBuilder
    private func sliceGlassBackground(index: Int, isOuterRing: Bool) -> some View {
        let slice = isOuterRing
            ? PieSlice(
                index: index,
                total: state.outerRingSliceCount,
                innerRadiusRatio: state.activeConfiguration.outerRingThreshold,
                outerRadiusRatio: 1.0,
                rotationOffset: outerRingRotationRadians
            )
            : PieSlice(
                index: index,
                total: state.sliceCount,
                innerRadiusRatio: state.activeConfiguration.innerRadiusRatio,
                outerRadiusRatio: innerRingOuterRatio,
                rotationOffset: innerRingRotationRadians
            )

        if #available(macOS 26.0, *) {
            slice
                .fill(.white.opacity(0.001))
                .glassEffect(.clear.tint(.white.opacity(0)), in: slice)
        } else {
            slice
                .fill(.ultraThinMaterial)
        }
    }

    @ViewBuilder
    private func sliceLabel(item: RadialMenuItem, index: Int, isHighlighted: Bool, color: Color, isOuterRing: Bool) -> some View {
        let angle = sliceCenterAngle(for: index, isOuterRing: isOuterRing)
        let distance: CGFloat = isOuterRing
            ? menuSize / 2 * (state.activeConfiguration.outerRingThreshold + 1.0) / 2
            : menuSize / 2 * (state.activeConfiguration.innerRadiusRatio + innerRingOuterRatio) / 2

        // Calculate max width based on ring size and slice count
        let sliceCount = isOuterRing ? state.outerRingSliceCount : state.sliceCount
        let ringThickness: CGFloat = isOuterRing
            ? state.activeConfiguration.outerRingSize
            : state.activeConfiguration.innerRingSize
        // Approximate arc width at the label distance, with padding
        let arcWidth = 2 * Double.pi * distance / Double(max(sliceCount, 1)) * 0.8

        Text(item.action.displayName)
            .font(.system(size: isHighlighted ? 14 : 12, weight: .medium))
            .foregroundStyle(isHighlighted ? color : .primary)
            .shadow(color: .black.opacity(0.2), radius: 1, x: 0, y: 1)
            .multilineTextAlignment(.center)
            .lineLimit(2)
            .frame(maxWidth: min(arcWidth, ringThickness * 1.5))
            .offset(
                x: cos(angle) * distance,
                y: sin(angle) * distance
            )
    }

    /// Calculate the center angle for a slice (for positioning labels)
    private func sliceCenterAngle(for index: Int, isOuterRing: Bool) -> Double {
        let sliceCount = isOuterRing ? state.outerRingSliceCount : state.sliceCount
        guard sliceCount > 0 else { return 0 }
        let sliceAngle = (2 * Double.pi) / Double(sliceCount)
        let rotationRadians = isOuterRing ? outerRingRotationRadians : innerRingRotationRadians
        return -Double.pi / 2 + sliceAngle * Double(index) + sliceAngle / 2 + rotationRadians
    }

    /// Inner ring rotation offset in radians (negative for clockwise rotation)
    private var innerRingRotationRadians: Double {
        -state.activeConfiguration.innerRingRotation * Double.pi / 180.0
    }

    /// Outer ring rotation offset in radians (negative for clockwise rotation)
    private var outerRingRotationRadians: Double {
        -state.activeConfiguration.outerRingRotation * Double.pi / 180.0
    }
}

// MARK: - Ring Shape (for masking)

struct Ring: Shape {
    let innerRadiusRatio: Double

    func path(in rect: CGRect) -> Path {
        let outerRadius = min(rect.width, rect.height) / 2
        let innerRadius = outerRadius * innerRadiusRatio
        var path = Path()
        path.addEllipse(in: rect)
        path.addEllipse(in: CGRect(
            x: rect.midX - innerRadius,
            y: rect.midY - innerRadius,
            width: innerRadius * 2,
            height: innerRadius * 2
        ))
        return path
    }
}

// MARK: - Pie Slice Shape

struct PieSlice: InsettableShape {
    let index: Int
    let total: Int
    let innerRadiusRatio: Double
    var outerRadiusRatio: Double = 1.0  // Outer edge ratio (1.0 = full radius)
    var rotationOffset: Double = 0  // Rotation in radians
    var insetAmount: CGFloat = 0

    func path(in rect: CGRect) -> Path {
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let maxRadius = min(rect.width, rect.height) / 2 - insetAmount
        let outerRadius = maxRadius * outerRadiusRatio
        let innerRadius = maxRadius * innerRadiusRatio

        let sliceAngle = (2 * Double.pi) / Double(total)
        // Start from top (-pi/2), plus rotation offset
        let startAngle = -Double.pi / 2 + sliceAngle * Double(index) + rotationOffset
        let endAngle = startAngle + sliceAngle

        // Fixed gap width in points (creates rectangular gaps with parallel edges)
        let gapWidth: Double = 4.0

        // Calculate perpendicular offsets at each radius
        let outerOffset = asin(min((gapWidth / 2) / outerRadius, 0.99))
        let innerOffset = asin(min((gapWidth / 2) / innerRadius, 0.99))

        let adjustedStartOuter = startAngle + outerOffset
        let adjustedEndOuter = endAngle - outerOffset
        let adjustedStartInner = startAngle + innerOffset
        let adjustedEndInner = endAngle - innerOffset

        var path = Path()

        // Outer arc
        path.addArc(
            center: center,
            radius: outerRadius,
            startAngle: .radians(adjustedStartOuter),
            endAngle: .radians(adjustedEndOuter),
            clockwise: false
        )

        // Line to inner arc (perpendicular edge, not radial)
        path.addLine(to: CGPoint(
            x: center.x + innerRadius * cos(adjustedEndInner),
            y: center.y + innerRadius * sin(adjustedEndInner)
        ))

        // Inner arc (reverse direction)
        path.addArc(
            center: center,
            radius: innerRadius,
            startAngle: .radians(adjustedEndInner),
            endAngle: .radians(adjustedStartInner),
            clockwise: true
        )

        path.closeSubpath()

        return path
    }

    func inset(by amount: CGFloat) -> some InsettableShape {
        var slice = self
        slice.insetAmount += amount
        return slice
    }
}

// MARK: - Radial Menu Window Controller

/// Manages the floating window that displays the radial menu
@MainActor
class RadialMenuWindowController {
    private var window: NSWindow?
    private var hostingView: NSHostingView<RadialMenuView>?
    private let state: RadialMenuState

    /// Current menu size from state (dynamic based on configuration)
    private var menuSize: CGFloat { state.menuSize }

    init(state: RadialMenuState) {
        self.state = state
        setupWindow()
    }

    private func setupWindow() {
        let contentView = RadialMenuView(state: state)
        let hostingView = NSHostingView(rootView: contentView)
        hostingView.frame = NSRect(x: 0, y: 0, width: menuSize, height: menuSize)
        self.hostingView = hostingView

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: menuSize, height: menuSize),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )

        window.isOpaque = false
        window.backgroundColor = .clear
        window.level = .floating
        window.hasShadow = false  // SwiftUI view handles shadow
        window.ignoresMouseEvents = true  // Click-through
        window.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary, .stationary]
        window.contentView = hostingView

        self.window = window
    }

    func show(at position: CGPoint) {
        guard let window = window, let hostingView = hostingView else { return }

        // Update window size to match current configuration
        let size = menuSize
        window.setContentSize(NSSize(width: size, height: size))
        hostingView.frame = NSRect(x: 0, y: 0, width: size, height: size)

        let origin = clampedOrigin(for: position)
        window.setFrameOrigin(origin)
        window.orderFront(nil)
    }

    func hide() {
        window?.orderOut(nil)
    }

    func updatePosition(_ position: CGPoint) {
        guard let window = window, window.isVisible else { return }
        let origin = clampedOrigin(for: position)
        window.setFrameOrigin(origin)
    }

    /// Calculate menu origin, clamped to keep the entire menu on screen
    private func clampedOrigin(for mousePosition: CGPoint) -> CGPoint {
        let size = menuSize
        // Start with centered position
        var origin = CGPoint(
            x: mousePosition.x - size / 2,
            y: mousePosition.y - size / 2
        )

        // Get the screen containing the mouse
        guard let screen = NSScreen.screens.first(where: {
            $0.frame.contains(mousePosition)
        }) ?? NSScreen.main else {
            return origin
        }

        let screenFrame = screen.visibleFrame  // Accounts for menu bar/dock

        // Clamp to keep menu fully on screen
        origin.x = max(screenFrame.minX, min(origin.x, screenFrame.maxX - size))
        origin.y = max(screenFrame.minY, min(origin.y, screenFrame.maxY - size))

        return origin
    }
}

// MARK: - Preview

#Preview {
    let state = RadialMenuState()
    state.highlightedIndex = 0
    state.ghostPosition = CGPoint(x: 50, y: -30)
    return RadialMenuView(state: state)
        .frame(width: 300, height: 300)
        .background(Color.gray.opacity(0.3))
}
