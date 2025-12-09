import SwiftUI

// MARK: - Input Indicator Components

struct TouchIndicator: View {
    let active: Bool

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(active ? Color.orange : Color.secondary.opacity(0.2))
                .frame(width: 14, height: 14)
            Text("Touch")
                .font(.system(size: 11))
                .foregroundColor(.secondary)
            Spacer()
        }
        .frame(minWidth: 80, maxWidth: .infinity, alignment: .leading)
    }
}

struct PressIndicator: View {
    let active: Bool

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(active ? Color.green : Color.secondary.opacity(0.2))
                .frame(width: 14, height: 14)
            Text("Press")
                .font(.system(size: 11))
                .foregroundColor(.secondary)
            Spacer()
        }
        .frame(minWidth: 80, maxWidth: .infinity, alignment: .leading)
    }
}

struct Arrow: View {
    var body: some View {
        Image(systemName: "arrow.right")
            .font(.system(size: 11))
            .foregroundColor(.secondary)
            .frame(width: 20)
    }
}

struct AnalogBar: View {
    let value: UInt8
    var color: Color = .blue

    private var progress: Double { Double(value) / 255.0 }

    var body: some View {
        HStack(spacing: 6) {
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 3)
                        .fill(Color.secondary.opacity(0.15))
                    RoundedRectangle(cornerRadius: 3)
                        .fill(color)
                        .frame(width: max(0, geo.size.width * progress))
                }
            }
            .frame(height: 14)

            Text("\(value)")
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(.secondary)
                .frame(width: 28, alignment: .trailing)
        }
        .frame(minWidth: 80, maxWidth: .infinity, alignment: .leading)
    }
}
