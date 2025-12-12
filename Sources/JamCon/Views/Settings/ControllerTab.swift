import SwiftUI

// MARK: - Controller Tab

struct ControllerTab: View {
    @ObservedObject var appState: AppState

    var body: some View {
        VStack(spacing: 0) {
            TabHeader(appState: appState)

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
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
                        // Controller list with cards
                        ForEach(appState.availableControllers) { controller in
                            ControllerCard(
                                controller: controller,
                                isSelected: controller.id == appState.selectedControllerID,
                                onSelect: { appState.selectController(id: controller.id) },
                                onDeselect: { appState.deselectController() }
                            )
                        }

                        Text("Select a device to use for input control.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
                .padding()
            }
        }
    }
}

// MARK: - Controller Card

private struct ControllerCard: View {
    let controller: ControllerInfo
    let isSelected: Bool
    let onSelect: () -> Void
    let onDeselect: () -> Void

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

    private var kindDisplayName: String {
        switch controller.kind {
        case .sense: return "Sense"
        case .joyCon: return "Joy-Con"
        case .mouse: return "Mouse"
        }
    }

    private var subtitleText: String {
        if controller.kind.hasSides {
            return "\(controller.side) • \(kindDisplayName)"
        } else {
            return kindDisplayName
        }
    }

    var body: some View {
        HStack(spacing: 12) {
            // Selection indicator
            Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                .font(.title2)
                .foregroundColor(isSelected ? .green : .secondary.opacity(0.4))

            // Controller icon
            Image(systemName: iconName)
                .font(.title2)
                .foregroundColor(isSelected ? .blue : .secondary)

            // Controller info
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(controller.name)
                        .font(.headline)
                        .foregroundColor(isSelected ? .primary : .secondary)
                    if isSelected {
                        Text("Active")
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
            if isSelected {
                Button(action: onDeselect) {
                    Image(systemName: "xmark")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
                .padding(8)
                .background(Color.secondary.opacity(0.1))
                .cornerRadius(6)
                .help("Stop using this controller")
            } else {
                Button("Select", action: onSelect)
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding()
        .background(isSelected ? Color.green.opacity(0.08) : Color.secondary.opacity(0.05))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(isSelected ? Color.green.opacity(0.3) : Color.clear, lineWidth: 2)
        )
        .cornerRadius(10)
    }
}
