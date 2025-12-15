import Foundation
import CoreGraphics
import os

extension InputEngine {

    // MARK: - Sense Report Processing

    func processSenseReport(_ report: SenseController.InputReport) {
        assertOnEngineQueue()
        guard isRunning else { return }

        // Read settings ONCE at start of frame
        let s = settings.snapshot()

        guard s.isEnabled else { return }

        guard let device = senseDevices[report.controllerID] else { return }
        let profile = device.profile
        let owner = ManagedDeviceKey(kind: .sense, id: device.id)

        let mapping = profile.isLeft ? leftMapping : rightMapping
        let buttonProfile = s.senseButtonMappings[profile] ?? .load(for: profile)
        let cursorEnabled = s.cursorControlEnabledByProfile[profile] ?? true

        // 1. Process buttons (updates internal state, fires actions)
        processSenseButtonActions(
            owner: owner,
            device: device,
            bytes: report.bytes,
            mapping: mapping,
            profile: buttonProfile,
            triggerThreshold: buttonProfile.triggerThreshold,
            holdThreshold: buttonProfile.holdThreshold
        )

        // 2. Process joystick scroll if enabled
        if s.joystickScrollEnabled, cursorEnabled {
            processJoystickScroll(bytes: report.bytes, mapping: mapping, settings: s)
        }

        // 3. Process gyro through unified remap → process pipeline
        let pipeline = GyroRemapper.process(
            rawX: report.gyroX,
            rawY: report.gyroY,
            rawZ: report.gyroZ,
            controllerKind: .sense
        )
        var gyroSettings = s.gyroSettings[.sense] ?? .defaultForKind(.sense)
        let userScale = gyroSettings.gyroScale
        gyroSettings.gyroScale = effectiveGyroScale(for: .sense, userScale: userScale)
        gyroSettings.expectedSampleRate = 60.0
        gyroSettings.biasMotionThreshold = 50.0
        if let (dx, dy) = device.gyroProcessor.process(
            rawX: pipeline.remapped.pitch,
            rawY: pipeline.remapped.yaw,
            rawZ: pipeline.remapped.roll,
            timestamp: report.timestamp,
            settings: gyroSettings
        ) {
            routeGyroMovement(
                owner: owner,
                dx: dx,
                dy: dy,
                cursorEnabled: cursorEnabled,
                hasDragMapping: buttonProfile.hasDragMapping,
                configuration: s.radialMenuConfiguration,
                modeState: device.mode
            )
        }

        // 4. Update battery level (from byte 43)
        if report.bytes.count > SenseHIDProtocol.Offset.battery {
            let batteryByte = report.bytes[SenseHIDProtocol.Offset.battery]
            setBatteryLevel(BatteryHelper.level(from: batteryByte), for: owner)
        }

        // 5. Record to debug buffer with all pipeline stages
        if s.debugRecordingEnabled && (s.debugRecordingTargetKind == nil || s.debugRecordingTargetKind == .sense) {
            debugBuffer.record(
                bytes: report.bytes,
                length: report.length,
                rawGyro: pipeline.raw,
                remappedGyro: pipeline.remapped,
                normalizedGyro: pipeline.normalized,
                accel: (report.accelX, report.accelY, report.accelZ),
                buttonStates: device.buttonStates,
                controllerKind: .sense,
                gyroDebug: mapGyroDebug(from: device.gyroProcessor.lastDebugState)
            )
        }
    }

    // MARK: - Sense Button Processing

