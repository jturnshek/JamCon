import SwiftUI
import AppKit

struct CompactMenuView: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.openWindow) var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Accessibility warning (if needed)
            if !appState.hasAccessibilityPermission {
                accessibilityWarning
            }

            // Device status section
            deviceStatusSection

            Divider()

            // Action buttons
            actionButtons
        }
        .padding()
        .frame(width: 320)
    }

    // MARK: - Accessibility Warning

    private var accessibilityWarning: some View {
        VStack(spacing: 6) {
            HStack {
                Image(systemName: "exclamationmark.triangle")
                    .foregroundColor(JamConColors.orange)
                Text("Accessibility Required")
                    .font(.headline)
            }

            Text("You may need to manually add this app in Settings.")
                .font(.caption)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)

            Button("Open Accessibility Settings") {
                appState.openAccessibilitySettings()
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
        .padding(JamConMetrics.spacingMD)
        .frame(maxWidth: .infinity)
        .overlay(
            RoundedRectangle(cornerRadius: JamConMetrics.radiusSmall)
                .strokeBorder(JamConColors.orange, lineWidth: JamConMetrics.strokeThin)
        )
    }

    // MARK: - Device Status Section

    private var deviceStatusSection: some View {
        VStack(spacing: 6) {
            slotRow(slot: .primary)
            slotRow(slot: .secondary)
        }
    }

    private func slotRow(slot: DeviceSlot) -> some View {
        let assignment = SlotAssignment.load(slot: slot)
        let deviceName = assignment.deviceName
        let isConnected = deviceName.map { isDeviceConnected(name: $0) } ?? false
        let batteryLevel = findBatteryLevel(for: deviceName)

        return HStack {
            Text(slot == .primary ? "Primary:" : "Secondary:")
                .foregroundColor(slot == .primary ? JamConColors.green : JamConColors.blue)
                .fontWeight(.medium)

            if let name = deviceName {
                Text(name)

                if let level = batteryLevel {
                    let (batteryImage, batteryColor) = batteryIconInfo(for: level)
                    Image(systemName: batteryImage)
                        .foregroundColor(batteryColor)
                }

                // Connection indicator
                Image(systemName: isConnected ? "circle.fill" : "circle")
                    .font(.caption2)
                    .foregroundColor(isConnected ? JamConColors.green : .secondary)
            } else {
                Text("Not configured")
                    .foregroundColor(.secondary)
            }

            Spacer()
        }
        .foregroundColor(isConnected ? .primary : .secondary)
    }

    private func isDeviceConnected(name: String) -> Bool {
        // Check Joy-Cons
        if appState.connectedControllers.contains(where: { $0.name == name }) {
            return true
        }
        // Check air mice
        if let deviceManager = appState.deviceManager {
            if deviceManager.connectedDevices.contains(where: { $0.displayName == name }) {
                return true
            }
        }
        return false
    }

    private func findBatteryLevel(for deviceName: String?) -> BatteryLevel? {
        guard let name = deviceName else { return nil }
        return appState.connectedControllers.first { $0.name == name }?.batteryLevel
    }

    private func batteryIconInfo(for level: BatteryLevel) -> (String, Color) {
        switch level {
        case .full:
            return ("battery.100", JamConColors.green)
        case .medium:
            return ("battery.75", JamConColors.green)
        case .low:
            return ("battery.25", JamConColors.yellow)
        case .critical, .empty:
            return ("battery.0", JamConColors.red)
        case .unknown:
            return ("battery.0", .secondary)
        }
    }

    // MARK: - Action Buttons

    private var actionButtons: some View {
        HStack {
            Button("Settings...") {
                openWindow(id: "settings")
                NSApp.activate(ignoringOtherApps: true)
            }
            .buttonStyle(.bordered)

            Spacer()

            Button(role: .destructive) {
                appState.quit()
            } label: {
                Label("Quit", systemImage: "power")
            }
            .buttonStyle(.bordered)
        }
    }
}

#Preview {
    CompactMenuView()
        .environmentObject(AppState())
}
