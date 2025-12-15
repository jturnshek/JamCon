import Foundation
import SwiftUI
import ApplicationServices

extension AppState {

    // MARK: - Debug Polling

    func startDebugPolling() {
        startDebugPolling(targetKind: nil)
    }

    func startDebugPolling(targetKind: ControllerKind?) {
        guard !debugPollingEnabled else { return }
        debugPollingEnabled = true
        debugTelemetry.reset()
        debugBuffer.startRecording()
        settingsStore.update {
            $0.debugRecordingEnabled = true
            $0.debugRecordingTargetKind = targetKind
        }
        updateG502XInterfaceDebugMode()

        debugPollingTask?.cancel()
        debugPollingTask = Task { @MainActor [weak self] in
            guard let self else { return }
            while !Task.isCancelled, self.debugPollingEnabled {
                self.pollDebugData()
                try? await Task.sleep(nanoseconds: 33_333_333) // ~30Hz
            }
        }
    }

    func stopDebugPolling() {
        debugPollingEnabled = false
        debugTelemetry.reset()
        debugBuffer.stopRecording()
        settingsStore.update {
            $0.debugRecordingEnabled = false
            $0.debugRecordingTargetKind = nil
        }
        debugPollingTask?.cancel()
        debugPollingTask = nil
        updateG502XInterfaceDebugMode()
    }

    private func pollDebugData() {
        guard debugPollingEnabled else { return }
        let sample = debugBuffer.latest()
        let stats = debugBuffer.stats()
        let byteLastChanged = debugBuffer.getByteLastChanged()
        let bitLastChanged = debugBuffer.getBitLastChanged()
        debugTelemetry.update(sample: sample, stats: stats, byteLastChanged: byteLastChanged, bitLastChanged: bitLastChanged)
    }

    func updateG502XInterfaceDebugMode() {
        let target = settingsStore.snapshot().debugRecordingTargetKind
        engine.g502xController.setInterfaceDebugEnabled(debugPollingEnabled && (target == nil || target == .mouse))
    }

    // MARK: - Log Polling

    func startLogPolling() {
        guard logPollingTask == nil else { return }

        // Poll immediately once
        pollLogMessages()

        logPollingTask = Task { @MainActor [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 500_000_000)
                guard !Task.isCancelled else { break }
                self.pollLogMessages()
            }
        }
    }

    func stopLogPolling() {
        logPollingTask?.cancel()
        logPollingTask = nil
    }

    private func pollLogMessages() {
        debugLog = debugBuffer.getLogMessages()
    }

    func clearLogs() {
        debugLog.removeAll()
        debugBuffer.clearLog()
    }

    // MARK: - Accessibility

    func checkAccessibilityPermission() {
        hasAccessibilityPermission = AXIsProcessTrusted()
    }

    func openAccessibilitySettings() {
        let promptKey = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        let options = [promptKey: true] as CFDictionary
        let trusted = AXIsProcessTrustedWithOptions(options)
        hasAccessibilityPermission = trusted

        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }

        startAccessibilityPolling()
    }

    private func startAccessibilityPolling() {
        accessibilityPollingTask?.cancel()
        accessibilityPollingTask = Task { @MainActor [weak self] in
            guard let self else { return }
            for _ in 0..<60 where !Task.isCancelled {
                self.checkAccessibilityPermission()
                if self.hasAccessibilityPermission {
                    break
                }
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
        }
    }

    // MARK: - Gyro Settings Reset

    func resetGyroSettings() {
        let defaults = GyroSettingsState.defaultForKind(configurationProfile.kind)

        sensitivity = defaults.sensitivity
        gyroScale = defaults.gyroScale
        filterEnabled = defaults.filterEnabled
        minCutoff = defaults.minCutoff
        beta = defaults.beta
        adaptiveSmoothingMode = defaults.adaptiveSmoothingMode
        accelerationMode = defaults.accelerationMode
        simpleAcceleration = defaults.simpleAcceleration
        accelerationCurve = defaults.accelerationCurve
        accelerationStrength = defaults.accelerationStrength
        sensitivityCap = defaults.sensitivityCap
        curveExponent = defaults.curveExponent
        rampSpeed = defaults.rampSpeed
        softCutoffThreshold = defaults.softCutoffThreshold
        recoveryThreshold = defaults.recoveryThreshold
        autoTuneSampleRate = defaults.autoTuneSampleRate
        autoNeutralEnabled = defaults.autoNeutralEnabled

        if configurationProfile.kind == .joyCon {
            joyConTimerFallbackEnabled = defaults.joyConTimerFallbackEnabled
            joyConTimerHybridEnabled = defaults.joyConTimerHybridEnabled
            joyConUseAveragedGyroSamples = defaults.joyConUseAveragedGyroSamples
        }
    }

    // MARK: - Convenience Accessors

    /// Safe accessor for report bytes
    func safeReportByte(_ index: Int) -> UInt8 {
        let bytes = debugTelemetry.reportBytes
        guard index >= 0 && index < bytes.count else { return 0 }
        return bytes[index]
    }

    /// Get G502X HID interface info for debug display
    func getG502XInterfaceInfo() -> [G502XInterfaceInfo] {
        engine.g502xController.getInterfaceInfo()
    }
}

