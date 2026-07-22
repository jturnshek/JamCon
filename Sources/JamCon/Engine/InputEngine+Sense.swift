import Foundation
import CoreGraphics
import QuartzCore
import os

enum SenseTriggerHysteresis {
    static let defaultReleaseMargin: UInt8 = 8

    static func isPressed(
        value: UInt8,
        pressThreshold: UInt8,
        wasPressed: Bool,
        releaseMargin: UInt8 = defaultReleaseMargin
    ) -> Bool {
        guard wasPressed else { return value >= pressThreshold }
        let releaseThreshold = pressThreshold > releaseMargin
            ? pressThreshold - releaseMargin
            : 0
        return value > releaseThreshold
    }
}

extension InputEngine {

    // MARK: - Sense Report Processing

    func processSenseReport(_ report: InputDeviceFrame) {
        assertOnEngineQueue()
        guard isRunning else { return }
        guard let motion = report.motion.latest else {
            JamLog.errorThrottled(
                .sense,
                key: "input.missing-motion.\(report.deviceID)",
                interval: 2,
                "Dropping Sense input frame without motion data"
            )
            return
        }
        let engineStartTimestamp = CACurrentMediaTime()
        let healthDevice = ManagedDeviceKey(kind: .sense, id: report.deviceID)
        let signpostID = Self.inputPerformanceLog.signpostsEnabled
            ? OSSignpostID(log: Self.inputPerformanceLog)
            : nil
        if let signpostID {
            os_signpost(.begin, log: Self.inputPerformanceLog, name: "Sense Input", signpostID: signpostID)
        }
        defer {
            let engineEndTimestamp = CACurrentMediaTime()
            recordInputHealth(
                device: healthDevice,
                inputTimestamp: report.inputTimestamp,
                timestampSource: report.timestampSource,
                receivedTimestamp: report.receivedTimestamp,
                engineStartTimestamp: engineStartTimestamp,
                engineEndTimestamp: engineEndTimestamp
            )
            if let signpostID {
                os_signpost(.end, log: Self.inputPerformanceLog, name: "Sense Input", signpostID: signpostID)
            }
        }

        // Read settings ONCE at start of frame
        let s = settings.snapshot()

        guard s.isEnabled else { return }

        guard let device = senseDevices[report.deviceID] else { return }
        let profile = device.profile
        let owner = ManagedDeviceKey(kind: .sense, id: device.id)

        let mapping = profile.isLeft ? leftMapping : rightMapping
        let buttonProfile = s.senseButtonMappings[profile] ?? .load(for: profile)
        let cursorEnabled = s.cursorControlEnabledByProfile[profile] ?? true

        // 1. Process buttons (updates internal state, fires actions)
        if device.hasPrimedButtonState {
            processSenseButtonActions(
                owner: owner,
                device: device,
                bytes: report.bytes,
                mapping: mapping,
                profile: buttonProfile,
                triggerThreshold: buttonProfile.triggerThreshold,
                holdThreshold: buttonProfile.holdThreshold
            )
        } else {
            primeSenseButtonStates(
                device: device,
                bytes: report.bytes,
                mapping: mapping,
                triggerThreshold: buttonProfile.triggerThreshold
            )
            device.hasPrimedButtonState = true
        }

        // 2. Process joystick scroll if enabled
        if s.joystickScrollEnabled, cursorEnabled {
            processJoystickScroll(
                bytes: report.bytes,
                mapping: mapping,
                timestamp: report.timestamp,
                timing: &device.joystickScrollTiming,
                settings: s
            )
        } else {
            device.joystickScrollTiming.reset()
        }

        // 3. Process gyro through unified remap → process pipeline
        let remappedGyro = GyroRemapper.remap(
            rawX: motion.gyroX,
            rawY: motion.gyroY,
            rawZ: motion.gyroZ,
            controllerKind: .sense
        )
        var gyroSettings = s.gyroSettings[.sense] ?? .defaultForKind(.sense)
        let userScale = gyroSettings.gyroScale
        gyroSettings.gyroScale = effectiveGyroScale(for: .sense, userScale: userScale)
        gyroSettings.expectedSampleRate = 60.0
        gyroSettings.biasMotionThreshold = 50.0
        if let (dx, dy) = device.gyroProcessor.process(
            rawX: remappedGyro.pitch,
            rawY: remappedGyro.yaw,
            rawZ: remappedGyro.roll,
            timestamp: report.timestamp,
            settings: gyroSettings
        ) {
            recordGyroResponseHealth(
                device: owner,
                timestamp: report.timestamp,
                sample: device.gyroProcessor.lastResponseSample
            )
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
            let engineEndTimestamp = CACurrentMediaTime()
            let normalizedGyro = GyroRemapper.normalize(
                pitch: remappedGyro.pitch,
                yaw: remappedGyro.yaw,
                roll: remappedGyro.roll,
                controllerKind: .sense
            )
            debugBuffer.recordTrace(
                device: owner,
                reportID: report.reportID,
                bytes: report.bytes,
                timestamp: report.receivedTimestamp
            )
            debugBuffer.record(
                bytes: report.bytes,
                length: report.length,
                rawGyro: (x: motion.gyroX, y: motion.gyroY, z: motion.gyroZ),
                remappedGyro: remappedGyro,
                normalizedGyro: normalizedGyro,
                accel: (motion.accelX, motion.accelY, motion.accelZ),
                buttonStates: device.buttonStates,
                controllerKind: .sense,
                gyroDebug: mapGyroDebug(from: device.gyroProcessor.lastDebugState),
                pipelineTiming: DebugBuffer.PipelineTiming(
                    inputTimestamp: report.inputTimestamp,
                    timestampSource: report.timestampSource,
                    receivedTimestamp: report.receivedTimestamp,
                    engineStartTimestamp: engineStartTimestamp,
                    engineEndTimestamp: engineEndTimestamp
                )
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
        let triggerPressed = SenseTriggerHysteresis.isPressed(
            value: triggerValue,
            pressThreshold: triggerThreshold,
            wasPressed: device.previousTriggerPressed
        )

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

    private func primeSenseButtonStates(
        device: SenseDeviceState,
        bytes: [UInt8],
        mapping: SenseButtonMapping,
        triggerThreshold: UInt8
    ) {
        for button in LogicalButton.allCases where button != .trigger {
            let idx = button.index
            let isPressed = mapping.isPressed(button, in: bytes)
            device.previousButtonStates[idx] = isPressed
            device.buttonStates[idx] = isPressed
            device.buttonPressStates[idx] = nil
            device.holdTimers[idx]?.cancel()
            device.holdTimers[idx] = nil
        }

        let triggerValue = mapping.triggerValue(in: bytes)
        let triggerPressed = SenseTriggerHysteresis.isPressed(
            value: triggerValue,
            pressThreshold: triggerThreshold,
            wasPressed: false
        )
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
            device.buttonPressStates[idx] = ButtonPressState(actions: actions, device: owner, control: button.rawValue)
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

        let state = ButtonPressState(actions: actions, device: owner, control: button.rawValue)
        device.buttonPressStates[idx] = state

        // Mouse buttons go down immediately so they can participate in dragging.
        if case .mouseClick = actions.press {
            actionExecutor.execute(actions.press, isPressed: true, owner: state.pressOwner)
        }

        // Schedule hold timer if there's a hold action
        if actions.hold != .none {
            let timer = DispatchWorkItem { [weak self] in
                guard let self else { return }
                guard self.isRunning else { return }
                guard let device = self.senseDevices[owner.id] else { return }
                guard var state = device.buttonPressStates[idx], !state.holdFired else { return }

                state.holdFired = true
                device.buttonPressStates[idx] = state
                self.actionExecutor.execute(state.actions.hold, isPressed: true, owner: state.holdOwner)
            }
            device.holdTimers[idx]?.cancel()
            device.holdTimers[idx] = timer
            holdScheduler.schedule(timer, after: holdThreshold, on: engineQueue)
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

        // Release the action that was active when the physical button went down,
        // even if the user edited its mapping while holding it.
        if let state = device.buttonPressStates[idx], state.actions.pressIsGyroMode {
            handleGyroModeRelease(owner: owner, action: state.actions.press, modeState: &device.mode)
            device.buttonPressStates[idx] = nil
            return
        }

        // A primed press has no stored state; retain the mapping fallback for it.
        let actions = mappingProfile.actions(for: button)
        if actions.pressIsGyroMode {
            handleGyroModeRelease(owner: owner, action: actions.press, modeState: &device.mode)
            return
        }

        guard let state = device.buttonPressStates[idx] else { return }

        // Handle mouse click release
        if case .mouseClick = state.actions.press {
            actionExecutor.execute(state.actions.press, isPressed: false, owner: state.pressOwner)
            if state.holdFired {
                actionExecutor.execute(state.actions.hold, isPressed: false, owner: state.holdOwner)
            }
            device.buttonPressStates[idx] = nil
            return
        }

        if state.holdFired {
            // Hold action was executed, release it
            actionExecutor.execute(state.actions.hold, isPressed: false, owner: state.holdOwner)
        } else {
            // Hold didn't fire, execute press action as tap
            if state.actions.press != .none {
                actionExecutor.tap(state.actions.press, owner: state.pressOwner)
            }
        }

        device.buttonPressStates[idx] = nil
    }
}
