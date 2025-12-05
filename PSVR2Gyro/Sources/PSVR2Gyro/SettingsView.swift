import SwiftUI

struct SettingsView: View {
    @ObservedObject var appState: AppState

    var body: some View {
        TabView {
            MouseControlTab(appState: appState)
                .tabItem {
                    Label("Mouse", systemImage: "computermouse")
                }

            DebugTab(appState: appState)
                .tabItem {
                    Label("Debug", systemImage: "ladybug")
                }

            LogTab(appState: appState)
                .tabItem {
                    Label("Log", systemImage: "doc.text")
                }
        }
        .frame(minWidth: 500, minHeight: 400)
    }
}

// MARK: - Mouse Control Tab

struct MouseControlTab: View {
    @ObservedObject var appState: AppState

    var body: some View {
        Form {
            Section {
                Toggle("Enable Mouse Control", isOn: $appState.isEnabled)
            }

            Section("Sensitivity") {
                LabeledContent("Sensitivity") {
                    HStack {
                        Slider(value: $appState.sensitivity, in: 1...50)
                            .frame(width: 200)
                        Text("\(Int(appState.sensitivity))")
                            .monospacedDigit()
                            .frame(width: 30)
                    }
                }

                LabeledContent("Gyro Scale") {
                    HStack {
                        Slider(value: $appState.gyroScale, in: 0.001...0.5)
                            .frame(width: 200)
                        Text(String(format: "%.4f", appState.gyroScale))
                            .monospacedDigit()
                            .frame(width: 50)
                    }
                }
            }

            Section("Gyro Axis Offsets (Bytes)") {
                Stepper("X Offset: \(appState.gyroOffsetX)", value: $appState.gyroOffsetX, in: 0...70)
                Stepper("Y Offset: \(appState.gyroOffsetY)", value: $appState.gyroOffsetY, in: 0...70)
                Stepper("Z Offset: \(appState.gyroOffsetZ)", value: $appState.gyroOffsetZ, in: 0...70)
            }

            Section("Debug") {
                LabeledContent("Gyro X") {
                    Text("\(appState.lastGyroX)")
                        .monospacedDigit()
                }
                LabeledContent("Gyro Y") {
                    Text("\(appState.lastGyroY)")
                        .monospacedDigit()
                }
                LabeledContent("Gyro Z") {
                    Text("\(appState.lastGyroZ)")
                        .monospacedDigit()
                }
                LabeledContent("Report Count") {
                    Text("\(appState.reportCount)")
                        .monospacedDigit()
                }

                Button("Recalibrate") {
                    appState.recalibrate()
                }
            }
        }
        .formStyle(.grouped)
        .padding()
    }
}

// MARK: - Debug Tab

struct DebugTab: View {
    @ObservedObject var appState: AppState

