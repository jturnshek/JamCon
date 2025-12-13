import Foundation
import CoreGraphics
import AppKit

/// Mouse controller using CGEvent with proper drag support
class MouseController {

    // MARK: - Properties

    /// Shared event source for mouse events - uses private state to avoid inheriting system modifier flags
    private static let eventSource: CGEventSource? = CGEventSource(stateID: .privateState)

    /// Track which mouse button is currently held (for drag events)
    private var heldMouseButton: MouseButton? = nil

    /// Track click timing for double/triple click detection
    private var lastClickTime: Date = .distantPast
    private var lastClickPosition: CGPoint = .zero
    private var clickCount: Int64 = 0

    private var cachedBounds: CGRect
    private let notificationCenter: NotificationCenter
    private var cachedPosition: CGPoint
    private var resyncTimer: Timer?
    private var notificationTokens: [NSObjectProtocol] = []

    // MARK: - Initialization

    init(notificationCenter: NotificationCenter = .default) {
        self.notificationCenter = notificationCenter
        self.cachedBounds = MouseController.computeScreenBounds()
        self.cachedPosition = NSEvent.mouseLocation
        observeScreenChanges()
        startPeriodicResync()
    }

    deinit {
        resyncTimer?.invalidate()
        for token in notificationTokens {
            notificationCenter.removeObserver(token)
        }
    }

    /// Move the mouse by a relative amount, clamped to screen bounds
    func moveRelative(dx: CGFloat, dy: CGFloat) {
        // Update cached position in Cocoa coords (origin bottom-left)
        cachedPosition.x += dx
        cachedPosition.y -= dy  // input dy is screen-down; Cocoa Y increases upward
        cachedPosition = clamp(cachedPosition, to: cachedBounds)
        let quartzPoint = toQuartzSpace(point: cachedPosition, in: cachedBounds)

        // Determine event type based on whether a mouse button is held
        let mouseType: CGEventType
        let mouseButton: CGMouseButton

        if let held = heldMouseButton {
            // Button is held - send drag event for proper drag-and-drop support
            switch held {
            case .left:
                mouseType = .leftMouseDragged
                mouseButton = .left
            case .right:
                mouseType = .rightMouseDragged
                mouseButton = .right
            case .middle:
                mouseType = .otherMouseDragged
                mouseButton = .center
            }
        } else {
            // No button held - send regular move event
            mouseType = .mouseMoved
            mouseButton = .left
        }

        guard let event = CGEvent(
            mouseEventSource: Self.eventSource,
            mouseType: mouseType,
            mouseCursorPosition: quartzPoint,
            mouseButton: mouseButton
        ) else {
            return
        }

        event.post(tap: .cghidEventTap)
    }

    // MARK: - Scroll

    /// Scroll the content under the cursor
    /// - Parameters:
    ///   - dx: Horizontal scroll amount (positive = right)
    ///   - dy: Vertical scroll amount (positive = down)
    func scroll(dx: CGFloat, dy: CGFloat) {
        // Scale factor to make scroll feel natural
        // Gyro values are in screen pixels, scroll needs smaller values
        let scrollScale: CGFloat = 0.5

        let scrollX = Int32(dx * scrollScale)
        let scrollY = Int32(-dy * scrollScale)  // Negate: positive dy = tilt down = scroll content up

        guard let event = CGEvent(
            scrollWheelEvent2Source: Self.eventSource,
            units: .pixel,
            wheelCount: 2,
            wheel1: scrollY,  // Vertical scroll
            wheel2: scrollX,  // Horizontal scroll
            wheel3: 0
        ) else {
            return
        }

        event.post(tap: .cghidEventTap)
    }

    // MARK: - Mouse Clicks

    /// Press mouse button down
    func mouseDown(button: MouseButton) {
        let currentPos = currentPosition()
        let bounds = cachedBounds
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
            mouseEventSource: Self.eventSource,
            mouseType: eventType,
            mouseCursorPosition: point,
            mouseButton: cgButton
        ) else {
            return
        }

        // Clear any inherited modifier flags - controller mouse clicks should be "clean"
        event.flags = []

        // Detect double/triple click based on timing and position
        let now = Date()
        let timeSinceLastClick = now.timeIntervalSince(lastClickTime)
        let doubleClickInterval = NSEvent.doubleClickInterval
        let maxClickDistance: CGFloat = 4.0  // pixels

        let distance = hypot(currentPos.x - lastClickPosition.x, currentPos.y - lastClickPosition.y)

