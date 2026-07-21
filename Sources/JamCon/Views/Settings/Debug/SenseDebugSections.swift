import SwiftUI

// MARK: - Buttons Section

struct DebugButtonsSection: View {
    @ObservedObject var telemetry: DebugTelemetryState
    let isLeft: Bool
    let stickTouch: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Button States")
                .font(.subheadline)
                .fontWeight(.medium)
                .foregroundColor(.secondary)

            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 8) {
                GridRow {
                    Text(isLeft ? "Triangle" : "Circle")
                        .font(.system(size: 12, weight: .medium))
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Color.clear.gridCellUnsizedAxes(.horizontal)
                    Arrow()
                    PressIndicator(active: telemetry.buttonStates[.faceTop] ?? false)
                }

                GridRow {
                    Text(isLeft ? "Square" : "X")
                        .font(.system(size: 12, weight: .medium))
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Color.clear.gridCellUnsizedAxes(.horizontal)
                    Arrow()
                    PressIndicator(active: telemetry.buttonStates[.faceBottom] ?? false)
                }

                GridRow {
                    Text(isLeft ? "L1 Grip" : "R1 Grip")
                        .font(.system(size: 12, weight: .medium))
                        .frame(maxWidth: .infinity, alignment: .leading)
                    AnalogBar(value: telemetry.safeReportByte(6), color: .orange)
                    Arrow()
                    PressIndicator(active: telemetry.buttonStates[.bumper] ?? false)
                }

                GridRow {
                    Text(isLeft ? "L2 Trigger" : "R2 Trigger")
                        .font(.system(size: 12, weight: .medium))
                        .frame(maxWidth: .infinity, alignment: .leading)
                    AnalogBar(value: telemetry.safeReportByte(5), color: .orange)
                    Arrow()
                    AnalogBar(value: telemetry.safeReportByte(4), color: .blue)
                }

                GridRow {
                    Text(isLeft ? "L3 Stick" : "R3 Stick")
                        .font(.system(size: 12, weight: .medium))
                        .frame(maxWidth: .infinity, alignment: .leading)
                    TouchIndicator(active: stickTouch)
                    Arrow()
                    PressIndicator(active: telemetry.buttonStates[.stickClick] ?? false)
                }

                GridRow {
                    Text(isLeft ? "L4 Create" : "R4 Options")
                        .font(.system(size: 12, weight: .medium))
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Color.clear.gridCellUnsizedAxes(.horizontal)
                    Arrow()
                    PressIndicator(active: telemetry.buttonStates[.menuButton] ?? false)
                }

                GridRow {
                    Text(isLeft ? "L5 PS" : "R5 PS")
                        .font(.system(size: 12, weight: .medium))
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Color.clear.gridCellUnsizedAxes(.horizontal)
                    Arrow()
                    PressIndicator(active: telemetry.buttonStates[.playStation] ?? false)
                }
            }
        }
        .padding()
        .background(Color.secondary.opacity(0.03))
        .cornerRadius(8)
    }
}

// MARK: - Stick Section

struct DebugStickSection: View {
    @ObservedObject var telemetry: DebugTelemetryState
    let isLeft: Bool
    let stickTouch: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Stick Position")
                .font(.subheadline)
                .fontWeight(.medium)
                .foregroundColor(.secondary)

            HStack(spacing: 16) {
                StickPositionIndicator(
                    x: telemetry.safeReportByte(SenseHIDProtocol.Offset.joystickX),
                    y: telemetry.safeReportByte(SenseHIDProtocol.Offset.joystickY),
                    isPressed: telemetry.buttonStates[.stickClick] ?? false
                )

                VStack(spacing: 8) {
                    StickAxisRow(
                        name: "X",
                        value: telemetry.safeReportByte(SenseHIDProtocol.Offset.joystickX)
                    )
                    StickAxisRow(
                        name: "Y",
                        value: telemetry.safeReportByte(SenseHIDProtocol.Offset.joystickY)
                    )
                }
            }

            Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 6) {
                GridRow {
                    Text(isLeft ? "L3 Stick" : "R3 Stick")
                        .font(.system(size: 12, weight: .medium))
                    TouchIndicator(active: stickTouch)
                    Arrow()
                    PressIndicator(active: telemetry.buttonStates[.stickClick] ?? false)
                }
            }
        }
        .padding()
        .background(Color.secondary.opacity(0.03))
        .cornerRadius(8)
    }
}

// MARK: - Raw Report Section

struct DebugRawReportSection: View {
    @ObservedObject var telemetry: DebugTelemetryState
    let currentTime: Date
    let bytesPerRow: Int
    let totalBytes: Int
    let decaySeconds: Double

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Raw HID Report")
                    .font(.subheadline)
                    .fontWeight(.medium)
                    .foregroundColor(.secondary)
                Spacer()
                Text("Length: \(telemetry.reportLength) bytes")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            HStack(spacing: 16) {
                HStack(spacing: 4) {
                    Circle().fill(Color.green).frame(width: 10, height: 10)
                    Text("Just changed")
                        .font(.caption2)
                }
                HStack(spacing: 4) {
                    Circle().fill(Color.red).frame(width: 10, height: 10)
                    Text("Stable (5s+)")
                        .font(.caption2)
                }
            }
            .foregroundColor(.secondary)

            VStack(alignment: .leading, spacing: 6) {
                ForEach(0..<10, id: \.self) { row in
                    HStack(spacing: 4) {
                        Text(String(format: "%02d:", row * bytesPerRow))
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundColor(.secondary)
                            .frame(width: 24, alignment: .trailing)

                        ForEach(0..<bytesPerRow, id: \.self) { col in
                            let i = row * bytesPerRow + col
                            if i < totalBytes {
                                ByteCell(
                                    value: telemetry.safeReportByte(i),
                                    index: i,
                                    color: colorForByte(i, at: currentTime)
                                )
                            } else {
                                VStack(spacing: 0) {
                                    Text("--")
                                        .font(.system(size: 13, design: .monospaced))
                                        .frame(width: 26, height: 22)
                                        .foregroundColor(.secondary.opacity(0.3))
                                    Text("")
                                        .font(.system(size: 8))
                                }
                            }
                        }
                    }
                }
            }
        }
        .padding()
        .background(Color.secondary.opacity(0.03))
        .cornerRadius(8)
    }

    private func colorForByte(_ index: Int, at currentTime: Date) -> Color {
        guard index < telemetry.byteLastChanged.count else { return .red }
        let lastChanged = telemetry.byteLastChanged[index]
        let elapsed = currentTime.timeIntervalSince(lastChanged)
        let progress = min(1.0, max(0.0, elapsed / decaySeconds))
        return Color(
            red: progress,
            green: 1.0 - progress,
            blue: 0
        )
    }
}
