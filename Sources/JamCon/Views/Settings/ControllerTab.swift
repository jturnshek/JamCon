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

    private var subtitleText: String {
        ControllerProfile(from: controller).displayName
    }

    var body: some View {
        HStack(spacing: 12) {
            // Selection indicator
            Image(systemName: isManaged ? "checkmark.circle.fill" : "circle")
                .font(.title2)
                .foregroundColor(isManaged ? .green : .secondary.opacity(0.4))

            // Controller icon
            Image(systemName: iconName)
                .font(.title2)
                .foregroundColor(isManaged ? .blue : .secondary)

            // Controller info
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(controller.name)
                        .font(.headline)
                        .foregroundColor(isManaged ? .primary : .secondary)
                    if isManaged {
                        Text("Managed")
                            .font(.caption2)
                            .fontWeight(.medium)
                            .foregroundColor(.green)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.green.opacity(0.15))
                            .cornerRadius(4)
                    }
                }
                Text(subtitleText)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Spacer()

            // Action button
            HStack(spacing: 8) {
                Toggle(
                    "Managed",
                    isOn: Binding(
                        get: { isManaged },
                        set: { appState.setDeviceManaged(controller, managed: $0) }
                    )
                )
                .toggleStyle(.switch)
                .font(.caption)

                NavigationLink {
                    DeviceDebugView(appState: appState, controller: controller)
                } label: {
                    Text("Live Debug")
                }
                .buttonStyle(.bordered)
                .disabled(!isManaged)
            }
        }
        .padding()
        .background(
            isManaged
            ? Color.green.opacity(0.08)
            : Color.secondary.opacity(0.05)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(
                    isManaged
                    ? Color.green.opacity(0.3)
                    : Color.clear,
                    lineWidth: 2
                )
        )
        .cornerRadius(10)
    }
}
