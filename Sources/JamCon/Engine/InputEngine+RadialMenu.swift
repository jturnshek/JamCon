import Foundation
import CoreGraphics
import os

extension InputEngine {

    // MARK: - Gyro Mode Routing

    @discardableResult
    func beginRadialMenu(
        owner: ManagedDeviceKey,
        activationOwner: SyntheticOutputOwner,
        pointerStyle: RadialMenuPointerStyle,
        modeState: inout GyroModeState
    ) -> Bool {
        assertOnEngineQueue()
        precondition(activationOwner.device == owner)

        // A second radial-mapped button must not reset or take ownership of a
        // gesture that is already in progress. Only the initiating control may
        // dismiss it on release.
        guard pendingRadialMenuAction == nil else { return false }
        if let active = radialMenuActivationOwner {
            return active == activationOwner
        }

        guard let position = currentCursorPositionQuartz() else {
            JamLog.errorThrottled(
                .engine,
                key: "radial-menu.cursor-position",
                interval: 2,
                "Could not open radial menu because the cursor position was unavailable"
            )
            return false
        }
        let config = settings.snapshot().radialMenuConfiguration

        radialMenuOwner = owner
        radialMenuActivationOwner = activationOwner
        radialMenuActiveConfiguration = config
        modeState.radialMenuButtonHeld = true
        radialMenuLock.withLock { radialMenuAccumulator = .zero }
        radialMenuHapticTracker.begin()
        radialMenuPendingDelta = .zero

        if pointerStyle == .ghostCursor {
            mouseController.hideCursor()
        }
        publishRadialMenuPresentation(
            .show(
                position: position,
                configuration: config,
                pointerStyle: pointerStyle
            )
        )

        if pointerStyle == .systemCursor {
            startRadialMenuCursorTracking(anchor: position)
        } else {
            startRadialMenuUIUpdateTimer()
        }
        return true
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
            guard radialMenuOwner == owner,
                  let configuration = radialMenuActiveConfiguration else { return }
            let scale = max(0.1, configuration.radialMovementScale)
            let scaledDx = dx * scale
            let scaledDy = dy * scale
            let selection = radialMenuLock.withLock {
                radialMenuAccumulator.x += scaledDx
                radialMenuAccumulator.y += scaledDy
                let result = RadialMenuGeometry.resolve(
                    offset: radialMenuAccumulator,
                    configuration: configuration
                )
                radialMenuAccumulator = result.clampedOffset
                return result.selection
            }
            if radialMenuHapticTracker.update(selection) {
                _ = backendRegistry.playHaptic(
                    id: owner.id,
                    kind: owner.kind,
                    effect: .selection
                )
            }
            radialMenuPendingDelta.x += dx
            radialMenuPendingDelta.y += dy
        }
    }

    func handleGyroModeRelease(
        owner: ManagedDeviceKey,
        activationOwner: SyntheticOutputOwner?,
        action: ButtonAction,
        modeState: inout GyroModeState
    ) {
        switch action {
        case .drag:
            modeState.dragButtonHeld = false
        case .scroll:
            modeState.scrollButtonHeld = false
        case .radialMenu:
            guard radialMenuOwner == owner,
                  radialMenuActivationOwner == activationOwner else { return }

            // Resolve against the exact configuration captured when the menu
            // opened, then tear down the presentation before posting an action
            // that may start a Space transition.
            let selectedItem = calculateRadialMenuSelection()
            modeState.radialMenuButtonHeld = false
            if let item = selectedItem {
                let pending = PendingRadialMenuAction(id: UUID(), owner: owner)
                pendingRadialMenuAction = pending
                dismissActiveRadialMenu(
                    resetHeldState: false,
                    afterPresentationApplied: { [weak self] in
                        guard let self,
                              self.pendingRadialMenuAction == pending else { return }
                        self.pendingRadialMenuAction = nil
                        guard self.isRunning,
                              self.settings.snapshot().isEnabled else { return }
                        self.executeRadialMenuAction(item.action, device: owner)
                    }
                )
            } else {
                dismissActiveRadialMenu(resetHeldState: false)
            }
        default:
            break
        }
    }

    func cancelRadialMenuIfOwned(by owner: ManagedDeviceKey) {
        if radialMenuOwner == owner {
            dismissActiveRadialMenu()
        }
        if pendingRadialMenuAction?.owner == owner {
            pendingRadialMenuAction = nil
        }
    }

    /// Cancels the current presentation without executing its selected action.
    /// Used by disconnect, disable, linked-mode transitions, and engine stop.
    func dismissActiveRadialMenu(
        resetHeldState: Bool = true,
        afterPresentationApplied: (@Sendable () -> Void)? = nil
    ) {
        guard let owner = radialMenuOwner else {
            stopRadialMenuUIUpdateTimer()
            stopRadialMenuCursorTracking()
            radialMenuActivationOwner = nil
            radialMenuActiveConfiguration = nil
            radialMenuHapticTracker.end()
            afterPresentationApplied?()
            return
        }

        stopRadialMenuUIUpdateTimer()
        stopRadialMenuCursorTracking()
        if resetHeldState {
            setRadialMenuHeld(false, for: owner)
        }
        if owner.kind != .mouse {
            mouseController.showCursor()
        }
        radialMenuOwner = nil
        radialMenuActivationOwner = nil
        radialMenuActiveConfiguration = nil
        radialMenuHapticTracker.end()
        radialMenuLock.withLock { radialMenuAccumulator = .zero }
        publishRadialMenuPresentation(
            .hide,
            afterApplied: afterPresentationApplied
        )
    }

    private func setRadialMenuHeld(_ held: Bool, for owner: ManagedDeviceKey) {
        switch owner.kind {
        case .sense:
            senseDevices[owner.id]?.mode.radialMenuButtonHeld = held
        case .joyCon:
            joyConDevices[owner.id]?.mode.radialMenuButtonHeld = held
        case .mouse:
            mouseMode.radialMenuButtonHeld = held
        }
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

            self.publishRadialMenuPresentation(
                .setPosition(offset: CGPoint(x: dx, y: dy))
            )
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
            self.publishRadialMenuPresentation(.update(delta: delta))
        }
        timer.resume()
        radialMenuUIUpdateTimer = timer
    }

    func stopRadialMenuUIUpdateTimer() {
        radialMenuPendingDelta = .zero
        radialMenuUIUpdateTimer?.cancel()
        radialMenuUIUpdateTimer = nil
    }

    private func currentCursorPositionQuartz() -> CGPoint? {
        radialMenuCursorPositionProvider()
    }

    /// Presentation acknowledgements provide a non-blocking ordering barrier:
    /// an action selected from the menu is posted only after AppKit has hidden
    /// the overlay. The continuation always returns to engineQueue.
    private func publishRadialMenuPresentation(
        _ event: RadialMenuPresentationEvent,
        afterApplied: (@Sendable () -> Void)? = nil
    ) {
        guard let onRadialMenuPresentation else {
            afterApplied?()
            return
        }
        guard let afterApplied else {
            onRadialMenuPresentation(event, nil)
            return
        }
        onRadialMenuPresentation(event, { [weak self] in
            self?.engineQueueAsync(afterApplied)
        })
    }

    // MARK: - Radial Menu

    private func calculateRadialMenuSelection() -> RadialMenuItem? {
        guard let config = radialMenuActiveConfiguration else { return nil }
        let accumulator = radialMenuLock.withLock { radialMenuAccumulator }
        switch RadialMenuGeometry.resolve(offset: accumulator, configuration: config).selection {
        case .inner(let index):
            return config.items[safe: index]
        case .outer(let index):
            return config.outerRingItems[safe: index]
        case nil:
            return nil
        }
    }

    private func executeRadialMenuAction(_ action: RadialMenuAction, device: ManagedDeviceKey) {
        let owner = SyntheticOutputOwner(
            device: device,
            control: "radialMenu.selection",
            role: .radialMenu
        )

        switch action {
        case .none:
            break
        case .keyPress(let combo):
            actionExecutor.tap(.keyPress(combo), owner: owner)
        case .mouseClick(let button):
            actionExecutor.tap(.mouseClick(button), owner: owner)
        case .systemAction(let action):
            actionExecutor.executeSystemAction(action, owner: owner)
        }
    }
}

// MARK: - Array Safe Subscript

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
