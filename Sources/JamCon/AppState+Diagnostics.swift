import Foundation
import SwiftUI
@preconcurrency import ApplicationServices
import UniformTypeIdentifiers

extension AppState {

    // MARK: - Debug Polling

    func startDebugPolling() {
        startDebugPolling(targetKind: nil)
    }

    func startDebugPolling(targetKind: ControllerKind?) {
        guard !debugPollingEnabled else { return }
        debugPollingEnabled = true
        debugTelemetry.reset()
        debugBuffer.clear()
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

    func exportHIDTrace() {
        do {
            let data = try debugBuffer.encodedHIDTrace()
            let panel = NSSavePanel()
            panel.title = "Export HID Trace"
            panel.nameFieldStringValue = "JamCon-HID-Trace.json"
            panel.allowedContentTypes = [.json]
            panel.canCreateDirectories = true

            guard panel.runModal() == .OK, let url = panel.url else { return }
            try data.write(to: url, options: .atomic)
            JamLog.info(.app, "Exported HID trace to \(url.lastPathComponent)")
        } catch {
            JamLog.error(.app, "Failed to export HID trace: \(error.localizedDescription)")
        }
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
        let trusted = AXIsProcessTrusted()
        if trusted != hasAccessibilityPermission {
            JamLog.info(.app, "Accessibility permission changed: \(trusted ? "granted" : "missing")")
        }
        hasAccessibilityPermission = trusted
    }

    func openAccessibilitySettings() {
        JamLog.info(.app, "Accessibility permission requested by user")
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

    enum GyroSettingsSection: Sendable {
        case sensitivity
        case filtering
        case samplingAndCalibration
        case acceleration
    }

    func resetGyroSettings(_ section: GyroSettingsSection) {
        let defaults = GyroSettingsState.defaultForKind(configurationProfile.kind)

        switch section {
        case .sensitivity:
            sensitivity = defaults.sensitivity

        case .filtering:
            filterEnabled = defaults.filterEnabled
            minCutoff = defaults.minCutoff
            beta = defaults.beta
            adaptiveSmoothingMode = defaults.adaptiveSmoothingMode

        case .samplingAndCalibration:
            autoTuneSampleRate = defaults.autoTuneSampleRate
            autoNeutralEnabled = defaults.autoNeutralEnabled
            if configurationProfile.kind == .joyCon {
                joyConUseAveragedGyroSamples = defaults.joyConUseAveragedGyroSamples
            }

        case .acceleration:
            accelerationMode = defaults.accelerationMode
            simpleAcceleration = defaults.simpleAcceleration
            accelerationCurve = defaults.accelerationCurve
            accelerationStrength = defaults.accelerationStrength
            sensitivityCap = defaults.sensitivityCap
            curveExponent = defaults.curveExponent
            rampSpeed = defaults.rampSpeed
        }
    }

    func resetGyroSettings() {
        let defaults = GyroSettingsState.defaultForKind(configurationProfile.kind)
        resetGyroSettings(.sensitivity)
        gyroScale = defaults.gyroScale
        resetGyroSettings(.filtering)
        resetGyroSettings(.samplingAndCalibration)
        resetGyroSettings(.acceleration)

        softCutoffThreshold = defaults.softCutoffThreshold
        recoveryThreshold = defaults.recoveryThreshold
    }

    func resetJoystickSettings() {
        joystickScrollEnabled = true
        joystickScrollSpeed = SettingsStore.InputSettings.defaultJoystickScrollSpeed
        joystickScrollAcceleration = SettingsStore.InputSettings.defaultJoystickScrollAcceleration
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
