import SwiftUI

// MARK: - Button Mapping Views

struct ButtonMappingsSection: View {
    @ObservedObject var appState: AppState
    @ObservedObject var keyCaptureManager: KeyCaptureManager
    let isLeft: Bool

    private let mappableButtons: [LogicalButton] = [
        .faceTop, .faceBottom, .bumper, .trigger, .stickClick, .menuButton, .playStation
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Button Mappings")
                .font(.subheadline)
                .fontWeight(.medium)
                .foregroundColor(.secondary)

            HStack(spacing: 12) {
                Text("")
                    .frame(width: 80, alignment: .leading)
                Text("Press")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text("Hold")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, 4)

            VStack(spacing: 8) {
                ForEach(mappableButtons, id: \.self) { button in
                    ButtonMappingRow(
                        button: button,
                        buttonName: button.name(isLeft: isLeft),
                        actions: appState.buttonMappingProfile.actions(for: button),
                        isCapturing: keyCaptureManager.isCapturing(button: button),
                        modifiersDisplay: keyCaptureManager.modifiersDisplay,
                        onPressActionSelected: { action in
                            appState.buttonMappingProfile.setPressAction(action, for: button)
                        },
                        onHoldActionSelected: { action in
                            appState.buttonMappingProfile.setHoldAction(action, for: button)
                        },
                        onStartCapture: { isHold in
                            keyCaptureManager.startCapture(for: button, isHold: isHold)
                        },
                        onCancelCapture: {
                            keyCaptureManager.cancelCapture()
                        }
                    )
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Trigger Threshold")
                        .font(.system(size: 12, weight: .medium))
                    Spacer()
                    Text("\(appState.buttonMappingProfile.triggerThreshold)")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(.secondary)
                }

                HStack(spacing: 8) {
                    Text("0")
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                    Slider(
                        value: Binding(
                            get: { Double(appState.buttonMappingProfile.triggerThreshold) },
                            set: { appState.buttonMappingProfile.triggerThreshold = UInt8($0) }
                        ),
                        in: 0...255,
                        step: 1
                    )
                    Text("255")
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                }

                Text("Analog trigger value needed to activate mapped action")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
            .padding(.top, 8)

            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Hold Threshold")
                        .font(.system(size: 12, weight: .medium))
                    Spacer()
                    Text(String(format: "%.1fs", appState.buttonMappingProfile.holdThreshold))
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(.secondary)
                }

                HStack(spacing: 8) {
                    Text("0.1s")
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                    Slider(
                        value: Binding(
                            get: { appState.buttonMappingProfile.holdThreshold },
                            set: { appState.buttonMappingProfile.holdThreshold = $0 }
                        ),
                        in: 0.1...1.0,
                        step: 0.1
                    )
                    Text("1.0s")
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                }

                Text("How long to hold before the hold action fires")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
        }
        .padding()
        .background(Color.secondary.opacity(0.03))
        .cornerRadius(8)
    }
}

struct ButtonMappingRow: View {
    let button: LogicalButton
    let buttonName: String
    let actions: ButtonActions
    let isCapturing: Bool
    let modifiersDisplay: String
    let onPressActionSelected: (ButtonAction) -> Void
    let onHoldActionSelected: (ButtonAction) -> Void
    let onStartCapture: (Bool) -> Void
    let onCancelCapture: () -> Void

    private var holdDisabled: Bool {
        actions.pressIsGyroMode
    }

    var body: some View {
        HStack(spacing: 12) {
            Text(buttonName)
                .font(.system(size: 12, weight: .medium))
                .frame(width: 80, alignment: .leading)

            if isCapturing {
                HStack(spacing: 8) {
                    Text(modifiersDisplay)
                        .font(.system(size: 11))
                        .foregroundColor(.orange)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    Button("Cancel") {
                        onCancelCapture()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Color.orange.opacity(0.1))
                .cornerRadius(6)
            } else {
                ActionPickerMenu(
                    action: actions.press,
                    includeGyroModes: true,
                    isHold: false,
                    onActionSelected: onPressActionSelected,
                    onStartCapture: onStartCapture
                )

                if holdDisabled {
                    Text("—")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary.opacity(0.5))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Color.secondary.opacity(0.05))
                        .cornerRadius(6)
                } else {
                    ActionPickerMenu(
                        action: actions.hold,
                        includeGyroModes: false,
                        isHold: true,
                        onActionSelected: onHoldActionSelected,
                        onStartCapture: onStartCapture
                    )
                }
            }
        }
    }
}

struct ActionPickerMenu: View {
    let action: ButtonAction
    let includeGyroModes: Bool
    let isHold: Bool
    let onActionSelected: (ButtonAction) -> Void
    let onStartCapture: (Bool) -> Void

    var body: some View {
        Menu {
            Button("None") {
                onActionSelected(.none)
            }

            if includeGyroModes {
                Divider()

                Button("Drag (hold to move)") {
                    onActionSelected(.drag)
                }
                Button("Scroll (hold to scroll)") {
                    onActionSelected(.scroll)
                }
                Button("Radial Menu") {
                    onActionSelected(.radialMenu)
                }
            }

            Divider()

            ForEach(MouseButton.allCases, id: \.self) { mouseButton in
                Button(mouseButton.displayName) {
                    onActionSelected(.mouseClick(mouseButton))
                }
            }

            Divider()

            ForEach(SystemAction.allCases, id: \.self) { systemAction in
                Button(systemAction.displayName) {
                    onActionSelected(.systemAction(systemAction))
                }
            }

            Divider()

            Button("Capture Keyboard Shortcut...") {
                onStartCapture(isHold)
            }

        } label: {
            HStack {
                Text(action.displayName)
                    .font(.system(size: 11))
                Spacer()
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 9))
                    .foregroundColor(.secondary)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Color.secondary.opacity(0.1))
            .cornerRadius(6)
        }
        .buttonStyle(.plain)
    }
}
