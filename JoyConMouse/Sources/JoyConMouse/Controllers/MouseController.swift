import Foundation
import CoreGraphics
import AppKit

/// Controls the system mouse using CGEvent APIs
class MouseController {

    // MARK: - Properties

    private var currentPosition: CGPoint {
        NSEvent.mouseLocation
    }

    private var screenBounds: CGRect {
        // Get the main screen bounds
        // Note: NSScreen coordinates have origin at bottom-left, CGEvent uses top-left
        guard let screen = NSScreen.main else {
            return CGRect(x: 0, y: 0, width: 1920, height: 1080)
        }
        return screen.frame
    }

    // MARK: - Mouse Movement

    /// Move the mouse by a relative amount, clamped to screen bounds
    func moveRelative(dx: CGFloat, dy: CGFloat) {
        let current = currentPosition

        // NSEvent.mouseLocation uses bottom-left origin, we need to flip for CGEvent
        let screenHeight = screenBounds.height
        let currentY = screenHeight - current.y  // Flip Y coordinate

        // Calculate new position
        var newX = current.x + dx
        var newY = currentY + dy  // dy positive = move down in screen coords

        // Clamp to screen bounds
        newX = max(0, min(newX, screenBounds.width - 1))
        newY = max(0, min(newY, screenHeight - 1))

        let newPoint = CGPoint(x: newX, y: newY)

        // Create and post mouse move event
        guard let event = CGEvent(
            mouseEventSource: nil,
            mouseType: .mouseMoved,
            mouseCursorPosition: newPoint,
            mouseButton: .left
        ) else { return }

        event.post(tap: .cghidEventTap)
    }

    /// Move the mouse to an absolute position
    func moveTo(x: CGFloat, y: CGFloat) {
        let point = CGPoint(x: x, y: y)

        guard let event = CGEvent(
            mouseEventSource: nil,
            mouseType: .mouseMoved,
            mouseCursorPosition: point,
            mouseButton: .left
        ) else { return }

        event.post(tap: .cghidEventTap)
    }

    // MARK: - Mouse Clicks

    /// Press mouse button down
    func mouseDown(button: MouseButton) {
        let currentPos = currentPosition
        let screenHeight = screenBounds.height
        let point = CGPoint(x: currentPos.x, y: screenHeight - currentPos.y)

        let eventType: CGEventType
        let cgButton: CGMouseButton

        switch button {
        case .left:
            eventType = .leftMouseDown
            cgButton = .left
        case .right:
            eventType = .rightMouseDown
            cgButton = .right
        }

        guard let event = CGEvent(
            mouseEventSource: nil,
            mouseType: eventType,
            mouseCursorPosition: point,
            mouseButton: cgButton
        ) else { return }

        event.post(tap: .cghidEventTap)
    }

    /// Release mouse button
    func mouseUp(button: MouseButton) {
        let currentPos = currentPosition
        let screenHeight = screenBounds.height
        let point = CGPoint(x: currentPos.x, y: screenHeight - currentPos.y)

        let eventType: CGEventType
        let cgButton: CGMouseButton

        switch button {
        case .left:
            eventType = .leftMouseUp
            cgButton = .left
        case .right:
            eventType = .rightMouseUp
            cgButton = .right
        }

        guard let event = CGEvent(
            mouseEventSource: nil,
            mouseType: eventType,
            mouseCursorPosition: point,
            mouseButton: cgButton
        ) else { return }

        event.post(tap: .cghidEventTap)
    }

    /// Perform a click (down + up)
    func click(button: MouseButton) {
        mouseDown(button: button)
        mouseUp(button: button)
    }

    // MARK: - Scrolling

    /// Scroll by the given amounts
    /// - Parameters:
    ///   - dx: Horizontal scroll (positive = right)
    ///   - dy: Vertical scroll (positive = up)
    func scroll(dx: CGFloat, dy: CGFloat) {
        // CGEvent scroll uses wheel1 for vertical (positive = up), wheel2 for horizontal
        let verticalDelta = Int32(dy)
        let horizontalDelta = Int32(dx)

        guard let event = CGEvent(
            scrollWheelEvent2Source: nil,
            units: .pixel,
            wheelCount: 2,
            wheel1: verticalDelta,
            wheel2: horizontalDelta,
            wheel3: 0
        ) else { return }

        event.post(tap: .cghidEventTap)
    }
}

// MARK: - Supporting Types

enum MouseButton {
    case left
    case right
}
