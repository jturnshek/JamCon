import Foundation
import CoreGraphics
import QuartzCore
import os

extension InputEngine {

    // MARK: - G502X Report Processing

    func processG502XReport(_ report: G502XHIDController.InputReport) {
        assertOnEngineQueue()
        guard isRunning else { return }
        let engineStartTimestamp = CACurrentMediaTime()
        let healthDevice = ManagedDeviceKey(kind: .mouse, id: selectedMouseID ?? "mouse")
        let signpostID = Self.inputPerformanceLog.signpostsEnabled
            ? OSSignpostID(log: Self.inputPerformanceLog)
            : nil
        if let signpostID {
            os_signpost(.begin, log: Self.inputPerformanceLog, name: "Mouse Input", signpostID: signpostID)
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
                os_signpost(.end, log: Self.inputPerformanceLog, name: "Mouse Input", signpostID: signpostID)
            }
        }

        // Read settings ONCE at start of frame
        let s = settings.snapshot()

        guard s.isEnabled else { return }

        let profile = ControllerProfile.mouse
        let buttonProfile = s.g502xButtonMappings[profile] ?? .default

        // Prime initial button state to avoid false "pressed" edges on startup/connect.
        // The Lightspeed receiver can deliver a non-zero snapshot while we are still setting up HID++.
        if !g502xHasPrimedButtonState {
            primeG502XButtonStates(bytes: report.bytes, mapping: g502xMapping)
            g502xHasPrimedButtonState = true
            return
        }

        // 1. Process mouse buttons
        processG502XButtonActions(
            bytes: report.bytes,
            mapping: g502xMapping,
            profile: buttonProfile,
            holdThreshold: buttonProfile.holdThreshold
        )

