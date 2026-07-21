import SwiftUI

struct SenseDebugView: View {
    @ObservedObject var telemetry: DebugTelemetryState
    let isLeft: Bool
    let bytesPerRow: Int
    let totalBytes: Int
    let decaySeconds: Double
    let currentTime: Date

    private var byte11: UInt8 { telemetry.safeReportByte(SenseHIDProtocol.Offset.touchStates) }
    private var stickTouch: Bool { (byte11 & SenseHIDProtocol.TouchStateMask.joystickTouch) != 0 }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                InputPerformanceMetricsView(telemetry: telemetry)

                Divider()

                // Section 1: Gyro Pipeline (all 3 stages)
                GyroPipelineView(controllerKind: .sense, telemetry: telemetry)

                Divider()

                // Section 2: Buttons
                DebugButtonsSection(
                    telemetry: telemetry,
                    isLeft: isLeft,
                    stickTouch: stickTouch
                )

                Divider()

                // Section 3: Stick
                DebugStickSection(telemetry: telemetry, isLeft: isLeft, stickTouch: stickTouch)

                Divider()

                // Section 4: Raw HID Report
                DebugRawReportSection(
                    telemetry: telemetry,
                    currentTime: currentTime,
                    bytesPerRow: bytesPerRow,
                    totalBytes: totalBytes,
                    decaySeconds: decaySeconds
                )

                Divider()

                // Section 5: Button Lab
                ButtonLabView(
                    buttonName: isLeft ? "Triangle, Square, Grip (L1)" : "Circle, X, Grip (R1)",
                    candidateBytes: [9],
                    reportBytes: telemetry.reportBytes,
                    bitLastChanged: telemetry.bitLastChanged,
                    currentTime: currentTime
                )

                ButtonLabView(
                    buttonName: isLeft ? "Joystick Click, Create, PlayStation" : "Joystick Click, Options, PlayStation",
                    candidateBytes: [10],
                    reportBytes: telemetry.reportBytes,
                    bitLastChanged: telemetry.bitLastChanged,
                    currentTime: currentTime
                )

                JoystickLabView(
                    xByte: 2,
                    yByte: 3,
                    useJoyConPacking: false,
                    reportBytes: telemetry.reportBytes
                )

                AnalogLabView(
                    title: "Analog Inputs",
                    inputs: [
                        (isLeft ? "Trigger (L2)" : "Trigger (R2)", 4),
                    ],
                    reportBytes: telemetry.reportBytes
                )

                AnalogLabView(
                    title: "Capacitive / Proximity (Analog)",
                    inputs: [
                        ("Trigger Proximity", 5),
                        ("Grip Touch", 6),
                    ],
                    reportBytes: telemetry.reportBytes
                )

                ButtonLabView(
                    buttonName: "Touch States (Joystick bit 2, Grip bit 3)",
                    candidateBytes: [11],
                    reportBytes: telemetry.reportBytes,
                    bitLastChanged: telemetry.bitLastChanged,
                    currentTime: currentTime
                )

                LogicalButtonTestView(
                    buttonStates: telemetry.buttonStates,
                    isLeftController: isLeft,
                    triggerValue: telemetry.safeReportByte(4),
                    joystickX: telemetry.safeReportByte(2),
                    joystickY: telemetry.safeReportByte(3)
                )

                Divider()
                    .padding(.vertical, 8)

                Text("Sensor Data (Confirmed)")
                    .font(.title3)
                    .fontWeight(.semibold)
                    .foregroundColor(.green)

                IMUAxisTesterView(reportBytes: telemetry.reportBytes)

                BatteryStatusView(reportBytes: telemetry.reportBytes)
            }
            .padding()
        }
    }
}
