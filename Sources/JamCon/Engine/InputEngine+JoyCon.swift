import Foundation
import CoreGraphics
import os

extension InputEngine {

    // MARK: - Joy-Con Report Processing

    func processJoyConReport(_ report: JoyConHIDController.InputReport) {
        assertOnEngineQueue()
        guard isRunning else { return }

        // Read settings ONCE at start of frame
        let s = settings.snapshot()

        guard s.isEnabled else { return }

        guard let device = joyConDevices[report.controllerID] else { return }
        let profile = device.profile
        let owner = ManagedDeviceKey(kind: .joyCon, id: device.id)

        // Keep Joy-Con timing mode in sync with settings
        joyConController.useTimerFallback = s.joyConTimerFallbackEnabled
        joyConController.useTimerHybrid = s.joyConTimerHybridEnabled

        let isLeft = profile.isLeft
        let buttonProfile: JoyConButtonMappingProfile = s.joyConButtonMappings[profile] ?? .defaultProfile(for: profile)
        let cursorEnabled = s.cursorControlEnabledByProfile[profile] ?? true

        // Continuous auto-calibration: updates center when stick is stationary
        let raw = device.mapping.joystickPositionRaw(in: report.bytes)
        device.mapping.calibration.updateAutoCalibration(rawX: raw.x, rawY: raw.y, timestamp: report.timestamp)

        // 1. Process Joy-Con buttons
        processJoyConButtonActions(
            owner: owner,
            device: device,
            bytes: report.bytes,
            mapping: device.mapping,
            profile: buttonProfile,
            holdThreshold: buttonProfile.holdThreshold
	        )

	        // 2. Process gyro through unified pipeline
	        // GyroRemapper handles the axis swapping for Joy-Con (different for left vs right)
	        let rawGyro: (x: Int16, y: Int16, z: Int16)
	        if s.joyConUseAveragedGyroSamples,
	           report.bytes.count >= JoyConHIDProtocol.Offset.imuSample2 + 12 {
	            func readInt16LE(_ offset: Int) -> Int16 {
	                Int16(bitPattern: UInt16(report.bytes[offset]) | (UInt16(report.bytes[offset + 1]) << 8))
	            }

	            let bases = [
	                JoyConHIDProtocol.Offset.imuSample0,
	                JoyConHIDProtocol.Offset.imuSample1,
	                JoyConHIDProtocol.Offset.imuSample2
	            ]

	            var sumX: Int32 = 0
	            var sumY: Int32 = 0
	            var sumZ: Int32 = 0
	            for base in bases {
	                sumX += Int32(readInt16LE(base + 6))
	                sumY += Int32(readInt16LE(base + 8))
	                sumZ += Int32(readInt16LE(base + 10))
	            }
	            rawGyro = (x: Int16(sumX / 3), y: Int16(sumY / 3), z: Int16(sumZ / 3))
	        } else {
	            rawGyro = (x: report.gyroX, y: report.gyroY, z: report.gyroZ)
	        }

	        let pipeline = GyroRemapper.process(
	            rawX: rawGyro.x,
	            rawY: rawGyro.y,
	            rawZ: rawGyro.z,
	            controllerKind: .joyCon,
	            isLeft: isLeft
	        )

        // Pass remapped values to gyro processor (which expects pitch in X, yaw in Y)
	        var gyroSettings = s.gyroSettings[.joyCon] ?? .defaultForKind(.joyCon)
	        let userScale = gyroSettings.gyroScale
	        gyroSettings.gyroScale = effectiveGyroScale(for: .joyCon, userScale: userScale)
	        gyroSettings.expectedSampleRate = 66.0  // Joy-Con packets are ~66 Hz (3 IMU samples per packet)
	        gyroSettings.biasMotionThreshold = 30.0 // Joy-Con has lower noise floor; tighten bias capture
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

        // 3. Process joystick scroll (if enabled)
        if s.joystickScrollEnabled, cursorEnabled {
            processJoyConJoystickScroll(bytes: report.bytes, mapping: device.mapping, settings: s)
        }

        // 4. Update battery level (Joy-Con battery is in byte 2, upper nibble)
        if report.bytes.count > 2 {
            setBatteryLevel(BatteryHelper.joyConLevel(from: report.bytes[2]), for: owner)
        }

        // 4. Record to debug buffer with all pipeline stages
        if s.debugRecordingEnabled && (s.debugRecordingTargetKind == nil || s.debugRecordingTargetKind == .joyCon) {
            debugBuffer.record(
                bytes: report.bytes,
                length: report.length,
                rawGyro: pipeline.raw,
                remappedGyro: pipeline.remapped,
                normalizedGyro: pipeline.normalized,
                accel: (report.accelX, report.accelY, report.accelZ),
                buttonStates: device.buttonStates,
                controllerKind: .joyCon,
                gyroDebug: mapGyroDebug(from: device.gyroProcessor.lastDebugState)
            )
        }
    }

    // MARK: - Joy-Con Button Processing

    private func processJoyConButtonActions(
        owner: ManagedDeviceKey,
        device: JoyConDeviceState,
        bytes: [UInt8],
        mapping: JoyConButtonMapping,
        profile: JoyConButtonMappingProfile,
        holdThreshold: Double
    ) {
        // Process all buttons available on this Joy-Con side
        let availableButtons = mapping.isLeftController ? JoyConLogicalButton.leftButtons : JoyConLogicalButton.rightButtons

        for button in availableButtons {
            let idx = button.index
            let isPressed = mapping.isPressed(button, in: bytes)
            let wasPressed = device.previousButtonStates[idx]

            if isPressed != wasPressed {
                let actions = profile.actions(for: button)
                if isPressed {
                    handleJoyConButtonDown(owner: owner, device: device, button: button, actions: actions, holdThreshold: holdThreshold)
                } else {
                    handleJoyConButtonUp(owner: owner, device: device, button: button, mappingProfile: profile)
                }
            }

            device.previousButtonStates[idx] = isPressed
            device.buttonStates[idx] = isPressed
        }
    }

    private func handleJoyConButtonDown(
        owner: ManagedDeviceKey,
        device: JoyConDeviceState,
        button: JoyConLogicalButton,
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
                guard let device = self.joyConDevices[owner.id] else { return }
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

    private func handleJoyConButtonUp(
        owner: ManagedDeviceKey,
        device: JoyConDeviceState,
        button: JoyConLogicalButton,
        mappingProfile: JoyConButtonMappingProfile
    ) {
        let idx = button.index

        // Cancel hold timer
        device.holdTimers[idx]?.cancel()
        device.holdTimers[idx] = nil

        // Also check current mapping for gyro modes
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

