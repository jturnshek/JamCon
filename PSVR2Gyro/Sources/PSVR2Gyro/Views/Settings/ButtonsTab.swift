import SwiftUI

// MARK: - Buttons Tab

struct ButtonsTab: View {
    @ObservedObject var appState: AppState
    @StateObject private var keyCaptureManager = KeyCaptureManager()

    private var isLeft: Bool { appState.isLeftController }

    var body: some View {
        VStack(spacing: 0) {
            TabHeader(appState: appState)

            ScrollView {
                VStack(spacing: 16) {
                    ButtonMappingsSection(
                        appState: appState,
                        keyCaptureManager: keyCaptureManager,
                        isLeft: isLeft
                    )

                    // Tip about PlayStation button
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: "info.circle")
                            .foregroundColor(.blue)
                        Text("If the PlayStation button opens Launchpad, disable it in System Settings \u{2192} Game Controllers \u{2192} \"Press Home button to open Launchpad\"")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    .padding()
                    .background(Color.blue.opacity(0.05))
                    .cornerRadius(8)

                    // Warning about Square/Circle buttons
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: "exclamationmark.triangle")
                            .foregroundColor(.orange)
                        Text("Square and Circle buttons may trigger unwanted keyboard shortcuts in macOS. For best results, use Triangle, X, triggers, or bumpers for mappings.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    .padding()
                    .background(Color.orange.opacity(0.05))
                    .cornerRadius(8)
                }
                .padding()
            }

            if !appState.isConnected {
                Text("Connect a controller to configure buttons")
                    .foregroundColor(.secondary)
                    .frame(maxHeight: .infinity)
            }
        }
        .onAppear {
            keyCaptureManager.onCapture = { button, combo, isHold in
                if isHold {
                    appState.buttonMappingProfile.setHoldAction(.keyPress(combo), for: button)
                } else {
                    appState.buttonMappingProfile.setPressAction(.keyPress(combo), for: button)
                }
            }
        }
    }
}
