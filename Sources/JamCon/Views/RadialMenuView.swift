import SwiftUI
import AppKit

// MARK: - Radial Menu View

/// The visual representation of the radial menu
struct RadialMenuView: View {
    @ObservedObject var state: RadialMenuState

    private let menuSize: CGFloat = 200

    var body: some View {
        ZStack {
            // Background blur circle (ring only, center is transparent)
            Circle()
                .fill(.ultraThinMaterial)
                .frame(width: menuSize, height: menuSize)
                .mask(
                    Ring(innerRadiusRatio: state.activeConfiguration.innerRadiusRatio)
                        .fill(style: FillStyle(eoFill: true))
                )

            // Pie slices
            ForEach(Array(state.activeConfiguration.items.enumerated()), id: \.element.id) { index, item in
                PieSlice(
                    index: index,
                    total: state.sliceCount,
                    innerRadiusRatio: state.activeConfiguration.innerRadiusRatio
                )
                .fill(sliceColor(isHighlighted: state.highlightedIndex == index))
                .overlay(
                    PieSlice(
                        index: index,
                        total: state.sliceCount,
                        innerRadiusRatio: state.activeConfiguration.innerRadiusRatio
                    )
                    .strokeBorder(
                        state.highlightedIndex == index
                            ? Color.white.opacity(0.8)
                            : Color.white.opacity(0.2),
                        lineWidth: state.highlightedIndex == index ? 2 : 1
                    )
                )

                // Icon for each slice
                sliceIcon(item: item, index: index, isHighlighted: state.highlightedIndex == index)
            }

            // Center hole border (transparent center)
            Circle()
                .strokeBorder(Color.white.opacity(0.2), lineWidth: 1)
                .frame(
                    width: menuSize * state.activeConfiguration.innerRadiusRatio,
                    height: menuSize * state.activeConfiguration.innerRadiusRatio
                )
        }
        .frame(width: menuSize, height: menuSize)
        .shadow(color: .black.opacity(0.25), radius: 20, x: 0, y: 10)
    }

    // MARK: - Helpers

    private func sliceColor(isHighlighted: Bool) -> Color {
        isHighlighted ? Color.accentColor.opacity(0.8) : Color.clear
    }

    @ViewBuilder
    private func sliceIcon(item: RadialMenuItem, index: Int, isHighlighted: Bool) -> some View {
        let angle = sliceCenterAngle(for: index)
        let distance = menuSize * 0.34  // Position icons between inner and outer radius

        Image(systemName: item.icon)
            .font(.system(size: isHighlighted ? 24 : 20, weight: .semibold))
            .foregroundStyle(isHighlighted ? .white : .primary)
            .shadow(color: .black.opacity(0.3), radius: 2, x: 0, y: 1)
            .offset(
                x: cos(angle) * distance,
                y: sin(angle) * distance
            )
            .animation(.easeOut(duration: 0.1), value: isHighlighted)
    }

    /// Calculate the center angle for a slice (for positioning icons)
    private func sliceCenterAngle(for index: Int) -> Double {
        let sliceAngle = (2 * Double.pi) / Double(state.sliceCount)
        // Start from top (-pi/2) and go clockwise
        return -Double.pi / 2 + sliceAngle * Double(index) + sliceAngle / 2
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
    var insetAmount: CGFloat = 0

    func path(in rect: CGRect) -> Path {
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let outerRadius = min(rect.width, rect.height) / 2 - insetAmount
        let innerRadius = outerRadius * innerRadiusRatio

        let sliceAngle = (2 * Double.pi) / Double(total)
        // Start from top (-pi/2)
        let startAngle = -Double.pi / 2 + sliceAngle * Double(index)
        let endAngle = startAngle + sliceAngle

        // Add small gap between slices
        let gapAngle = 0.03  // radians
        let adjustedStart = startAngle + gapAngle / 2
        let adjustedEnd = endAngle - gapAngle / 2

        var path = Path()

        // Outer arc
        path.addArc(
            center: center,
            radius: outerRadius,
            startAngle: .radians(adjustedStart),
            endAngle: .radians(adjustedEnd),
            clockwise: false
        )

        // Line to inner arc
        path.addLine(to: CGPoint(
            x: center.x + innerRadius * cos(adjustedEnd),
            y: center.y + innerRadius * sin(adjustedEnd)
        ))

        // Inner arc (reverse direction)
        path.addArc(
            center: center,
            radius: innerRadius,
            startAngle: .radians(adjustedEnd),
            endAngle: .radians(adjustedStart),
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
    private let menuSize: CGFloat = 200

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
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        window.contentView = hostingView

        self.window = window
    }

    func show(at position: CGPoint) {
        guard let window = window else { return }

        // Position window centered on mouse
        // NSEvent.mouseLocation uses bottom-left origin (Cocoa coordinates)
        let origin = CGPoint(
            x: position.x - menuSize / 2,
            y: position.y - menuSize / 2
        )

        window.setFrameOrigin(origin)
        window.orderFront(nil)
    }

    func hide() {
        window?.orderOut(nil)
    }

    func updatePosition(_ position: CGPoint) {
        guard let window = window, window.isVisible else { return }
        let origin = CGPoint(
            x: position.x - menuSize / 2,
            y: position.y - menuSize / 2
        )
        window.setFrameOrigin(origin)
    }
}

// MARK: - Preview

#Preview {
    let state = RadialMenuState()
    state.highlightedIndex = 0
    return RadialMenuView(state: state)
        .frame(width: 250, height: 250)
        .background(Color.gray.opacity(0.3))
}
