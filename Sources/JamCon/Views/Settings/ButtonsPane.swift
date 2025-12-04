import SwiftUI

struct ButtonsPane: View {
    @EnvironmentObject var appState: AppState
    @StateObject private var keyCaptureManager = KeyCaptureManager()
    @State private var selectedRole: MappingRole = .primary

    enum MappingRole: String, CaseIterable {
        case primary = "Primary"
        case secondary = "Secondary"
    }

    var body: some View {
        VStack(spacing: 0) {
            // Role picker and settings header
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("Controller Role:")
                    Picker("", selection: $selectedRole) {
                        ForEach(MappingRole.allCases, id: \.self) { role in
                            Text(role.rawValue).tag(role)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    .frame(width: 200)

                    Spacer()

                    Text("Hold Delay:")
                    Slider(value: $appState.holdThreshold, in: 0.2...2.0)
                        .frame(width: 120)
                    Text(String(format: "%.1fs", appState.holdThreshold))
                        .font(.system(.body, design: .monospaced))
                        .foregroundColor(.secondary)
                        .frame(width: 40)
                }

                Toggle("Mirror face buttons (D-pad acts as face buttons)", isOn: $appState.mirrorFaceButtons)
            }
            .padding()

            Divider()

            // Button mappings table
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    // Header row
                    buttonMappingHeader
                        .padding(.horizontal)
                        .padding(.vertical, 8)
                        .background(Color(nsColor: .controlBackgroundColor))

                    Divider()

                    // Button groups
                    ForEach(LogicalButton.buttonGroups, id: \.name) { group in
                        buttonGroupView(group)
                    }
                }
            }

            Divider()

