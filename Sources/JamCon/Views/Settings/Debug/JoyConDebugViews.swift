import SwiftUI
import QuartzCore

// MARK: - Joy-Con Debug View

struct JoyConDebugView: View {
    @ObservedObject var telemetry: DebugTelemetryState
    let isLeft: Bool
    let bytesPerRow: Int
    let totalBytes: Int
    let decaySeconds: Double
    let currentTime: Date

    // Joystick start byte differs by controller side
    private var joystickStartByte: Int {
        isLeft ? JoyConHIDProtocol.Offset.leftStickStart : JoyConHIDProtocol.Offset.rightStickStart
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                InputPerformanceMetricsView(telemetry: telemetry)

                Divider()

                // Pipeline visualization (all 3 stages)
                GyroPipelineView(controllerKind: .joyCon, telemetry: telemetry)

                CalibrationDebugView(telemetry: telemetry)

                JoyConQuickRows(
                    telemetry: telemetry,
                    isLeft: isLeft,
                    currentTime: currentTime
                )

                JoystickLabView(
                    xByte: joystickStartByte,
                    yByte: joystickStartByte + 1,
                    useJoyConPacking: true,
                    reportBytes: telemetry.reportBytes
                )

                DebugRawReportSection(
                    telemetry: telemetry,
                    currentTime: currentTime,
                    bytesPerRow: bytesPerRow,
                    totalBytes: totalBytes,
                    decaySeconds: decaySeconds
                )
            }
            .padding()
        }
    }
}

// MARK: - Gyro Section

struct CalibrationDebugView: View {
    @ObservedObject var telemetry: DebugTelemetryState

    private var gyroDebug: DebugBuffer.GyroDebug? {
        telemetry.gyroDebug
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Calibration")
                    .font(.subheadline)
                    .fontWeight(.medium)
                    .foregroundColor(.secondary)
                Spacer()
                if let debug = gyroDebug {
                    Label(debug.calibrated ? "Calibrated" : "Calibrating", systemImage: debug.calibrated ? "checkmark.circle" : "clock")
                        .font(.caption)
                        .foregroundColor(debug.calibrated ? .green : .orange)
                }
            }

            if let debug = gyroDebug {
                VStack(alignment: .leading, spacing: 4) {
                    Text(String(format: "Bias (deg/s): X %.3f  Y %.3f  Z %.3f", debug.biasX, debug.biasY, debug.biasZ))
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(.secondary)
                    if let neutralTs = debug.lastNeutralUpdate {
                        Text(String(format: "Last auto-neutral: %.2fs ago", CACurrentMediaTime() - neutralTs))
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundColor(.secondary)
                    } else {
                        Text("Last auto-neutral: n/a")
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundColor(.secondary)
                    }
                    Text(String(format: "Observed rate: %.1f Hz", debug.observedSampleRate))
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(.secondary)
                }
            } else {
                Text("No gyro debug data yet.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .padding()
        .background(Color.secondary.opacity(0.03))
        .cornerRadius(8)
    }
}

// MARK: - Joy-Con Quick Byte Rows

struct JoyConQuickRows: View {
    @ObservedObject var telemetry: DebugTelemetryState
    let isLeft: Bool
    let currentTime: Date

    private let motionBytes = Array(36...47)  // Hypothesis: latest IMU sample block
    private let batteryBytes = [2]            // Battery nibble (upper)

    // Button bytes differ by controller side
    private var buttonBytes: [Int] {
        isLeft ? [4, 5] : [3, 4]  // Left uses bytes 4-5, Right uses bytes 3-4
    }

    // Joystick bytes differ by controller side
    private var joystickBytes: [Int] {
        isLeft ? [6, 7, 8] : [9, 10, 11]  // Left stick at 6-8, Right stick at 9-11
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            JoyConRow(title: "Motion (hypothesis: bytes 36-47)", bytes: motionBytes, telemetry: telemetry, currentTime: currentTime)
            JoyConRow(title: "Buttons (\(isLeft ? "Left: bytes 4-5" : "Right: bytes 3-4"))", bytes: buttonBytes, telemetry: telemetry, currentTime: currentTime)
            JoyConRow(title: "Joystick (\(isLeft ? "Left: bytes 6-8" : "Right: bytes 9-11"))", bytes: joystickBytes, telemetry: telemetry, currentTime: currentTime)
            JoyConRow(title: "Battery", bytes: batteryBytes, telemetry: telemetry, currentTime: currentTime)
            JoyConButtonTester(telemetry: telemetry, isLeft: isLeft, currentTime: currentTime)
        }
        .padding()
        .background(Color.secondary.opacity(0.03))
        .cornerRadius(8)
    }
}

private struct JoyConButtonTester: View {
    @ObservedObject var telemetry: DebugTelemetryState
    let isLeft: Bool
    let currentTime: Date

    private struct JoyConButtonEntry: Identifiable {
        let id = UUID()
        let name: String
        let byte: Int
        let mask: UInt8
    }

