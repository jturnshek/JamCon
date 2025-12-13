import SwiftUI

// MARK: - Unified Tab Header

/// Consistent header component for all settings tabs
/// Shows: Controller name + optional controls + battery + connection status
struct TabHeader<TrailingContent: View>: View {
    @ObservedObject var appState: AppState
    let trailingContent: TrailingContent?

    init(appState: AppState) where TrailingContent == EmptyView {
        self.appState = appState
        self.trailingContent = nil
    }

    init(appState: AppState, @ViewBuilder trailing: () -> TrailingContent) {
        self.appState = appState
        self.trailingContent = trailing()
    }

    private var displayName: String {
        appState.controllerName
    }

    var body: some View {
        HStack {
            Text(displayName)
                .font(.headline)
            Spacer()
            if let trailing = trailingContent {
                trailing
            }
            if appState.isConnected && appState.batteryLevel > 0 {
                BatteryIndicator(level: appState.batteryLevel)
            }
            ConnectionIndicator(isConnected: appState.isConnected)
        }
        .padding(.horizontal)
        .padding(.vertical, 14)
        .background(Color.secondary.opacity(0.05))
    }
}

/// Picker for choosing which controller profile the settings UI is editing.
struct ConfigurationTargetControl: View {
    @ObservedObject var appState: AppState

    var body: some View {
        HStack(spacing: 6) {
            Text("Configuring")
                .font(.caption)
                .foregroundColor(.secondary)

            Picker("", selection: $appState.configurationProfile) {
                ForEach(ControllerProfile.allProfiles, id: \.self) { profile in
                    Text(profile.displayName)
                        .tag(profile)
                }
            }
            .pickerStyle(.menu)
        }
    }
}