        if s.debugRecordingEnabled && (s.debugRecordingTargetKind == nil || s.debugRecordingTargetKind == .mouse) {
            let engineEndTimestamp = CACurrentMediaTime()
            debugBuffer.recordTrace(
                device: ManagedDeviceKey(kind: .mouse, id: selectedMouseID ?? "mouse"),
                reportID: 0,
                bytes: report.bytes,
                timestamp: report.receivedTimestamp
            )
            debugBuffer.record(
                bytes: report.bytes,
                length: report.length,
                rawGyro: (0, 0, 0),           // Mouse has no gyro
                remappedGyro: (0, 0, 0),
                normalizedGyro: (0, 0, 0),
                accel: (0, 0, 0),
                buttonStates: g502xPreviousButtonStates,
                controllerKind: .mouse,
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

    func resetG502XButtonStateBaseline() {
        g502xHasPrimedButtonState = false
        for i in 0..<g502xPreviousButtonStates.count {
            if let pressState = g502xButtonPressStates[i] {
                actionExecutor.execute(pressState.actions.press, isPressed: false, owner: pressState.pressOwner)
                if pressState.holdFired {
                    actionExecutor.execute(pressState.actions.hold, isPressed: false, owner: pressState.holdOwner)
                }
            }
            g502xPreviousButtonStates[i] = false
            g502xButtonStates[i] = false
            g502xButtonPressStates[i] = nil
            g502xHoldTimers[i]?.cancel()
            g502xHoldTimers[i] = nil
        }
    }

    private func primeG502XButtonStates(bytes: [UInt8], mapping: G502XButtonMapping) {
        for button in G502XLogicalButton.allCases {
            let idx = button.index
            let pressed = mapping.isPressed(button, in: bytes)
            g502xPreviousButtonStates[idx] = pressed
            g502xButtonStates[idx] = pressed
            g502xButtonPressStates[idx] = nil
            g502xHoldTimers[idx]?.cancel()
            g502xHoldTimers[idx] = nil
        }
    }

    // MARK: - G502X Button Processing

    private func processG502XButtonActions(
        bytes: [UInt8],
        mapping: G502XButtonMapping,
        profile: G502XButtonMappingProfile,
        holdThreshold: Double
    ) {
        // Log G9 state for debugging (byte 1, bit 0)
        let g9Pressed = bytes.count > 1 ? (bytes[1] & 0x01) != 0 : false
        let g9WasPrevious = g502xPreviousButtonStates[G502XLogicalButton.g9.index]
        if g9Pressed != g9WasPrevious {
            JamLog.debug(.g502x, "HID: G9 state change - byte1=0x\(String(format: "%02X", bytes.count > 1 ? bytes[1] : 0)) pressed=\(g9Pressed) was=\(g9WasPrevious)")
        }

        // Process all G502X buttons
        for button in G502XLogicalButton.allCases {
            let idx = button.index
            let isPressed = mapping.isPressed(button, in: bytes)
            let wasPressed = g502xPreviousButtonStates[idx]

            if isPressed != wasPressed {
                let actions = profile.actions(for: button)
                if isPressed {
                    handleG502XButtonDown(button: button, actions: actions, holdThreshold: holdThreshold)
                } else {
                    handleG502XButtonUp(button: button, mappingProfile: profile)
                }
            }

            g502xPreviousButtonStates[idx] = isPressed
            g502xButtonStates[idx] = isPressed
        }
    }

    private func handleG502XButtonDown(button: G502XLogicalButton, actions: ButtonActions, holdThreshold: Double) {
        let idx = button.index
        let deviceOwner = ManagedDeviceKey(kind: .mouse, id: selectedMouseID ?? "mouse")

        // Handle gyro mode actions (radial menu for mouse)
        if actions.pressIsGyroMode {
            g502xButtonPressStates[idx] = ButtonPressState(actions: actions, device: deviceOwner, control: button.rawValue)
            switch actions.press {
            case .radialMenu:
                JamLog.debug(.g502x, "Opening radial menu (button=\(button))")
                let owner = ManagedDeviceKey(kind: .mouse, id: selectedMouseID ?? "mouse")
                beginRadialMenu(owner: owner, pointerStyle: .systemCursor, modeState: &mouseMode)
            case .drag, .scroll:
                // These don't make sense for mouse (it already has native cursor/scroll)
                // but we handle them for consistency
                if actions.press == .drag {
                    mouseMode.dragButtonHeld = true
                } else {
                    mouseMode.scrollButtonHeld = true
                }
            default:
                break
            }
            return
        }

        let state = ButtonPressState(actions: actions, device: deviceOwner, control: button.rawValue)
        g502xButtonPressStates[idx] = state

        if case .mouseClick = actions.press {
            actionExecutor.execute(actions.press, isPressed: true, owner: state.pressOwner)
        }

        // Schedule hold timer if there's a hold action
        if actions.hold != .none {
            let timer = DispatchWorkItem { [weak self] in
                guard let self = self else { return }
                guard self.isRunning else { return }
                guard var state = self.g502xButtonPressStates[idx], !state.holdFired else { return }

                state.holdFired = true
                self.g502xButtonPressStates[idx] = state
                self.actionExecutor.execute(state.actions.hold, isPressed: true, owner: state.holdOwner)
            }
            g502xHoldTimers[idx]?.cancel()
            g502xHoldTimers[idx] = timer
            holdScheduler.schedule(timer, after: holdThreshold, on: engineQueue)
        }
    }

    private func handleG502XButtonUp(button: G502XLogicalButton, mappingProfile: G502XButtonMappingProfile) {
        let idx = button.index

        // Cancel hold timer
        g502xHoldTimers[idx]?.cancel()
        g502xHoldTimers[idx] = nil

        let owner = ManagedDeviceKey(kind: .mouse, id: selectedMouseID ?? "mouse")

        // Check for gyro mode button release
        if let state = g502xButtonPressStates[idx], state.actions.pressIsGyroMode {
            handleGyroModeRelease(owner: owner, action: state.actions.press, modeState: &mouseMode)
            g502xButtonPressStates[idx] = nil
            return
        }

        // Also check current mapping for gyro modes
        let actions = mappingProfile.actions(for: button)
        if actions.pressIsGyroMode {
            handleGyroModeRelease(owner: owner, action: actions.press, modeState: &mouseMode)
            return
        }

        guard let state = g502xButtonPressStates[idx] else { return }

        // Handle mouse click release
        if case .mouseClick = state.actions.press {
            actionExecutor.execute(state.actions.press, isPressed: false, owner: state.pressOwner)
            if state.holdFired {
                actionExecutor.execute(state.actions.hold, isPressed: false, owner: state.holdOwner)
            }
            g502xButtonPressStates[idx] = nil
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

        g502xButtonPressStates[idx] = nil
    }

    // NOTE: We intentionally do not "passthrough" mouse buttons by re-posting CGEvents.
    // The G502X is opened non-exclusively, so the system already receives native mouse events.
}
