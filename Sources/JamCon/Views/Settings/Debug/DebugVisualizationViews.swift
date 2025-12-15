import SwiftUI

// MARK: - Gyro Visualization Components

/// Observable class to track min/max gyro values for auto-scaling
final class GyroRangeTracker: ObservableObject {
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
                path.move(to: CGPoint(x: size / 2, y: 0))
                path.addLine(to: CGPoint(x: size / 2, y: size))
                path.move(to: CGPoint(x: 0, y: size / 2))
                path.addLine(to: CGPoint(x: size, y: size / 2))
            }
            .stroke(Color.secondary.opacity(0.2), lineWidth: 1)

            // Vector dot - Y maps to horizontal, X maps to vertical
            Circle()
                .fill(Color.blue)
                .frame(width: 10, height: 10)
                .offset(
                    x: -normalizedY * (size / 2 - 5), // Y -> horizontal (inverted for natural feel)
                    y: -normalizedX * (size / 2 - 5)  // X -> vertical (inverted for natural feel)
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

// MARK: - Stick Visualization Components

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
                path.move(to: CGPoint(x: size / 2, y: 0))
                path.addLine(to: CGPoint(x: size / 2, y: size))
                path.move(to: CGPoint(x: 0, y: size / 2))
                path.addLine(to: CGPoint(x: size, y: size / 2))
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
    let controllerKind: ControllerKind
    @ObservedObject var telemetry: DebugTelemetryState
    @StateObject private var rangeTracker = GyroRangeTracker()

    private var remappedSubtitle: String {
        switch controllerKind {
        case .sense:
            return "Sense: identity"
        case .joyCon:
            return "Joy-Con: X↔Y swapped"
        case .mouse:
            return "Mouse: n/a"
        }
    }

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
                subtitle: remappedSubtitle,
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
                path.move(to: CGPoint(x: size / 2, y: 0))
                path.addLine(to: CGPoint(x: size / 2, y: size))
                path.move(to: CGPoint(x: 0, y: size / 2))
                path.addLine(to: CGPoint(x: size, y: size / 2))
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
                path.move(to: CGPoint(x: size / 2, y: 0))
                path.addLine(to: CGPoint(x: size / 2, y: size))
                path.move(to: CGPoint(x: 0, y: size / 2))
                path.addLine(to: CGPoint(x: size, y: size / 2))
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
