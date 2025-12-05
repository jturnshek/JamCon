import SwiftUI

// MARK: - Byte Inspector Views

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

struct ButtonLabView: View {
    let buttonName: String
    let candidateBytes: [Int]
    let reportBytes: [UInt8]
    let bitLastChanged: [[Date]]
    let currentTime: Date
    let decaySeconds: Double = 5.0

    private func safeReportByte(_ index: Int) -> UInt8 {
        guard index >= 0 && index < reportBytes.count else { return 0 }
        return reportBytes[index]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Testing: \(buttonName)")
                    .font(.headline)
                Spacer()
            }

            ForEach(candidateBytes, id: \.self) { byteIndex in
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("Byte \(byteIndex):")
                            .font(.system(.body, design: .monospaced))
                        Text(String(format: "0x%02X", safeReportByte(byteIndex)))
                            .font(.system(.body, design: .monospaced))
                            .foregroundColor(.orange)
                        Text("(\(safeReportByte(byteIndex)))")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }

                    HStack(spacing: 4) {
                        ForEach((0..<8).reversed(), id: \.self) { bit in
                            BitIndicator(
                                bit: bit,
                                isSet: (safeReportByte(byteIndex) >> bit) & 1 == 1,
                                lastChanged: bitLastChanged.count > byteIndex ? bitLastChanged[byteIndex][bit] : Date.distantPast,
                                currentTime: currentTime,
                                decaySeconds: decaySeconds
                            )
                        }
                    }

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
            return Color(
                red: progress * 0.2,
                green: 1.0 - progress * 0.5,
                blue: 0
            )
        } else {
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

struct JoystickLabView: View {
    let xByte: Int
    let yByte: Int
    let reportBytes: [UInt8]

    private let size: CGFloat = 120

    private func safeReportByte(_ index: Int) -> UInt8 {
        guard index >= 0 && index < reportBytes.count else { return 0 }
        return reportBytes[index]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Joystick (Bytes \(xByte), \(yByte))")
                .font(.headline)

            HStack(spacing: 20) {
                ZStack {
                    Rectangle()
                        .fill(Color.secondary.opacity(0.1))
                        .frame(width: size, height: size)

                    Path { path in
                        path.move(to: CGPoint(x: size/2, y: 0))
                        path.addLine(to: CGPoint(x: size/2, y: size))
                        path.move(to: CGPoint(x: 0, y: size/2))
                        path.addLine(to: CGPoint(x: size, y: size/2))
                    }
                    .stroke(Color.secondary.opacity(0.3), lineWidth: 1)

                    Circle()
                        .fill(Color.blue)
                        .frame(width: 12, height: 12)
                        .offset(
                            x: CGFloat(safeReportByte(xByte)) / 255.0 * size - size/2,
                            y: CGFloat(safeReportByte(yByte)) / 255.0 * size - size/2
                        )
                }
                .frame(width: size, height: size)
                .border(Color.secondary.opacity(0.3))

                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("X:")
                            .font(.system(.body, design: .monospaced))
                            .frame(width: 20, alignment: .trailing)
                        Text(String(format: "%3d", safeReportByte(xByte)))
                            .font(.system(.body, design: .monospaced))
                            .foregroundColor(.orange)
                        Text(String(format: "(0x%02X)", safeReportByte(xByte)))
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }

                    HStack {
                        Text("Y:")
                            .font(.system(.body, design: .monospaced))
                            .frame(width: 20, alignment: .trailing)
                        Text(String(format: "%3d", safeReportByte(yByte)))
                            .font(.system(.body, design: .monospaced))
                            .foregroundColor(.orange)
                        Text(String(format: "(0x%02X)", safeReportByte(yByte)))
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }

                    Divider()

                    Text("Center: ~128")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Text("Range: 0-255")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
        }
        .padding()
        .background(Color.secondary.opacity(0.05))
        .cornerRadius(8)
    }
}

struct AnalogLabView: View {
    let title: String
    let inputs: [(name: String, byte: Int)]
    let reportBytes: [UInt8]

    private func safeReportByte(_ index: Int) -> UInt8 {
        guard index >= 0 && index < reportBytes.count else { return 0 }
        return reportBytes[index]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(.headline)

            ForEach(inputs, id: \.byte) { input in
                HStack(spacing: 12) {
                    Text(input.name)
                        .font(.system(.body, design: .monospaced))
                        .frame(width: 140, alignment: .leading)

                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            Rectangle()
                                .fill(Color.secondary.opacity(0.2))
                            Rectangle()
                                .fill(Color.blue)
                                .frame(width: geo.size.width * CGFloat(safeReportByte(input.byte)) / 255.0)
                        }
                    }
                    .frame(height: 20)
                    .cornerRadius(4)

                    Text(String(format: "%3d", safeReportByte(input.byte)))
                        .font(.system(.body, design: .monospaced))
                        .foregroundColor(.orange)
                        .frame(width: 30, alignment: .trailing)

                    Text(String(format: "(0x%02X)", safeReportByte(input.byte)))
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .frame(width: 50)
                }
                .frame(height: 24)
            }
        }
        .padding()
        .background(Color.secondary.opacity(0.05))
        .cornerRadius(8)
    }
}

