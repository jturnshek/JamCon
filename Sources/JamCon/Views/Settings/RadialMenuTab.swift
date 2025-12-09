import SwiftUI

// MARK: - Radial Menu Tab

struct RadialMenuTab: View {
    @ObservedObject var appState: AppState
    @StateObject private var keyCaptureManager = KeyCaptureManager()
    @StateObject private var previewState = RadialMenuState()

    var body: some View {
        VStack(spacing: 0) {
            TabHeader(appState: appState)

            ScrollView {
                VStack(spacing: 16) {
                    // Menu preview
                    menuPreview

                    // Inner ring configuration (segments, rotation, size)
                    innerRingSection

                    // Outer ring toggle and configuration
                    outerRingSection

                    // Usage tip
                    usageTip
                }
                .padding()
            }
        }
        .onAppear {
            keyCaptureManager.onCapture = { _, combo, _ in
                // Find the segment being captured for and update it
                if let index = captureIndex {
                    var config = appState.radialMenuConfiguration
                    config.items[index].action = .keyPress(combo)
                    appState.radialMenuConfiguration = config
                    captureIndex = nil
                } else if let index = outerRingCaptureIndex {
                    var config = appState.radialMenuConfiguration
                    config.outerRingItems[index].action = .keyPress(combo)
                    appState.radialMenuConfiguration = config
                    outerRingCaptureIndex = nil
                }
            }
        }
    }

    @State private var captureIndex: Int? = nil
    @State private var outerRingCaptureIndex: Int? = nil

    // MARK: - Menu Preview

    private var menuPreview: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Preview")
                .font(.subheadline)
                .fontWeight(.medium)
                .foregroundColor(.secondary)