    private func processSenseButtonActions(
        owner: ManagedDeviceKey,
        device: SenseDeviceState,
        bytes: [UInt8],
        mapping: SenseButtonMapping,
        profile: SenseButtonMappingProfile,
        triggerThreshold: UInt8,
        holdThreshold: Double
    ) {
        // Process all digital buttons
        for button in LogicalButton.allCases where button != .trigger {
            let idx = button.index
            let isPressed = mapping.isPressed(button, in: bytes)
            let wasPressed = device.previousButtonStates[idx]

            if isPressed != wasPressed {
                let actions = profile.actions(for: button)
                if isPressed {
                    handleSenseButtonDown(owner: owner, device: device, button: button, actions: actions, holdThreshold: holdThreshold)
                } else {
                    handleSenseButtonUp(owner: owner, device: device, button: button, mappingProfile: profile)
                }
            }

            device.previousButtonStates[idx] = isPressed
            device.buttonStates[idx] = isPressed
        }

        // Handle trigger with threshold
        let triggerValue = mapping.triggerValue(in: bytes)
        let triggerPressed = triggerValue >= triggerThreshold

        if triggerPressed != device.previousTriggerPressed {
            let actions = profile.actions(for: .trigger)
            if triggerPressed {
                handleSenseButtonDown(owner: owner, device: device, button: .trigger, actions: actions, holdThreshold: holdThreshold)
            } else {
                handleSenseButtonUp(owner: owner, device: device, button: .trigger, mappingProfile: profile)
            }
        }

        device.previousTriggerPressed = triggerPressed
        device.buttonStates[LogicalButton.trigger.index] = triggerPressed
    }

    private func handleSenseButtonDown(
        owner: ManagedDeviceKey,
        device: SenseDeviceState,
        button: LogicalButton,
        actions: ButtonActions,
        holdThreshold: Double
    ) {
        let idx = button.index

        // Handle gyro mode actions immediately
        if actions.pressIsGyroMode {
            switch actions.press {
            case .drag:
                device.mode.dragButtonHeld = true
            case .scroll:
                device.mode.scrollButtonHeld = true
            case .radialMenu:
                beginRadialMenu(owner: owner, pointerStyle: .ghostCursor, modeState: &device.mode)
            default:
                break
            }
            return
        }

        // Handle mouse clicks immediately
        if case .mouseClick = actions.press {
            actionExecutor.execute(actions.press, isPressed: true)
            device.buttonPressStates[idx] = ButtonPressState(pressTime: Date(), actions: actions)
            return
        }

        // Record press state
        device.buttonPressStates[idx] = ButtonPressState(pressTime: Date(), actions: actions)

        // Schedule hold timer if there's a hold action
        if actions.hold != .none {
            let timer = DispatchWorkItem { [weak self] in
                guard let self else { return }
                guard self.isRunning else { return }
                guard let device = self.senseDevices[owner.id] else { return }
                guard var state = device.buttonPressStates[idx], !state.holdFired else { return }

                state.holdFired = true
                device.buttonPressStates[idx] = state
                self.actionExecutor.execute(actions.hold, isPressed: true)
            }
            device.holdTimers[idx]?.cancel()
            device.holdTimers[idx] = timer
            engineQueue.asyncAfter(deadline: .now() + holdThreshold, execute: timer)
        }
    }

    private func handleSenseButtonUp(
        owner: ManagedDeviceKey,
        device: SenseDeviceState,
        button: LogicalButton,
        mappingProfile: SenseButtonMappingProfile
    ) {
        let idx = button.index

        // Cancel hold timer
        device.holdTimers[idx]?.cancel()
        device.holdTimers[idx] = nil

        // Also check current mapping for gyro modes (gyro mode presses are not tracked).
        let actions = mappingProfile.actions(for: button)
        if actions.pressIsGyroMode {
            handleGyroModeRelease(owner: owner, action: actions.press, modeState: &device.mode)
            return
        }

        guard let state = device.buttonPressStates[idx] else { return }

        // Handle mouse click release
        if case .mouseClick = state.actions.press {
            actionExecutor.execute(state.actions.press, isPressed: false)
            device.buttonPressStates[idx] = nil
            return
        }

        if state.holdFired {
            // Hold action was executed, release it
            actionExecutor.execute(state.actions.hold, isPressed: false)
        } else {
            // Hold didn't fire, execute press action as tap
            if state.actions.press != .none {
                actionExecutor.execute(state.actions.press, isPressed: true)
                actionExecutor.execute(state.actions.press, isPressed: false)
            }
        }

        device.buttonPressStates[idx] = nil
    }
}

