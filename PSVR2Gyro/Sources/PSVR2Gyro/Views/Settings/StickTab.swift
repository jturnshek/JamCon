import SwiftUI

// MARK: - Stick Tab

struct StickTab: View {
    @ObservedObject var appState: AppState

    private var isLeft: Bool { appState.isLeftController }
    private var side: String { isLeft ? "Left" : "Right" }

    private var isStickTouched: Bool {
        (appState.safeReportByte(11) & 0x04) != 0
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("\(side) Stick")
                    .font(.headline)
                Spacer()
                ConnectionIndicator(isConnected: appState.isConnected)
            }
            .padding(.horizontal)
            .padding(.vertical, 10)
            .background(Color.secondary.opacity(0.05))

            if appState.isConnected {
                ScrollView {
                    VStack(spacing: 12) {
                        HStack(spacing: 16) {
                            StickPositionIndicator(
                                x: appState.safeReportByte(2),
                                y: appState.safeReportByte(3),
                                isPressed: appState.buttonStates[.stickClick] ?? false
                            )

                            VStack(spacing: 8) {
                                StickAxisRow(
                                    name: "X",
                                    value: appState.safeReportByte(2)
                                )
                                StickAxisRow(
                                    name: "Y",
                                    value: appState.safeReportByte(3)
                                )
                            }
                        }

                        Divider()

                        Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 6) {
                            GridRow {
                                Text(isLeft ? "L3 Stick" : "R3 Stick")
                                    .font(.system(size: 12, weight: .medium))
                                TouchIndicator(active: isStickTouched)
                                Arrow()
                                PressIndicator(active: appState.buttonStates[.stickClick] ?? false)
                            }
                        }
                    }
                    .padding()
                }
            } else {
                Spacer()
                Text("Connect a controller to see stick position")
                    .foregroundColor(.secondary)
                Spacer()
            }
        }
    }
}

struct StickPositionIndicator: View {
    let x: UInt8
    let y: UInt8
    let isPressed: Bool

    private let size: CGFloat = 80
    private var normalizedX: CGFloat { (CGFloat(x) - 128) / 128 }
    private var normalizedY: CGFloat { (CGFloat(y) - 128) / 128 }

    var body: some View {
        ZStack {
            Rectangle()
                .fill(Color.secondary.opacity(0.1))

            Path { path in
                path.move(to: CGPoint(x: size/2, y: 0))
                path.addLine(to: CGPoint(x: size/2, y: size))
                path.move(to: CGPoint(x: 0, y: size/2))
                path.addLine(to: CGPoint(x: size, y: size/2))
            }
            .stroke(Color.secondary.opacity(0.2), lineWidth: 1)

            Circle()
                .fill(isPressed ? Color.green : Color.blue)
                .frame(width: 10, height: 10)
                .offset(
                    x: normalizedX * (size / 2 - 5),
                    y: normalizedY * (size / 2 - 5)
                )
        }
        .frame(width: size, height: size)
        .cornerRadius(4)
        .overlay(
            RoundedRectangle(cornerRadius: 4)
                .stroke(Color.secondary.opacity(0.2), lineWidth: 1)
        )
    }
}

struct StickAxisRow: View {
    let name: String
    let value: UInt8

    private var normalized: Double { (Double(value) - 128) / 128 }

    var body: some View {
        HStack(spacing: 8) {
            Text(name)
                .font(.system(size: 12, weight: .medium))
                .frame(width: 16, alignment: .leading)

            GeometryReader { geo in
                ZStack {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(Color.secondary.opacity(0.15))

                    let barWidth = abs(normalized) * (geo.size.width / 2)
                    RoundedRectangle(cornerRadius: 2)
                        .fill(Color.blue)
                        .frame(width: barWidth)
                        .offset(x: normalized >= 0 ? barWidth / 2 : -barWidth / 2)

                    Rectangle()
                        .fill(Color.secondary.opacity(0.4))
                        .frame(width: 1)
                }
            }
            .frame(height: 14)

            Text("\(value)")
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(.secondary)
                .frame(width: 28, alignment: .trailing)
        }
    }
}
