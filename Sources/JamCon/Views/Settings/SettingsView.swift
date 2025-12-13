import SwiftUI

// MARK: - Settings View

/// Main settings window with explicit hierarchical navigation
struct SettingsView: View {
    @ObservedObject var appState: AppState

    private enum SidebarSelection: Hashable {
        case devices
        case profile(ControllerProfile)
        case radialMenu
        case log
    }

    @State private var selection: SidebarSelection? = .devices

    var body: some View {
        NavigationSplitView {
            List(selection: $selection) {
                Section("Devices") {
                    NavigationLink(value: SidebarSelection.devices) {
                        Label("Manage Devices", systemImage: "gamecontroller")
                    }
                }

                Section("Profiles") {
                    ForEach(ControllerProfile.allProfiles, id: \.self) { profile in
                        NavigationLink(value: SidebarSelection.profile(profile)) {
                            Label(profile.displayName, systemImage: iconName(for: profile))
                        }
                    }
                }

                Section("Global") {
                    NavigationLink(value: SidebarSelection.radialMenu) {
                        Label("Radial Menu", systemImage: "circle.hexagongrid")
                    }
                    NavigationLink(value: SidebarSelection.log) {
                        Label("Log", systemImage: "doc.text")
                    }
                }
            }
            .navigationSplitViewColumnWidth(min: 220, ideal: 260)
        } detail: {
            NavigationStack {
                detailView
            }
            .id(selection)
        }
        .frame(minWidth: 760, minHeight: 520)
        .onAppear {
            if selection == nil {
                selection = .devices
            }
        }
    }

    @ViewBuilder
    private var detailView: some View {
        switch selection {
        case .devices, .none:
            ControllerTab(appState: appState)

        case .profile(let profile):
            ProfileHubView(appState: appState, profile: profile)

        case .radialMenu:
            RadialMenuTab(appState: appState)

        case .log:
            LogTab(appState: appState)
        }
    }

    private func iconName(for profile: ControllerProfile) -> String {
        switch profile.kind {
        case .sense, .joyCon:
            return profile.isLeft ? "l.joystick" : "r.joystick"
        case .mouse:
            return "computermouse"
        }
    }
}

private struct ProfileHubView: View {
    @ObservedObject var appState: AppState
    let profile: ControllerProfile

    var body: some View {
        List {
            Section {
                if profile.kind != .mouse {
                    NavigationLink {
                        MouseControlTab(appState: appState)
                    } label: {
                        Label("Cursor & Gyro", systemImage: "cursorarrow.motionlines")
                    }
                }

                NavigationLink {
                    ButtonsTab(appState: appState)
                } label: {
                    Label("Buttons", systemImage: "circle.grid.3x3")
                }

                if profile.kind.hasJoystick {
                    NavigationLink {
                        JoystickTab(appState: appState)
                    } label: {
                        Label("Joystick", systemImage: "l.joystick")
                    }
                }
            } footer: {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Profiles are shared templates by controller type/side.")
                    Text("Devices are managed separately in “Manage Devices”.")
                }
                .font(.caption)
                .foregroundColor(.secondary)
            }
        }
        .navigationTitle(profile.displayName)
        .onAppear {
            appState.configurationProfile = profile
        }
    }
}
