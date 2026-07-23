import SwiftUI

// MARK: - Buttons Tab

struct ButtonsTab: View {
    @ObservedObject var appState: AppState
    @StateObject private var keyCaptureManager = KeyCaptureManager()
    @StateObject private var joyConKeyCaptureManager = JoyConKeyCaptureManager()
    @StateObject private var g502xKeyCaptureManager = G502XKeyCaptureManager()

    private var isLeft: Bool { appState.configurationProfile.isLeft }
    private var controllerKind: ControllerKind { appState.configurationProfile.kind }

    var body: some View {
        VStack(spacing: 0) {
            ButtonProfileIndicator(appState: appState)

            ScrollView {
                switch controllerKind {
                case .joyCon:
                    VStack(spacing: 16) {
                        JoyConButtonMappingsSection(
                            appState: appState,
                            keyCaptureManager: joyConKeyCaptureManager,
                            profile: appState.configurationProfile
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

                case .mouse:
                    VStack(spacing: 16) {
                        G502XButtonMappingsSection(
                            appState: appState,
                            keyCaptureManager: g502xKeyCaptureManager
                        )

                        // Tip about unmapped buttons
                        HStack(alignment: .top, spacing: 8) {
                            Image(systemName: "info.circle")
                                .foregroundColor(.blue)
                            Text("Unmapped buttons (left, right, middle click) will pass through to apps normally. Only buttons with assigned actions are intercepted.")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        .padding()
                        .background(Color.blue.opacity(0.05))
                        .cornerRadius(8)
                    }
                    .padding()

                case .sense:
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
        }
        .navigationTitle("Buttons")
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
            g502xKeyCaptureManager.onCapture = { button, combo, isHold in
                if isHold {
                    appState.g502xButtonMappingProfile.setHoldAction(.keyPress(combo), for: button)
                } else {
                    appState.g502xButtonMappingProfile.setPressAction(.keyPress(combo), for: button)
                }
            }
        }
    }
}

// MARK: - Button Profile Indicator

private struct ButtonProfileIndicator: View {
    @ObservedObject var appState: AppState

    private var helperText: String {
        if appState.configurationProfile.kind == .joyCon {
            return "Button mappings are saved separately for each Joy-Con generation and side"
        }
        return appState.configurationProfile.kind.hasSides
            ? "Button mappings are saved separately for each controller side"
            : "Button mappings are saved separately per controller type"
    }

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "hand.raised")
                .foregroundColor(.green)
            VStack(alignment: .leading, spacing: 2) {
                Text("Configuring: \(appState.configurationProfile.displayName)")
                    .font(.caption.bold())
                Text(helperText)
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
            Spacer()
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
        .background(Color.green.opacity(0.05))
    }
}

// MARK: - Joy-Con Button Mappings Section

struct JoyConButtonMappingsSection: View {
    @ObservedObject var appState: AppState
    @ObservedObject var keyCaptureManager: JoyConKeyCaptureManager
    let profile: ControllerProfile

    private var mappableButtons: [JoyConLogicalButton] {
        JoyConLogicalButton.availableButtons(for: profile)
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

    deinit {
        stopCapture()
    }
}

// MARK: - G502X Button Mappings Section

struct G502XButtonMappingsSection: View {
    @ObservedObject var appState: AppState
    @ObservedObject var keyCaptureManager: G502XKeyCaptureManager

    // All G502X buttons
    private var mappableButtons: [G502XLogicalButton] {
        G502XLogicalButton.allCases
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("G502X Button Mappings")
                .font(.subheadline)
                .fontWeight(.medium)
                .foregroundColor(.secondary)

            HStack(spacing: 12) {
                Text("")
                    .frame(width: 90, alignment: .leading)
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
                    G502XButtonMappingRow(
                        button: button,
                        buttonName: button.displayName,
                        actions: appState.g502xButtonMappingProfile.actions(for: button),
                        isCapturing: keyCaptureManager.isCapturing(button: button),
                        modifiersDisplay: keyCaptureManager.modifiersDisplay,
                        onPressActionSelected: { action in
                            appState.g502xButtonMappingProfile.setPressAction(action, for: button)
                        },
                        onHoldActionSelected: { action in
                            appState.g502xButtonMappingProfile.setHoldAction(action, for: button)
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
                    Text(String(format: "%.1fs", appState.g502xButtonMappingProfile.holdThreshold))
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(.secondary)
                }

                HStack(spacing: 8) {
                    Text("0.1s")
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                    Slider(
                        value: Binding(
                            get: { appState.g502xButtonMappingProfile.holdThreshold },
                            set: { appState.g502xButtonMappingProfile.holdThreshold = $0 }
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

struct G502XButtonMappingRow: View {
    let button: G502XLogicalButton
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
                .frame(width: 90, alignment: .leading)

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

// MARK: - G502X Key Capture Manager

class G502XKeyCaptureManager: ObservableObject {
    @Published private(set) var capturingButton: G502XLogicalButton?
    @Published private(set) var isHoldCapture: Bool = false
    @Published private(set) var modifiersDisplay: String = ""

    var onCapture: ((G502XLogicalButton, KeyCombo, Bool) -> Void)?

    private var eventMonitor: Any?
    private var flagsMonitor: Any?

    func isCapturing(button: G502XLogicalButton) -> Bool {
        capturingButton == button
    }

    func startCapture(for button: G502XLogicalButton, isHold: Bool) {
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

    deinit {
        stopCapture()
    }
}
