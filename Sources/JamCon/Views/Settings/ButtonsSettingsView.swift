import SwiftUI

/// Button mapping settings for a specific slot and device type
struct ButtonsSettingsView: View {
    @EnvironmentObject var appState: AppState
    let slot: DeviceSlot
    let deviceType: ConfigurableDeviceType
    @Binding var settings: DeviceTypeSettings
    @StateObject private var keyCaptureManager = KeyCaptureManager()

    var body: some View {
        VStack(spacing: 0) {
            // Header with hold delay and mirror toggle
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("Hold Delay:")
                    Slider(value: $settings.holdThreshold, in: 0.2...2.0)
                        .frame(width: 120)
                    Text(String(format: "%.1fs", settings.holdThreshold))
                        .font(.system(.body, design: .monospaced))
                        .foregroundColor(.secondary)
                        .frame(width: 40)
                }

                if deviceType == .leftJoyCon || deviceType == .rightJoyCon || deviceType == .proController {
                    Toggle("Mirror face buttons (D-pad acts as face buttons)", isOn: $settings.mirrorFaceButtons)
                }
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

                    // Button groups (filtered by device type)
                    ForEach(filteredButtonGroups, id: \.name) { group in
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
            settings.save(slot: slot, deviceType: deviceType)
            appState.syncInputSettings()
        }
    }

    // MARK: - Filtered Button Groups

    private var filteredButtonGroups: [(name: String, buttons: [LogicalButton])] {
        let availableButtons = Set(deviceType.availableButtons)
        return LogicalButton.buttonGroups.compactMap { group in
            let filtered = group.buttons.filter { availableButtons.contains($0) }
            return filtered.isEmpty ? nil : (name: group.name, buttons: filtered)
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
            Text(button.displayName(mirrored: settings.mirrorFaceButtons))
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
        let action = actionType == .press ? settings.buttonMappings[button].press : settings.buttonMappings[button].hold

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
            get: { settings.clutchButtons.contains(button) },
            set: { newValue in
                if newValue {
                    settings.clutchButtons.insert(button)
                } else {
                    settings.clutchButtons.remove(button)
                }
            }
        )) {
            EmptyView()
        }
        .toggleStyle(.checkbox)
        .help("Hold to clutch (freeze cursor) for repositioning")
    }

    private func scrollCell(for button: LogicalButton) -> some View {
        Toggle(isOn: Binding(
            get: { settings.scrollButtons.contains(button) },
            set: { newValue in
                if newValue {
                    settings.scrollButtons.insert(button)
                } else {
                    settings.scrollButtons.remove(button)
                }
            }
        )) {
            EmptyView()
        }
        .toggleStyle(.checkbox)
        .help("Hold to turn motion into scroll")
    }

    private func zoomCell(for button: LogicalButton) -> some View {
        Toggle(isOn: Binding(
            get: { settings.zoomButtons.contains(button) },
            set: { newValue in
                if newValue {
                    settings.zoomButtons.insert(button)
                } else {
                    settings.zoomButtons.remove(button)
                }
            }
        )) {
            EmptyView()
        }
        .toggleStyle(.checkbox)
        .help("Hold to zoom (vertical motion)")
    }

    // MARK: - Helpers

    private func setAction(_ action: ButtonAction, for button: LogicalButton, actionType: ActionType) {
        var actions = settings.buttonMappings[button]
        if actionType == .press {
            actions.press = action
        } else {
            actions.hold = action
        }
        settings.buttonMappings[button] = actions
    }

    private func resetMappingsToDefaults() {
        settings.buttonMappings = slot == .primary ? .defaultPrimary : .defaultSecondary
    }

    private func isOverrideButton(_ button: LogicalButton) -> Bool {
        settings.clutchButtons.contains(button) ||
        settings.scrollButtons.contains(button) ||
        settings.zoomButtons.contains(button)
    }
}

#Preview {
    NavigationStack {
        ButtonsSettingsView(
            slot: .primary,
            deviceType: .rightJoyCon,
            settings: .constant(DeviceTypeSettings())
        )
    }
    .frame(width: 600, height: 500)
}
