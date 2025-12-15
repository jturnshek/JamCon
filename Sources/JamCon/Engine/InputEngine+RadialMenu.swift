import Foundation
import CoreGraphics
import os

extension InputEngine {

    // MARK: - Gyro Mode Routing

    func beginRadialMenu(owner: ManagedDeviceKey, pointerStyle: RadialMenuPointerStyle, modeState: inout GyroModeState) {
        if radialMenuOwner == nil {
            radialMenuOwner = owner
        }
        guard radialMenuOwner == owner else { return }

        modeState.radialMenuButtonHeld = true
        radialMenuLock.withLock { radialMenuAccumulator = .zero }
        radialMenuPendingDelta = .zero

        guard let position = currentCursorPositionQuartz() else { return }
        let config = settings.snapshot().radialMenuConfiguration

        if pointerStyle == .ghostCursor {
            mouseController.hideCursor()
        }
        onRadialMenuShow?(quartzToCocoa(position), config, pointerStyle)

        if pointerStyle == .systemCursor {
            startRadialMenuCursorTracking(anchor: position)
        } else {
            startRadialMenuUIUpdateTimer()
        }
    }

    private enum GyroMode {
        case none       // No cursor movement (drag mapped but not held)
        case normal     // Normal cursor movement
        case drag       // Drag button held
        case scroll     // Scroll button held
        case radialMenu // Radial menu active
    }

    private func currentGyroMode(owner: ManagedDeviceKey, hasDragMapping: Bool, modeState: GyroModeState) -> GyroMode {
        if modeState.radialMenuButtonHeld, radialMenuOwner == owner { return .radialMenu }
        if modeState.scrollButtonHeld { return .scroll }
        if modeState.dragButtonHeld { return .drag }
        if hasDragMapping { return .none }
        return .normal
    }

    func routeGyroMovement(
        owner: ManagedDeviceKey,
        dx: CGFloat,
        dy: CGFloat,
        cursorEnabled: Bool,
        hasDragMapping: Bool,
        configuration: RadialMenuConfiguration,
        modeState: GyroModeState
    ) {
        let mode = currentGyroMode(owner: owner, hasDragMapping: hasDragMapping, modeState: modeState)

        switch mode {
        case .none:
            break
        case .normal, .drag:
            if cursorEnabled {
                mouseController.moveRelative(dx: dx, dy: dy)
            }
        case .scroll:
            if cursorEnabled {
                mouseController.scroll(dx: dx, dy: dy)
            }
        case .radialMenu:
            guard radialMenuOwner == owner else { return }
            let scale = max(0.1, configuration.radialMovementScale)
            let scaledDx = dx * scale
            let scaledDy = dy * scale
            radialMenuLock.withLock {
                radialMenuAccumulator.x += scaledDx
                radialMenuAccumulator.y += scaledDy
            }
            radialMenuPendingDelta.x += dx
            radialMenuPendingDelta.y += dy
        }
    }

    func handleGyroModeRelease(owner: ManagedDeviceKey, action: ButtonAction, modeState: inout GyroModeState) {
        switch action {
        case .drag:
            modeState.dragButtonHeld = false
        case .scroll:
            modeState.scrollButtonHeld = false
        case .radialMenu:
            guard radialMenuOwner == owner else { return }
            stopRadialMenuUIUpdateTimer(flush: true)
            if owner.kind == .mouse {
                stopRadialMenuCursorTracking()
            }
            radialMenuOwner = nil
            modeState.radialMenuButtonHeld = false

            // Determine selected item based on accumulated movement
            let selectedItem = calculateRadialMenuSelection()
            onRadialMenuHide?(selectedItem)

            // Execute the selected action
            if let item = selectedItem {
                executeRadialMenuAction(item.action)
            }
            if owner.kind != .mouse {
                mouseController.showCursor()
            }
        default:
            break
        }
    }

    func cancelRadialMenuIfOwned(by owner: ManagedDeviceKey) {
        guard radialMenuOwner == owner else { return }

        stopRadialMenuUIUpdateTimer(flush: true)
        if owner.kind == .mouse {
            stopRadialMenuCursorTracking()
            mouseMode.radialMenuButtonHeld = false
        } else {
            mouseController.showCursor()
        }

        radialMenuOwner = nil
        onRadialMenuHide?(nil)
    }

    // MARK: - Radial Menu Cursor Tracking (Mouse)

