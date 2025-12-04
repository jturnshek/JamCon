import SwiftUI
import AppKit

struct LogPane: View {
    @ObservedObject private var logger = AppLogger.shared
    @State private var filterText = ""
    @State private var autoScroll = true
    @State private var showLevel: AppLogger.LogEntry.Level? = nil

    var body: some View {
        VStack(spacing: 0) {
            // Toolbar
            HStack {
                // Filter
                HStack {
                    Image(systemName: "magnifyingglass")
                        .foregroundColor(.secondary)
                    TextField("Filter logs...", text: $filterText)
                        .textFieldStyle(.plain)
                }
                .padding(6)
                .background(Color(nsColor: .textBackgroundColor))
                .cornerRadius(6)
                .frame(maxWidth: 200)

                Spacer()

                // Level filter
                Picker("Level", selection: $showLevel) {
                    Text("All").tag(nil as AppLogger.LogEntry.Level?)
                    Text("Debug").tag(AppLogger.LogEntry.Level.debug as AppLogger.LogEntry.Level?)
                    Text("Info").tag(AppLogger.LogEntry.Level.info as AppLogger.LogEntry.Level?)
                    Text("Warning").tag(AppLogger.LogEntry.Level.warning as AppLogger.LogEntry.Level?)
                    Text("Error").tag(AppLogger.LogEntry.Level.error as AppLogger.LogEntry.Level?)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 300)

                Toggle("Auto-scroll", isOn: $autoScroll)
                    .toggleStyle(.checkbox)

                Button {
                    copyLogsToClipboard()
                } label: {
                    Label("Copy", systemImage: "doc.on.doc")
                }
                .buttonStyle(.bordered)

                Button {
                    logger.clear()
                } label: {
                    Label("Clear", systemImage: "trash")
                }
                .buttonStyle(.bordered)
            }
            .padding()

            Divider()

            // Log entries
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(filteredEntries) { entry in
                            LogEntryRow(entry: entry)
                                .id(entry.id)
                        }
                    }
                    .padding(.horizontal)
                    .padding(.vertical, 8)
                }
                .onChange(of: logger.entries.count) { _, _ in
                    if autoScroll, let last = filteredEntries.last {
                        withAnimation(.easeOut(duration: 0.1)) {
                            proxy.scrollTo(last.id, anchor: .bottom)
                        }
                    }
                }
            }
        }
        .navigationTitle("Log")
        .frame(minWidth: 600, minHeight: 400)
    }

    private var filteredEntries: [AppLogger.LogEntry] {
        logger.entries.filter { entry in
            // Level filter
            if let level = showLevel, entry.level != level {
                return false
            }

            // Text filter
            if !filterText.isEmpty {
                let searchText = filterText.lowercased()
                let matches = entry.message.lowercased().contains(searchText) ||
                              entry.category.lowercased().contains(searchText)
                if !matches { return false }
            }

            return true
        }
    }

    private func copyLogsToClipboard() {
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "HH:mm:ss.SSS"

        let text = filteredEntries.map { entry in
            "\(dateFormatter.string(from: entry.timestamp)) \(entry.level.rawValue) [\(entry.category)] \(entry.message)"
        }.joined(separator: "\n")

        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

// MARK: - Log Entry Row

private struct LogEntryRow: View {
    let entry: AppLogger.LogEntry

    private let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            // Timestamp
            Text(dateFormatter.string(from: entry.timestamp))
                .font(.system(.caption, design: .monospaced))
                .foregroundColor(.secondary)
                .frame(width: 90, alignment: .leading)

            // Level indicator
            Text(entry.level.rawValue)
                .font(.system(.caption, design: .monospaced))
                .fontWeight(.medium)
                .foregroundColor(levelColor)
                .frame(width: 50, alignment: .leading)

            // Category
            Text("[\(entry.category)]")
                .font(.system(.caption, design: .monospaced))
                .foregroundColor(.purple)
                .frame(width: 120, alignment: .leading)

            // Message
            Text(entry.message)
                .font(.system(.caption, design: .monospaced))
                .foregroundColor(.primary)
                .textSelection(.enabled)

            Spacer()
        }
        .padding(.vertical, 2)
    }

    private var levelColor: Color {
        switch entry.level {
        case .debug: return .gray
        case .info: return .blue
        case .warning: return .orange
        case .error: return .red
        }
    }
}

#Preview {
    LogPane()
        .frame(width: 800, height: 500)
        .onAppear {
            // Add some sample logs
            logInfo("Application started", category: "App")
            logDebug("Initializing controllers", category: "App")
            logInfo("Device discovered: ZY RMC", category: "AirMouse")
            logInfo("VendorID: 0x1234, ProductID: 0x5678", category: "AirMouse")
            logWarning("Device not seized properly", category: "AirMouse")
            logError("Failed to connect", category: "JoyCon")
        }
}
