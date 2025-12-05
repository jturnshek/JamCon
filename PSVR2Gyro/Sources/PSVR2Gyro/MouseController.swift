import Foundation
import CoreGraphics
import AppKit

/// Minimal mouse controller using CGEvent
class MouseController {

    // MARK: - Properties

    private static let eventSource: CGEventSource? = CGEventSource(stateID: .privateState)

    private var currentPosition: CGPoint {
        NSEvent.mouseLocation
    }

    private var screenBounds: CGRect {
        let screens = NSScreen.screens
        guard var union = screens.first?.frame else {
            return CGRect(x: 0, y: 0, width: 1920, height: 1080)
        }
        for screen in screens.dropFirst() {
            union = union.union(screen.frame)
        }
        return union
    }

    // MARK: - Mouse Movement

    /// Move the mouse by a relative amount
    func moveRelative(dx: CGFloat, dy: CGFloat) {
        let current = currentPosition
        let bounds = screenBounds

        // Calculate new position in Cocoa coords (origin bottom-left)
        // dy from input is "screen down"; Cocoa Y increases upward, so subtract
        let proposed = CGPoint(x: current.x + dx, y: current.y - dy)
        let clamped = clamp(proposed, to: bounds)
        let quartzPoint = toQuartzSpace(point: clamped, in: bounds)

        guard let event = CGEvent(
            mouseEventSource: Self.eventSource,
            mouseType: .mouseMoved,
            mouseCursorPosition: quartzPoint,
            mouseButton: .left
        ) else {
            return
        }

        event.post(tap: .cghidEventTap)
    }

    // MARK: - Helpers

    private func clamp(_ point: CGPoint, to bounds: CGRect) -> CGPoint {
        let x = min(max(point.x, bounds.minX), bounds.maxX)
        let y = min(max(point.y, bounds.minY), bounds.maxY)
        return CGPoint(x: x, y: y)
    }

    private func toQuartzSpace(point: CGPoint, in bounds: CGRect) -> CGPoint {
        let relativeY = point.y - bounds.minY
        let quartzY = bounds.maxY - relativeY
        return CGPoint(x: point.x, y: quartzY)
    }
}
