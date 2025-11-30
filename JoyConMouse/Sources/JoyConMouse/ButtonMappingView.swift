import SwiftUI
import Carbon.HIToolbox

struct ButtonMappingView: View {
    @EnvironmentObject private var appState: AppState
    @State private var selectedRole: MappingRole = .primary
    @State private var capturingButton: JoyConButton? = nil

    enum MappingRole: String, CaseIterable {
        case primary = "Primary"
        case secondary = "Secondary"
    }

    var body: some View {
        VStack(spacing: 0) {
            // Role picker
            Picker("Role", selection: $selectedRole) {
                ForEach(MappingRole.allCases, id: \.self) { role in
                    Text(role.rawValue).tag(role)
                }
            }
            .pickerStyle(.segmented)
            .padding()

            Divider()

            // Button mappings list
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    ForEach(ButtonMappingProfile.buttonGroups, id: \.name) { group in
                        buttonGroupSection(group)
                    }
                }
                .padding()
            }

            Divider()

            // Footer buttons
            HStack {
                Button("Reset to Defaults") {
                    resetToDefaults()
                }
                .buttonStyle(.bordered)

                Spacer()
            }
            .padding()
        }
        .frame(width: 350, height: 500)
    }

    // MARK: - Button Group Section

    private func buttonGroupSection(_ group: (name: String, buttons: [JoyConButton])) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(group.name)
                .font(.headline)
                .foregroundColor(.secondary)

            ForEach(group.buttons, id: \.rawValue) { button in
                buttonRow(button)
            }
        }
    }

    private func buttonRow(_ button: JoyConButton) -> some View {
        HStack {
            Text(buttonDisplayName(button))
                .frame(width: 80, alignment: .leading)

            Spacer()

            actionPicker(for: button)
        }
        .padding(.vertical, 2)
    }

    // MARK: - Action Picker

    private func actionPicker(for button: JoyConButton) -> some View {
        let currentAction = currentMapping[button]

        return Menu {
            // None option
            Button("None") {
                setAction(.none, for: button)
            }

            Divider()

            // Mouse clicks
            Menu("Mouse Click") {
                Button("Left Click") {
                    setAction(.mouseClick(.left), for: button)
                }
                Button("Right Click") {
                    setAction(.mouseClick(.right), for: button)
                }
                Button("Middle Click") {
                    setAction(.mouseClick(.middle), for: button)
                }
            }

            Divider()

            // Common keyboard shortcuts
            Menu("Keyboard") {
                // Navigation
                Menu("Navigation") {
                    Button("Escape") { setAction(.keyPress(.escape), for: button) }
                    Button("Enter") { setAction(.keyPress(.enter), for: button) }
                    Button("Space") { setAction(.keyPress(.space), for: button) }
                    Button("Tab") { setAction(.keyPress(.tab), for: button) }
                    Button("Backspace") { setAction(.keyPress(.backspace), for: button) }
                }

                // Arrows
                Menu("Arrow Keys") {
                    Button("Up") { setAction(.keyPress(.arrowUp), for: button) }
                    Button("Down") { setAction(.keyPress(.arrowDown), for: button) }
                    Button("Left") { setAction(.keyPress(.arrowLeft), for: button) }
                    Button("Right") { setAction(.keyPress(.arrowRight), for: button) }
                }

                // Common shortcuts
                Menu("Shortcuts") {
                    Button("Copy (Cmd+C)") { setAction(.keyPress(.copy), for: button) }
                    Button("Paste (Cmd+V)") { setAction(.keyPress(.paste), for: button) }
                    Button("Cut (Cmd+X)") { setAction(.keyPress(.cut), for: button) }
                    Button("Undo (Cmd+Z)") { setAction(.keyPress(.undo), for: button) }
                    Button("Redo (Cmd+Shift+Z)") { setAction(.keyPress(.redo), for: button) }
                    Button("Select All (Cmd+A)") { setAction(.keyPress(.selectAll), for: button) }
                }
            }
        } label: {
            HStack {
                Text(currentAction.displayName)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Color.secondary.opacity(0.1))
            .cornerRadius(6)
        }
        .menuStyle(.borderlessButton)
        .frame(width: 180)
    }

    // MARK: - Helpers

    private var currentMapping: ButtonMappingProfile {
        switch selectedRole {
        case .primary:
            return appState.primaryMapping
        case .secondary:
            return appState.secondaryMapping
        }
    }

    private func setAction(_ action: ButtonAction, for button: JoyConButton) {
        switch selectedRole {
        case .primary:
            appState.primaryMapping[button] = action
        case .secondary:
            appState.secondaryMapping[button] = action
        }
    }

    private func resetToDefaults() {
        switch selectedRole {
        case .primary:
            appState.primaryMapping = .defaultPrimary
        case .secondary:
            appState.secondaryMapping = .defaultSecondary
        }
    }

    private func buttonDisplayName(_ button: JoyConButton) -> String {
        switch button {
        case .a: return "A"
        case .b: return "B"
        case .x: return "X"
        case .y: return "Y"
        case .r: return "R"
        case .zr: return "ZR"
        case .l: return "L"
        case .zl: return "ZL"
        case .plus: return "+"
        case .minus: return "-"
        case .home: return "Home"
        case .capture: return "Capture"
        case .rightStick: return "R Stick"
        case .leftStick: return "L Stick"
        case .up: return "D-Up"
        case .down: return "D-Down"
        case .left: return "D-Left"
        case .right: return "D-Right"
        case .sr_r, .sr_l: return "SR"
        case .sl_r, .sl_l: return "SL"
        }
    }
}

#Preview {
    ButtonMappingView()
        .environmentObject(AppState())
}
