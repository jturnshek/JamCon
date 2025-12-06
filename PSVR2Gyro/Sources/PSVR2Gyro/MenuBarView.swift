import SwiftUI

struct MenuBarView: View {
    @ObservedObject var appState: AppState
    let openSettings: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Connection status
            HStack {
                StatusDot(isActive: appState.isConnected, size: 10)
                Text(appState.controllerName)
                    .font(.headline)
                Spacer()
                if appState.isConnected {
                    Image(systemName: BatteryHelper.icon(for: appState.batteryLevel))
                        .foregroundColor(BatteryHelper.color(for: appState.batteryLevel))
                    Text("\(appState.batteryLevel)%")
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