    // 78 bytes = 10 rows of 8 (last row has 6)
    private let bytesPerRow = 8
    private let totalBytes = 78
    private let decaySeconds: Double = 5.0

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.1)) { timeline in
            VStack(spacing: 0) {
                // Header
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

                // Legend
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

                // Full byte grid and button lab
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        // Byte grid
                        VStack(alignment: .leading, spacing: 6) {
                            ForEach(0..<10, id: \.self) { row in
                                HStack(spacing: 4) {
                                    // Row label
                                    Text(String(format: "%02d:", row * bytesPerRow))
                                        .font(.system(size: 10, design: .monospaced))
                                        .foregroundColor(.secondary)
                                        .frame(width: 24, alignment: .trailing)

                                    // Bytes in this row
                                    ForEach(0..<bytesPerRow, id: \.self) { col in
                                        let i = row * bytesPerRow + col
                                        if i < totalBytes {
                                            ByteCell(
                                                value: appState.reportBytes[i],
                                                index: i,
                                                color: colorForByte(i, at: timeline.date)
                                            )
                                        } else {
                                            // Empty cell for padding
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

                        // Button Lab - testing buttons
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

                        ButtonLabView(
                            buttonName: "Trigger (R2)",
                            candidateBytes: [4],
                            reportBytes: appState.reportBytes,
                            bitLastChanged: appState.bitLastChanged,
                            currentTime: timeline.date
                        )
                    }
                    .padding()
                }
            }
        }
    }

    private func colorForByte(_ index: Int, at currentTime: Date) -> Color {
        let lastChanged = appState.byteLastChanged[index]
        let elapsed = currentTime.timeIntervalSince(lastChanged)
        let progress = min(1.0, max(0.0, elapsed / decaySeconds))
        // Green (0) -> Red (1)
        return Color(
            red: progress,
            green: 1.0 - progress,
            blue: 0
        )
    }
}

struct ByteCell: View {
    let value: UInt8
    let index: Int
    let color: Color

    var body: some View {
        VStack(spacing: 0) {
            Text(String(format: "%02X", value))
                .font(.system(size: 13, design: .monospaced))
                .foregroundColor(.white)
                .frame(width: 26, height: 22)
                .background(color)
                .cornerRadius(3)
            Text("\(index)")
                .font(.system(size: 8))
                .foregroundColor(.secondary)
        }
    }
}

// MARK: - Button Lab View

struct ButtonLabView: View {
    let buttonName: String
    let candidateBytes: [Int]
    let reportBytes: [UInt8]
    let bitLastChanged: [[Date]]
    let currentTime: Date
    let decaySeconds: Double = 5.0

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Header
            HStack {
                Text("Testing: \(buttonName)")
                    .font(.headline)
                Spacer()
            }

            // Show each candidate byte
            ForEach(candidateBytes, id: \.self) { byteIndex in
                VStack(alignment: .leading, spacing: 4) {
                    // Byte info
                    HStack {
                        Text("Byte \(byteIndex):")
                            .font(.system(.body, design: .monospaced))
                        Text(String(format: "0x%02X", reportBytes[byteIndex]))
                            .font(.system(.body, design: .monospaced))
                            .foregroundColor(.orange)
                        Text("(\(reportBytes[byteIndex]))")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }

                    // Bit indicators
                    HStack(spacing: 4) {
                        ForEach((0..<8).reversed(), id: \.self) { bit in
                            BitIndicator(
                                bit: bit,
                                isSet: (reportBytes[byteIndex] >> bit) & 1 == 1,
                                lastChanged: bitLastChanged[byteIndex][bit],
                                currentTime: currentTime,
                                decaySeconds: decaySeconds
                            )
                        }
                    }

                    // Bit labels
                    HStack(spacing: 4) {
                        ForEach((0..<8).reversed(), id: \.self) { bit in
                            Text("\(bit)")
                                .font(.system(size: 9, design: .monospaced))
                                .foregroundColor(.secondary)
                                .frame(width: 24)
                        }
                    }
                }
                .padding(8)
                .background(Color.secondary.opacity(0.1))
                .cornerRadius(6)
            }
        }
        .padding()
        .background(Color.secondary.opacity(0.05))
        .cornerRadius(8)
    }
}

struct BitIndicator: View {
    let bit: Int
    let isSet: Bool
    let lastChanged: Date
    let currentTime: Date
    let decaySeconds: Double

    private var color: Color {
        let elapsed = currentTime.timeIntervalSince(lastChanged)
        let progress = min(1.0, max(0.0, elapsed / decaySeconds))

        if isSet {
            // Bright green when set, fading to dark green
            return Color(
                red: progress * 0.2,
                green: 1.0 - progress * 0.5,
                blue: 0
            )
        } else {
            // Recent change shows yellow/orange fading to gray
            if elapsed < decaySeconds {
                return Color(
                    red: 1.0 - progress,
                    green: 0.5 - progress * 0.5,
                    blue: 0
                )
            } else {
                return Color.gray.opacity(0.3)
            }
        }
    }

    var body: some View {
        Text(isSet ? "1" : "0")
            .font(.system(size: 12, design: .monospaced))
            .foregroundColor(.white)
            .frame(width: 24, height: 24)
            .background(color)
            .cornerRadius(4)
    }
}

// MARK: - Log Tab

struct LogTab: View {
    @ObservedObject var appState: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            HStack {
                Text("Debug Log")
                    .font(.headline)
                Spacer()
                Button("Clear") {
                    appState.debugLog.removeAll()
                }
                .buttonStyle(.borderless)
            }
            .padding()

            Divider()

            // Log content
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(Array(appState.debugLog.enumerated()), id: \.offset) { index, message in
                            Text(message)
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundColor(.primary)
                                .textSelection(.enabled)
                                .id(index)
                        }
                    }
                    .padding()
                }
                .onChange(of: appState.debugLog.count) { _, _ in
                    if let last = appState.debugLog.indices.last {
                        withAnimation {
                            proxy.scrollTo(last, anchor: .bottom)
                        }
                    }
                }
            }
            .background(Color(nsColor: .textBackgroundColor))
        }
    }
}
