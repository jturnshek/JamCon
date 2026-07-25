import Foundation
import QuartzCore

extension InputEngine {
    static let linkedGamepadFreshnessTimeout: TimeInterval = 0.25
    private static let linkedGamepadWatchdogInterval: TimeInterval = 0.05

    /// Atomically replaces the linked-pair policy. Changing either selection
    /// discards cached half-state so the new virtual device cannot inherit
    /// controls from a previously selected controller.
    func setLinkedGamepadConfiguration(_ configuration: LinkedGamepadConfiguration) {
        engineQueueSync {
            if linkedGamepadConfiguration == configuration {
                if configuration.isEnabled,
                   configuration.isComplete,
                   !virtualGamepadActivationRequested,
                   !virtualGamepadFailureLatched {
                    startLinkedGamepadRuntime()
                }
                return
            }
            let wasConfigured = linkedGamepadConfiguration.isEnabled
                && linkedGamepadConfiguration.isComplete
            let affectedDeviceIDs = Set([
                linkedGamepadConfiguration.left?.deviceID,
                linkedGamepadConfiguration.right?.deviceID,
                configuration.left?.deviceID,
                configuration.right?.deviceID,
            ].compactMap { $0 })
            for deviceID in affectedDeviceIDs {
                if let device = joyConDevices[deviceID] {
                    resetJoyConTransientState(device)
                }
                cancelRadialMenuIfOwned(
                    by: ManagedDeviceKey(kind: .joyCon, id: deviceID)
                )
            }
            linkedGamepadConfiguration = configuration
            let isConfigured = configuration.isEnabled && configuration.isComplete
            switch (wasConfigured, isConfigured) {
            case (_, false):
                resetLinkedGamepadRuntime(status: linkedGamepadConfiguredIdleStatus)
            case (false, true):
                startLinkedGamepadRuntime()
            case (true, true):
                if virtualGamepadFailureLatched || !virtualGamepadActivationRequested {
                    // Selecting a different physical half is an explicit
                    // recovery action. Restart instead of replacing the
                    // visible failure with an activation that never runs.
                    startLinkedGamepadRuntime()
                } else {
                    linkedGamepadComposer = LinkedJoyConGamepadComposer()
                    virtualGamepadInputsAreFresh = false
                    publishLinkedGamepadState(VirtualGamepadState())
                    updateVirtualGamepadRuntimeStatus(
                        virtualGamepadOutputIsActive ? .waitingForControllers : .activating
                    )
                }
            }
        }
    }

    func retryLinkedGamepadOutput() {
        engineQueueSync {
            guard linkedGamepadConfiguration.isEnabled,
                  linkedGamepadConfiguration.isComplete else { return }
            startLinkedGamepadRuntime()
        }
    }

    var linkedGamepadConfiguredIdleStatus: VirtualGamepadRuntimeStatus {
        guard linkedGamepadConfiguration.isEnabled else { return .disabled }
        guard linkedGamepadConfiguration.isComplete else { return .needsControllers }
        return .waitingForControllers
    }

    func resetLinkedGamepadRuntime(status: VirtualGamepadRuntimeStatus) {
        assertOnEngineQueue()
        linkedGamepadWatchdog?.cancel()
        linkedGamepadWatchdog = nil
        linkedGamepadComposer = LinkedJoyConGamepadComposer()
        virtualGamepadActivationRequested = false
        virtualGamepadOutputIsActive = false
        virtualGamepadInputsAreFresh = false
        virtualGamepadFailureLatched = false
        virtualGamepadOutput.deactivate()
        updateVirtualGamepadRuntimeStatus(status)
    }

    func handleLinkedJoyConUnavailable(deviceID: String) {
        assertOnEngineQueue()
        guard let side = linkedGamepadConfiguration.side(for: deviceID) else { return }
        linkedGamepadComposer.remove(side)
        virtualGamepadInputsAreFresh = false
        guard linkedGamepadConfiguration.isEnabled,
              linkedGamepadConfiguration.isComplete else {
            updateVirtualGamepadRuntimeStatus(linkedGamepadConfiguredIdleStatus)
            return
        }
        publishLinkedGamepadState(VirtualGamepadState())
        if !virtualGamepadFailureLatched {
            updateVirtualGamepadRuntimeStatus(.waitingForControllers)
        }
    }

