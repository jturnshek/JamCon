import SwiftUI

// MARK: - Debug Tab

struct DebugTab: View {
    @ObservedObject var appState: AppState

    private let bytesPerRow = 8
    private let totalBytes = 78
    private let decaySeconds: Double = 5.0

    private var isLeft: Bool { appState.isLeftController }
    private var side: String { isLeft ? "Left" : "Right" }

    @State private var cachedBatteryLevel: Int = 0

    private var byte11: UInt8 { appState.safeReportByte(PSVR2HIDProtocol.Offset.touchStates) }
    private var faceTopTouch: Bool { (byte11 & 0x01) != 0 }
    private var faceBottomTouch: Bool { (byte11 & 0x02) != 0 }
    private var stickTouch: Bool { (byte11 & PSVR2HIDProtocol.TouchStateMask.joystickTouch) != 0 }

    var body: some View {
        VStack(spacing: 0) {
            // Header with toggle - matches TabHeader style but adds Live toggle
            HStack {
                Text("\(side) Controller")
                    .font(.headline)
                Spacer()
                Toggle("Live Rendering", isOn: $appState.debugRenderingEnabled)
                    .toggleStyle(.switch)
                    .labelsHidden()
                Text("Live")
                    .font(.caption)
                    .foregroundColor(.secondary)
                if appState.isConnected {
                    BatteryIndicator(level: cachedBatteryLevel)
                }
                ConnectionIndicator(isConnected: appState.isConnected)
            }
            .padding(.horizontal)
            .padding(.vertical, 10)
            .background(Color.secondary.opacity(0.05))
            .onAppear {
                cachedBatteryLevel = BatteryHelper.level(
                    from: appState.safeReportByte(PSVR2HIDProtocol.Offset.battery)
                )
            }

            if appState.debugRenderingEnabled && appState.isConnected {
                TimelineView(.periodic(from: .now, by: 0.1)) { timeline in
                    ScrollView {
                        VStack(alignment: .leading, spacing: 16) {
                            // Section 1: Gyro/Motion
                            DebugGyroSection(appState: appState)

                            Divider()

                            // Section 2: Buttons
                            DebugButtonsSection(
                                appState: appState,
                                isLeft: isLeft,
                                faceTopTouch: faceTopTouch,
                                faceBottomTouch: faceBottomTouch,
                                stickTouch: stickTouch
                            )

                            Divider()

                            // Section 3: Stick
                            DebugStickSection(appState: appState, isLeft: isLeft, stickTouch: stickTouch)

                            Divider()

                            // Section 4: Raw HID Report
                            DebugRawReportSection(
                                appState: appState,
                                currentTime: timeline.date,
                                bytesPerRow: bytesPerRow,
                                totalBytes: totalBytes,
                                decaySeconds: decaySeconds
                            )

                            Divider()

                            // Section 5: Button Lab
                            ButtonLabView(
                                buttonName: "Circle, X, Grip (R1)",
                                candidateBytes: [9],
                                reportBytes: appState.reportBytes,
                                bitLastChanged: appState.bitLastChanged,
                                currentTime: timeline.date
                            )

                            ButtonLabView(
                                buttonName: "Joystick Click, Start, PlayStation",
                                candidateBytes: [10],
                                reportBytes: appState.reportBytes,
                                bitLastChanged: appState.bitLastChanged,
                                currentTime: timeline.date
                            )

                            JoystickLabView(
                                xByte: 2,
                                yByte: 3,
                                reportBytes: appState.reportBytes
                            )

                            AnalogLabView(
                                title: "Analog Inputs",
                                inputs: [
                                    ("Trigger (R2)", 4),
                                ],
                                reportBytes: appState.reportBytes
                            )

                            AnalogLabView(
                                title: "Capacitive / Proximity (Analog)",
                                inputs: [
                                    ("Trigger Proximity", 5),
                                    ("Grip Touch", 6),
                                ],
                                reportBytes: appState.reportBytes
                            )

                            ButtonLabView(
                                buttonName: "Touch States (Joystick bit 2, Grip bit 3)",
                                candidateBytes: [11],
                                reportBytes: appState.reportBytes,
                                bitLastChanged: appState.bitLastChanged,
                                currentTime: timeline.date
                            )

                            LogicalButtonTestView(
                                buttonStates: appState.buttonStates,
                                isLeftController: appState.isLeftController,
                                triggerValue: appState.safeReportByte(4),
                                joystickX: appState.safeReportByte(2),
                                joystickY: appState.safeReportByte(3)
                            )

                            Divider()
                                .padding(.vertical, 8)

                            Text("Sensor Data (Confirmed)")
                                .font(.title3)
                                .fontWeight(.semibold)
                                .foregroundColor(.green)

                            IMUAxisTesterView(reportBytes: appState.reportBytes)

                            BatteryStatusView(reportBytes: appState.reportBytes)
                        }
                        .padding()
                    }
                }
            } else if !appState.isConnected {
                Spacer()
                Text("Connect a controller to see debug data")
                    .foregroundColor(.secondary)
                Spacer()
            } else {
                Spacer()
                VStack(spacing: 12) {
                    Image(systemName: "pause.circle")
                        .font(.system(size: 48))
                        .foregroundColor(.secondary.opacity(0.5))
                    Text("Live rendering is paused")
                        .font(.headline)
                        .foregroundColor(.secondary)
                    Text("Enable the toggle above to see real-time data")
                        .font(.caption)
                        .foregroundColor(.secondary.opacity(0.7))
                }
                Spacer()
            }
        }
    }
}

