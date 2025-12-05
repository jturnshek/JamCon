import Foundation
import SwiftUI
import ApplicationServices  // For AXIsProcessTrusted

/// Central app state for PSVR2Gyro
@MainActor
class AppState: ObservableObject {

    // MARK: - Published State

    @Published var isConnected: Bool = false
    @Published var controllerName: String = "Not connected"
    @Published var isEnabled: Bool = true
    @Published var statusMessage: String = "Waiting for controller..."

    // MARK: - Accessibility Permission
    @Published var hasAccessibilityPermission: Bool = AXIsProcessTrusted()

    // Debug display
    @Published var lastGyroX: Int16 = 0
    @Published var lastGyroY: Int16 = 0
    @Published var lastGyroZ: Int16 = 0
    @Published var reportCount: Int = 0
    @Published var debugLog: [String] = []

    // Raw report data (full 78 bytes)
    @Published var reportBytes: [UInt8] = Array(repeating: 0, count: 78)
    @Published var reportLength: Int = 0
    @Published var byteLastChanged: [Date] = Array(repeating: Date.distantPast, count: 78)

    // Bit-level tracking for button discovery (78 bytes * 8 bits)
    @Published var bitLastChanged: [[Date]] = Array(repeating: Array(repeating: Date.distantPast, count: 8), count: 78)

    // MARK: - Settings

    @Published var sensitivity: Double = 15.0 {
        didSet { gyroProcessor.sensitivity = sensitivity }
    }

    @Published var gyroScale: Double = 1.0 / 16.0 {
        didSet { gyroProcessor.gyroScale = gyroScale }
    }

    // Gyro axis offsets (for tuning)
    @Published var gyroOffsetX: Int = 17 {
        didSet { controller.gyroOffsetX = gyroOffsetX }
    }
    @Published var gyroOffsetY: Int = 19 {
        didSet { controller.gyroOffsetY = gyroOffsetY }
    }
    @Published var gyroOffsetZ: Int = 21 {
        didSet { controller.gyroOffsetZ = gyroOffsetZ }
    }

    // MARK: - Controllers

    let controller = PSVR2Controller()
    let gyroProcessor = GyroProcessor()
    let mouseController = MouseController()

    // MARK: - Initialization

    init() {
        setupCallbacks()
        controller.start()
    }

    private func setupCallbacks() {
        controller.onDebugMessage = { [weak self] message in
            Task { @MainActor in
                self?.debugLog.append(message)
                if (self?.debugLog.count ?? 0) > 10 {
                    self?.debugLog.removeFirst()
                }
                self?.statusMessage = message
            }
        }

        controller.onConnectionChange = { [weak self] connected, name in
            Task { @MainActor in
                self?.isConnected = connected
                self?.controllerName = name ?? "Unknown"
                self?.statusMessage = connected ? "Connected: \(name ?? "Controller")" : "Disconnected"
                self?.reportCount = 0
            }
        }

        controller.onGyroData = { [weak self] x, y, z, timestamp in
            guard let self = self else { return }

            // Update debug display (throttled)
            Task { @MainActor in
                self.lastGyroX = x
                self.lastGyroY = y
                self.lastGyroZ = z
                self.reportCount += 1
            }

            // Process gyro if enabled
            guard self.isEnabled else { return }

            if let (dx, dy) = self.gyroProcessor.process(rawX: x, rawY: y, rawZ: z, timestamp: timestamp) {
                self.mouseController.moveRelative(dx: dx, dy: dy)
            }
        }

        controller.onReportData = { [weak self] bytes, length in
            guard let self = self else { return }

            Task { @MainActor in
                let now = Date()
                // Track which bytes and bits changed
                for i in 0..<min(bytes.count, self.reportBytes.count) {
                    if bytes[i] != self.reportBytes[i] {
                        self.byteLastChanged[i] = now

                        // Track individual bit changes
                        let oldByte = self.reportBytes[i]
                        let newByte = bytes[i]
                        let changedBits = oldByte ^ newByte
                        for bit in 0..<8 {
                            if (changedBits >> bit) & 1 == 1 {
                                self.bitLastChanged[i][bit] = now
                            }
                        }
                    }
                }
                self.reportBytes = bytes
                self.reportLength = length
            }
        }
    }

    // MARK: - Actions

    func recalibrate() {
        gyroProcessor.reset()
        statusMessage = "Calibrating... keep still"

        Task {
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            await MainActor.run {
                if gyroProcessor.isCalibrated {
                    statusMessage = "Calibrated!"
                } else {
                    statusMessage = "Keep still to calibrate"
                }
            }
        }
    }

    /// Check if the app has Accessibility permission
    func checkAccessibilityPermission() {
        hasAccessibilityPermission = AXIsProcessTrusted()
    }

    /// Open Accessibility settings and prompt for permission
    func openAccessibilitySettings() {
        // Try to trigger the system Accessibility permission prompt
        let promptKey = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        let options = [promptKey: true] as CFDictionary
        let trusted = AXIsProcessTrustedWithOptions(options)

        hasAccessibilityPermission = trusted

        // Also open System Settings to the Accessibility pane
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }

        // Start polling for permission changes
        startAccessibilityPolling()
    }

    private var accessibilityTimer: Timer?

    private func startAccessibilityPolling() {
        accessibilityTimer?.invalidate()
        accessibilityTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.checkAccessibilityPermission()
                if self?.hasAccessibilityPermission == true {
                    self?.accessibilityTimer?.invalidate()
                    self?.accessibilityTimer = nil
                }
            }
        }
    }
}
