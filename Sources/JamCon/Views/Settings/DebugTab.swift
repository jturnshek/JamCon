import SwiftUI

// MARK: - Device Debug View (Device-scoped)

struct DeviceDebugView: View {
    @ObservedObject var appState: AppState
    @ObservedObject private var telemetry: DebugTelemetryState
    let controller: ControllerInfo

    private let bytesPerRow = 8
    private let decaySeconds: Double = 5.0

    private var isManaged: Bool { appState.isDeviceManaged(controller) }

    private var liveBinding: Binding<Bool> {
        Binding(
            get: { appState.debugPollingEnabled },
            set: { enabled in
                if enabled {
                    guard isManaged else { return }
                    appState.startDebugPolling(targetKind: controller.kind)
                } else {
                    appState.stopDebugPolling()
                }
            }
        )
    }

    init(appState: AppState, controller: ControllerInfo) {
        self.appState = appState
        self.controller = controller
        _telemetry = ObservedObject(wrappedValue: appState.debugTelemetry)
    }

    private var totalBytes: Int {
        if telemetry.reportLength > 0 {
            return telemetry.reportLength
        }
        switch controller.kind {
        case .mouse:
            return 16
        case .joyCon:
            return JoyConHIDProtocol.reportLength
        case .sense:
            return SenseHIDProtocol.reportLength
        }
    }

    private var byte11: UInt8 { telemetry.safeReportByte(SenseHIDProtocol.Offset.touchStates) }
    private var faceTopTouch: Bool { (byte11 & 0x01) != 0 }
    private var faceBottomTouch: Bool { (byte11 & 0x02) != 0 }
    private var stickTouch: Bool { (byte11 & SenseHIDProtocol.TouchStateMask.joystickTouch) != 0 }

