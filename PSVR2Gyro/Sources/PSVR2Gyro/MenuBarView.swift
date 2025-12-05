import SwiftUI

struct MenuBarView: View {
    @ObservedObject var appState: AppState
    let openSettings: () -> Void

    // Battery from byte 43 (lower nibble × 10 = percentage)
    private var batteryLevel: Int {
        Int(appState.safeReportByte(43) & 0x0F) * 10
    }

    private var batteryColor: Color {
        if batteryLevel > 50 { return .green }
        if batteryLevel > 20 { return .yellow }
        return .red
    }

    private var batteryIcon: String {
        if batteryLevel >= 75 { return "battery.100" }
        if batteryLevel >= 50 { return "battery.75" }
        if batteryLevel >= 25 { return "battery.50" }
        if batteryLevel > 0 { return "battery.25" }
        return "battery.0"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Connection status
            HStack {
                Circle()
                    .fill(appState.isConnected ? Color.green : Color.red)
                    .frame(width: 10, height: 10)
                Text(appState.controllerName)
                    .font(.headline)
                Spacer()
                if appState.isConnected {
                    Image(systemName: batteryIcon)
                        .foregroundColor(batteryColor)
                    Text("\(batteryLevel)%")
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundColor(.secondary)
                }
            }

            Text(appState.statusMessage)
                .font(.caption)
                .foregroundColor(.secondary)

            Divider()

            // Settings button
            Button(action: openSettings) {
                HStack {
                    Image(systemName: "gear")
                    Text("Settings...")
                    Spacer()
                }
            }
            .buttonStyle(.plain)

            Divider()

            // Quit button
            Button {
                NSApplication.shared.terminate(nil)
            } label: {
                HStack {
                    Image(systemName: "power")
                    Text("Quit")
                    Spacer()
                }
            }
            .buttonStyle(.plain)
        }
        .padding()
        .frame(width: 330)
    }
}
