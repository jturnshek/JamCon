import SwiftUI

// MARK: - Status Indicator Components

/// Generic status dot indicator for binary states
struct StatusDot: View {
    let isActive: Bool
    var activeColor: Color = .green
    var inactiveColor: Color = .red
    var size: CGFloat = 8

    var body: some View {
        Circle()
            .fill(isActive ? activeColor : inactiveColor)
            .frame(width: size, height: size)
    }
}

/// Connection status indicator with dot and label
struct ConnectionIndicator: View {
    let isConnected: Bool

    var body: some View {
        HStack(spacing: 6) {
            StatusDot(isActive: isConnected)
            Text(isConnected ? "Connected" : "Disconnected")
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }
}

/// Battery level indicator with icon and percentage
struct BatteryIndicator: View {
    let level: Int  // 0-100

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: BatteryHelper.icon(for: level))
                .foregroundColor(BatteryHelper.color(for: level))
                .font(.system(size: 14))
            Text("\(level)%")
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(.secondary)
        }
    }
}

/// Extended battery indicator with optional progress bar
struct BatteryIndicatorWithBar: View {
    let level: Int  // 0-100
    var barWidth: CGFloat = 60
    var barHeight: CGFloat = 12

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: BatteryHelper.icon(for: level))
                .foregroundColor(BatteryHelper.color(for: level))
            Text("\(level)%")
                .font(.system(.body, design: .monospaced))

            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 3)
                        .fill(Color.secondary.opacity(0.2))
                    RoundedRectangle(cornerRadius: 3)
                        .fill(BatteryHelper.color(for: level))
                        .frame(width: geo.size.width * CGFloat(level) / 100.0)
                }
            }
            .frame(width: barWidth, height: barHeight)
        }
    }
}
