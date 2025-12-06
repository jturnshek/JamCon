import SwiftUI

// MARK: - Stick Tab

struct StickTab: View {
    @ObservedObject var appState: AppState

    var body: some View {
        VStack(spacing: 0) {
            TabHeader(appState: appState)

            Spacer()
            VStack(spacing: 12) {
                Image(systemName: "l.joystick")
                    .font(.system(size: 48))
                    .foregroundColor(.secondary.opacity(0.5))
                Text("Stick configuration")
                    .font(.headline)
                    .foregroundColor(.secondary)
                Text("Real-time stick data is available in the Debug tab")
                    .font(.caption)
                    .foregroundColor(.secondary.opacity(0.7))
            }
            Spacer()
        }
    }
}