        if timeSinceLastClick <= doubleClickInterval && distance <= maxClickDistance {
            // Rapid click near same position - increment click count (max 3 for triple-click)
            clickCount = min(clickCount + 1, 3)
        } else {
            // New click sequence
            clickCount = 1
        }

        lastClickTime = now
        lastClickPosition = currentPos

        // Set click state for proper recognition in all applications
        event.setIntegerValueField(.mouseEventClickState, value: clickCount)

        // Track this button as held (for drag events)
        heldMouseButton = button

        event.post(tap: .cghidEventTap)
    }

    /// Release mouse button
    func mouseUp(button: MouseButton) {
        let currentPos = currentPosition()
        let bounds = cachedBounds
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
            mouseEventSource: Self.eventSource,
            mouseType: eventType,
            mouseCursorPosition: point,
            mouseButton: cgButton
        ) else {
            return
        }

        // Clear any inherited modifier flags
        event.flags = []

        // Set click state to match the mouseDown (for double/triple click recognition)
        event.setIntegerValueField(.mouseEventClickState, value: clickCount)

        // Clear held button state (drag ended)
        heldMouseButton = nil

        event.post(tap: .cghidEventTap)
    }

    /// Perform a click (down + up)
    func click(button: MouseButton) {
        mouseDown(button: button)
        mouseUp(button: button)
    }

    // MARK: - Helpers

    private func currentPosition() -> CGPoint {
        // Use NSEvent to stay in the same (Cocoa) coordinate space as cached bounds
        return NSEvent.mouseLocation
    }

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

    private func observeScreenChanges() {
        let token = notificationCenter.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: nil
        ) { [weak self] _ in
            guard let self else { return }
            self.cachedBounds = MouseController.computeScreenBounds()
            self.cachedPosition = NSEvent.mouseLocation
        }
        notificationTokens.append(token)
    }

    private static func computeScreenBounds() -> CGRect {
        let screens = NSScreen.screens
        guard var union = screens.first?.frame else {
            return CGRect(x: 0, y: 0, width: 1920, height: 1080)
        }
        for screen in screens.dropFirst() {
            union = union.union(screen.frame)
        }
        return union
    }

    private func startPeriodicResync() {
        // Resync on activation/launch to catch external warps
        let didBecomeActiveToken = notificationCenter.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: nil
        ) { [weak self] _ in
            self?.resyncPosition()
        }
        notificationTokens.append(didBecomeActiveToken)

        let didFinishLaunchingToken = notificationCenter.addObserver(
            forName: NSApplication.didFinishLaunchingNotification,
            object: nil,
            queue: nil
        ) { [weak self] _ in
            self?.resyncPosition()
        }
        notificationTokens.append(didFinishLaunchingToken)
        // Periodic safety resync to align with external cursor moves
        resyncTimer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { [weak self] _ in
            self?.resyncPosition()
        }
    }

    private func resyncPosition() {
        cachedPosition = NSEvent.mouseLocation
        cachedBounds = MouseController.computeScreenBounds()
    }

    // MARK: - Cursor Visibility

    /// Track cursor hide/show balance
    private var cursorHideCount: Int = 0

    private static func activeDisplayIDs() -> [CGDirectDisplayID] {
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(0, nil, &count) == .success, count > 0 else {
            return [CGMainDisplayID()]
        }

        var displays = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetActiveDisplayList(count, &displays, &count) == .success, count > 0 else {
            return [CGMainDisplayID()]
        }

        return Array(displays.prefix(Int(count)))
    }

    /// Hide the system cursor
    func hideCursor() {
        // Cursor visibility is effectively UI state; apply on main to avoid timing races with
        // SwiftUI/AppKit window operations (e.g. radial menu overlay).
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            if self.cursorHideCount == 0 {
                for displayID in Self.activeDisplayIDs() {
                    CGDisplayHideCursor(displayID)
                }
            }
            self.cursorHideCount += 1
        }
    }

    /// Show the system cursor (must match previous hide calls)
    func showCursor() {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.cursorHideCount = max(self.cursorHideCount - 1, 0)
            if self.cursorHideCount == 0 {
                for displayID in Self.activeDisplayIDs() {
                    CGDisplayShowCursor(displayID)
                }
            }
        }
    }

    /// Force show cursor regardless of hide count (for cleanup)
    func forceShowCursor() {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            while self.cursorHideCount > 0 {
                for displayID in Self.activeDisplayIDs() {
                    CGDisplayShowCursor(displayID)
                }
                self.cursorHideCount -= 1
            }
        }
    }
}