// MARK: - Gyro Section

private struct DebugGyroSection: View {
    @ObservedObject var appState: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Motion / Gyro")
                .font(.subheadline)
                .fontWeight(.medium)
                .foregroundColor(.secondary)

            HStack(spacing: 16) {
                GyroVectorIndicator(
                    x: appState.lastGyroX,
                    y: appState.lastGyroY
                )

                VStack(spacing: 8) {
                    GyroAxisRow(
                        name: "Y",
                        label: "horizontal",
                        value: appState.lastGyroY
                    )
                    GyroAxisRow(
                        name: "X",
                        label: "vertical",
                        value: appState.lastGyroX
                    )
                }
            }
        }
        .padding()
        .background(Color.secondary.opacity(0.03))
        .cornerRadius(8)
    }
}

// MARK: - Buttons Section

private struct DebugButtonsSection: View {
    @ObservedObject var appState: AppState
    let isLeft: Bool
    let faceTopTouch: Bool
    let faceBottomTouch: Bool
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
                    TouchIndicator(active: faceTopTouch)
                    Arrow()
                    PressIndicator(active: appState.buttonStates[.faceTop] ?? false)
                }

                GridRow {
                    Text(isLeft ? "Square" : "X")
                        .font(.system(size: 12, weight: .medium))
                        .frame(maxWidth: .infinity, alignment: .leading)
                    TouchIndicator(active: faceBottomTouch)
                    Arrow()
                    PressIndicator(active: appState.buttonStates[.faceBottom] ?? false)
                }

                GridRow {
                    Text(isLeft ? "L1 Grip" : "R1 Grip")
                        .font(.system(size: 12, weight: .medium))
                        .frame(maxWidth: .infinity, alignment: .leading)
                    AnalogBar(value: appState.safeReportByte(6), color: .orange)
                    Arrow()
                    PressIndicator(active: appState.buttonStates[.bumper] ?? false)
                }

                GridRow {
                    Text(isLeft ? "L2 Trigger" : "R2 Trigger")
                        .font(.system(size: 12, weight: .medium))
                        .frame(maxWidth: .infinity, alignment: .leading)
                    AnalogBar(value: appState.safeReportByte(5), color: .orange)
                    Arrow()
                    AnalogBar(value: appState.safeReportByte(4), color: .blue)
                }

                GridRow {
                    Text(isLeft ? "L3 Stick" : "R3 Stick")
                        .font(.system(size: 12, weight: .medium))
                        .frame(maxWidth: .infinity, alignment: .leading)
                    TouchIndicator(active: stickTouch)
                    Arrow()
                    PressIndicator(active: appState.buttonStates[.stickClick] ?? false)
                }

                GridRow {
                    Text(isLeft ? "L4 Create" : "R4 Options")
                        .font(.system(size: 12, weight: .medium))
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Color.clear.gridCellUnsizedAxes(.horizontal)
                    Arrow()
                    PressIndicator(active: appState.buttonStates[.menuButton] ?? false)
                }

                GridRow {
                    Text(isLeft ? "L5 PS" : "R5 PS")
                        .font(.system(size: 12, weight: .medium))
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Color.clear.gridCellUnsizedAxes(.horizontal)
                    Arrow()
                    PressIndicator(active: appState.buttonStates[.playStation] ?? false)
                }
            }
        }
        .padding()
        .background(Color.secondary.opacity(0.03))
        .cornerRadius(8)
    }
}