            // Footer with reset button
            HStack {
                Spacer()
                Button("Reset to Defaults") {
                    resetMappingsToDefaults()
                }
                .buttonStyle(.bordered)
            }
            .padding()
        }
        .navigationTitle("Buttons")
        .onAppear {
            keyCaptureManager.onCapture = { button, actionType, combo in
                setAction(.keyPress(combo), for: button, actionType: actionType)
            }
        }
        .onDisappear {
            keyCaptureManager.cancelCapture()
        }
        .onChange(of: selectedRole) { _, _ in
            keyCaptureManager.cancelCapture()
        }
    }

    // MARK: - Table Components

    private var buttonMappingHeader: some View {
        HStack(spacing: 8) {
            Text("Button")
                .fontWeight(.medium)
                .frame(width: 80, alignment: .leading)
            Text("Press")
                .fontWeight(.medium)
                .frame(maxWidth: .infinity)
            Text("Hold")
                .fontWeight(.medium)
                .frame(maxWidth: .infinity)
            Text("Clutch")
                .fontWeight(.medium)
                .frame(width: 50, alignment: .center)
            Text("Scroll")
                .fontWeight(.medium)
                .frame(width: 50, alignment: .center)
            Text("Zoom")
                .fontWeight(.medium)
                .frame(width: 50, alignment: .center)
        }
        .font(.caption)
        .foregroundColor(.secondary)
    }

    private func buttonGroupView(_ group: (name: String, buttons: [LogicalButton])) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(group.name)
                .font(.caption)
                .fontWeight(.semibold)
                .foregroundColor(.secondary)
                .padding(.horizontal)
                .padding(.vertical, 6)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.secondary.opacity(0.05))

            ForEach(group.buttons, id: \.rawValue) { button in
                buttonMappingRow(button)
                    .padding(.horizontal)
                    .padding(.vertical, 4)

                if button != group.buttons.last {
                    Divider()
                        .padding(.leading)
                }
            }
        }
    }

    private func buttonMappingRow(_ button: LogicalButton) -> some View {
        HStack(spacing: 8) {
            Text(button.displayName(mirrored: appState.mirrorFaceButtons))
                .frame(width: 80, alignment: .leading)

            actionCell(for: button, actionType: .press)
                .frame(maxWidth: .infinity)
                .disabled(isOverrideButton(button))

            actionCell(for: button, actionType: .hold)
                .frame(maxWidth: .infinity)
                .disabled(isOverrideButton(button))

            clutchCell(for: button)
                .frame(width: 50, alignment: .center)

            scrollCell(for: button)
                .frame(width: 50, alignment: .center)

            zoomCell(for: button)
                .frame(width: 50, alignment: .center)
        }
        .font(.callout)
    }

    // MARK: - Action Cells

    @ViewBuilder
    private func actionCell(for button: LogicalButton, actionType: ActionType) -> some View {
        if keyCaptureManager.isCapturing(button: button, actionType: actionType) {
            keyCaptureView
        } else {
            actionDisplayCell(for: button, actionType: actionType)
        }
    }

    private var keyCaptureView: some View {
        HStack(spacing: 4) {
            if keyCaptureManager.currentModifiers.isEmpty {
                Text("Press keys...")
                    .font(.caption)
                    .foregroundColor(.secondary)
            } else {
                Text(keyCaptureManager.currentModifiers.displayString)
                    .font(.caption)
            }

            Button {
                keyCaptureManager.cancelCapture()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(Color.accentColor.opacity(0.2))
        .cornerRadius(4)
    }

    private func actionDisplayCell(for button: LogicalButton, actionType: ActionType) -> some View {
        let actions = currentMapping[button]
        let action = actionType == .press ? actions.press : actions.hold

        return HStack(spacing: 4) {
            Button {
                keyCaptureManager.startCapture(for: button, actionType: actionType)
            } label: {
                HStack(spacing: 2) {
                    Image(systemName: "keyboard")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                    Text(action.displayName)
                        .font(.caption)
                        .lineLimit(1)
                }
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 4)
            .padding(.vertical, 2)
            .background(Color.secondary.opacity(0.1))
            .cornerRadius(4)

            if action != .none {
                Button {
                    setAction(.none, for: button, actionType: actionType)
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
            }

            Menu {
                Section("Mouse") {
                    Button("Left Click") { setAction(.mouseClick(.left), for: button, actionType: actionType) }
                    Button("Right Click") { setAction(.mouseClick(.right), for: button, actionType: actionType) }
                    Button("Middle Click") { setAction(.mouseClick(.middle), for: button, actionType: actionType) }
                }
                Section("System") {
                    Button("Mission Control") { setAction(.systemAction(.missionControl), for: button, actionType: actionType) }
                    Button("Launchpad") { setAction(.systemAction(.launchpad), for: button, actionType: actionType) }
                    Button("Show Desktop") { setAction(.systemAction(.showDesktop), for: button, actionType: actionType) }
                    Button("App Switcher") { setAction(.systemAction(.appSwitcher), for: button, actionType: actionType) }
                    Button("Play/Pause") { setAction(.systemAction(.playPause), for: button, actionType: actionType) }
                }
            } label: {
                Image(systemName: "plus.circle")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
        }
    }

    // MARK: - Override Cells

    private func clutchCell(for button: LogicalButton) -> some View {
        Toggle(isOn: Binding(
            get: { isClutchButton(button) },
            set: { newValue in setClutchButton(newValue ? button : nil) }
        )) {
            EmptyView()
        }
        .toggleStyle(.checkbox)
        .help("Hold to clutch (freeze cursor) so you can reposition the controller")
    }

    private func scrollCell(for button: LogicalButton) -> some View {
        Toggle(isOn: Binding(
            get: { isScrollButton(button) },
            set: { newValue in setScrollButton(newValue ? button : nil) }
        )) {
            EmptyView()
        }
        .toggleStyle(.checkbox)
        .help("Hold to turn motion into scroll (X/Y)")
    }

    private func zoomCell(for button: LogicalButton) -> some View {
        Toggle(isOn: Binding(
            get: { isZoomButton(button) },
            set: { newValue in setZoomButton(newValue ? button : nil) }
        )) {
            EmptyView()
        }
        .toggleStyle(.checkbox)
        .help("Hold to zoom (vertical motion)")
    }

    // MARK: - Mapping Helpers

    private var currentMapping: ButtonMappingProfile {
        switch selectedRole {
        case .primary: return appState.primaryMapping
        case .secondary: return appState.secondaryMapping
        }
    }

    private func setAction(_ action: ButtonAction, for button: LogicalButton, actionType: ActionType) {
        switch selectedRole {
        case .primary:
            var actions = appState.primaryMapping[button]
            if actionType == .press {
                actions.press = action
            } else {
                actions.hold = action
            }
            appState.primaryMapping[button] = actions
        case .secondary:
            var actions = appState.secondaryMapping[button]
            if actionType == .press {
                actions.press = action
            } else {
                actions.hold = action
            }
            appState.secondaryMapping[button] = actions
        }
    }

    private func resetMappingsToDefaults() {
        switch selectedRole {
        case .primary:
            appState.primaryMapping = .defaultPrimary
        case .secondary:
            appState.secondaryMapping = .defaultSecondary
        }
    }

    // MARK: - Override Helpers

    private var currentClutchButtons: Set<LogicalButton> {
        get {
            switch selectedRole {
            case .primary: return appState.primaryClutchButtons
            case .secondary: return appState.secondaryClutchButtons
            }
        }
        nonmutating set {
            switch selectedRole {
            case .primary: appState.primaryClutchButtons = newValue
            case .secondary: appState.secondaryClutchButtons = newValue
            }
        }
    }

    private var currentScrollButtons: Set<LogicalButton> {
        get {
            switch selectedRole {
            case .primary: return appState.primaryScrollButtons
            case .secondary: return appState.secondaryScrollButtons
            }
        }
        nonmutating set {
            switch selectedRole {
            case .primary: appState.primaryScrollButtons = newValue
            case .secondary: appState.secondaryScrollButtons = newValue
            }
        }
    }

    private var currentZoomButtons: Set<LogicalButton> {
        get {
            switch selectedRole {
            case .primary: return appState.primaryZoomButtons
            case .secondary: return appState.secondaryZoomButtons
            }
        }
        nonmutating set {
            switch selectedRole {
            case .primary: appState.primaryZoomButtons = newValue
            case .secondary: appState.secondaryZoomButtons = newValue
            }
        }
    }

    private func isClutchButton(_ button: LogicalButton) -> Bool {
        currentClutchButtons.contains(button)
    }

    private func setClutchButton(_ button: LogicalButton?) {
        keyCaptureManager.cancelCapture()
        var buttons = currentClutchButtons
        if let button {
            buttons.insert(button)
        } else {
            buttons.removeAll()
        }
        currentClutchButtons = buttons
    }

    private func isScrollButton(_ button: LogicalButton) -> Bool {
        currentScrollButtons.contains(button)
    }

    private func setScrollButton(_ button: LogicalButton?) {
        keyCaptureManager.cancelCapture()
        var buttons = currentScrollButtons
        if let button {
            buttons.insert(button)
        } else {
            buttons.removeAll()
        }
        currentScrollButtons = buttons
    }

    private func isZoomButton(_ button: LogicalButton) -> Bool {
        currentZoomButtons.contains(button)
    }

    private func setZoomButton(_ button: LogicalButton?) {
        keyCaptureManager.cancelCapture()
        var buttons = currentZoomButtons
        if let button {
            buttons.insert(button)
        } else {
            buttons.removeAll()
        }
        currentZoomButtons = buttons
    }

    private func isOverrideButton(_ button: LogicalButton) -> Bool {
        isClutchButton(button) || isScrollButton(button) || isZoomButton(button)
    }
}

#Preview {
    ButtonsPane()
        .environmentObject(AppState())
        .frame(width: 600, height: 500)
}
