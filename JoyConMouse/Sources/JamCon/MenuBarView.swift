import SwiftUI

struct MenuBarView: View {
    @EnvironmentObject private var appState: AppState
    @State private var showButtonMapping = false
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

            // Sensitivity settings
            sensitivitySection

            Divider()

            // Stabilization settings
            stabilizationSection

            Divider()

            // Button mapping
            buttonMappingSection

            Divider()

            // Footer with accessibility and quit
            footerSection
        }
        .padding()
        .frame(width: 280)
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

    // MARK: - Sensitivity Section

    private var sensitivitySection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Sensitivity")
                .font(.subheadline)
                .foregroundColor(.secondary)

            // Mouse sensitivity
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Mouse")
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
    }

    // MARK: - Stabilization Section

    private var stabilizationSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Stabilization")
                .font(.subheadline)
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
                Slider(value: $appState.smoothThreshold, in: 0...20, step: 1)
            }

            // Calibration status and button
            HStack {
                // Status indicator
                HStack(spacing: 4) {
                    Circle()
                        .fill(appState.isGyroCalibrated ? Color.green : Color.orange)
                        .frame(width: 8, height: 8)
                    Text(appState.isGyroCalibrated ? "Calibrated" : "Calibrating...")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                Spacer()

                // Recalibrate button
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

    // MARK: - Button Mapping Section

    private var buttonMappingSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Expandable header
            Button(action: { withAnimation { showButtonMapping.toggle() } }) {
                HStack {
                    Image(systemName: "keyboard")
                    Text("Button Mapping")
                        .font(.subheadline)
                    Spacer()
                    Image(systemName: showButtonMapping ? "chevron.up" : "chevron.down")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            .buttonStyle(.plain)
            .foregroundColor(.secondary)

            if showButtonMapping {
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
        HStack {
            Text(button.displayName)
                .font(.caption)
                .frame(width: 60, alignment: .leading)

            Spacer()

            actionMenu(for: button)
        }
    }

    private func actionMenu(for button: LogicalButton) -> some View {
        let currentAction = currentMapping[button]

        return Menu {
            Button("None") { setAction(.none, for: button) }

            Divider()

            Menu("Mouse") {
                Button("Left Click") { setAction(.mouseClick(.left), for: button) }
                Button("Right Click") { setAction(.mouseClick(.right), for: button) }
                Button("Middle Click") { setAction(.mouseClick(.middle), for: button) }
            }

            Divider()

            Menu("Keyboard") {
                Menu("Navigation") {
                    Button("Escape") { setAction(.keyPress(.escape), for: button) }
                    Button("Enter") { setAction(.keyPress(.enter), for: button) }
                    Button("Space") { setAction(.keyPress(.space), for: button) }
                    Button("Tab") { setAction(.keyPress(.tab), for: button) }
                    Button("Backspace") { setAction(.keyPress(.backspace), for: button) }
                }

                Menu("Arrows") {
                    Button("Up") { setAction(.keyPress(.arrowUp), for: button) }
                    Button("Down") { setAction(.keyPress(.arrowDown), for: button) }
                    Button("Left") { setAction(.keyPress(.arrowLeft), for: button) }
                    Button("Right") { setAction(.keyPress(.arrowRight), for: button) }
                }

                Menu("Shortcuts") {
                    Button("Copy") { setAction(.keyPress(.copy), for: button) }
                    Button("Paste") { setAction(.keyPress(.paste), for: button) }
                    Button("Cut") { setAction(.keyPress(.cut), for: button) }
                    Button("Undo") { setAction(.keyPress(.undo), for: button) }
                    Button("Redo") { setAction(.keyPress(.redo), for: button) }
                }
            }
        } label: {
            HStack(spacing: 4) {
                Text(currentAction.displayName)
                    .font(.caption)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.caption2)
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Color.secondary.opacity(0.1))
            .cornerRadius(4)
        }
        .menuStyle(.borderlessButton)
    }

    private var currentMapping: ButtonMappingProfile {
        switch selectedMappingRole {
        case .primary: return appState.primaryMapping
        case .secondary: return appState.secondaryMapping
        }
    }

    private func setAction(_ action: ButtonAction, for button: LogicalButton) {
        switch selectedMappingRole {
        case .primary:
            appState.primaryMapping[button] = action
        case .secondary:
            appState.secondaryMapping[button] = action
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
