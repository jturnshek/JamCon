import SwiftUI

/// Stick settings for a specific slot and device type
struct StickSettingsView: View {
    @EnvironmentObject var appState: AppState
    let slot: DeviceSlot
    let deviceType: ConfigurableDeviceType
    @Binding var settings: DeviceTypeSettings
    @StateObject private var keyCaptureManager = KeyCaptureManager()

    var body: some View {
        Form {
            Section("Mode") {
                Picker("Stick Mode", selection: $settings.stickMode) {
                    ForEach(StickMode.allCases, id: \.self) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }
                .pickerStyle(.segmented)

                Text(settings.stickMode == .scroll
                     ? "Joystick scrolls content"
                     : "Joystick shows radial menu")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            if settings.stickMode == .scroll {
                Section("Scroll Settings") {
                    LabeledContent("Scroll Speed") {
                        HStack {
                            Slider(value: $settings.scrollSensitivity, in: 1...40)
                                .frame(width: 200)
                            Text(String(format: "%.0f", settings.scrollSensitivity))
                                .font(.system(.body, design: .monospaced))
                                .foregroundColor(.secondary)
                                .frame(width: 40, alignment: .trailing)
                        }
                    }

                    LabeledContent("Deadzone") {
                        HStack {
                            Slider(value: $settings.stickDeadzone, in: 0...0.5)
                                .frame(width: 200)
                            Text(String(format: "%.2f", settings.stickDeadzone))
                                .font(.system(.body, design: .monospaced))
                                .foregroundColor(.secondary)
                                .frame(width: 50, alignment: .trailing)
                        }
                    }
                }
            }

            if settings.stickMode == .radialMenu {
                Section("Radial Menu Items") {
                    ForEach(Array(settings.radialMenuItems.enumerated()), id: \.element.id) { index, item in
                        radialMenuItemRow(item: item, index: index)
                    }

                    if keyCaptureManager.isCapturingRadialItem {
                        radialMenuCaptureView
                    } else if settings.radialMenuItems.count < 10 {
                        Button {
                            keyCaptureManager.startRadialMenuCapture()
                        } label: {
                            Label("Add Item", systemImage: "plus.circle")
                        }
                    }

                    if settings.radialMenuItems.count >= 10 {
                        Text("Maximum 10 items")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Stick")
        .onAppear {
            keyCaptureManager.onRadialMenuCapture = { combo in
                let newItem = RadialMenuItem(
                    label: combo.displayName,
                    icon: "",
                    action: .keyPress(combo)
                )
                settings.radialMenuItems.append(newItem)
            }
        }
        .onDisappear {
            keyCaptureManager.cancelCapture()
            settings.save(slot: slot, deviceType: deviceType)
            appState.syncInputSettings()
        }
    }

    private func radialMenuItemRow(item: RadialMenuItem, index: Int) -> some View {
        let itemCount = settings.radialMenuItems.count

        return HStack {
            Text("\(index + 1).")
                .foregroundColor(.secondary)
                .frame(width: 24, alignment: .leading)

            Text(item.action.displayName)
                .frame(maxWidth: .infinity, alignment: .leading)

            Button {
                moveRadialMenuItem(from: index, direction: -1)
            } label: {
                Image(systemName: "chevron.up")
            }
            .buttonStyle(.borderless)
            .disabled(index == 0)

            Button {
                moveRadialMenuItem(from: index, direction: 1)
            } label: {
                Image(systemName: "chevron.down")
            }
            .buttonStyle(.borderless)
            .disabled(index == itemCount - 1)

            Button(role: .destructive) {
                removeRadialMenuItem(at: index)
            } label: {
                Image(systemName: "xmark.circle.fill")
            }
            .buttonStyle(.borderless)
        }
    }

    private var radialMenuCaptureView: some View {
        HStack(spacing: 8) {
            Image(systemName: "keyboard")
                .foregroundColor(.accentColor)

            if keyCaptureManager.currentModifiers.isEmpty {
                Text("Press keys...")
                    .foregroundColor(.secondary)
            } else {
                Text(keyCaptureManager.currentModifiers.displayString)
            }

            Spacer()

            Button {
                keyCaptureManager.cancelCapture()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundColor(.secondary)
            }
            .buttonStyle(.borderless)
        }
        .padding(8)
        .background(Color.accentColor.opacity(0.1))
        .cornerRadius(6)
    }

    private func removeRadialMenuItem(at index: Int) {
        guard index >= 0 && index < settings.radialMenuItems.count else { return }
        settings.radialMenuItems.remove(at: index)
    }

    private func moveRadialMenuItem(from index: Int, direction: Int) {
        let newIndex = index + direction
        guard newIndex >= 0 && newIndex < settings.radialMenuItems.count else { return }
        settings.radialMenuItems.swapAt(index, newIndex)
    }
}

#Preview {
    NavigationStack {
        StickSettingsView(
            slot: .primary,
            deviceType: .rightJoyCon,
            settings: .constant(DeviceTypeSettings())
        )
    }
    .frame(width: 500, height: 400)
}