    // Right Joy-Con buttons (bytes 3-4)
    private let rightButtons: [JoyConButtonEntry] = [
        .init(name: "Y", byte: 3, mask: 0x01),
        .init(name: "X", byte: 3, mask: 0x02),
        .init(name: "B", byte: 3, mask: 0x04),
        .init(name: "A", byte: 3, mask: 0x08),
        .init(name: "SR", byte: 3, mask: 0x10),
        .init(name: "SL", byte: 3, mask: 0x20),
        .init(name: "R", byte: 3, mask: 0x40),
        .init(name: "ZR", byte: 3, mask: 0x80),
        .init(name: "Plus", byte: 4, mask: 0x02),
        .init(name: "Stick Click", byte: 4, mask: 0x04),
        .init(name: "Home", byte: 4, mask: 0x10),
    ]

    // Left Joy-Con buttons (bytes 4-5)
    // From JoyConHIDProtocol.LeftButton:
    // Byte 4: down=0x01, up=0x02, right=0x04, left=0x08, sr=0x10, sl=0x20, l=0x40, zl=0x80
    // Byte 5: minus=0x01, lStick=0x04, capture=0x20
    private let leftButtons: [JoyConButtonEntry] = [
        .init(name: "Down", byte: 4, mask: 0x01),
        .init(name: "Up", byte: 4, mask: 0x02),
        .init(name: "Right", byte: 4, mask: 0x04),
        .init(name: "Left", byte: 4, mask: 0x08),
        .init(name: "SR", byte: 4, mask: 0x10),
        .init(name: "SL", byte: 4, mask: 0x20),
        .init(name: "L", byte: 4, mask: 0x40),
        .init(name: "ZL", byte: 4, mask: 0x80),
        .init(name: "Minus", byte: 5, mask: 0x01),
        .init(name: "Stick Click", byte: 5, mask: 0x04),
        .init(name: "Capture", byte: 5, mask: 0x20),
    ]

    private var buttons: [JoyConButtonEntry] {
        isLeft ? leftButtons : rightButtons
    }

    private func isPressed(_ entry: JoyConButtonEntry) -> Bool {
        let value = telemetry.safeReportByte(entry.byte)
        return (value & entry.mask) != 0
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Button Tester (\(isLeft ? "Left" : "Right") Joy-Con)")
                .font(.headline)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 110), spacing: 8)], spacing: 8) {
                ForEach(buttons) { entry in
                    HStack(spacing: 6) {
                        Circle()
                            .fill(isPressed(entry) ? Color.green : Color.secondary.opacity(0.3))
                            .frame(width: 10, height: 10)
                        Text(entry.name)
                            .font(.system(size: 12, weight: .medium))
                        Text(String(format: "b%d 0x%02X", entry.byte, entry.mask))
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundColor(.secondary)
                    }
                    .padding(6)
                    .background(Color.secondary.opacity(0.08))
                    .cornerRadius(6)
                }
            }

            // Also show raw byte values for debugging
            VStack(alignment: .leading, spacing: 4) {
                Text("Raw Button Bytes")
                    .font(.caption)
                    .foregroundColor(.secondary)
                if isLeft {
                    Text(String(format: "Byte 4: 0x%02X (%@)", telemetry.safeReportByte(4), byteToBinary(telemetry.safeReportByte(4))))
                        .font(.system(size: 11, design: .monospaced))
                    Text(String(format: "Byte 5: 0x%02X (%@)", telemetry.safeReportByte(5), byteToBinary(telemetry.safeReportByte(5))))
                        .font(.system(size: 11, design: .monospaced))
                } else {
                    Text(String(format: "Byte 3: 0x%02X (%@)", telemetry.safeReportByte(3), byteToBinary(telemetry.safeReportByte(3))))
                        .font(.system(size: 11, design: .monospaced))
                    Text(String(format: "Byte 4: 0x%02X (%@)", telemetry.safeReportByte(4), byteToBinary(telemetry.safeReportByte(4))))
                        .font(.system(size: 11, design: .monospaced))
                }
            }
            .padding(.top, 8)
        }
    }

    private func byteToBinary(_ value: UInt8) -> String {
        let binary = String(value, radix: 2)
        return String(repeating: "0", count: max(0, 8 - binary.count)) + binary
    }
}

private struct JoyConRow: View {
    let title: String
    let bytes: [Int]
    @ObservedObject var telemetry: DebugTelemetryState
    let currentTime: Date

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.caption)
                .foregroundColor(.secondary)
            HStack(spacing: 4) {
                ForEach(bytes, id: \.self) { i in
                    ByteCell(
                        value: telemetry.safeReportByte(i),
                        index: i,
                        color: colorForByte(i)
                    )
                }
            }
        }
    }

    private func colorForByte(_ index: Int) -> Color {
        guard index < telemetry.byteLastChanged.count else { return .red }
        let lastChanged = telemetry.byteLastChanged[index]
        let elapsed = currentTime.timeIntervalSince(lastChanged)
        let progress = min(1.0, max(0.0, elapsed / 5.0))
        return Color(
            red: progress,
            green: 1.0 - progress,
            blue: 0
        )
    }
}
