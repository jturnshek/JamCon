import SwiftUI

// MARK: - Sensor Validation Views

struct IMUAxisTesterView: View {
    let reportBytes: [UInt8]

    private func readInt16LE(_ offset: Int) -> Int16 {
        guard offset + 1 < reportBytes.count else { return 0 }
        return Int16(bitPattern: UInt16(reportBytes[offset]) | (UInt16(reportBytes[offset + 1]) << 8))
    }

    private var gyro: (x: Int16, y: Int16, z: Int16) {
        (readInt16LE(17), readInt16LE(19), readInt16LE(21))
    }

    private var accel: (x: Int16, y: Int16, z: Int16) {
        (readInt16LE(23), readInt16LE(25), readInt16LE(27))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("IMU Data")
                    .font(.headline)
                Spacer()
                Text("✓ CONFIRMED")
                    .font(.caption)
                    .fontWeight(.semibold)
                    .foregroundColor(.green)
            }

            Text("Gyro ~0 at rest. Accel shows gravity ~4096/g.")
                .font(.caption)
                .foregroundColor(.secondary)

            HStack(spacing: 20) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Gyroscope")
                        .font(.subheadline)
                        .fontWeight(.medium)
                    Text("Bytes 17-22 (angular velocity)")
                        .font(.caption2)
                        .foregroundColor(.secondary)

                    IMUAxisRow(label: "X", value: gyro.x)
                    IMUAxisRow(label: "Y", value: gyro.y)
                    IMUAxisRow(label: "Z", value: gyro.z)
                }
                .frame(maxWidth: .infinity)
                .padding()
                .background(Color.blue.opacity(0.1))
                .cornerRadius(8)

                VStack(alignment: .leading, spacing: 8) {
                    Text("Accelerometer")
                        .font(.subheadline)
                        .fontWeight(.medium)
                    Text("Bytes 23-28 (~4096/g)")
                        .font(.caption2)
                        .foregroundColor(.secondary)

                    IMUAxisRow(label: "X", value: accel.x)
                    IMUAxisRow(label: "Y", value: accel.y)
                    IMUAxisRow(label: "Z", value: accel.z)
                }
                .frame(maxWidth: .infinity)
                .padding()
                .background(Color.green.opacity(0.1))
                .cornerRadius(8)
            }

            Text("Flip controller to see gravity axis invert on accelerometer.")
                .font(.caption)
                .foregroundColor(.secondary)
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

struct IMUAxisRow: View {
    let label: String
    let value: Int16

    private let maxValue: Double = 8000

    var body: some View {
        HStack(spacing: 8) {
            Text(label)
                .font(.system(size: 10, design: .monospaced))
                .frame(width: 70, alignment: .leading)

            GeometryReader { geo in
                ZStack {
                    Rectangle()
                        .fill(Color.secondary.opacity(0.2))

                    let normalized = Double(value) / maxValue
                    let barWidth = abs(normalized) * (geo.size.width / 2)

                    Rectangle()
                        .fill(value >= 0 ? Color.green : Color.red)
                        .frame(width: barWidth)
                        .offset(x: value >= 0 ? barWidth / 2 : -barWidth / 2)

                    Rectangle()
                        .fill(Color.secondary)
                        .frame(width: 1)
                }
            }
            .frame(height: 16)
            .cornerRadius(3)

            Text("\(value)")
                .font(.system(size: 10, design: .monospaced))
                .foregroundColor(.orange)
                .frame(width: 50, alignment: .trailing)
        }
    }
}

struct BatteryStatusView: View {
    let reportBytes: [UInt8]

    private var byte43: UInt8 { reportBytes.count > 43 ? reportBytes[43] : 0 }
    private var byte44: UInt8 { reportBytes.count > 44 ? reportBytes[44] : 0 }

    private var lowerNibble: UInt8 { byte43 & 0x0F }
    private var upperNibble: UInt8 { (byte43 >> 4) & 0x0F }
    private var batteryLevel: Int { Int(lowerNibble) * 10 }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Battery Status")
                    .font(.headline)
                Image(systemName: "checkmark.circle.fill")
                    .foregroundColor(.green)
                    .font(.caption)
                Text("CONFIRMED")
                    .font(.caption)
                    .fontWeight(.medium)
                    .foregroundColor(.green)
                Spacer()
            }

            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Byte 43:")
                        .font(.system(.body, design: .monospaced))
                        .frame(width: 70, alignment: .leading)
                    Text(String(format: "0x%02X", byte43))
                        .font(.system(.body, design: .monospaced))
                        .foregroundColor(.orange)
                    Text("= \(byte43) decimal")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                HStack(spacing: 16) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Lower nibble (& 0x0F)")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                        HStack {
                            Text("\(lowerNibble)")
                                .font(.system(.title3, design: .monospaced))
                                .fontWeight(.bold)
                            Text("× 10 =")
                                .font(.caption)
                                .foregroundColor(.secondary)
                            Text("\(batteryLevel)%")
                                .font(.system(.title3, design: .monospaced))
                                .fontWeight(.bold)
                                .foregroundColor(.green)
                        }
                    }

                    Divider().frame(height: 40)

                    VStack(alignment: .leading, spacing: 2) {
                        Text("Upper nibble (>> 4)")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                        HStack {
                            Text("\(upperNibble)")
                                .font(.system(.title3, design: .monospaced))
                            Text("charging/status?")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                }

                HStack(spacing: 8) {
                    Image(systemName: batteryIconName)
                        .foregroundColor(batteryColor)
                        .font(.title2)
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            RoundedRectangle(cornerRadius: 4)
                                .fill(Color.secondary.opacity(0.2))
                            RoundedRectangle(cornerRadius: 4)
                                .fill(batteryColor)
                                .frame(width: geo.size.width * CGFloat(batteryLevel) / 100.0)
                        }
                    }
                    .frame(height: 24)
                    Text("\(batteryLevel)%")
                        .font(.system(.title3, design: .monospaced))
                        .fontWeight(.semibold)
                        .frame(width: 50, alignment: .trailing)
                }
            }
            .padding(10)
            .background(Color.green.opacity(0.08))
            .cornerRadius(8)

            HStack {
                Text("Byte 44:")
                    .font(.system(.body, design: .monospaced))
                    .frame(width: 70, alignment: .leading)
                Text(String(format: "0x%02X", byte44))
                    .font(.system(.body, design: .monospaced))
                    .foregroundColor(.orange)
                Text("= \(byte44)")
                    .font(.caption)
                    .foregroundColor(.secondary)
                Text("(purpose unknown)")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .padding()
        .background(Color.green.opacity(0.03))
        .cornerRadius(8)
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.green.opacity(0.5), lineWidth: 2)
        )
    }

    private var batteryColor: Color {
        if batteryLevel > 50 { return .green }
        if batteryLevel > 20 { return .yellow }
        return .red
    }

    private var batteryIconName: String {
        if batteryLevel >= 75 { return "battery.100" }
        if batteryLevel >= 50 { return "battery.75" }
        if batteryLevel >= 25 { return "battery.50" }
        return "battery.25"
    }
}

