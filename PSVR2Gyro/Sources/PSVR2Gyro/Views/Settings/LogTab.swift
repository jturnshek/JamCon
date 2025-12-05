import SwiftUI
import AppKit

// MARK: - Log Tab

struct LogTab: View {
    @ObservedObject var appState: AppState
    @State private var copyFeedback = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Debug Log")
                    .font(.headline)
                Spacer()
                Button {
                    let logText = appState.debugLog.joined(separator: "\n")
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(logText, forType: .string)
                    copyFeedback = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                        copyFeedback = false
                    }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: copyFeedback ? "checkmark" : "doc.on.doc")
                        Text(copyFeedback ? "Copied!" : "Copy")
                    }
                }
                .buttonStyle(.borderless)

                Button("Clear") {
                    appState.debugLog.removeAll()
                }
                .buttonStyle(.borderless)
            }
            .padding()

            Divider()

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(Array(appState.debugLog.enumerated()), id: \.offset) { index, message in
                            Text(message)
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundColor(.primary)
                                .textSelection(.enabled)
                                .id(index)
                        }
                    }
                    .padding()
                }
                .onChange(of: appState.debugLog.count) { _, _ in
                    if let last = appState.debugLog.indices.last {
                        withAnimation {
                            proxy.scrollTo(last, anchor: .bottom)
                        }
                    }
                }
            }
            .background(Color(nsColor: .textBackgroundColor))
        }
    }
}
