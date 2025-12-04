import SwiftUI

struct StickPane: View {
    @EnvironmentObject var appState: AppState
    @StateObject private var keyCaptureManager = KeyCaptureManager()

    var body: some View {
        Form {
            Section("Mode") {
                Picker("Stick Mode", selection: $appState.stickMode) {
                    ForEach(StickMode.allCases, id: \.self) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }
                .pickerStyle(.segmented)

                Text(appState.stickMode == .scroll
                     ? "Joystick scrolls content"
                     : "Joystick shows radial menu")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            if appState.stickMode == .scroll {
                Section("Scroll Settings") {
                    LabeledContent("Scroll Speed") {
                        HStack {
                            Slider(value: $appState.scrollSensitivity, in: 1...40)
                                .frame(width: 200)
                            Text(String(format: "%.0f", appState.scrollSensitivity))
                                .font(.system(.body, design: .monospaced))
                                .foregroundColor(.secondary)
                                .frame(width: 40, alignment: .trailing)
                        }
                    }
                }
            }

            if appState.stickMode == .radialMenu {
                Section("Radial Menu Items") {
                    ForEach(Array(appState.radialMenuConfiguration.items.enumerated()), id: \.element.id) { index, item in
                        radialMenuItemRow(item: item, index: index)
                    }

                    if keyCaptureManager.isCapturingRadialItem {
                        radialMenuCaptureView
                    } else if appState.radialMenuConfiguration.items.count < 10 {
                        Button {
                            keyCaptureManager.startRadialMenuCapture()
                        } label: {
                            Label("Add Item", systemImage: "plus.circle")
                        }
                    }

                    if appState.radialMenuConfiguration.items.count >= 10 {
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
            keyCaptureManager.onRadialMenuCapture = { [weak appState] combo in
                guard let appState else { return }
                let newItem = RadialMenuItem(
                    label: combo.displayName,
                    icon: "",
                    action: .keyPress(combo)
                )
                var config = appState.radialMenuConfiguration
                config.items.append(newItem)
                appState.radialMenuConfiguration = config
            }
        }
        .onDisappear {
            keyCaptureManager.cancelCapture()
        }
    }

    private func radialMenuItemRow(item: RadialMenuItem, index: Int) -> some View {
        let itemCount = appState.radialMenuConfiguration.items.count

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
        var config = appState.radialMenuConfiguration
        guard index >= 0 && index < config.items.count else { return }
        config.items.remove(at: index)
        appState.radialMenuConfiguration = config
    }

    private func moveRadialMenuItem(from index: Int, direction: Int) {
        var config = appState.radialMenuConfiguration
        let newIndex = index + direction
        guard newIndex >= 0 && newIndex < config.items.count else { return }
        config.items.swapAt(index, newIndex)
        appState.radialMenuConfiguration = config
    }
}

#Preview {
    StickPane()
        .environmentObject(AppState())
        .frame(width: 500, height: 400)
}