    func handleVirtualGamepadOutputStatus(_ status: VirtualGamepadOutputStatus) {
        assertOnEngineQueue()
        guard linkedGamepadConfiguration.isEnabled,
              linkedGamepadConfiguration.isComplete else {
            updateVirtualGamepadRuntimeStatus(linkedGamepadConfiguredIdleStatus)
            return
        }

        switch status {
        case .inactive:
            virtualGamepadOutputIsActive = false
            if virtualGamepadActivationRequested && !virtualGamepadFailureLatched {
                updateVirtualGamepadRuntimeStatus(.activating)
            } else if !virtualGamepadActivationRequested {
                updateVirtualGamepadRuntimeStatus(.waitingForControllers)
            }
        case .activating:
            guard virtualGamepadActivationRequested else { return }
            virtualGamepadOutputIsActive = false
            updateVirtualGamepadRuntimeStatus(.activating)
        case .active:
            guard virtualGamepadActivationRequested else { return }
            virtualGamepadOutputIsActive = true
            updateVirtualGamepadRuntimeStatus(
                virtualGamepadInputsAreFresh ? .active : .waitingForControllers
            )
        case let .failed(message):
            guard virtualGamepadActivationRequested else { return }
            virtualGamepadOutputIsActive = false
            virtualGamepadActivationRequested = false
            virtualGamepadFailureLatched = true
            updateVirtualGamepadRuntimeStatus(.failed(message))
        }
    }

    @discardableResult
    func processLinkedJoyConGamepadFrame(
        device: JoyConDeviceState,
        controlBytes: [UInt8],
        timestamp: TimeInterval
    ) -> Bool {
        assertOnEngineQueue()
        let configuration = linkedGamepadConfiguration
        guard configuration.isEnabled,
              configuration.isComplete,
              let side = configuration.side(for: device.id) else {
            return false
        }

        var pressedButtonBits: UInt32 = 0
        for button in JoyConLogicalButton.availableButtons(for: device.profile) {
            let isPressed = device.mapping.isPressed(button, in: controlBytes)
            device.buttonStates[button.index] = isPressed
            device.previousButtonStates[button.index] = isPressed
            if isPressed {
                pressedButtonBits |= 1 << UInt32(button.index)
            }
        }

        let raw = device.mapping.joystickPositionRaw(in: controlBytes)
        let calibration = device.mapping.calibration
        let stickX: Int16
        let stickY: Int16
        if calibration.isCalibrated {
            stickX = VirtualGamepadAxisNormalizer.normalize(
                raw: raw.x,
                center: calibration.centerX,
                negativeRange: calibration.negativeRangeX,
                positiveRange: calibration.positiveRangeX,
                deadzone: JoyConButtonMapping.deadzoneRadius
            )
            // HID Y is encoded downward-positive. Game Controller presents
            // the standard upward-positive semantic to applications.
            stickY = VirtualGamepadAxisNormalizer.normalize(
                raw: raw.y,
                center: calibration.centerY,
                negativeRange: calibration.negativeRangeY,
                positiveRange: calibration.positiveRangeY,
                deadzone: JoyConButtonMapping.deadzoneRadius,
                inverted: true
            )
        } else {
            stickX = 0
            stickY = 0
        }
        let half = JoyConGamepadHalfState(
            side: side,
            stickX: stickX,
            stickY: stickY,
            pressedButtonBits: pressedButtonBits
        )

        linkedGamepadComposer.update(half, timestamp: timestamp)
        guard let combinedState = linkedGamepadComposer.freshState(
            at: timestamp,
            timeout: Self.linkedGamepadFreshnessTimeout
        ) else {
            if virtualGamepadInputsAreFresh {
                virtualGamepadInputsAreFresh = false
                publishLinkedGamepadState(VirtualGamepadState())
            }
            if virtualGamepadOutputIsActive && !virtualGamepadFailureLatched {
                updateVirtualGamepadRuntimeStatus(.waitingForControllers)
            }
            return true
        }

        virtualGamepadInputsAreFresh = true
        publishLinkedGamepadState(combinedState)
        if virtualGamepadOutputIsActive && !virtualGamepadFailureLatched {
            updateVirtualGamepadRuntimeStatus(.active)
        }
        return true
    }