    var body: some View {
        Group {
            if !isManaged {
                ContentUnavailableView {
                    Label("Not Managed", systemImage: "checkmark.circle.badge.xmark")
                } description: {
                    Text("Toggle Managed for this device in Devices to enable input, then turn on Live.")
                }
            } else if !appState.debugPollingEnabled {
                ContentUnavailableView {
                    Label("Live Rendering Paused", systemImage: "pause.circle")
                } description: {
                    Text("Enable Live to see real-time data.")
                }
            } else {
                switch controller.kind {
                case .mouse:
                    TimelineView(.periodic(from: .now, by: 0.1)) { timeline in
                        MouseDebugView(
                            appState: appState,
                            telemetry: telemetry,
                            bytesPerRow: bytesPerRow,
                            totalBytes: totalBytes,
                            decaySeconds: decaySeconds,
                            currentTime: timeline.date
                        )
                    }

                case .joyCon:
                    TimelineView(.periodic(from: .now, by: 0.1)) { timeline in
                        JoyConDebugView(
                            appState: appState,
                            telemetry: telemetry,
                            isLeft: controller.isLeft,
                            bytesPerRow: bytesPerRow,
                            totalBytes: totalBytes,
                            decaySeconds: decaySeconds,
                            currentTime: timeline.date
                        )
                    }

                case .sense:
                    TimelineView(.periodic(from: .now, by: 0.1)) { timeline in
                        ScrollView {
                            VStack(alignment: .leading, spacing: 16) {
                                // Section 1: Gyro Pipeline (all 3 stages)
                                GyroPipelineView(appState: appState, telemetry: telemetry)

                                Divider()

                                // Section 2: Buttons
                                DebugButtonsSection(
                                    telemetry: telemetry,
                                    isLeft: controller.isLeft,
                                    faceTopTouch: faceTopTouch,
                                    faceBottomTouch: faceBottomTouch,
                                    stickTouch: stickTouch
                                )

                                Divider()

                                // Section 3: Stick
                                DebugStickSection(telemetry: telemetry, isLeft: controller.isLeft, stickTouch: stickTouch)

                                Divider()

                                // Section 4: Raw HID Report
                                DebugRawReportSection(
                                    telemetry: telemetry,
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
	                                    reportBytes: telemetry.reportBytes,
	                                    bitLastChanged: telemetry.bitLastChanged,
	                                    currentTime: timeline.date
	                                )

	                                ButtonLabView(
	                                    buttonName: "Joystick Click, Start, PlayStation",
	                                    candidateBytes: [10],
	                                    reportBytes: telemetry.reportBytes,
	                                    bitLastChanged: telemetry.bitLastChanged,
	                                    currentTime: timeline.date
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
	                                        ("Trigger (R2)", 4),
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
	                                    currentTime: timeline.date
	                                )

		                                LogicalButtonTestView(
		                                    buttonStates: telemetry.buttonStates,
		                                    isLeftController: controller.isLeft,
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
            }
        }
        .navigationTitle("Live Debug")
        .toolbar {
            ToolbarItem {
                Toggle("Live", isOn: liveBinding)
                    .toggleStyle(.switch)
                    .disabled(!isManaged)
            }
        }
        .onDisappear {
            appState.stopDebugPolling()
        }
    }
}

// MARK: - Debug Tab

struct DebugTab: View {
    @ObservedObject var appState: AppState
    @ObservedObject private var telemetry: DebugTelemetryState

    private let bytesPerRow = 8
    private let decaySeconds: Double = 5.0

    init(appState: AppState) {
        self.appState = appState
        _telemetry = ObservedObject(wrappedValue: appState.debugTelemetry)
    }

    private var liveBinding: Binding<Bool> {
        Binding(
            get: { appState.debugPollingEnabled },
            set: { enabled in
                if enabled {
                    appState.startDebugPolling()
                } else {
                    appState.stopDebugPolling()
                }
            }
        )
    }

    private var isMouse: Bool { appState.activeControllerKind == .mouse }
    private var isJoyCon: Bool { appState.activeControllerKind == .joyCon }
    private var isLeft: Bool { appState.isLeftController }
    private var side: String { isLeft ? "Left" : "Right" }
    private var totalBytes: Int {
        if telemetry.reportLength > 0 {
            return telemetry.reportLength
        }
        if isMouse {
            return 16  // Default display for mouse
        }
        return isJoyCon ? JoyConHIDProtocol.reportLength : SenseHIDProtocol.reportLength
    }

    private var byte11: UInt8 { telemetry.safeReportByte(SenseHIDProtocol.Offset.touchStates) }
    private var faceTopTouch: Bool { (byte11 & 0x01) != 0 }
    private var faceBottomTouch: Bool { (byte11 & 0x02) != 0 }
    private var stickTouch: Bool { (byte11 & SenseHIDProtocol.TouchStateMask.joystickTouch) != 0 }

    var body: some View {
        VStack(spacing: 0) {
            TabHeader(appState: appState) {
                Toggle("Live", isOn: liveBinding)
                    .toggleStyle(.switch)
            }

            if appState.debugPollingEnabled && appState.isConnected {
                if isMouse {
                    TimelineView(.periodic(from: .now, by: 0.1)) { timeline in
                        MouseDebugView(
                            appState: appState,
                            telemetry: telemetry,
                            bytesPerRow: bytesPerRow,
                            totalBytes: totalBytes,
                            decaySeconds: decaySeconds,
                            currentTime: timeline.date
                        )
                    }
                } else if isJoyCon {
                    TimelineView(.periodic(from: .now, by: 0.1)) { timeline in
                        JoyConDebugView(
                            appState: appState,
                            telemetry: telemetry,
                            isLeft: isLeft,
                            bytesPerRow: bytesPerRow,
                            totalBytes: totalBytes,
                            decaySeconds: decaySeconds,
                            currentTime: timeline.date
                        )
                    }
                } else {
                    TimelineView(.periodic(from: .now, by: 0.1)) { timeline in
                        ScrollView {
                            VStack(alignment: .leading, spacing: 16) {
                                // Section 1: Gyro Pipeline (all 3 stages)
                                GyroPipelineView(appState: appState, telemetry: telemetry)

                                Divider()

                                // Section 2: Buttons
                                DebugButtonsSection(
                                    telemetry: telemetry,
                                    isLeft: isLeft,
                                    faceTopTouch: faceTopTouch,
                                    faceBottomTouch: faceBottomTouch,
                                    stickTouch: stickTouch
                                )

                                Divider()

                                // Section 3: Stick
                                DebugStickSection(telemetry: telemetry, isLeft: isLeft, stickTouch: stickTouch)

                                Divider()

                                // Section 4: Raw HID Report
                                DebugRawReportSection(
                                    telemetry: telemetry,
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
	                                    reportBytes: telemetry.reportBytes,
	                                    bitLastChanged: telemetry.bitLastChanged,
	                                    currentTime: timeline.date
	                                )

	                                ButtonLabView(
	                                    buttonName: "Joystick Click, Start, PlayStation",
	                                    candidateBytes: [10],
	                                    reportBytes: telemetry.reportBytes,
	                                    bitLastChanged: telemetry.bitLastChanged,
	                                    currentTime: timeline.date
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
	                                        ("Trigger (R2)", 4),
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
	                                    currentTime: timeline.date
	                                )

		                                LogicalButtonTestView(
		                                    buttonStates: telemetry.buttonStates,
		                                    isLeftController: appState.isLeftController,
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
        .onDisappear {
            // Stop polling when leaving this tab
            appState.stopDebugPolling()
        }
    }
}

// MARK: - Joy-Con Debug View

private struct JoyConDebugView: View {
    @ObservedObject var appState: AppState
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
                // Pipeline visualization (all 3 stages)
                GyroPipelineView(appState: appState, telemetry: telemetry)

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

private struct CalibrationDebugView: View {
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

// MARK: - Buttons Section

private struct DebugButtonsSection: View {
    @ObservedObject var telemetry: DebugTelemetryState
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
                    PressIndicator(active: telemetry.buttonStates[.faceTop] ?? false)
                }

                GridRow {
                    Text(isLeft ? "Square" : "X")
                        .font(.system(size: 12, weight: .medium))
                        .frame(maxWidth: .infinity, alignment: .leading)
                    TouchIndicator(active: faceBottomTouch)
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

private struct DebugStickSection: View {
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

private struct DebugRawReportSection: View {
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

// MARK: - Joy-Con Quick Byte Rows

private struct JoyConQuickRows: View {
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
        String(value, radix: 2).leftPadded(toLength: 8, withPad: "0")
    }
}

private extension String {
    func leftPadded(toLength length: Int, withPad pad: Character) -> String {
        let padCount = length - self.count
        guard padCount > 0 else { return self }
        return String(repeating: pad, count: padCount) + self
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

// MARK: - Gyro Visualization Components (moved from MouseControlTab)

/// Observable class to track min/max gyro values for auto-scaling
class GyroRangeTracker: ObservableObject {
    @Published var minX: Int16 = 0
    @Published var maxX: Int16 = 0
    @Published var minY: Int16 = 0
    @Published var maxY: Int16 = 0
    @Published var minZ: Int16 = 0
    @Published var maxZ: Int16 = 0

    var maxAbsValue: CGFloat {
        let values = [abs(Int(minX)), abs(Int(maxX)), abs(Int(minY)), abs(Int(maxY)), abs(Int(minZ)), abs(Int(maxZ))]
        return max(100, CGFloat(values.max() ?? 100))  // Minimum scale of 100
    }

    func update(x: Int16, y: Int16, z: Int16) {
        if x < minX { minX = x }
        if x > maxX { maxX = x }
        if y < minY { minY = y }
        if y > maxY { maxY = y }
        if z < minZ { minZ = z }
        if z > maxZ { maxZ = z }
    }

    func reset() {
        minX = 0; maxX = 0
        minY = 0; maxY = 0
        minZ = 0; maxZ = 0
    }
}

struct GyroVectorIndicator: View {
    let x: Int16  // Vertical (up/down tilting)
    let y: Int16  // Horizontal (left/right pointing)
    let maxValue: CGFloat  // Dynamic max value for scaling

    private let size: CGFloat = 80

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
    var maxValue: Double = 500  // Dynamic max value for scaling

    private var normalized: Double {
        Double(value).clamped(to: -maxValue...maxValue) / maxValue
    }

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
                .frame(width: 55, alignment: .trailing)
                .lineLimit(1)
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

// MARK: - Gyro Pipeline Visualization

/// Multi-stage gyro pipeline visualization showing Raw → Remapped → Normalized
struct GyroPipelineView: View {
    @ObservedObject var appState: AppState
    @ObservedObject var telemetry: DebugTelemetryState
    @StateObject private var rangeTracker = GyroRangeTracker()

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Gyro Pipeline")
                    .font(.headline)
                Spacer()
                Button("Reset Range") {
                    rangeTracker.reset()
                }
                .font(.caption)
                .buttonStyle(.bordered)
                .controlSize(.small)
            }

            // Stage 1: Raw (direct from HID)
            PipelineStageView(
                stageNumber: 1,
                title: "Raw",
                subtitle: "Direct from HID",
                x: telemetry.rawGyroX,
                y: telemetry.rawGyroY,
                z: telemetry.rawGyroZ,
                xLabel: "X",
                yLabel: "Y",
                zLabel: "Z",
                maxValue: rangeTracker.maxAbsValue,
                color: .orange
            )

            // Stage 2: Remapped (semantic axes)
            PipelineStageView(
                stageNumber: 2,
                title: "Remapped",
                subtitle: appState.activeControllerKind == .joyCon ? "Joy-Con: X↔Y swapped" : "Sense: identity",
                x: telemetry.remappedPitch,
                y: telemetry.remappedYaw,
                z: telemetry.remappedRoll,
                xLabel: "Pitch",
                yLabel: "Yaw",
                zLabel: "Roll",
                maxValue: rangeTracker.maxAbsValue,
                color: .green
            )

            // Stage 3: Normalized (degrees per second)
            NormalizedStageView(
                stageNumber: 3,
                title: "Normalized",
                subtitle: "Degrees/second",
                pitch: telemetry.normalizedPitch,
                yaw: telemetry.normalizedYaw,
                roll: telemetry.normalizedRoll
            )
        }
        .padding()
        .background(Color.secondary.opacity(0.03))
        .cornerRadius(8)
        .onChange(of: telemetry.rawGyroX) { _, _ in
            rangeTracker.update(x: telemetry.rawGyroX, y: telemetry.rawGyroY, z: telemetry.rawGyroZ)
        }
        .onChange(of: telemetry.rawGyroY) { _, _ in
            rangeTracker.update(x: telemetry.rawGyroX, y: telemetry.rawGyroY, z: telemetry.rawGyroZ)
        }
    }
}

/// A single pipeline stage visualization (for Int16 values)
private struct PipelineStageView: View {
    let stageNumber: Int
    let title: String
    let subtitle: String
    let x: Int16
    let y: Int16
    let z: Int16
    let xLabel: String
    let yLabel: String
    let zLabel: String
    let maxValue: CGFloat
    let color: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 4) {
                Text("\(stageNumber).")
                    .font(.caption.bold())
                    .foregroundColor(color)
                Text(title)
                    .font(.subheadline.bold())
                Text("–")
                    .foregroundColor(.secondary)
                Text(subtitle)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            HStack(spacing: 12) {
                // Vector indicator showing X (pitch) vs Y (yaw)
                PipelineVectorIndicator(x: x, y: y, maxValue: maxValue, color: color)

                VStack(alignment: .leading, spacing: 4) {
                    PipelineAxisRow(name: xLabel, value: x, maxValue: Double(maxValue), color: color)
                    PipelineAxisRow(name: yLabel, value: y, maxValue: Double(maxValue), color: color)
                    PipelineAxisRow(name: zLabel, value: z, maxValue: Double(maxValue), color: color.opacity(0.5))
                }
            }
        }
        .padding(8)
        .background(color.opacity(0.05))
        .cornerRadius(6)
    }
}

/// Normalized stage visualization (for Double values in °/s)
private struct NormalizedStageView: View {
    let stageNumber: Int
    let title: String
    let subtitle: String
    let pitch: Double
    let yaw: Double
    let roll: Double

    // Typical max for normalized values (°/s)
    private let maxDegPerSec: Double = 500.0

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 4) {
                Text("\(stageNumber).")
                    .font(.caption.bold())
                    .foregroundColor(.blue)
                Text(title)
                    .font(.subheadline.bold())
                Text("–")
                    .foregroundColor(.secondary)
                Text(subtitle)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            HStack(spacing: 12) {
                // Vector indicator
                NormalizedVectorIndicator(pitch: pitch, yaw: yaw, maxValue: maxDegPerSec)

                VStack(alignment: .leading, spacing: 4) {
                    NormalizedAxisRow(name: "Pitch", value: pitch, maxValue: maxDegPerSec)
                    NormalizedAxisRow(name: "Yaw", value: yaw, maxValue: maxDegPerSec)
                    NormalizedAxisRow(name: "Roll", value: roll, maxValue: maxDegPerSec)
                }
            }
        }
        .padding(8)
        .background(Color.blue.opacity(0.05))
        .cornerRadius(6)
    }
}

/// Vector indicator for Int16 pipeline stages
private struct PipelineVectorIndicator: View {
    let x: Int16
    let y: Int16
    let maxValue: CGFloat
    let color: Color

    private let size: CGFloat = 60

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

            Path { path in
                path.move(to: CGPoint(x: size/2, y: 0))
                path.addLine(to: CGPoint(x: size/2, y: size))
                path.move(to: CGPoint(x: 0, y: size/2))
                path.addLine(to: CGPoint(x: size, y: size/2))
            }
            .stroke(Color.secondary.opacity(0.2), lineWidth: 1)

            Circle()
                .fill(color)
                .frame(width: 8, height: 8)
                .offset(
                    x: normalizedY * (size / 2 - 4),
                    y: -normalizedX * (size / 2 - 4)
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

/// Vector indicator for normalized (Double) values
private struct NormalizedVectorIndicator: View {
    let pitch: Double
    let yaw: Double
    let maxValue: Double

    private let size: CGFloat = 60

    private var normalizedPitch: CGFloat {
        CGFloat(pitch.clamped(to: -maxValue...maxValue) / maxValue)
    }

    private var normalizedYaw: CGFloat {
        CGFloat(yaw.clamped(to: -maxValue...maxValue) / maxValue)
    }

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
                .fill(Color.blue)
                .frame(width: 8, height: 8)
                .offset(
                    x: normalizedYaw * (size / 2 - 4),
                    y: -normalizedPitch * (size / 2 - 4)
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

/// Axis row for Int16 pipeline stages
private struct PipelineAxisRow: View {
    let name: String
    let value: Int16
    let maxValue: Double
    let color: Color

    private var normalized: Double {
        Double(value).clamped(to: -maxValue...maxValue) / maxValue
    }

    var body: some View {
        HStack(spacing: 6) {
            Text(name)
                .font(.system(size: 10, weight: .medium))
                .frame(width: 32, alignment: .leading)

            GeometryReader { geo in
                ZStack {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(Color.secondary.opacity(0.15))

                    let barWidth = abs(normalized) * (geo.size.width / 2)
                    RoundedRectangle(cornerRadius: 2)
                        .fill(color)
                        .frame(width: barWidth)
                        .offset(x: normalized >= 0 ? barWidth / 2 : -barWidth / 2)

                    Rectangle()
                        .fill(Color.secondary.opacity(0.4))
                        .frame(width: 1)
                }
            }
            .frame(height: 10)

            Text("\(value)")
                .font(.system(size: 9, design: .monospaced))
                .foregroundColor(.secondary)
                .frame(width: 45, alignment: .trailing)
                .lineLimit(1)
        }
    }
}

/// Axis row for normalized (Double) values
private struct NormalizedAxisRow: View {
    let name: String
    let value: Double
    let maxValue: Double

    private var normalized: Double {
        value.clamped(to: -maxValue...maxValue) / maxValue
    }

    var body: some View {
        HStack(spacing: 6) {
            Text(name)
                .font(.system(size: 10, weight: .medium))
                .frame(width: 32, alignment: .leading)

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
            .frame(height: 10)

            Text(String(format: "%.1f", value))
                .font(.system(size: 9, design: .monospaced))
                .foregroundColor(.secondary)
                .frame(width: 45, alignment: .trailing)
                .lineLimit(1)
        }
    }
}

// MARK: - Mouse Debug View

private struct MouseDebugView: View {
    @ObservedObject var appState: AppState
    @ObservedObject var telemetry: DebugTelemetryState
    let bytesPerRow: Int
    let totalBytes: Int
    let decaySeconds: Double
    let currentTime: Date

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                // Section 0: HID Interfaces (per-interface byte visualization)
                MouseHIDInterfacesSection(
                    appState: appState,
                    currentTime: currentTime,
                    decaySeconds: decaySeconds
                )

                Divider()

                // Section 1: Debug Log
                MouseDebugLogSection(appState: appState)

                Divider()

                // Section 2: Raw HID Report
                MouseRawReportSection(
                    appState: appState,
                    telemetry: telemetry,
                    currentTime: currentTime,
                    bytesPerRow: bytesPerRow,
                    totalBytes: totalBytes,
                    decaySeconds: decaySeconds
                )

                Divider()

                // Section 3: Bit Inspector for button discovery
                MouseBitInspectorSection(
                    appState: appState,
                    telemetry: telemetry,
                    currentTime: currentTime
                )
            }
            .padding()
        }
    }
}

// MARK: - Mouse Debug Log Section

private struct MouseDebugLogSection: View {
    @ObservedObject var appState: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Debug Log")
                    .font(.subheadline)
                    .fontWeight(.medium)
                    .foregroundColor(.secondary)
                Spacer()
                Button("Clear") {
                    appState.debugBuffer.clearLog()
                }
                .font(.caption)
                .buttonStyle(.bordered)
                .controlSize(.small)
            }

            let messages = appState.debugBuffer.getLogMessages()

            if messages.isEmpty {
                Text("No log messages yet")
                    .font(.caption)
                    .foregroundColor(.secondary)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(messages.suffix(20).reversed(), id: \.self) { msg in
                            Text(msg)
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundColor(msg.contains("RELEASED") ? .green : (msg.contains("PRESSED") ? .orange : .primary))
                                .lineLimit(2)
                        }
                    }
                }
                .frame(maxHeight: 150)
            }
        }
        .padding()
        .background(Color.secondary.opacity(0.03))
        .cornerRadius(8)
    }
}

// MARK: - Mouse HID Interfaces Section (Per-Interface Byte Grids)

private struct MouseHIDInterfacesSection: View {
    @ObservedObject var appState: AppState
    let currentTime: Date
    let decaySeconds: Double

    // Cache interface info to avoid threading crashes
    @State private var cachedInterfaces: [G502XInterfaceInfo] = []

    private let bytesPerRow = 8

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("HID Interfaces")
                .font(.subheadline)
                .fontWeight(.medium)
                .foregroundColor(.secondary)

            if cachedInterfaces.isEmpty {
                Text("No interfaces")
                    .font(.caption)
                    .foregroundColor(.secondary)
            } else {
                // Show each interface with its own byte grid
                ForEach(cachedInterfaces) { iface in
                    InterfaceByteGrid(
                        iface: iface,
                        bytesPerRow: bytesPerRow,
                        decaySeconds: decaySeconds,
                        currentTime: currentTime
                    )
                }
            }
        }
        .padding()
        .background(Color.secondary.opacity(0.03))
        .cornerRadius(8)
        .onAppear { updateCache() }
        .onChange(of: currentTime) { updateCache() }
    }

    private func updateCache() {
        cachedInterfaces = appState.getG502XInterfaceInfo()
    }
}

/// Byte grid for a single HID interface
private struct InterfaceByteGrid: View {
    let iface: G502XInterfaceInfo
    let bytesPerRow: Int
    let decaySeconds: Double
    let currentTime: Date

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            // Header
            HStack {
                Text(iface.interfaceType)
                    .font(.system(size: 11, weight: .bold))
                    .foregroundColor(iface.interfaceType == "Vendor" ? .purple : .blue)

                Text("(\(iface.usagePageHex)/\(iface.usageHex))")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(.secondary)

                Spacer()

                Text("\(iface.reportCount) reports")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(.green)

                Text("len \(iface.reportLength)")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(.secondary)
            }

            // Show a grid even before the first report arrives by falling back to maxReportSize.
            let expectedLength = max(iface.reportLength, iface.maxReportSize)
            let totalBytes = min(expectedLength, iface.lastReportBytes.count, 64)
            let bytes = Array(iface.lastReportBytes.prefix(totalBytes))

            if bytes.isEmpty {
                Text("No data yet — press a mouse button")
                    .font(.caption)
                    .foregroundColor(.secondary.opacity(0.5))
            } else {
                let numRows = min(8, (totalBytes + bytesPerRow - 1) / bytesPerRow)
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(0..<numRows, id: \.self) { row in
                        HStack(spacing: 4) {
                            Text(String(format: "%02d:", row * bytesPerRow))
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundColor(.secondary)
                                .frame(width: 24, alignment: .trailing)

                            ForEach(0..<bytesPerRow, id: \.self) { col in
                                let idx = row * bytesPerRow + col
                                if idx < totalBytes {
                                    ByteCell(
                                        value: bytes[idx],
                                        index: idx,
                                        color: colorForByte(idx)
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
        }
        .padding(8)
        .background(iface.interfaceType == "Vendor" ? Color.purple.opacity(0.03) : Color.blue.opacity(0.03))
        .cornerRadius(6)
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(iface.interfaceType == "Vendor" ? Color.purple.opacity(0.2) : Color.blue.opacity(0.2), lineWidth: 1)
        )
    }

    private func colorForByte(_ index: Int) -> Color {
        guard index < iface.byteLastChanged.count else { return .red }
        let lastChanged = iface.byteLastChanged[index]
        let elapsed = currentTime.timeIntervalSince(lastChanged)
        let progress = min(1.0, max(0.0, elapsed / decaySeconds))
        return Color(red: progress, green: 1.0 - progress, blue: 0)
    }
}

// MARK: - Mouse Raw Report Section

private struct MouseRawReportSection: View {
    @ObservedObject var appState: AppState
    @ObservedObject var telemetry: DebugTelemetryState
    let currentTime: Date
    let bytesPerRow: Int
    let totalBytes: Int
    let decaySeconds: Double

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("G502X HID Report")
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

            // Show more rows for mouse (up to 8 rows = 64 bytes)
            let numRows = min(8, (totalBytes + bytesPerRow - 1) / bytesPerRow)
            VStack(alignment: .leading, spacing: 6) {
                ForEach(0..<numRows, id: \.self) { row in
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

// MARK: - Mouse Bit Inspector Section

private struct MouseBitInspectorSection: View {
    @ObservedObject var appState: AppState
    @ObservedObject var telemetry: DebugTelemetryState
    let currentTime: Date
    @State private var selectedByte: Int = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Bit Inspector")
                .font(.subheadline)
                .fontWeight(.medium)
                .foregroundColor(.secondary)

            // Byte selector
            HStack {
                Text("Byte:")
                    .font(.caption)
                Stepper("\(selectedByte)", value: $selectedByte, in: 0...15)
                    .frame(width: 100)
                Spacer()
            }

            // Show the selected byte value
            let byteValue = telemetry.safeReportByte(selectedByte)
            VStack(alignment: .leading, spacing: 8) {
                Text(String(format: "Byte %d: 0x%02X (%@)", selectedByte, byteValue, byteToBinary(byteValue)))
                    .font(.system(size: 12, design: .monospaced))

                // Bit grid - 8 bits in a row
                HStack(spacing: 8) {
                    ForEach((0..<8).reversed(), id: \.self) { bit in
                        let isSet = (byteValue & (1 << bit)) != 0
                        let lastChanged = bitLastChanged(byte: selectedByte, bit: bit)
                        let elapsed = currentTime.timeIntervalSince(lastChanged)
                        let isRecent = elapsed < 2.0

                        VStack(spacing: 4) {
                            Circle()
                                .fill(isSet ? (isRecent ? Color.green : Color.blue) : Color.secondary.opacity(0.2))
                                .frame(width: 24, height: 24)
                                .overlay(
                                    Circle()
                                        .stroke(isRecent ? Color.green : Color.clear, lineWidth: 2)
                                )

                            Text("\(bit)")
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundColor(.secondary)
                        }
                    }
                }
                .padding(.vertical, 8)

                // Last changed info
                if let (lastByte, lastBit, lastTime) = findLastChangedBit() {
                    let elapsed = currentTime.timeIntervalSince(lastTime)
                    Text(String(format: "Last change: Byte %d, Bit %d (%.1fs ago)", lastByte, lastBit, elapsed))
                        .font(.caption)
                        .foregroundColor(elapsed < 2.0 ? .green : .secondary)
                }
            }
        }
        .padding()
        .background(Color.secondary.opacity(0.03))
        .cornerRadius(8)
    }

    private func byteToBinary(_ value: UInt8) -> String {
        String(value, radix: 2).leftPadded(toLength: 8, withPad: "0")
    }

    private func bitLastChanged(byte: Int, bit: Int) -> Date {
        guard byte < telemetry.bitLastChanged.count,
              bit < telemetry.bitLastChanged[byte].count else {
            return .distantPast
        }
        return telemetry.bitLastChanged[byte][bit]
    }

    private func findLastChangedBit() -> (byte: Int, bit: Int, time: Date)? {
        var lastByte = 0
        var lastBit = 0
        var lastTime = Date.distantPast

        for byteIdx in 0..<min(16, telemetry.bitLastChanged.count) {
            for bitIdx in 0..<8 {
                let time = telemetry.bitLastChanged[byteIdx][bitIdx]
                if time > lastTime {
                    lastTime = time
                    lastByte = byteIdx
                    lastBit = bitIdx
                }
            }
        }

        return lastTime > .distantPast ? (lastByte, lastBit, lastTime) : nil
    }
}