    /// For real mice, the user expects to select using the system cursor.
    /// We poll cursor position relative to the menu anchor and update selection.
    private func startRadialMenuCursorTracking(anchor: CGPoint) {
        stopRadialMenuCursorTracking()
        radialMenuCursorAnchor = anchor

        let timer = DispatchSource.makeTimerSource(queue: engineQueue)
        timer.schedule(deadline: .now(), repeating: Self.radialMenuUIUpdateInterval)  // ~120Hz
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            guard self.radialMenuOwner?.kind == .mouse, self.mouseMode.radialMenuButtonHeld, let anchor = self.radialMenuCursorAnchor else { return }
            guard let current = self.currentCursorPositionQuartz() else { return }

            let dx = current.x - anchor.x
            let dy = current.y - anchor.y

            self.radialMenuLock.withLock {
                self.radialMenuAccumulator = CGPoint(x: dx, y: dy)
            }

            self.onRadialMenuSetPosition?(CGPoint(x: dx, y: dy))
        }
        timer.resume()
        radialMenuCursorPollTimer = timer
    }

    func stopRadialMenuCursorTracking() {
        radialMenuCursorPollTimer?.cancel()
        radialMenuCursorPollTimer = nil
        radialMenuCursorAnchor = nil
    }

    private func startRadialMenuUIUpdateTimer() {
        stopRadialMenuUIUpdateTimer()

        let timer = DispatchSource.makeTimerSource(queue: engineQueue)
        timer.schedule(deadline: .now(), repeating: Self.radialMenuUIUpdateInterval)
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            guard let owner = self.radialMenuOwner, owner.kind != .mouse else { return }

            let delta = self.radialMenuPendingDelta
            guard delta != .zero else { return }
            self.radialMenuPendingDelta = .zero
            self.onRadialMenuUpdate?(delta)
        }
        timer.resume()
        radialMenuUIUpdateTimer = timer
    }

    func stopRadialMenuUIUpdateTimer(flush: Bool = false) {
        if flush {
            let delta = radialMenuPendingDelta
            radialMenuPendingDelta = .zero
            if delta != .zero {
                onRadialMenuUpdate?(delta)
            }
        } else {
            radialMenuPendingDelta = .zero
        }

        radialMenuUIUpdateTimer?.cancel()
        radialMenuUIUpdateTimer = nil
    }

    private func currentCursorPositionQuartz() -> CGPoint? {
        CGEvent(source: nil)?.location
    }

    private func quartzToCocoa(_ quartz: CGPoint) -> CGPoint {
        let mainHeight = CGDisplayBounds(CGMainDisplayID()).height
        return CGPoint(x: quartz.x, y: mainHeight - quartz.y)
    }

    // MARK: - Radial Menu

    private func calculateRadialMenuSelection() -> RadialMenuItem? {
        let config = settings.snapshot().radialMenuConfiguration
        let accumulator = radialMenuLock.withLock { radialMenuAccumulator }
        let magnitude = sqrt(accumulator.x * accumulator.x + accumulator.y * accumulator.y)

        guard magnitude > config.deadzoneSize else { return nil }

        let angle = atan2(accumulator.y, accumulator.x)

        // Determine ring and item
        let outerRingEnabled = config.outerRingEnabled && !config.outerRingItems.isEmpty
        let outerRingStart = config.deadzoneSize + config.innerRingSize

        if outerRingEnabled && magnitude >= outerRingStart {
            // Outer ring
            let index = angleToIndex(angle, count: config.outerRingItems.count, rotation: config.outerRingRotation)
            return config.outerRingItems[safe: index]
        } else {
            // Inner ring
            let index = angleToIndex(angle, count: config.items.count, rotation: config.innerRingRotation)
            return config.items[safe: index]
        }
    }

    private func angleToIndex(_ angle: Double, count: Int, rotation: Double) -> Int {
        guard count > 0 else { return 0 }

        let rotationRadians = -rotation * Double.pi / 180.0
        var normalizedAngle = angle + Double.pi / 2 - rotationRadians

        let twoPi = Double.pi * 2.0
        normalizedAngle = fmod(normalizedAngle, twoPi)
        if normalizedAngle < 0 { normalizedAngle += twoPi }

        let sliceAngle = twoPi / Double(count)
        return min(Int(normalizedAngle / sliceAngle), count - 1)
    }

    private func executeRadialMenuAction(_ action: RadialMenuAction) {
        switch action {
        case .none:
            break
        case .keyPress(let combo):
            var flags = combo.eventFlags
            let arrowKeys: [UInt16] = [123, 124, 125, 126]
            if arrowKeys.contains(combo.keyCode) {
                flags.insert(.maskNumericPad)
            }
            if flags.contains(.maskControl) && arrowKeys.contains(combo.keyCode) {
                flags.insert(.maskSecondaryFn)
            }

            if let event = CGEvent(keyboardEventSource: nil, virtualKey: CGKeyCode(combo.keyCode), keyDown: true) {
                event.flags = flags
                event.post(tap: .cghidEventTap)
            }
            if let event = CGEvent(keyboardEventSource: nil, virtualKey: CGKeyCode(combo.keyCode), keyDown: false) {
                event.flags = flags
                event.post(tap: .cghidEventTap)
            }
        case .mouseClick(let button):
            mouseController.click(button: button)
        case .systemAction(let action):
            actionExecutor.executeSystemAction(action)
        }
    }
}

// MARK: - Array Safe Subscript

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