struct StatusLabView: View {
    let title: String
    let bytes: [Int]
    let reportBytes: [UInt8]
    let byteLastChanged: [Date]
    let currentTime: Date

    private func safeReportByte(_ index: Int) -> UInt8 {
        guard index >= 0 && index < reportBytes.count else { return 0 }
        return reportBytes[index]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(.headline)

            ForEach(bytes, id: \.self) { byteIndex in
                HStack(spacing: 12) {
                    Text("Byte \(byteIndex):")
                        .font(.system(.body, design: .monospaced))
                        .frame(width: 80, alignment: .leading)

                    Text(String(format: "%3d", safeReportByte(byteIndex)))
                        .font(.system(.body, design: .monospaced))
                        .foregroundColor(.orange)
                        .frame(width: 30)

                    Text(String(format: "(0x%02X)", safeReportByte(byteIndex)))
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .frame(width: 50)

                    let elapsed = byteLastChanged.count > byteIndex ? currentTime.timeIntervalSince(byteLastChanged[byteIndex]) : 999
                    Text(formatElapsed(elapsed))
                        .font(.caption)
                        .foregroundColor(elapsed < 5.0 ? .green : .secondary)
                }
            }

            Text("These increment over time and reset on Bluetooth reconnect")
                .font(.caption)
                .foregroundColor(.secondary)
                .padding(.top, 4)
        }
        .padding()
        .background(Color.secondary.opacity(0.05))
        .cornerRadius(8)
    }

    private func formatElapsed(_ seconds: TimeInterval) -> String {
        if seconds < 1 {
            return "just now"
        } else if seconds < 60 {
            return String(format: "%.0fs ago", seconds)
        } else if seconds < 3600 {
            return String(format: "%.0fm ago", seconds / 60)
        } else {
            return "long ago"
        }
    }
}

struct LogicalButtonTestView: View {
    let buttonStates: [LogicalButton: Bool]
    let isLeftController: Bool
    let triggerValue: UInt8
    let joystickX: UInt8
    let joystickY: UInt8

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Logical Button Test")
                    .font(.headline)
                Spacer()
                Text(isLeftController ? "Left Controller" : "Right Controller")
                    .font(.caption)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(isLeftController ? Color.blue.opacity(0.2) : Color.orange.opacity(0.2))
                    .cornerRadius(4)
            }

            Text("These buttons should work the same on both controllers:")
                .font(.caption)
                .foregroundColor(.secondary)

            LazyVGrid(columns: [
                GridItem(.flexible()),
                GridItem(.flexible()),
                GridItem(.flexible()),
            ], spacing: 8) {
                ButtonIndicator(
                    name: LogicalButton.faceTop.name(isLeft: isLeftController),
                    subtext: "Face Top",
                    isPressed: buttonStates[.faceTop] ?? false
                )
                ButtonIndicator(
                    name: LogicalButton.faceBottom.name(isLeft: isLeftController),
                    subtext: "Face Bottom",
                    isPressed: buttonStates[.faceBottom] ?? false
                )
                ButtonIndicator(
                    name: LogicalButton.bumper.name(isLeft: isLeftController),
                    subtext: "Bumper",
                    isPressed: buttonStates[.bumper] ?? false
                )
                ButtonIndicator(
                    name: LogicalButton.trigger.name(isLeft: isLeftController),
                    subtext: "\(triggerValue)",
                    isPressed: triggerValue > 10
                )
                ButtonIndicator(
                    name: LogicalButton.stickClick.name(isLeft: isLeftController),
                    subtext: "Stick Click",
                    isPressed: buttonStates[.stickClick] ?? false
                )
                ButtonIndicator(
                    name: LogicalButton.menuButton.name(isLeft: isLeftController),
                    subtext: "Menu",
                    isPressed: buttonStates[.menuButton] ?? false
                )
            }

            HStack {
                ButtonIndicator(
                    name: "PS",
                    subtext: "⚠️ Opens Arcade",
                    isPressed: buttonStates[.playStation] ?? false
                )
                .frame(maxWidth: 120)

                Spacer()

                VStack(spacing: 2) {
                    Text("Joystick")
                        .font(.caption2)
                    Text("X:\(joystickX) Y:\(joystickY)")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(.secondary)
                }
            }
        }
        .padding()
        .background(Color.green.opacity(0.05))
        .cornerRadius(8)
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.green.opacity(0.3), lineWidth: 1)
        )
    }
}

struct ButtonIndicator: View {
    let name: String
    let subtext: String
    let isPressed: Bool

    var body: some View {
        VStack(spacing: 4) {
            Text(name)
                .font(.system(size: 11, weight: .medium))
            Text(subtext)
                .font(.system(size: 9))
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
        .background(isPressed ? Color.green : Color.secondary.opacity(0.1))
        .foregroundColor(isPressed ? .white : .primary)
        .cornerRadius(6)
    }
}