    func startLinkedGamepadRuntime() {
        assertOnEngineQueue()
        linkedGamepadWatchdog?.cancel()
        linkedGamepadComposer = LinkedJoyConGamepadComposer()
        virtualGamepadActivationRequested = true
        virtualGamepadOutputIsActive = false
        virtualGamepadInputsAreFresh = false
        virtualGamepadFailureLatched = false
        updateVirtualGamepadRuntimeStatus(.activating)
        virtualGamepadOutput.activate()
        publishLinkedGamepadState(VirtualGamepadState())

        let watchdog = DispatchSource.makeTimerSource(queue: engineQueue)
        watchdog.schedule(
            deadline: .now() + Self.linkedGamepadWatchdogInterval,
            repeating: Self.linkedGamepadWatchdogInterval,
            leeway: .milliseconds(10)
        )
        watchdog.setEventHandler { [weak self] in
            self?.checkLinkedGamepadFreshness()
        }
        linkedGamepadWatchdog = watchdog
        watchdog.resume()
    }

    private func checkLinkedGamepadFreshness() {
        assertOnEngineQueue()
        guard linkedGamepadConfiguration.isEnabled,
              linkedGamepadConfiguration.isComplete,
              virtualGamepadInputsAreFresh else { return }
        let now = CACurrentMediaTime()
        guard linkedGamepadComposer.freshState(
            at: now,
            timeout: Self.linkedGamepadFreshnessTimeout
        ) == nil else { return }

        virtualGamepadInputsAreFresh = false
        publishLinkedGamepadState(VirtualGamepadState())
        if virtualGamepadOutputIsActive && !virtualGamepadFailureLatched {
            updateVirtualGamepadRuntimeStatus(.waitingForControllers)
        }
    }

    private func publishLinkedGamepadState(_ state: VirtualGamepadState) {
        assertOnEngineQueue()
        guard virtualGamepadActivationRequested,
              !virtualGamepadFailureLatched else { return }
        virtualGamepadReportSequence &+= 1
        virtualGamepadOutput.submit(
            VirtualGamepadHIDReport(state: state),
            sequence: virtualGamepadReportSequence
        )
    }

    func recordLinkedGamepadDebugIfNeeded(
        report: InputDeviceFrame,
        device: JoyConDeviceState,
        owner: ManagedDeviceKey,
        settings: SettingsStore.InputSettings,
        engineStartTimestamp: TimeInterval
    ) {
        assertOnEngineQueue()
        guard settings.debugRecordingEnabled,
              settings.debugRecordingTargetKind == nil
                || settings.debugRecordingTargetKind == .joyCon else { return }

        debugBuffer.recordTrace(
            device: owner,
            reportID: report.reportID,
            bytes: report.bytes,
            timestamp: report.receivedTimestamp
        )

        let motion = report.motion.latest
        let rawGyro = settings.joyConUseAveragedGyroSamples
            ? (report.motion.averagedGyro ?? (
                x: motion?.gyroX ?? 0,
                y: motion?.gyroY ?? 0,
                z: motion?.gyroZ ?? 0
            ))
            : (
                x: motion?.gyroX ?? 0,
                y: motion?.gyroY ?? 0,
                z: motion?.gyroZ ?? 0
            )
        let pipeline = GyroRemapper.process(
            rawX: rawGyro.x,
            rawY: rawGyro.y,
            rawZ: rawGyro.z,
            controllerKind: .joyCon,
            isLeft: device.profile.isLeft,
            profileVariant: device.profile.variant,
            nativeScale: report.gyroScale
        )
        let engineEndTimestamp = CACurrentMediaTime()
        debugBuffer.record(
            bytes: report.bytes,
            length: report.length,
            rawGyro: pipeline.raw,
            remappedGyro: pipeline.remapped,
            normalizedGyro: pipeline.normalized,
            accel: (
                motion?.accelX ?? 0,
                motion?.accelY ?? 0,
                motion?.accelZ ?? 0
            ),
            buttonStates: device.buttonStates,
            controllerKind: .joyCon,
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

    private func updateVirtualGamepadRuntimeStatus(_ status: VirtualGamepadRuntimeStatus) {
        assertOnEngineQueue()
        guard virtualGamepadRuntimeStatus != status else { return }
        virtualGamepadRuntimeStatus = status
        onVirtualGamepadStatusChanged?(status)
    }
}
