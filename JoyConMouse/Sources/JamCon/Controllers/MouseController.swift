import Foundation
import CoreGraphics
import AppKit
import Carbon.HIToolbox

/// Controls the system mouse and keyboard using CGEvent APIs
class MouseController {

    // MARK: - Properties

    /// Callback when accessibility permission appears to be missing (after consecutive failures)
    var onAccessibilityError: (() -> Void)?

    /// Number of consecutive event creation failures before triggering error callback
    private let failureThreshold = 5
    private var consecutiveFailures = 0

    private var currentPosition: CGPoint {
        NSEvent.mouseLocation
    }

    private var screenBounds: CGRect {
        // Union of all screens to support multi-display setups (coordinates are bottom-left origin)
        let screens = NSScreen.screens
        guard var union = screens.first?.frame else {
            return CGRect(x: 0, y: 0, width: 1920, height: 1080)
        }
        for screen in screens.dropFirst() {
            union = union.union(screen.frame)
        }
        return union
    }

    private func clamp(_ point: CGPoint, to bounds: CGRect) -> CGPoint {
        let x = min(max(point.x, bounds.minX), bounds.maxX)
        let y = min(max(point.y, bounds.minY), bounds.maxY)
        return CGPoint(x: x, y: y)
    }

    /// Convert from Cocoa (bottom-left origin) to Quartz (top-left origin) within union bounds
    private func toQuartzSpace(point: CGPoint, in bounds: CGRect) -> CGPoint {
        let relativeY = point.y - bounds.minY
        let quartzY = bounds.maxY - relativeY
        return CGPoint(x: point.x, y: quartzY)
    }

    // MARK: - Error Handling

    /// Track event creation failure and notify if threshold exceeded
    private func handleEventCreationFailure() {
        consecutiveFailures += 1
        if consecutiveFailures >= failureThreshold {
            print("[MouseController] CGEvent creation failed \(consecutiveFailures) times - accessibility permission may be revoked")
            onAccessibilityError?()
        }
    }

    /// Reset failure counter on successful event creation
    private func handleEventSuccess() {
        consecutiveFailures = 0
    }

    // MARK: - Mouse Movement

    /// Move the mouse by a relative amount, clamped to screen bounds
    func moveRelative(dx: CGFloat, dy: CGFloat) {
        let current = currentPosition
        let bounds = screenBounds

        // Calculate new position in Cocoa coords (origin bottom-left)
        // dy from input is "screen down"; Cocoa Y increases upward, so subtract
        let proposed = CGPoint(x: current.x + dx, y: current.y - dy)
        let clamped = clamp(proposed, to: bounds)
        let quartzPoint = toQuartzSpace(point: clamped, in: bounds)

        // Create and post mouse move event
        guard let event = CGEvent(
            mouseEventSource: nil,
            mouseType: .mouseMoved,
            mouseCursorPosition: quartzPoint,
            mouseButton: .left
        ) else {
            handleEventCreationFailure()
            return
        }

        handleEventSuccess()
        event.post(tap: .cghidEventTap)
    }

    /// Move the mouse to an absolute position
    func moveTo(x: CGFloat, y: CGFloat) {
        let bounds = screenBounds
        let clamped = clamp(CGPoint(x: x, y: y), to: bounds)
        let point = toQuartzSpace(point: clamped, in: bounds)

        guard let event = CGEvent(
            mouseEventSource: nil,
            mouseType: .mouseMoved,
            mouseCursorPosition: point,
            mouseButton: .left
        ) else {
            handleEventCreationFailure()
            return
        }

        handleEventSuccess()
        event.post(tap: .cghidEventTap)
    }

    // MARK: - Mouse Clicks

    /// Press mouse button down
    func mouseDown(button: MouseButton) {
        let currentPos = currentPosition
        let bounds = screenBounds
        let point = toQuartzSpace(point: currentPos, in: bounds)

        let eventType: CGEventType
        let cgButton: CGMouseButton

        switch button {
        case .left:
            eventType = .leftMouseDown
            cgButton = .left
        case .right:
            eventType = .rightMouseDown
            cgButton = .right
        case .middle:
            eventType = .otherMouseDown
            cgButton = .center
        }

        guard let event = CGEvent(
            mouseEventSource: nil,
            mouseType: eventType,
            mouseCursorPosition: point,
            mouseButton: cgButton
        ) else {
            handleEventCreationFailure()
            return
        }

        handleEventSuccess()
        event.post(tap: .cghidEventTap)
    }

    /// Release mouse button
    func mouseUp(button: MouseButton) {
        let currentPos = currentPosition
        let bounds = screenBounds
        let point = toQuartzSpace(point: currentPos, in: bounds)

        let eventType: CGEventType
        let cgButton: CGMouseButton

        switch button {
        case .left:
            eventType = .leftMouseUp
            cgButton = .left
        case .right:
            eventType = .rightMouseUp
            cgButton = .right
        case .middle:
            eventType = .otherMouseUp
            cgButton = .center
        }

        guard let event = CGEvent(
            mouseEventSource: nil,
            mouseType: eventType,
            mouseCursorPosition: point,
            mouseButton: cgButton
        ) else {
            handleEventCreationFailure()
            return
        }

        handleEventSuccess()
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
        ) else {
            handleEventCreationFailure()
            return
        }

        handleEventSuccess()
        event.post(tap: .cghidEventTap)
    }

    // MARK: - Keyboard Events

    /// Press a key combination down
    func keyDown(_ keyCombo: KeyCombo) {
        // Set modifier flags
        var flags: CGEventFlags = []
        if keyCombo.modifiers.contains(.shift) {
            flags.insert(.maskShift)
        }
        if keyCombo.modifiers.contains(.control) {
            flags.insert(.maskControl)
        }
        if keyCombo.modifiers.contains(.option) {
            flags.insert(.maskAlternate)
        }
        if keyCombo.modifiers.contains(.command) {
            flags.insert(.maskCommand)
        }

        // Create and post key down event
        guard let event = CGEvent(keyboardEventSource: nil, virtualKey: keyCombo.keyCode, keyDown: true) else {
            handleEventCreationFailure()
            return
        }
        handleEventSuccess()
        event.flags = flags
        event.post(tap: .cghidEventTap)
    }

    /// Release a key combination
    func keyUp(_ keyCombo: KeyCombo) {
        // Set modifier flags (same as key down)
        var flags: CGEventFlags = []
        if keyCombo.modifiers.contains(.shift) {
            flags.insert(.maskShift)
        }
        if keyCombo.modifiers.contains(.control) {
            flags.insert(.maskControl)
        }
        if keyCombo.modifiers.contains(.option) {
            flags.insert(.maskAlternate)
        }
        if keyCombo.modifiers.contains(.command) {
            flags.insert(.maskCommand)
        }

        // Create and post key up event
        guard let event = CGEvent(keyboardEventSource: nil, virtualKey: keyCombo.keyCode, keyDown: false) else {
            handleEventCreationFailure()
            return
        }
        handleEventSuccess()
        event.flags = flags
        event.post(tap: .cghidEventTap)
    }

    /// Press and release a key combination
    func keyPress(_ keyCombo: KeyCombo) {
        keyDown(keyCombo)
        keyUp(keyCombo)
    }
}

// MARK: - Supporting Types

enum MouseButton: Codable, Hashable, Sendable {
    case left
    case right
    case middle
}
