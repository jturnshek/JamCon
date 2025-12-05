import SwiftUI

// MARK: - Debug Tab

struct DebugTab: View {
    @ObservedObject var appState: AppState

    private let bytesPerRow = 8
    private let totalBytes = 78
    private let decaySeconds: Double = 5.0

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.1)) { timeline in
            VStack(spacing: 0) {
                HStack {
                    Text("Raw HID Report")
                        .font(.headline)
                    Spacer()
                    Text("Length: \(appState.reportLength) bytes")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .padding()
                .background(Color.secondary.opacity(0.1))

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
                .padding(.vertical, 6)
                .foregroundColor(.secondary)

                Divider()

                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
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
                                                color: colorForByte(i, at: timeline.date)
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

                        Divider()

                        ButtonLabView(
                            buttonName: "Circle ✓ (Bit 2), X, Grip (R1)",
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

                        StatusLabView(
                            title: "Connection Timers (reset on reconnect)",
                            bytes: [14, 32, 52],
                            reportBytes: appState.reportBytes,
                            byteLastChanged: appState.byteLastChanged,
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

                        Text("PSVR2-controller-explorer Claims")
                            .font(.title3)
                            .fontWeight(.semibold)
                            .foregroundColor(.purple)

                        IMUAxisTesterView(reportBytes: appState.reportBytes)

                        BatteryStatusView(reportBytes: appState.reportBytes)

                        TriggerFeedbackView(reportBytes: appState.reportBytes)

                        CRC32ValidatorView(reportBytes: appState.reportBytes)

                        OutputTestView(
                            controller: appState.controller,
                            isConnected: appState.isConnected
                        )

                        Divider()
                            .padding(.vertical, 8)

                        Text("Motion Control Hypotheses")
                            .font(.title3)
                            .fontWeight(.semibold)
                            .foregroundColor(.blue)

                        GyroProcessingPipelineView(
                            rawX: appState.lastGyroX,
                            rawY: appState.lastGyroY,
                            rawZ: appState.lastGyroZ,
                            gyroProcessor: appState.gyroProcessor
                        )

                        AxisMappingHypothesesView(
                            rawX: appState.lastGyroX,
                            rawY: appState.lastGyroY,
                            rawZ: appState.lastGyroZ
                        )

                        IndividualAxisView(
                            rawX: appState.lastGyroX,
                            rawY: appState.lastGyroY,
                            rawZ: appState.lastGyroZ
                        )

                        MouseMovementPreviewView(
                            rawX: appState.lastGyroX,
                            rawY: appState.lastGyroY,
                            rawZ: appState.lastGyroZ
                        )

                        Divider()
                            .padding(.vertical, 8)

                        Text("Sensor Fusion (Gravity-Aware)")
                            .font(.title3)
                            .fontWeight(.semibold)
                            .foregroundColor(.orange)

                        SensorFusionDebugView(
                            gyroX: appState.lastGyroX,
                            gyroY: appState.lastGyroY,
                            gyroZ: appState.lastGyroZ,
                            accelX: appState.lastAccelX,
                            accelY: appState.lastAccelY,
                            accelZ: appState.lastAccelZ
                        )
                    }
                    .padding()
                }
            }
        }
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
