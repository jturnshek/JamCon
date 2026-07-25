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

// MARK: - Controller Card

private struct ControllerCard: View {
    @ObservedObject var appState: AppState
    let controller: ControllerInfo

    private var isManaged: Bool { appState.isDeviceManaged(controller) }

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
