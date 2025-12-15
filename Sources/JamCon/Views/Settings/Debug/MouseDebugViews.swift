import SwiftUI

// MARK: - Mouse Debug View

struct MouseDebugView: View {
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
        let binary = String(value, radix: 2)
        return String(repeating: "0", count: max(0, 8 - binary.count)) + binary
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

