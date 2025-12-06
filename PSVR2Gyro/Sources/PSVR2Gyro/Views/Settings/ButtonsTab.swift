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
