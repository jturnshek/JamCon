import SwiftUI

struct MenuBarView: View {
    @EnvironmentObject private var appState: AppState
    @StateObject private var keyCaptureManager = KeyCaptureManager()
    @State private var showMouseSection = false
    @State private var showButtonsSection = false
    @State private var selectedMappingRole: MappingRole = .primary

    enum MappingRole: String, CaseIterable {
        case primary = "Primary"
        case secondary = "Secondary"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Accessibility permission warning
            if !appState.hasAccessibilityPermission {
                accessibilityWarning
            }

            // Header with connection status
            headerSection

            Divider()

            // Enable/Disable toggle
            toggleSection

            Divider()

            // Collapsible Mouse section
            mouseSection

            Divider()

            // Collapsible Buttons section
            buttonsSection

            Divider()

            // Footer with quit
            footerSection
        }
        .padding()
        .frame(width: 420)
        .onAppear {
            keyCaptureManager.onCapture = { button, actionType, combo in
                setAction(.keyPress(combo), for: button, actionType: actionType)
            }
        }
        .onDisappear {
            keyCaptureManager.cancelCapture()
        }
        .onChange(of: selectedMappingRole) { _, _ in
            keyCaptureManager.cancelCapture()
        }
        .onChange(of: showButtonsSection) { _, newValue in
            if !newValue {
                keyCaptureManager.cancelCapture()
            }
        }
    }

    // MARK: - Accessibility Warning

    private var accessibilityWarning: some View {
        VStack(spacing: 6) {
            HStack {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundColor(.orange)
                Text("Accessibility Required")
                    .font(.headline)
            }

            Text("You may need to manually add this app in Settings.")
                .font(.caption)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)

            Button(action: appState.openAccessibilitySettings) {
                Text("Open Accessibility Settings")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
        .padding()
        .frame(maxWidth: .infinity)
        .background(Color.orange.opacity(0.1))
        .cornerRadius(8)
    }

    // MARK: - Header Section

    private var headerSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            if appState.connectedControllers.isEmpty {
                // No controllers connected
                HStack {
                    Image(systemName: "gamecontroller")
                        .font(.title2)
                        .foregroundColor(.secondary)

                    VStack(alignment: .leading, spacing: 2) {
                        Text("No Controller")
                            .font(.headline)
                        Text("Pair via Bluetooth Settings")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }

                    Spacer()
                }
            } else {
                // Show all connected controllers
                ForEach(appState.connectedControllers) { controller in
                    controllerRow(controller)
                }
            }
        }
    }

    private func controllerRow(_ controller: ConnectedController) -> some View {
        let isPrimary = controller.id == appState.primaryController?.id
        let (batteryImage, batteryColor) = batteryIconInfo(for: controller.batteryLevel)

        return HStack {
            Image(systemName: isPrimary ? "gamecontroller.fill" : "gamecontroller")
                .font(.title2)
                .foregroundColor(isPrimary ? .green : .secondary)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Text(controller.type.rawValue)
                        .font(.headline)
                    if isPrimary {
                        Text("Primary")
                            .font(.caption2)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .background(Color.green.opacity(0.2))
                            .foregroundColor(.green)
                            .cornerRadius(3)
                    }
                }

                HStack(spacing: 4) {
                    Image(systemName: batteryImage)
                        .font(.caption)
                        .foregroundColor(batteryColor)
                    Text(controller.batteryLevel.rawValue)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }

            Spacer()

            // Set as primary button (only show if not already primary and multiple controllers)
            if !isPrimary && appState.connectedControllers.count > 1 {
                Button(action: { appState.setPrimaryControllerType(controller.type) }) {
                    Text("Set Primary")
                        .font(.caption)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
    }

    private func batteryIconInfo(for level: BatteryLevel) -> (String, Color) {
        switch level {
        case .full:
            return ("battery.100", .green)
        case .medium:
            return ("battery.75", .green)
        case .low:
            return ("battery.25", .yellow)
        case .critical, .empty:
            return ("battery.0", .red)
        case .unknown:
            return ("battery.0", .secondary)
        }
    }

    // MARK: - Toggle Section

    private var toggleSection: some View {
        Toggle(isOn: $appState.isEnabled) {
            HStack {
                Image(systemName: appState.isEnabled ? "cursorarrow.motionlines" : "cursorarrow")
                Text("Mouse Control")
            }
        }
        .toggleStyle(.switch)
        .disabled(!appState.isConnected)
    }

    // MARK: - Mouse Section (Collapsible)

    private var mouseSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Expandable header
            Button(action: { withAnimation { showMouseSection.toggle() } }) {
                HStack {
                    Image(systemName: "cursorarrow.motionlines")
                    Text("Mouse")
                        .font(.subheadline)
                    Spacer()
                    Image(systemName: showMouseSection ? "chevron.up" : "chevron.down")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            .buttonStyle(.plain)
            .foregroundColor(.secondary)

            if showMouseSection {
                // Sensitivity subsection
                VStack(alignment: .leading, spacing: 8) {
                    Text("Sensitivity")
                        .font(.caption)
                        .foregroundColor(.secondary)

                    // Mouse sensitivity
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text("Speed")
                                .font(.caption)
                            Spacer()
                            Text(String(format: "%.0f", appState.gyroSensitivity))
                                .font(.caption)
                                .foregroundColor(.secondary)
                                .frame(width: 30, alignment: .trailing)
                        }
                        Slider(value: $appState.gyroSensitivity, in: 1...50, step: 1)
                    }

                    // Scroll sensitivity
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text("Scroll")
                                .font(.caption)
                            Spacer()
                            Text(String(format: "%.0f", appState.scrollSensitivity))
                                .font(.caption)
                                .foregroundColor(.secondary)
                                .frame(width: 30, alignment: .trailing)
                        }
                        Slider(value: $appState.scrollSensitivity, in: 1...20, step: 1)
                    }
                }

                Divider()

                // Stabilization subsection
                VStack(alignment: .leading, spacing: 8) {
                    Text("Stabilization")
                        .font(.caption)
                        .foregroundColor(.secondary)

                    // Smoothing threshold
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text("Smoothing")
                                .font(.caption)
                            Spacer()
                            Text(appState.smoothThreshold == 0 ? "Off" : String(format: "%.0f", appState.smoothThreshold))
                                .font(.caption)
                                .foregroundColor(.secondary)
                                .frame(width: 30, alignment: .trailing)
                        }
                        Slider(value: $appState.smoothThreshold, in: 0...50, step: 1)
                    }

                    // Calibration status and button
                    HStack {
                        HStack(spacing: 4) {
                            Circle()
                                .fill(appState.isGyroCalibrated ? Color.green : Color.orange)
                                .frame(width: 8, height: 8)
                            Text(appState.isGyroCalibrated ? "Calibrated" : "Calibrating...")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }

                        Spacer()

                        Button(action: appState.resetGyroCalibration) {
                            Text("Recalibrate")
                                .font(.caption)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .disabled(!appState.isConnected)
                    }

                    Text("Hold controller still to calibrate")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
            }
        }
    }

    // MARK: - Buttons Section (Collapsible)

    private var buttonsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Expandable header
            Button(action: { withAnimation { showButtonsSection.toggle() } }) {
                HStack {
                    Image(systemName: "keyboard")
                    Text("Buttons")
                        .font(.subheadline)
                    Spacer()
                    Image(systemName: showButtonsSection ? "chevron.up" : "chevron.down")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            .buttonStyle(.plain)
            .foregroundColor(.secondary)

            if showButtonsSection {
                // Hold delay slider
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("Hold Delay")
                            .font(.caption)
                        Spacer()
                        Text(String(format: "%.1fs", appState.holdThreshold))
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .frame(width: 30, alignment: .trailing)
                    }
                    Slider(value: $appState.holdThreshold, in: 0.2...2.0, step: 0.1)
                }

                Divider()

                // Mirror toggle
                Toggle(isOn: $appState.mirrorFaceButtons) {
                    Text("Mirror face buttons")
                        .font(.caption)
                }
                .toggleStyle(.switch)
                .controlSize(.small)

                Text("When on, D-pad acts as face buttons")
                    .font(.caption2)
                    .foregroundColor(.secondary)

                // Role picker
                Picker("Role", selection: $selectedMappingRole) {
                    ForEach(MappingRole.allCases, id: \.self) { role in
                        Text(role.rawValue).tag(role)
                    }
                }
                .pickerStyle(.segmented)
                .padding(.vertical, 4)

                // Column headers
                buttonMappingHeader

                // Button mappings
                ForEach(LogicalButton.buttonGroups, id: \.name) { group in
                    buttonGroupView(group)
                }

                // Reset button
                Button("Reset to Defaults") {
                    resetMappingsToDefaults()
                }
                .font(.caption)
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
    }

    private var buttonMappingHeader: some View {
        HStack(spacing: 8) {
            Text("Button")
                .font(.caption)
                .fontWeight(.medium)
                .frame(width: 70, alignment: .leading)
            Text("Press")
                .font(.caption)
                .fontWeight(.medium)
                .frame(maxWidth: .infinity)
            Text("Hold")
                .font(.caption)
                .fontWeight(.medium)
                .frame(maxWidth: .infinity)
        }
        .foregroundColor(.secondary)
        .padding(.bottom, 2)
    }

    private func buttonGroupView(_ group: (name: String, buttons: [LogicalButton])) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(group.name)
                .font(.caption)
                .foregroundColor(.secondary)

            ForEach(group.buttons, id: \.rawValue) { button in
                buttonMappingRow(button)
            }
        }
    }

    private func buttonMappingRow(_ button: LogicalButton) -> some View {
        HStack(spacing: 8) {
            Text(button.displayName(mirrored: appState.mirrorFaceButtons))
                .font(.caption)
                .frame(width: 70, alignment: .leading)

            actionCell(for: button, actionType: .press)
            actionCell(for: button, actionType: .hold)
        }
    }

    @ViewBuilder
    private func actionCell(for button: LogicalButton, actionType: ActionType) -> some View {
        if keyCaptureManager.isCapturing(button: button, actionType: actionType) {
            keyCaptureView
                .frame(maxWidth: .infinity)
        } else {
            actionDisplayCell(for: button, actionType: actionType)
                .frame(maxWidth: .infinity)
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

            Button(action: { keyCaptureManager.cancelCapture() }) {
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

        return HStack(spacing: 2) {
            // Click to capture keyboard shortcut
            Button(action: {
                keyCaptureManager.startCapture(for: button, actionType: actionType)
            }) {
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

            // Clear button (only show if action is not .none)
            if action != .none {
                Button(action: { setAction(.none, for: button, actionType: actionType) }) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
            }

            // Mouse click dropdown
            Menu {
                Button("Left Click") { setAction(.mouseClick(.left), for: button, actionType: actionType) }
                Button("Right Click") { setAction(.mouseClick(.right), for: button, actionType: actionType) }
                Button("Middle Click") { setAction(.mouseClick(.middle), for: button, actionType: actionType) }
            } label: {
                Image(systemName: "computermouse")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
            .menuStyle(.borderlessButton)
            .frame(width: 16)
        }
    }

    private var currentMapping: ButtonMappingProfile {
        switch selectedMappingRole {
        case .primary: return appState.primaryMapping
        case .secondary: return appState.secondaryMapping
        }
    }

    private func setAction(_ action: ButtonAction, for button: LogicalButton, actionType: ActionType) {
        switch selectedMappingRole {
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
        switch selectedMappingRole {
        case .primary:
            appState.primaryMapping = .defaultPrimary
        case .secondary:
            appState.secondaryMapping = .defaultSecondary
        }
    }

    // MARK: - Footer Section

    private var footerSection: some View {
        Button(action: appState.quit) {
            HStack {
                Image(systemName: "power")
                Text("Quit JamCon")
                Spacer()
            }
        }
        .buttonStyle(.plain)
        .foregroundColor(.red)
    }
}

#Preview {
    MenuBarView()
        .environmentObject(AppState())
}
