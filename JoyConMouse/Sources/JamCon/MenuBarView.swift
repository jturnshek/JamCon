import SwiftUI
import AppKit

struct MenuBarView: View {
    @EnvironmentObject private var appState: AppState
    @StateObject private var keyCaptureManager = KeyCaptureManager()
    @State private var showPointerSection = false
    @State private var showButtonMappingsSection = false
    @State private var showDebugSection = false
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

            // Top-level controls (always visible)
            topLevelControls

            Divider()

            // Collapsible Pointer Controls section
            pointerSection

            Divider()

            // Collapsible Button Mappings section
            buttonMappingsSection

            Divider()

            // Debug section
            debugSection

            Divider()

            // Footer with quit
            footerSection
        }
        .padding()
        .frame(width: 480)
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
        .onChange(of: showButtonMappingsSection) { _, newValue in
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
        let leftController = appState.connectedControllers.first { $0.type == .leftJoyCon }
        let rightController = appState.connectedControllers.first { $0.type == .rightJoyCon || $0.type == .proController }

        return VStack(spacing: 4) {
            // Left Joy-Con row
            controllerRow(type: .leftJoyCon, controller: leftController)
            // Right Joy-Con row
            controllerRow(type: .rightJoyCon, controller: rightController)
        }
    }

    private func controllerRow(type: ControllerType, controller: ConnectedController?) -> some View {
        let isConnected = controller != nil
        let isPrimary = controller?.id == appState.primaryController?.id
        let deviceName = controller?.name ?? type.rawValue

        return HStack {
            joyConIcon(type: type, isConnected: isConnected)
                .padding(.trailing, 4)
            Text(deviceName)

            if let controller = controller {
                let (batteryImage, batteryColor) = batteryIconInfo(for: controller.batteryLevel)
                Image(systemName: batteryImage)
                    .foregroundColor(batteryColor)
            }

            if isPrimary {
                Text("Primary")
                    .font(.caption2)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 2)
                    .background(Color.green.opacity(0.2))
                    .foregroundColor(.green)
                    .cornerRadius(3)
            }

            Spacer()
        }
        .foregroundColor(isConnected ? .primary : .secondary)
    }

    private func controllerRow(_ controller: ConnectedController) -> some View {
        let isPrimary = controller.id == appState.primaryController?.id
        let (batteryImage, batteryColor) = batteryIconInfo(for: controller.batteryLevel)

        return HStack {
            joyConIcon(type: controller.type, isConnected: true, isPrimary: isPrimary)

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

    @ViewBuilder
    private func joyConIcon(type: ControllerType, isConnected: Bool, isPrimary: Bool = false) -> some View {
        let imageName = type == .leftJoyCon ? "joyconR" : "joyconL"

        if let nsImage = loadJoyConImage(imageName) {
            Image(nsImage: nsImage)
                .renderingMode(.template)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(height: 17)
                .rotationEffect(.degrees(-90))  // 90° clockwise for both
                .foregroundColor(isConnected ? .green : .secondary)
                .opacity(isConnected ? 1.0 : 0.25)
        } else {
            // Fallback to SF Symbol if image not found
            Image(systemName: "gamecontroller")
                .font(.largeTitle)
                .foregroundColor(isConnected ? .green : .secondary)
                .opacity(isConnected ? 1.0 : 0.25)
        }
    }

    private func loadJoyConImage(_ name: String) -> NSImage? {
        if let url = Bundle.main.url(forResource: name, withExtension: "png") {
            return NSImage(contentsOf: url)
        }
        return nil
    }

    // MARK: - Top Level Controls

    private var topLevelControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Mouse Control toggle
            Toggle(isOn: $appState.isEnabled) {
                HStack {
                    Image(systemName: appState.isEnabled ? "cursorarrow.motionlines" : "cursorarrow")
                    Text("Mouse Control")
                }
            }
            .toggleStyle(.switch)
            .disabled(!appState.isConnected)

            // Calibration status
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

            Divider()

            // Auto power-off
            VStack(alignment: .leading, spacing: 4) {
                Toggle(isOn: $appState.autoPowerOffEnabled) {
                    Text("Auto power-off")
                        .font(.caption)
                }
                .toggleStyle(.switch)
                .controlSize(.small)

                if appState.autoPowerOffEnabled {
                    HStack {
                        Text("Idle timeout")
                            .font(.caption)
                        Spacer()
                        Text(String(format: "%.0f min", appState.idleTimeoutMinutes))
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .frame(width: 50, alignment: .trailing)
                    }
                    Slider(value: $appState.idleTimeoutMinutes, in: 1...120, step: 1)
                }

                Text("Turns controllers off after inactivity")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
        }
    }

    // MARK: - Pointer Controls Section (Collapsible)

    private var pointerSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Expandable header
            Button(action: { withAnimation { showPointerSection.toggle() } }) {
                HStack {
                    Image(systemName: "cursorarrow.motionlines")
                    Text("Pointer Controls")
                        .font(.subheadline)
                    Spacer()
                    Image(systemName: showPointerSection ? "chevron.up" : "chevron.down")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            .buttonStyle(.plain)
            .contentShape(Rectangle())
            .foregroundColor(.secondary)

            if showPointerSection {
                // Speed (gyro sensitivity)
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("Speed")
                            .font(.caption)
                        Spacer()
                        Text(String(format: "%.0f", appState.gyroSensitivity))
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .frame(width: 36, alignment: .trailing)
                    }
                    Slider(value: $appState.gyroSensitivity, in: 1...200, step: 1)
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
                            .frame(width: 36, alignment: .trailing)
                    }
                    Slider(value: $appState.scrollSensitivity, in: 1...40, step: 1)
                }

                // Jitter Filter
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("Jitter Filter")
                            .font(.caption)
                        Spacer()
                        Text(appState.smoothThreshold == 0 ? "Off" : String(format: "%.0f", appState.smoothThreshold))
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .frame(width: 30, alignment: .trailing)
                    }
                    Slider(value: $appState.smoothThreshold, in: 0...50, step: 1)
                    Text("Higher = smoother when moving slowly; too high can feel floaty.")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }

                Divider()

                // Acceleration
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("Acceleration")
                            .font(.caption)
                        Spacer()
                        Text(String(format: "%.1fx", 1.0 + appState.accelerationGain))
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .frame(width: 52, alignment: .trailing)
                    }
                    Slider(value: $appState.accelerationGain, in: 0...200, step: 0.1)
                    Text("Boosts speed for fast wrist flicks while leaving fine aim unchanged.")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }

                // Precision Zone toggle
                Toggle(isOn: $appState.precisionZoneEnabled) {
                    Text("Precision Zone")
                        .font(.caption)
                }
                .toggleStyle(.switch)
                .controlSize(.small)

                Text("Slows cursor at low speeds for fine aiming")
                    .font(.caption2)
                    .foregroundColor(.secondary)

                // Early Ramp toggle
                Toggle(isOn: $appState.earlyRampEnabled) {
                    Text("Early Ramp")
                        .font(.caption)
                }
                .toggleStyle(.switch)
                .controlSize(.small)

                Text("Reaches top acceleration gain sooner")
                    .font(.caption2)
                    .foregroundColor(.secondary)

                Divider()

                // Filter Responsiveness
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("Filter Responsiveness")
                            .font(.caption)
                        Spacer()
                        Text(String(format: "%.2f", appState.filterBeta))
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .frame(width: 40, alignment: .trailing)
                    }
                    Slider(value: $appState.filterBeta, in: 0...1.0, step: 0.01)
                    Text("Higher = drops smoothing sooner during motion; lower = steadier but can add lag.")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }

                // Adaptive Smoothing
                HStack {
                    Text("Adaptive Smoothing")
                        .font(.caption)
                    Spacer()
                    Picker("", selection: $appState.adaptiveSmoothingMode) {
                        ForEach(AdaptiveSmoothingMode.allCases, id: \.self) { mode in
                            Text(mode.displayName).tag(mode)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                }
            }
        }
    }

    // MARK: - Button Mappings Section (Collapsible)

    private var buttonMappingsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Expandable header
            Button(action: { withAnimation { showButtonMappingsSection.toggle() } }) {
                HStack {
                    Image(systemName: "keyboard")
                    Text("Button Mappings")
                        .font(.subheadline)
                    Spacer()
                    Image(systemName: showButtonMappingsSection ? "chevron.up" : "chevron.down")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            .buttonStyle(.plain)
            .contentShape(Rectangle())
            .foregroundColor(.secondary)

            if showButtonMappingsSection {
                // Role picker
                Picker("Role", selection: $selectedMappingRole) {
                    ForEach(MappingRole.allCases, id: \.self) { role in
                        Text(role.rawValue).tag(role)
                    }
                }
                .pickerStyle(.segmented)
                .padding(.vertical, 4)

                // Hold delay slider
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("Hold Delay")
                            .font(.caption)
                        Spacer()
                        Text(String(format: "%.1fs", appState.holdThreshold))
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .frame(width: 36, alignment: .trailing)
                    }
                    Slider(value: $appState.holdThreshold, in: 0.2...2.0, step: 0.1)
                    Text("Time before a press becomes a hold action")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }

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

                Divider()

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

    // MARK: - Debug Section (Collapsible)

    private var debugSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button(action: { withAnimation { showDebugSection.toggle() } }) {
                HStack {
                    Image(systemName: "waveform.path.ecg")
                    Text("Debug")
                        .font(.subheadline)
                    Spacer()
                    Image(systemName: showDebugSection ? "chevron.up" : "chevron.down")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            .buttonStyle(.plain)
            .contentShape(Rectangle())
            .foregroundColor(.secondary)

            if showDebugSection {
                let samples = appState.imuDtSamples
                let maxDt = samples.max() ?? 0
                let avgDt = samples.isEmpty ? 0 : samples.reduce(0, +) / Double(samples.count)
                let avgHz = avgDt > 0 ? 1.0 / avgDt : 0

                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("IMU Timing")
                            .font(.caption)
                        Spacer()
                        Text(String(format: "%.0f Hz avg", avgHz))
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }

                    SparklineView(values: samples, maxValue: 0.03)
                        .frame(height: 32)
                        .background(Color.secondary.opacity(0.08))
                        .cornerRadius(6)

                    HStack(spacing: 12) {
                        Text(String(format: "Max dt: %.3f s", maxDt))
                            .font(.caption2)
                            .foregroundColor(.secondary)
                        Text("Gaps: \(appState.imuGapCount)")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                }
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
                        Text("Clutch")
                .font(.caption)
                .fontWeight(.medium)
                .frame(width: 40, alignment: .center)
            Text("Scroll")
                .font(.caption)
                .fontWeight(.medium)
                .frame(width: 40, alignment: .center)
            Text("Zoom")
                .font(.caption)
                .fontWeight(.medium)
                .frame(width: 40, alignment: .center)
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
                .disabled(isOverrideButton(button))
            actionCell(for: button, actionType: .hold)
                .disabled(isOverrideButton(button))
            clutchCell(for: button)
            scrollCell(for: button)
            zoomCell(for: button)
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

        return HStack(spacing: 4) {
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

            // Actions dropdown (mouse clicks + system actions)
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
                }
            } label: {
                Image(systemName: "plus.circle")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .fixedSize()
        }
    }

    private func clutchCell(for button: LogicalButton) -> some View {
        Toggle(isOn: Binding(
            get: { isClutchButton(button) },
            set: { newValue in setClutchButton(newValue ? button : nil) }
        )) {
            EmptyView()
        }
        .toggleStyle(.checkbox)
        .frame(width: 40, alignment: .center)
        .help("Hold to clutch (freeze cursor) so you can reposition the controller; disables other actions for this button.")
    }

    private func scrollCell(for button: LogicalButton) -> some View {
        Toggle(isOn: Binding(
            get: { isScrollButton(button) },
            set: { newValue in setScrollButton(newValue ? button : nil) }
        )) {
            EmptyView()
        }
        .toggleStyle(.checkbox)
        .frame(width: 40, alignment: .center)
        .help("Hold to turn motion into scroll (X/Y); cursor stays still.")
    }

    private func zoomCell(for button: LogicalButton) -> some View {
        Toggle(isOn: Binding(
            get: { isZoomButton(button) },
            set: { newValue in setZoomButton(newValue ? button : nil) }
        )) {
            EmptyView()
        }
        .toggleStyle(.checkbox)
        .frame(width: 40, alignment: .center)
        .help("Hold to zoom (vertical motion -> scroll up/down); cursor stays still.")
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

    // MARK: - Override button helpers

    private func isClutchButton(_ button: LogicalButton) -> Bool {
        appState.clutchButtons.contains(button)
    }

    private func setClutchButton(_ button: LogicalButton?) {
        // Clear any in-progress captures when toggling clutch state
        keyCaptureManager.cancelCapture()
        var buttons = appState.clutchButtons
        if let button {
            buttons.insert(button)
        } else {
            buttons.removeAll()
        }
        appState.clutchButtons = buttons
    }

    private func isScrollButton(_ button: LogicalButton) -> Bool {
        appState.scrollButtons.contains(button)
    }

    private func setScrollButton(_ button: LogicalButton?) {
        keyCaptureManager.cancelCapture()
        var buttons = appState.scrollButtons
        if let button {
            buttons.insert(button)
        } else {
            buttons.removeAll()
        }
        appState.scrollButtons = buttons
    }

    private func isZoomButton(_ button: LogicalButton) -> Bool {
        appState.zoomButtons.contains(button)
    }

    private func setZoomButton(_ button: LogicalButton?) {
        keyCaptureManager.cancelCapture()
        var buttons = appState.zoomButtons
        if let button {
            buttons.insert(button)
        } else {
            buttons.removeAll()
        }
        appState.zoomButtons = buttons
    }

    private func isOverrideButton(_ button: LogicalButton) -> Bool {
        isClutchButton(button) || isScrollButton(button) || isZoomButton(button)
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

// Simple sparkline for debug timing
private struct SparklineView: View {
    let values: [Double]
    let maxValue: Double

    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            let height = geometry.size.height
            let count = values.count

            Path { path in
                guard count > 1 else { return }
                for (index, value) in values.enumerated() {
                    let x = CGFloat(Double(index) / Double(count - 1)) * width
                    let clamped = max(0.0, min(value, maxValue))
                    let normalized = clamped / maxValue
                    let y = height - CGFloat(normalized) * height
                    if index == 0 {
                        path.move(to: CGPoint(x: x, y: y))
                    } else {
                        path.addLine(to: CGPoint(x: x, y: y))
                    }
                }
            }
            .stroke(Color.blue, lineWidth: 1)
        }
    }
}