            HStack {
                Spacer()
                RadialMenuView(state: previewState)
                    .frame(width: 275, height: 275)
                    .onChange(of: appState.radialMenuConfiguration) { _, newConfig in
                        previewState.activeConfiguration = newConfig
                    }
                    .onAppear {
                        previewState.activeConfiguration = appState.radialMenuConfiguration
                    }
                Spacer()
            }
            .frame(height: 300)
            .background(Color.secondary.opacity(0.05))
            .cornerRadius(8)
        }
    }

    // MARK: - Inner Ring Section

    private var innerRingSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Inner Ring")
                .font(.subheadline)
                .fontWeight(.medium)
                .foregroundColor(.secondary)

            HStack(alignment: .top, spacing: 16) {
                // Left column: Segments
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(Array(appState.radialMenuConfiguration.items.enumerated()), id: \.element.id) { index, item in
                        segmentRow(index: index, item: item, isOuterRing: false)
                    }

                    // Add segment button
                    HStack(spacing: 12) {
                        Button {
                            var config = appState.radialMenuConfiguration
                            let newItem = RadialMenuItem(
                                label: "New",
                                icon: "circle",
                                action: .none
                            )
                            config.addItem(newItem)
                            appState.radialMenuConfiguration = config
                        } label: {
                            Label("Add Segment", systemImage: "plus.circle")
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .disabled(appState.radialMenuConfiguration.items.count >= 8)

                        Spacer()

                        Button("Reset to Default") {
                            appState.radialMenuConfiguration = .arrowKeys
                        }
                        .font(.caption)
                        .foregroundColor(.secondary)
                    }
                }
                .frame(maxWidth: .infinity)

                Divider()

                // Right column: Sliders
                VStack(alignment: .leading, spacing: 12) {
                    // Rotation slider
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text("Rotation")
                                .font(.caption)
                                .foregroundColor(.secondary)
                            Spacer()
                            Text("\(String(format: "%.1f", appState.radialMenuConfiguration.innerRingRotation))°")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }

                        Slider(
                            value: Binding(
                                get: { appState.radialMenuConfiguration.innerRingRotation },
                                set: { newValue in
                                    var config = appState.radialMenuConfiguration
                                    config.innerRingRotation = newValue
                                    appState.radialMenuConfiguration = config
                                }
                            ),
                            in: 0...337.5,
                            step: 22.5
                        )
                        .controlSize(.small)
                    }

                    // Deadzone size slider
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text("Deadzone")
                                .font(.caption)
                                .foregroundColor(.secondary)
                            Spacer()
                            Text("\(Int(appState.radialMenuConfiguration.deadzoneSize))px")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }

                        Slider(
                            value: Binding(
                                get: { appState.radialMenuConfiguration.deadzoneSize },
                                set: { newValue in
                                    var config = appState.radialMenuConfiguration
                                    config.deadzoneSize = newValue
                                    appState.radialMenuConfiguration = config
                                }
                            ),
                            in: 20...80,
                            step: 5
                        )
                        .controlSize(.small)
                    }

                    // Inner ring size slider
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text("Ring Size")
                                .font(.caption)
                                .foregroundColor(.secondary)
                            Spacer()
                            Text("\(Int(appState.radialMenuConfiguration.innerRingSize))px")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }

                        Slider(
                            value: Binding(
                                get: { appState.radialMenuConfiguration.innerRingSize },
                                set: { newValue in
                                    var config = appState.radialMenuConfiguration
                                    config.innerRingSize = newValue
                                    appState.radialMenuConfiguration = config
                                }
                            ),
                            in: 30...100,
                            step: 5
                        )
                        .controlSize(.small)
                    }

                    // Total size display
                    HStack {
                        Text("Total Size")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        Spacer()
                        Text("\(Int(appState.radialMenuConfiguration.menuDiameter))px")
                            .font(.caption.bold())
                            .foregroundColor(.primary)
                    }
                }
                .frame(maxWidth: .infinity)
            }
        }
        .padding()
        .background(Color.secondary.opacity(0.03))
        .cornerRadius(8)
    }

    private func segmentRow(index: Int, item: RadialMenuItem, isOuterRing: Bool) -> some View {
        let items = isOuterRing ? appState.radialMenuConfiguration.outerRingItems : appState.radialMenuConfiguration.items
        let itemCount = items.count

        return HStack(spacing: 8) {
            // Move up/down buttons
            VStack(spacing: 2) {
                Button {
                    guard index > 0 else { return }
                    var config = appState.radialMenuConfiguration
                    if isOuterRing {
                        config.outerRingItems.swapAt(index, index - 1)
                    } else {
                        config.items.swapAt(index, index - 1)
                    }
                    appState.radialMenuConfiguration = config
                } label: {
                    Image(systemName: "chevron.up")
                        .font(.system(size: 10, weight: .medium))
                }
                .buttonStyle(.plain)
                .foregroundColor(index > 0 ? .secondary : .secondary.opacity(0.3))
                .disabled(index == 0)

                Button {
                    guard index < itemCount - 1 else { return }
                    var config = appState.radialMenuConfiguration
                    if isOuterRing {
                        config.outerRingItems.swapAt(index, index + 1)
                    } else {
                        config.items.swapAt(index, index + 1)
                    }
                    appState.radialMenuConfiguration = config
                } label: {
                    Image(systemName: "chevron.down")
                        .font(.system(size: 10, weight: .medium))
                }
                .buttonStyle(.plain)
                .foregroundColor(index < itemCount - 1 ? .secondary : .secondary.opacity(0.3))
                .disabled(index == itemCount - 1)
            }

            // Segment number with color indicator
            ZStack {
                Circle()
                    .fill(RadialMenuColors.rainbow(at: index, count: itemCount))
                    .frame(width: 24, height: 24)
                Text("\(index + 1)")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundColor(.white)
            }

            // Action picker
            let isCapturing = isOuterRing ? (outerRingCaptureIndex == index) : (captureIndex == index)
            if isCapturing {
                HStack(spacing: 8) {
                    Text(keyCaptureManager.modifiersDisplay)
                        .font(.system(size: 11))
                        .foregroundColor(.orange)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    Button("Cancel") {
                        if isOuterRing {
                            outerRingCaptureIndex = nil
                        } else {
                            captureIndex = nil
                        }
                        keyCaptureManager.cancelCapture()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Color.orange.opacity(0.1))
                .cornerRadius(6)
            } else {
                radialActionPicker(index: index, action: item.action, isOuterRing: isOuterRing)
            }

            // Delete button (only if more than 2 segments)
            if itemCount > 2 {
                Button {
                    var config = appState.radialMenuConfiguration
                    if isOuterRing {
                        config.removeOuterRingItem(at: index)
                    } else {
                        config.removeItem(at: index)
                    }
                    appState.radialMenuConfiguration = config
                } label: {
                    Image(systemName: "trash")
                        .foregroundColor(.red)
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func radialActionPicker(index: Int, action: RadialMenuAction, isOuterRing: Bool) -> some View {
        Menu {
            Button("None") {
                updateSegmentAction(index: index, action: .none, isOuterRing: isOuterRing)
            }

            Divider()

            ForEach(MouseButton.allCases, id: \.self) { mouseButton in
                Button(mouseButton.displayName) {
                    updateSegmentAction(index: index, action: .mouseClick(mouseButton), isOuterRing: isOuterRing)
                }
            }

            Divider()

            ForEach(SystemAction.allCases, id: \.self) { systemAction in
                Button(systemAction.displayName) {
                    updateSegmentAction(index: index, action: .systemAction(systemAction), isOuterRing: isOuterRing)
                }
            }

            Divider()

            Button("Capture Keyboard Shortcut...") {
                if isOuterRing {
                    outerRingCaptureIndex = index
                } else {
                    captureIndex = index
                }
                keyCaptureManager.startCapture(for: .faceTop, isHold: false) // Use dummy button
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

    private func updateSegmentAction(index: Int, action: RadialMenuAction, isOuterRing: Bool) {
        var config = appState.radialMenuConfiguration
        if isOuterRing {
            config.outerRingItems[index].action = action
        } else {
            config.items[index].action = action
        }
        appState.radialMenuConfiguration = config
    }

    // MARK: - Outer Ring Section

    private var outerRingSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Toggle
            Toggle("Enable Outer Ring", isOn: Binding(
                get: { appState.radialMenuConfiguration.outerRingEnabled },
                set: { enabled in
                    var config = appState.radialMenuConfiguration
                    config.outerRingEnabled = enabled
                    // Add default items if enabling with empty outer ring
                    if enabled && config.outerRingItems.isEmpty {
                        config.outerRingItems = [
                            RadialMenuItem(label: "1", icon: "circle", action: .none),
                            RadialMenuItem(label: "2", icon: "circle", action: .none),
                            RadialMenuItem(label: "3", icon: "circle", action: .none),
                            RadialMenuItem(label: "4", icon: "circle", action: .none),
                        ]
                    }
                    appState.radialMenuConfiguration = config
                }
            ))
            .font(.subheadline)
            .fontWeight(.medium)

            if appState.radialMenuConfiguration.outerRingEnabled {
                HStack(alignment: .top, spacing: 16) {
                    // Left column: Segments
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(Array(appState.radialMenuConfiguration.outerRingItems.enumerated()), id: \.element.id) { index, item in
                            segmentRow(index: index, item: item, isOuterRing: true)
                        }

                        // Add outer ring segment button
                        Button {
                            var config = appState.radialMenuConfiguration
                            let newItem = RadialMenuItem(
                                label: "New",
                                icon: "circle",
                                action: .none
                            )
                            config.addOuterRingItem(newItem)
                            appState.radialMenuConfiguration = config
                        } label: {
                            Label("Add Segment", systemImage: "plus.circle")
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .disabled(appState.radialMenuConfiguration.outerRingItems.count >= 8)
                    }
                    .frame(maxWidth: .infinity)

                    Divider()

                    // Right column: Sliders
                    VStack(alignment: .leading, spacing: 12) {
                        // Rotation slider
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text("Rotation")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                Spacer()
                                Text("\(String(format: "%.1f", appState.radialMenuConfiguration.outerRingRotation))°")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }

                            Slider(
                                value: Binding(
                                    get: { appState.radialMenuConfiguration.outerRingRotation },
                                    set: { newValue in
                                        var config = appState.radialMenuConfiguration
                                        config.outerRingRotation = newValue
                                        appState.radialMenuConfiguration = config
                                    }
                                ),
                                in: 0...337.5,
                                step: 22.5
                            )
                            .controlSize(.small)
                        }

                        // Outer ring size slider
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text("Ring Size")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                Spacer()
                                Text("\(Int(appState.radialMenuConfiguration.outerRingSize))px")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }

                            Slider(
                                value: Binding(
                                    get: { appState.radialMenuConfiguration.outerRingSize },
                                    set: { newValue in
                                        var config = appState.radialMenuConfiguration
                                        config.outerRingSize = newValue
                                        appState.radialMenuConfiguration = config
                                    }
                                ),
                                in: 30...100,
                                step: 5
                            )
                            .controlSize(.small)
                        }

                        // Total size display
                        HStack {
                            Text("Total Size")
                                .font(.caption)
                                .foregroundColor(.secondary)
                            Spacer()
                            Text("\(Int(appState.radialMenuConfiguration.menuDiameter))px")
                                .font(.caption.bold())
                                .foregroundColor(.primary)
                        }
                    }
                    .frame(maxWidth: .infinity)
                }
            }
        }
        .padding()
        .background(Color.secondary.opacity(0.03))
        .cornerRadius(8)
    }

    // MARK: - Usage Tip

    private var usageTip: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "info.circle")
                .foregroundColor(.blue)
            VStack(alignment: .leading, spacing: 4) {
                Text("Assign \"Radial Menu\" to a button in the Buttons tab to activate.")
                    .font(.caption)
                Text("Hold the button and move the controller to select a segment. Release to execute the action.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .padding()
        .background(Color.blue.opacity(0.05))
        .cornerRadius(8)
    }
}
