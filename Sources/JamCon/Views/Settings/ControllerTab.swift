import SwiftUI

// MARK: - Controller Tab

struct ControllerTab: View {
    @ObservedObject var appState: AppState

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Choose which connected devices JamCon should listen to. Configure their behavior under Profiles.")
                    .font(.callout)
                    .foregroundColor(.secondary)

                LinkedGamepadCard(appState: appState)

                if appState.availableControllers.isEmpty {
                    // Empty state
                    VStack(spacing: 12) {
                        Image(systemName: "gamecontroller")
                            .font(.system(size: 48))
                            .foregroundColor(.secondary.opacity(0.5))
                        Text("No devices found")
                            .font(.headline)
                            .foregroundColor(.secondary)
                        Text("Connect a controller via Bluetooth or plug in a supported mouse")
                            .font(.caption)
                            .foregroundColor(.secondary.opacity(0.7))
                            .multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 40)
                } else {
                    ForEach(appState.availableControllers) { controller in
                        ControllerCard(
                            appState: appState,
                            controller: controller
                        )
                    }
                }
            }
            .padding()
        }
        .navigationTitle("Devices")
    }
}

// MARK: - Linked Gamepad

private struct LinkedGamepadCard: View {
    @ObservedObject var appState: AppState

    private var configuration: LinkedGamepadConfiguration {
        appState.linkedGamepadConfiguration
    }

    private var canActivate: Bool {
        appState.virtualGamepadAvailability.isAvailable
            && configuration.isComplete
            && appState.isEnabled
    }