// MARK: - Stick Section

private struct DebugStickSection: View {
    @ObservedObject var appState: AppState
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
                    x: appState.safeReportByte(PSVR2HIDProtocol.Offset.joystickX),
                    y: appState.safeReportByte(PSVR2HIDProtocol.Offset.joystickY),
                    isPressed: appState.buttonStates[.stickClick] ?? false
                )

                VStack(spacing: 8) {
                    StickAxisRow(
                        name: "X",
                        value: appState.safeReportByte(PSVR2HIDProtocol.Offset.joystickX)
                    )
                    StickAxisRow(
                        name: "Y",
                        value: appState.safeReportByte(PSVR2HIDProtocol.Offset.joystickY)
                    )
                }
            }

            Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 6) {
                GridRow {
                    Text(isLeft ? "L3 Stick" : "R3 Stick")
                        .font(.system(size: 12, weight: .medium))
                    TouchIndicator(active: stickTouch)
                    Arrow()
                    PressIndicator(active: appState.buttonStates[.stickClick] ?? false)
                }
            }
        }
        .padding()
        .background(Color.secondary.opacity(0.03))
        .cornerRadius(8)
    }
}

// MARK: - Raw Report Section

private struct DebugRawReportSection: View {
    @ObservedObject var appState: AppState
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
                Text("Length: \(appState.reportLength) bytes")
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
                                    value: appState.safeReportByte(i),
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
        guard index < appState.byteLastChanged.count else { return .red }
        let lastChanged = appState.byteLastChanged[index]
        let elapsed = currentTime.timeIntervalSince(lastChanged)
        let progress = min(1.0, max(0.0, elapsed / decaySeconds))
        return Color(
            red: progress,
            green: 1.0 - progress,
            blue: 0
        )
    }
}

// MARK: - Gyro Visualization Components (moved from MouseControlTab)

struct GyroVectorIndicator: View {
    let x: Int16  // Vertical (up/down tilting)
    let y: Int16  // Horizontal (left/right pointing)

    private let size: CGFloat = 80
    private let maxValue: CGFloat = 500  // Typical gyro range for visible motion

    private var normalizedX: CGFloat {
        CGFloat(x).clamped(to: -maxValue...maxValue) / maxValue
    }

    private var normalizedY: CGFloat {
        CGFloat(y).clamped(to: -maxValue...maxValue) / maxValue
    }

    var body: some View {
        ZStack {
            Rectangle()
                .fill(Color.secondary.opacity(0.1))

            // Crosshairs
            Path { path in
                path.move(to: CGPoint(x: size/2, y: 0))
                path.addLine(to: CGPoint(x: size/2, y: size))
                path.move(to: CGPoint(x: 0, y: size/2))
                path.addLine(to: CGPoint(x: size, y: size/2))
            }
            .stroke(Color.secondary.opacity(0.2), lineWidth: 1)

            // Vector dot - Y maps to horizontal, X maps to vertical
            Circle()
                .fill(Color.blue)
                .frame(width: 10, height: 10)
                .offset(
                    x: -normalizedY * (size / 2 - 5),  // Y -> horizontal (inverted for natural feel)
                    y: -normalizedX * (size / 2 - 5)   // X -> vertical (inverted for natural feel)
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

struct GyroAxisRow: View {
    let name: String
    let label: String
    let value: Int16

    private let maxValue: Double = 500

    private var normalized: Double {
        Double(value).clamped(to: -maxValue...maxValue) / maxValue
    }

    var body: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 0) {
                Text(name)
                    .font(.system(size: 12, weight: .medium))
                Text(label)
                    .font(.system(size: 9))
                    .foregroundColor(.secondary)
            }
            .frame(width: 60, alignment: .leading)

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
                .frame(width: 40, alignment: .trailing)
        }
    }
}

// MARK: - Stick Visualization Components (moved from StickTab)

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

// MARK: - Clamped Extension

private extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}
