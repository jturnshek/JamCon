import SwiftUI

/// Empty state view shown when no controller is connected
struct NoControllerView: View {
    let icon: String
    let message: String

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 48))
                .foregroundColor(.secondary.opacity(0.5))
            Text("No controller connected")
                .font(.headline)
                .foregroundColor(.secondary)
            Text(message)
                .font(.caption)
                .foregroundColor(.secondary.opacity(0.7))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
