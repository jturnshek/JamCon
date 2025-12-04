import SwiftUI

// MARK: - Settings Sections

enum SettingsSection: String, CaseIterable, Identifiable {
    case devices = "Devices"
    case advanced = "Advanced"
    case log = "Log"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .devices: return "gamecontroller"
        case .advanced: return "gearshape.2"
        case .log: return "doc.text"
        }
    }
}

// MARK: - Settings Container

struct SettingsContainer: View {
    @EnvironmentObject var appState: AppState
    @State private var selection: SettingsSection = .devices

    var body: some View {
        NavigationSplitView {
            SettingsSidebar(selection: $selection)
        } detail: {
            detailView
                .frame(minWidth: 500, minHeight: 400)
        }
        .navigationSplitViewStyle(.balanced)
    }

    @ViewBuilder
    private var detailView: some View {
        switch selection {
        case .devices:
            DevicesPane()
        case .advanced:
            AdvancedPane()
        case .log:
            LogPane()
        }
    }
}

// MARK: - Settings Sidebar

struct SettingsSidebar: View {
    @Binding var selection: SettingsSection

    var body: some View {
        List(SettingsSection.allCases, selection: $selection) { section in
            Label(section.rawValue, systemImage: section.icon)
                .tag(section)
        }
        .listStyle(.sidebar)
        .frame(minWidth: 150)
    }
}

#Preview {
    SettingsContainer()
        .environmentObject(AppState())
        .frame(width: 700, height: 500)
}
