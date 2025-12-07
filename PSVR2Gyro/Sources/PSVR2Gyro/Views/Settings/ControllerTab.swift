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
                            Text("No controllers found")
                                .font(.headline)
                                .foregroundColor(.secondary)
                            Text("Press the PlayStation button to connect")
                                .font(.caption)
                                .foregroundColor(.secondary.opacity(0.7))
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 40)
                    } else {
                        // Controller list with cards
                        ForEach(appState.availableControllers) { controller in
                            ControllerCard(
                                controller: controller,
                                isSelected: controller.id == appState.selectedControllerID,
                                onSelect: { appState.selectController(id: controller.id) }
                            )
                        }

                        Text("Select the controller to use for gyro mouse control.")
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

    private var iconName: String {
        switch controller.kind {
        case .psvr2:
            return controller.isLeft ? "l.joystick" : "r.joystick"
        case .joyCon:
            return controller.isLeft ? "l.joystick" : "r.joystick"
        }
    }

    var body: some View {
        HStack {
            Image(systemName: iconName)
                .font(.title2)
                .foregroundColor(.blue)

            VStack(alignment: .leading, spacing: 2) {
                Text(controller.side)
                    .font(.headline)
                Text("\(controller.name) • \(controller.kind == .joyCon ? "Joy-Con" : "PSVR2")")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Spacer()

            if isSelected {
                Image(systemName: "checkmark.circle.fill")
                    .font(.title2)
                    .foregroundColor(.green)
            } else {
                Button("Select", action: onSelect)
                    .buttonStyle(.bordered)
            }
        }
        .padding()
        .background(isSelected ? Color.blue.opacity(0.1) : Color.secondary.opacity(0.05))
        .cornerRadius(8)
    }
}
