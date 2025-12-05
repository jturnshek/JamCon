import SwiftUI

// MARK: - Status Indicator Components

struct ConnectionIndicator: View {
    let isConnected: Bool

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(isConnected ? Color.green : Color.red)
                .frame(width: 8, height: 8)
            Text(isConnected ? "Connected" : "Disconnected")
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }
}

struct BatteryIndicator: View {
    let level: Int  // 0-100

    private var color: Color {
        if level > 50 { return .green }
        if level > 20 { return .yellow }
        return .red
    }

    private var iconName: String {
        if level >= 75 { return "battery.100" }
        if level >= 50 { return "battery.75" }
        if level >= 25 { return "battery.50" }
        if level > 0 { return "battery.25" }
        return "battery.0"
    }

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: iconName)
                .foregroundColor(color)
                .font(.system(size: 14))
            Text("\(level)%")
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(.secondary)
        }
    }
}
