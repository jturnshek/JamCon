import SwiftUI

// MARK: - Buttons Tab

struct ButtonsTab: View {
    @ObservedObject var appState: AppState
    @StateObject private var keyCaptureManager = KeyCaptureManager()
    @StateObject private var joyConKeyCaptureManager = JoyConKeyCaptureManager()

    private var isLeft: Bool { appState.isLeftController }
    private var isJoyCon: Bool { appState.activeControllerKind == .joyCon }

    var body: some View {
        VStack(spacing: 0) {
            TabHeader(appState: appState)

            ScrollView {
                if isJoyCon {
                    VStack(spacing: 16) {
                        JoyConButtonMappingsSection(
                            appState: appState,
                            keyCaptureManager: joyConKeyCaptureManager,
                            isLeft: isLeft
                        )

                        // Tip about Home button
                        HStack(alignment: .top, spacing: 8) {
                            Image(systemName: "info.circle")
                                .foregroundColor(.blue)
                            Text("If the Home button opens Launchpad, disable it in System Settings \u{2192} Game Controllers \u{2192} \"Press Home button to open Launchpad\"")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        .padding()
                        .background(Color.blue.opacity(0.05))
                        .cornerRadius(8)
                    }
                    .padding()
                } else {
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
            joyConKeyCaptureManager.onCapture = { button, combo, isHold in
                if isHold {
                    appState.joyConButtonMappingProfile.setHoldAction(.keyPress(combo), for: button)
                } else {
                    appState.joyConButtonMappingProfile.setPressAction(.keyPress(combo), for: button)
                }
            }
        }
    }
}

// MARK: - Joy-Con Button Mappings Section

struct JoyConButtonMappingsSection: View {
    @ObservedObject var appState: AppState
    @ObservedObject var keyCaptureManager: JoyConKeyCaptureManager
    let isLeft: Bool

    private var mappableButtons: [JoyConLogicalButton] {
        isLeft ? JoyConLogicalButton.leftButtons : JoyConLogicalButton.rightButtons
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Joy-Con Button Mappings")
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
                    JoyConButtonMappingRow(
                        button: button,
                        buttonName: button.displayName,
                        actions: appState.joyConButtonMappingProfile.actions(for: button),
                        isCapturing: keyCaptureManager.isCapturing(button: button),
                        modifiersDisplay: keyCaptureManager.modifiersDisplay,
                        onPressActionSelected: { action in
                            appState.joyConButtonMappingProfile.setPressAction(action, for: button)
                        },
                        onHoldActionSelected: { action in
                            appState.joyConButtonMappingProfile.setHoldAction(action, for: button)
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

            // Hold threshold
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Hold Threshold")
                        .font(.system(size: 12, weight: .medium))
                    Spacer()
                    Text(String(format: "%.1fs", appState.joyConButtonMappingProfile.holdThreshold))
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(.secondary)
                }

                HStack(spacing: 8) {
                    Text("0.1s")
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                    Slider(
                        value: Binding(
                            get: { appState.joyConButtonMappingProfile.holdThreshold },
                            set: { appState.joyConButtonMappingProfile.holdThreshold = $0 }
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

struct JoyConButtonMappingRow: View {
    let button: JoyConLogicalButton
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

// MARK: - Joy-Con Key Capture Manager

class JoyConKeyCaptureManager: ObservableObject {
    @Published private(set) var capturingButton: JoyConLogicalButton?
    @Published private(set) var isHoldCapture: Bool = false
    @Published private(set) var modifiersDisplay: String = ""

    var onCapture: ((JoyConLogicalButton, KeyCombo, Bool) -> Void)?

    private var eventMonitor: Any?
    private var flagsMonitor: Any?

    func isCapturing(button: JoyConLogicalButton) -> Bool {
        capturingButton == button
    }

    func startCapture(for button: JoyConLogicalButton, isHold: Bool) {
        capturingButton = button
        isHoldCapture = isHold
        modifiersDisplay = "Press a key..."

        // Monitor key events
        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self = self, let button = self.capturingButton else { return event }

            // Convert NSEvent.ModifierFlags to CGEventFlags
            var cgFlags: CGEventFlags = []
            let nsFlags = event.modifierFlags
            if nsFlags.contains(.control) { cgFlags.insert(.maskControl) }
            if nsFlags.contains(.option) { cgFlags.insert(.maskAlternate) }
            if nsFlags.contains(.shift) { cgFlags.insert(.maskShift) }
            if nsFlags.contains(.command) { cgFlags.insert(.maskCommand) }

            let combo = KeyCombo(keyCode: event.keyCode, modifiers: cgFlags)
            self.onCapture?(button, combo, self.isHoldCapture)
            self.stopCapture()
            return nil
        }

        // Monitor modifier changes for display
        flagsMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            guard let self = self else { return event }
            let flags = event.modifierFlags
            var parts: [String] = []
            if flags.contains(.control) { parts.append("⌃") }
            if flags.contains(.option) { parts.append("⌥") }
            if flags.contains(.shift) { parts.append("⇧") }
            if flags.contains(.command) { parts.append("⌘") }
            self.modifiersDisplay = parts.isEmpty ? "Press a key..." : parts.joined() + "..."
            return event
        }
    }

    func cancelCapture() {
        stopCapture()
    }

    private func stopCapture() {
        if let monitor = eventMonitor {
            NSEvent.removeMonitor(monitor)
            eventMonitor = nil
        }
        if let monitor = flagsMonitor {
            NSEvent.removeMonitor(monitor)
            flagsMonitor = nil
        }
        capturingButton = nil
        modifiersDisplay = ""
    }
}
