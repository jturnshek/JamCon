import SwiftUI

// MARK: - Unified Tab Header

/// Consistent header component for all settings tabs
/// Shows: [Side] Controller + battery + connection status
struct TabHeader: View {
    @ObservedObject var appState: AppState
    @State private var cachedBatteryLevel: Int = 0

    private var side: String { appState.isLeftController ? "Left" : "Right" }

    var body: some View {
        HStack {
            Text("\(side) Controller")
                .font(.headline)
            Spacer()
            if appState.isConnected {
                BatteryIndicator(level: cachedBatteryLevel)
            }
            ConnectionIndicator(isConnected: appState.isConnected)
        }
        .padding(.horizontal)
        .padding(.vertical, 10)
        .background(Color.secondary.opacity(0.05))
        .onAppear {
            cachedBatteryLevel = BatteryHelper.level(
                from: appState.safeReportByte(PSVR2HIDProtocol.Offset.battery)
            )
        }
    }
}