    private var statusColor: Color {
        switch appState.virtualGamepadRuntimeStatus {
        case .active:
            return .green
        case .activating, .waitingForControllers:
            return .orange
        case .failed:
            return .red
        case .unavailable, .disabled, .needsControllers:
            return .secondary
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "gamecontroller.fill")
                    .font(.title2)
                    .foregroundColor(configuration.isEnabled ? .blue : .secondary)

                VStack(alignment: .leading, spacing: 4) {
                    Text("Linked Joy-Cons")
                        .font(.headline)
                    Text("Combine one left and one right Joy-Con into a standard game controller.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                Spacer(minLength: 8)

                Text(appState.virtualGamepadRuntimeStatus.title)
                    .font(.caption.weight(.semibold))
                    .foregroundColor(statusColor)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(statusColor.opacity(0.12))
                    .clipShape(Capsule())
            }

            HStack(spacing: 12) {
                LinkedGamepadSlot(
                    title: "Left controller",
                    side: .left,
                    selection: configuration.left,
                    candidates: appState.leftLinkedGamepadCandidates,
                    isConnected: appState.isLinkedGamepadSelectionConnected(.left),
                    select: { appState.selectLinkedGamepadController($0, for: .left) }
                )

                LinkedGamepadSlot(
                    title: "Right controller",
                    side: .right,
                    selection: configuration.right,
                    candidates: appState.rightLinkedGamepadCandidates,
                    isConnected: appState.isLinkedGamepadSelectionConnected(.right),
                    select: { appState.selectLinkedGamepadController($0, for: .right) }
                )
            }

            if let explanation = appState.virtualGamepadAvailability.explanation {
                Label(explanation, systemImage: "clock.badge.exclamationmark")
                    .font(.caption)
                    .foregroundColor(.secondary)
            } else if case let .failed(message) = appState.virtualGamepadRuntimeStatus {
                HStack(spacing: 10) {
                    Label(message, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundColor(.red)
                    Spacer(minLength: 8)
                    Button("Try Again") {
                        appState.retryLinkedGamepad()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            } else {
                Text(
                    "When active, these controllers feed the gamepad directly instead of "
                        + "JamCon’s cursor and button mappings. The virtual controller stays "
                        + "present and sends neutral input until both controllers are online."
                )
                .font(.caption)
                .foregroundColor(.secondary)
            }

            Divider()
                .opacity(0.6)

            Toggle(
                "Expose this pair as a game controller",
                isOn: Binding(
                    get: { configuration.isEnabled },
                    set: { appState.setLinkedGamepadEnabled($0) }
                )
            )
            .toggleStyle(.switch)
            .font(.subheadline)
            .disabled(!canActivate && !configuration.isEnabled)
        }
        .padding(16)
        .background(Color.blue.opacity(configuration.isEnabled ? 0.08 : 0.04))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(
                    configuration.isEnabled
                        ? Color.blue.opacity(0.35)
                        : Color.secondary.opacity(0.1),
                    lineWidth: configuration.isEnabled ? 2 : 1
                )
        )
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }
}

private struct LinkedGamepadSlot: View {
    let title: String
    let side: LinkedJoyConSide
    let selection: LinkedJoyConSelection?
    let candidates: [ControllerInfo]
    let isConnected: Bool
    let select: (ControllerInfo?) -> Void

    private var iconName: String {
        side == .left ? "l.joystick" : "r.joystick"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundColor(.secondary)

            Menu {
                if candidates.isEmpty {
                    Text("No \(side == .left ? "left" : "right") Joy-Con connected")
                } else {
                    ForEach(candidates) { controller in
                        Button {
                            select(controller)
                        } label: {
                            if selection?.deviceID == controller.id {
                                Label(controller.displayName, systemImage: "checkmark")
                            } else {
                                Text(controller.displayName)
                            }
                        }
                    }
                }

                if selection != nil {
                    Divider()
                    Button("Clear Selection", role: .destructive) {
                        select(nil)
                    }
                }
            } label: {
                HStack(spacing: 9) {
                    Image(systemName: iconName)
                        .foregroundColor(selection == nil ? .secondary : .blue)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(selection?.displayName ?? "Choose Controller")
                            .foregroundColor(.primary)
                            .lineLimit(1)
                        if selection != nil {
                            Label(
                                isConnected ? "Connected" : "Saved — waiting to connect",
                                systemImage: isConnected ? "circle.fill" : "circle"
                            )
                            .font(.caption2)
                            .foregroundColor(isConnected ? .green : .secondary)
                        }
                    }

                    Spacer(minLength: 6)
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
                .padding(10)
                .frame(maxWidth: .infinity, minHeight: 52, alignment: .leading)
                .background(Color.secondary.opacity(0.07))
                .clipShape(RoundedRectangle(cornerRadius: 8))
            }
            .menuStyle(.borderlessButton)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Controller Card

private struct ControllerCard: View {
    @ObservedObject var appState: AppState
    let controller: ControllerInfo

    private var isManaged: Bool { appState.isDeviceManaged(controller) }
    private var gamepadSide: LinkedJoyConSide? {
        appState.linkedGamepadSide(for: controller)
    }

    private var iconName: String {
        switch controller.kind {
        case .sense:
            return controller.isLeft ? "l.joystick" : "r.joystick"
        case .joyCon:
            return controller.isLeft ? "l.joystick" : "r.joystick"
        case .mouse:
            return "computermouse"
        }
    }

    private var detailText: String {
        if let transportName = controller.meaningfulTransportName {
            return "\(controller.transportDescription) · \(transportName)"
        }
        return controller.transportDescription
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: isManaged ? "checkmark.circle.fill" : "circle")
                    .font(.title2)
                    .foregroundColor(isManaged ? .green : .secondary.opacity(0.4))

                Image(systemName: iconName)
                    .font(.title2)
                    .foregroundColor(isManaged ? .blue : .secondary)

                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: 7) {
                        Text(controller.displayName)
                            .font(.headline)
                            .foregroundColor(isManaged ? .primary : .secondary)

                        if isManaged {
                            Text("Managed")
                                .font(.caption2.weight(.medium))
                                .foregroundColor(.green)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Color.green.opacity(0.15))
                                .clipShape(RoundedRectangle(cornerRadius: 4))
                        }

                        if let gamepadSide {
                            Text(gamepadSide == .left ? "Gamepad Left" : "Gamepad Right")
                                .font(.caption2.weight(.medium))
                                .foregroundColor(.blue)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Color.blue.opacity(0.12))
                                .clipShape(RoundedRectangle(cornerRadius: 4))
                        }
                    }

                    Text(detailText)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                Spacer(minLength: 8)
            }

            Divider()
                .opacity(0.6)

            HStack(spacing: 12) {
                Toggle(
                    "Manage this device",
                    isOn: Binding(
                        get: { isManaged },
                        set: { appState.setDeviceManaged(controller, managed: $0) }
                    )
                )
                .toggleStyle(.switch)
                .font(.subheadline)

                Spacer(minLength: 8)

                Button {
                    appState.resetDevice(controller)
                } label: {
                    Label("Reset Device", systemImage: "arrow.clockwise")
                }
                .buttonStyle(.bordered)
                .disabled(!isManaged)

                NavigationLink {
                    DeviceDebugView(appState: appState, controller: controller)
                } label: {
                    Label("Live Debug", systemImage: "waveform.path.ecg")
                }
                .buttonStyle(.bordered)
                .disabled(!isManaged)
            }
        }
        .padding(16)
        .background(
            isManaged
            ? Color.green.opacity(0.08)
            : Color.secondary.opacity(0.05)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(
                    isManaged
                    ? Color.green.opacity(0.3)
                    : Color.secondary.opacity(0.08),
                    lineWidth: isManaged ? 2 : 1
                )
        )
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }
}
