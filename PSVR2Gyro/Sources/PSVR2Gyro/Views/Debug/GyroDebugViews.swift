import SwiftUI

// MARK: - Gyro Debug Views

struct GyroProcessingPipelineView: View {
    let rawX: Int16
    let rawY: Int16
    let rawZ: Int16
    let gyroProcessor: GyroProcessor

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Gyro Processing Pipeline")
                    .font(.headline)
                Spacer()
                Text("Current processor state")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("1. Raw Input (signed Int16)")
                    .font(.subheadline)
                    .fontWeight(.medium)
                HStack(spacing: 20) {
                    ValueBox(label: "X", value: "\(rawX)", color: .red)
                    ValueBox(label: "Y", value: "\(rawY)", color: .green)
                    ValueBox(label: "Z", value: "\(rawZ)", color: .blue)
                }
            }

            let magnitude = sqrt(Double(rawX) * Double(rawX) + Double(rawY) * Double(rawY) + Double(rawZ) * Double(rawZ))
            VStack(alignment: .leading, spacing: 4) {
                Text("2. Motion Detection")
                    .font(.subheadline)
                    .fontWeight(.medium)
                HStack {
                    Text("Magnitude:")
                        .font(.caption)
                    Text(String(format: "%.1f", magnitude))
                        .font(.system(.body, design: .monospaced))
                    Spacer()
                    Text(magnitude < 50 ? "STATIONARY (calibrating)" : "MOVING")
                        .font(.caption)
                        .fontWeight(.semibold)
                        .foregroundColor(magnitude < 50 ? .orange : .green)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 2)
                        .background(magnitude < 50 ? Color.orange.opacity(0.2) : Color.green.opacity(0.2))
                        .cornerRadius(4)
                }
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("3. Scale Factor (gyroScale)")
                    .font(.subheadline)
                    .fontWeight(.medium)

                Text("Current: 1/16 = 0.0625 (guessed)")
                    .font(.caption)
                    .foregroundColor(.secondary)

                let scales: [(name: String, scale: Double)] = [
                    ("1/8", 1.0/8.0),
                    ("1/16", 1.0/16.0),
                    ("1/32", 1.0/32.0),
                    ("1/64", 1.0/64.0),
                    ("1/131 (MPU-6050)", 1.0/131.0),
                ]

                ForEach(scales, id: \.name) { item in
                    HStack {
                        Text(item.name)
                            .font(.system(size: 10, design: .monospaced))
                            .frame(width: 80, alignment: .leading)
                        Text("→")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        Text(String(format: "Y=%.2f°/s Z=%.2f°/s", Double(rawY) * item.scale, Double(rawZ) * item.scale))
                            .font(.system(size: 10, design: .monospaced))
                    }
                }
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("4. Calibration")
                    .font(.subheadline)
                    .fontWeight(.medium)
                HStack {
                    Circle()
                        .fill(gyroProcessor.isCalibrated ? Color.green : Color.orange)
                        .frame(width: 8, height: 8)
                    Text(gyroProcessor.isCalibrated ? "Calibrated" : "Calibrating...")
                        .font(.caption)
                }
            }
        }
        .padding()
        .background(Color.blue.opacity(0.05))
        .cornerRadius(8)
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.blue.opacity(0.3), lineWidth: 1)
        )
    }
}

struct AxisMappingHypothesesView: View {
    let rawX: Int16
    let rawY: Int16
    let rawZ: Int16

    struct MappingHypothesis: Identifiable {
        let id: String
        let name: String
        let description: String
        let dxSource: String
        let dySource: String
        let dxValue: Int16
        let dyValue: Int16
        let dxSign: Int16
        let dySign: Int16
    }

    var hypotheses: [MappingHypothesis] {
        [
            MappingHypothesis(
                id: "current",
                name: "Current (Z→dx, Y→dy)",
                description: "Z=yaw=horizontal, Y=pitch=vertical",
                dxSource: "Z", dySource: "Y",
                dxValue: rawZ, dyValue: rawY,
                dxSign: 1, dySign: -1
            ),
            MappingHypothesis(
                id: "swapped",
                name: "Swapped (Y→dx, Z→dy)",
                description: "Y=horizontal, Z=vertical",
                dxSource: "Y", dySource: "Z",
                dxValue: rawY, dyValue: rawZ,
                dxSign: 1, dySign: -1
            ),
            MappingHypothesis(
                id: "x_y",
                name: "X→dx, Y→dy",
                description: "Roll for horizontal, Pitch for vertical",
                dxSource: "X", dySource: "Y",
                dxValue: rawX, dyValue: rawY,
                dxSign: 1, dySign: -1
            ),
            MappingHypothesis(
                id: "x_z",
                name: "X→dx, Z→dy",
                description: "Roll for horizontal, Yaw for vertical",
                dxSource: "X", dySource: "Z",
                dxValue: rawX, dyValue: rawZ,
                dxSign: 1, dySign: -1
            ),
            MappingHypothesis(
                id: "inverted",
                name: "Current Inverted",
                description: "Same as current but signs flipped",
                dxSource: "Z", dySource: "Y",
                dxValue: rawZ, dyValue: rawY,
                dxSign: -1, dySign: 1
            ),
        ]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Axis Mapping Hypotheses")
                    .font(.headline)
                Spacer()
                Text("Which feels natural?")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Text("Move controller horizontally (left/right) and vertically (up/down). Watch which hypothesis shows matching dx/dy values.")
                .font(.caption)
                .foregroundColor(.secondary)

            LazyVGrid(columns: [
                GridItem(.flexible()),
                GridItem(.flexible()),
            ], spacing: 8) {
                ForEach(hypotheses) { hyp in
                    HypothesisCard(hypothesis: hyp)
                }
            }
        }
        .padding()
        .background(Color.purple.opacity(0.05))
        .cornerRadius(8)
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.purple.opacity(0.3), lineWidth: 1)
        )
    }
}

struct HypothesisCard: View {
    let hypothesis: AxisMappingHypothesesView.MappingHypothesis

    private var computedDx: Int16 { hypothesis.dxValue * hypothesis.dxSign }
    private var computedDy: Int16 { hypothesis.dyValue * hypothesis.dySign }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(hypothesis.name)
                .font(.system(size: 11))
                .fontWeight(.semibold)

            Text(hypothesis.description)
                .font(.system(size: 9))
                .foregroundColor(.secondary)
                .lineLimit(2)

            HStack(spacing: 12) {
                VStack(spacing: 2) {
                    Text("dx")
                        .font(.system(size: 9))
                        .foregroundColor(.secondary)
                    Text("\(computedDx)")
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundColor(computedDx > 10 ? .green : (computedDx < -10 ? .red : .primary))
                }

                VStack(spacing: 2) {
                    Text("dy")
                        .font(.system(size: 9))
                        .foregroundColor(.secondary)
                    Text("\(computedDy)")
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundColor(computedDy > 10 ? .green : (computedDy < -10 ? .red : .primary))
                }

                DirectionArrow(dx: Int(computedDx), dy: Int(computedDy))
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.secondary.opacity(0.1))
        .cornerRadius(6)
    }
}

struct DirectionArrow: View {
    let dx: Int
    let dy: Int

    private var angle: Double {
        guard dx != 0 || dy != 0 else { return 0 }
        return atan2(Double(dy), Double(dx)) * 180 / .pi
    }

    private var magnitude: Double {
        sqrt(Double(dx * dx + dy * dy))
    }

    var body: some View {
        ZStack {
            Circle()
                .fill(Color.secondary.opacity(0.2))
                .frame(width: 30, height: 30)

            if magnitude > 5 {
                Image(systemName: "arrow.up")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundColor(.blue)
                    .rotationEffect(.degrees(angle - 90))
            } else {
                Circle()
                    .fill(Color.secondary)
                    .frame(width: 4, height: 4)
            }
        }
    }
}

// MARK: - Individual Axis View (to identify which axis does what)

struct IndividualAxisView: View {
    let rawX: Int16
    let rawY: Int16
    let rawZ: Int16

    @State private var xTrail: [CGFloat] = []
    @State private var yTrail: [CGFloat] = []
    @State private var zTrail: [CGFloat] = []

    @State private var dxAxis: AxisChoice = .y
    @State private var dyAxis: AxisChoice = .x
    @State private var invertDx: Bool = false
    @State private var invertDy: Bool = true

    @State private var customTrail: [CGPoint] = []
    @State private var customPos: CGPoint = CGPoint(x: 100, y: 100)

    private let trailWidth: CGFloat = 200
    private let maxTrailLength = 60

    enum AxisChoice: String, CaseIterable {
        case x = "X"
        case y = "Y"
        case z = "Z"
    }

    private func getValue(for axis: AxisChoice) -> Int16 {
        switch axis {
        case .x: return rawX
        case .y: return rawY
        case .z: return rawZ
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Individual Axis Analysis")
                    .font(.headline)
                Spacer()
                Text("Find which axis = which motion")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Text("Move the controller in ONE direction at a time. Watch which axis responds.")
                .font(.caption)
                .foregroundColor(.secondary)

            // Three separate axis trails
            VStack(spacing: 8) {
                AxisTrailRow(label: "X", value: rawX, trail: $xTrail, color: .red, trailWidth: trailWidth, maxTrail: maxTrailLength)
                AxisTrailRow(label: "Y", value: rawY, trail: $yTrail, color: .green, trailWidth: trailWidth, maxTrail: maxTrailLength)
                AxisTrailRow(label: "Z", value: rawZ, trail: $zTrail, color: .blue, trailWidth: trailWidth, maxTrail: maxTrailLength)
            }
            .padding(8)
            .background(Color.secondary.opacity(0.05))
            .cornerRadius(6)

            // Motion guide
            VStack(alignment: .leading, spacing: 4) {
                Text("Test each motion and note which axis moves:")
                    .font(.caption)
                    .fontWeight(.medium)
                HStack(spacing: 16) {
                    VStack(alignment: .leading) {
                        Text("• Point left/right")
                        Text("• Tilt up/down")
                        Text("• Twist wrist (roll)")
                    }
                    .font(.caption2)
                    .foregroundColor(.secondary)
                    VStack(alignment: .leading) {
                        Text("→ Horizontal mouse")
                        Text("→ Vertical mouse")
                        Text("→ Should be ignored")
                    }
                    .font(.caption2)
                    .foregroundColor(.orange)
                }
            }

            Divider()

            // Custom axis mapping test
            VStack(alignment: .leading, spacing: 8) {
                Text("Custom Mapping Test")
                    .font(.subheadline)
                    .fontWeight(.medium)

                HStack(spacing: 16) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Horizontal (dx)")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                        HStack {
                            Picker("", selection: $dxAxis) {
                                ForEach(AxisChoice.allCases, id: \.self) { axis in
                                    Text(axis.rawValue).tag(axis)
                                }
                            }
                            .pickerStyle(.segmented)
                            .frame(width: 100)
                            Toggle("Invert", isOn: $invertDx)
                                .font(.caption2)
                        }
                    }

                    VStack(alignment: .leading, spacing: 4) {
                        Text("Vertical (dy)")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                        HStack {
                            Picker("", selection: $dyAxis) {
                                ForEach(AxisChoice.allCases, id: \.self) { axis in
                                    Text(axis.rawValue).tag(axis)
                                }
                            }
                            .pickerStyle(.segmented)
                            .frame(width: 100)
                            Toggle("Invert", isOn: $invertDy)
                                .font(.caption2)
                        }
                    }
                }

                // Custom mapping canvas
                HStack(spacing: 12) {
                    ZStack {
                        Rectangle()
                            .fill(Color.black.opacity(0.05))

                        // Grid
                        Canvas { context, size in
                            let center = CGPoint(x: size.width / 2, y: size.height / 2)
                            context.stroke(
                                Path { path in
                                    path.move(to: CGPoint(x: 0, y: center.y))
                                    path.addLine(to: CGPoint(x: size.width, y: center.y))
                                    path.move(to: CGPoint(x: center.x, y: 0))
                                    path.addLine(to: CGPoint(x: center.x, y: size.height))
                                },
                                with: .color(.secondary.opacity(0.3)),
                                lineWidth: 1
                            )
                        }

                        // Trail
                        Canvas { context, _ in
                            guard customTrail.count > 1 else { return }
                            var path = Path()
                            path.move(to: customTrail[0])
                            for point in customTrail.dropFirst() {
                                path.addLine(to: point)
                            }
                            context.stroke(path, with: .color(.purple.opacity(0.6)), lineWidth: 2)
                        }

                        // Position
                        Circle()
                            .fill(Color.purple)
                            .frame(width: 10, height: 10)
                            .position(customPos)
                    }
                    .frame(width: 200, height: 200)
                    .cornerRadius(6)
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(Color.purple.opacity(0.3), lineWidth: 1)
                    )

                    VStack(alignment: .leading, spacing: 8) {
                        Text("Mapping:")
                            .font(.caption)
                            .fontWeight(.medium)
                        Text("dx = \(invertDx ? "-" : "")\(dxAxis.rawValue)")
                            .font(.system(size: 11, design: .monospaced))
                        Text("dy = \(invertDy ? "-" : "")\(dyAxis.rawValue)")
                            .font(.system(size: 11, design: .monospaced))

                        Spacer()

                        Button("Reset") {
                            customPos = CGPoint(x: 100, y: 100)
                            customTrail.removeAll()
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                    .frame(width: 80)
                }
            }
        }
        .padding()
        .background(Color.indigo.opacity(0.05))
        .cornerRadius(8)
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.indigo.opacity(0.3), lineWidth: 1)
        )
        .onReceive(Timer.publish(every: 1.0/30.0, on: .main, in: .common).autoconnect()) { _ in
            updateTrails()
            updateCustomPos()
        }
    }

    private func updateTrails() {
        // X trail
        xTrail.append(CGFloat(rawX))
        if xTrail.count > maxTrailLength { xTrail.removeFirst() }

        // Y trail
        yTrail.append(CGFloat(rawY))
        if yTrail.count > maxTrailLength { yTrail.removeFirst() }

        // Z trail
        zTrail.append(CGFloat(rawZ))
        if zTrail.count > maxTrailLength { zTrail.removeFirst() }
    }

    private func updateCustomPos() {
        let scale = 0.05
        var dxVal = Double(getValue(for: dxAxis)) * scale
        var dyVal = Double(getValue(for: dyAxis)) * scale

        if invertDx { dxVal = -dxVal }
        if invertDy { dyVal = -dyVal }

        guard abs(dxVal) > 0.3 || abs(dyVal) > 0.3 else { return }

        var newX = customPos.x + CGFloat(dxVal)
        var newY = customPos.y + CGFloat(dyVal)

        newX = max(5, min(195, newX))
        newY = max(5, min(195, newY))

        customPos = CGPoint(x: newX, y: newY)
        customTrail.append(customPos)
        if customTrail.count > maxTrailLength { customTrail.removeFirst() }
    }
}

struct AxisTrailRow: View {
    let label: String
    let value: Int16
    @Binding var trail: [CGFloat]
    let color: Color
    let trailWidth: CGFloat
    let maxTrail: Int

    // Scale to fit typical gyro values (-500 to 500) into display
    private let displayScale: CGFloat = 0.15

    var body: some View {
        HStack(spacing: 8) {
            // Label and current value
            VStack(alignment: .leading, spacing: 0) {
                Text(label)
                    .font(.system(size: 12, weight: .bold, design: .monospaced))
                    .foregroundColor(color)
                Text("\(value)")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(.secondary)
            }
            .frame(width: 40, alignment: .leading)

            // Trail visualization (1D horizontal)
            ZStack {
                Rectangle()
                    .fill(Color.secondary.opacity(0.1))

                // Center line (zero)
                Rectangle()
                    .fill(Color.secondary.opacity(0.3))
                    .frame(width: 1)

                // Trail line
                Canvas { context, size in
                    guard trail.count > 1 else { return }
                    let centerY = size.height / 2
                    let stepX = size.width / CGFloat(maxTrail)

                    var path = Path()
                    for (index, val) in trail.enumerated() {
                        let x = CGFloat(index) * stepX
                        let y = centerY - (val * displayScale)  // Clamp to view
                        let clampedY = max(2, min(size.height - 2, y))

                        if index == 0 {
                            path.move(to: CGPoint(x: x, y: clampedY))
                        } else {
                            path.addLine(to: CGPoint(x: x, y: clampedY))
                        }
                    }

                    context.stroke(path, with: .color(color), lineWidth: 1.5)
                }

                // Current value indicator
                let displayY = (trailWidth / 2) - CGFloat(value) * displayScale
                let clampedY = max(4, min(trailWidth - 4, displayY))
                Circle()
                    .fill(color)
                    .frame(width: 6, height: 6)
                    .position(x: trailWidth - 4, y: clampedY)
            }
            .frame(width: trailWidth, height: 30)
            .cornerRadius(4)

            // Activity indicator
            let activity = abs(value)
            Text(activity > 100 ? "ACTIVE" : activity > 20 ? "slight" : "still")
                .font(.system(size: 9))
                .foregroundColor(activity > 100 ? color : .secondary)
                .frame(width: 45, alignment: .leading)
        }
    }
}

struct MouseMovementPreviewView: View {
    let rawX: Int16
    let rawY: Int16
    let rawZ: Int16

    @State private var trail: [CGPoint] = []
    @State private var currentPos: CGPoint = CGPoint(x: 150, y: 150)
    private let maxTrailLength = 100
    private let canvasSize: CGFloat = 300

    struct SensitivityPreset: Identifiable {
        let id: String
        let name: String
        let scale: Double
    }

    let presets: [SensitivityPreset] = [
        SensitivityPreset(id: "low", name: "Low (0.01)", scale: 0.01),
        SensitivityPreset(id: "med", name: "Medium (0.05)", scale: 0.05),
        SensitivityPreset(id: "high", name: "High (0.1)", scale: 0.1),
        SensitivityPreset(id: "vhigh", name: "Very High (0.2)", scale: 0.2),
    ]

    @State private var selectedPreset: String = "med"

    private var activeScale: Double {
        presets.first { $0.id == selectedPreset }?.scale ?? 0.05
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Mouse Movement Preview")
                    .font(.headline)
                Spacer()
                Picker("Sensitivity", selection: $selectedPreset) {
                    ForEach(presets) { preset in
                        Text(preset.name).tag(preset.id)
                    }
                }
                .pickerStyle(.menu)
                .frame(width: 160)
            }

            Text("Visual preview of how gyro maps to cursor movement (Z→horizontal, Y→vertical)")
                .font(.caption)
                .foregroundColor(.secondary)

            HStack(spacing: 16) {
                ZStack {
                    Canvas { context, size in
                        let gridSpacing: CGFloat = 30
                        context.stroke(
                            Path { path in
                                for x in stride(from: 0, through: size.width, by: gridSpacing) {
                                    path.move(to: CGPoint(x: x, y: 0))
                                    path.addLine(to: CGPoint(x: x, y: size.height))
                                }
                                for y in stride(from: 0, through: size.height, by: gridSpacing) {
                                    path.move(to: CGPoint(x: 0, y: y))
                                    path.addLine(to: CGPoint(x: size.width, y: y))
                                }
                            },
                            with: .color(.secondary.opacity(0.2)),
                            lineWidth: 1
                        )

                        let center = CGPoint(x: size.width / 2, y: size.height / 2)
                        context.stroke(
                            Path { path in
                                path.move(to: CGPoint(x: center.x - 10, y: center.y))
                                path.addLine(to: CGPoint(x: center.x + 10, y: center.y))
                                path.move(to: CGPoint(x: center.x, y: center.y - 10))
                                path.addLine(to: CGPoint(x: center.x, y: center.y + 10))
                            },
                            with: .color(.secondary),
                            lineWidth: 1
                        )
                    }

                    Canvas { context, size in
                        guard trail.count > 1 else { return }

                        var path = Path()
                        path.move(to: trail[0])
                        for point in trail.dropFirst() {
                            path.addLine(to: point)
                        }

                        context.stroke(
                            path,
                            with: .linearGradient(
                                Gradient(colors: [.blue.opacity(0.3), .blue]),
                                startPoint: trail.first ?? .zero,
                                endPoint: trail.last ?? .zero
                            ),
                            lineWidth: 2
                        )
                    }

                    Circle()
                        .fill(Color.blue)
                        .frame(width: 10, height: 10)
                        .position(currentPos)

                    VStack {
                        Spacer()
                        HStack {
                            Spacer()
                            Button("Reset") {
                                currentPos = CGPoint(x: canvasSize / 2, y: canvasSize / 2)
                                trail.removeAll()
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                        }
                    }
                    .padding(8)
                }
                .frame(width: canvasSize, height: canvasSize)
                .background(Color.black.opacity(0.05))
                .cornerRadius(8)
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(Color.secondary.opacity(0.3), lineWidth: 1)
                )

                VStack(alignment: .leading, spacing: 12) {
                    Text("Current Values")
                        .font(.subheadline)
                        .fontWeight(.medium)

                    Group {
                        LabeledValue(label: "Raw Y (pitch)", value: "\(rawY)")
                        LabeledValue(label: "Raw Z (yaw)", value: "\(rawZ)")
                    }

                    Divider()

                    Group {
                        let dx = Double(rawZ) * activeScale
                        let dy = Double(-rawY) * activeScale
                        LabeledValue(label: "Computed dx", value: String(format: "%.2f px", dx))
                        LabeledValue(label: "Computed dy", value: String(format: "%.2f px", dy))
                    }

                    Divider()

                    Group {
                        LabeledValue(label: "Cursor X", value: String(format: "%.0f", currentPos.x))
                        LabeledValue(label: "Cursor Y", value: String(format: "%.0f", currentPos.y))
                        LabeledValue(label: "Trail pts", value: "\(trail.count)")
                    }
                }
                .frame(width: 120)
            }
        }
        .padding()
        .background(Color.cyan.opacity(0.05))
        .cornerRadius(8)
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.cyan.opacity(0.3), lineWidth: 1)
        )
        .onReceive(Timer.publish(every: 1.0/30.0, on: .main, in: .common).autoconnect()) { _ in
            updatePosition()
        }
    }

    private func updatePosition() {
        let dx = Double(rawZ) * activeScale
        let dy = Double(-rawY) * activeScale

        guard abs(dx) > 0.5 || abs(dy) > 0.5 else { return }

        var newX = currentPos.x + CGFloat(dx)
        var newY = currentPos.y + CGFloat(dy)

        newX = max(5, min(canvasSize - 5, newX))
        newY = max(5, min(canvasSize - 5, newY))

        currentPos = CGPoint(x: newX, y: newY)

        trail.append(currentPos)
        if trail.count > maxTrailLength {
            trail.removeFirst()
        }
    }
}

struct SensorFusionDebugView: View {
    let gyroX: Int16
    let gyroY: Int16
    let gyroZ: Int16
    let accelX: Int16
    let accelY: Int16
    let accelZ: Int16

    @State private var fusionTrail: [CGPoint] = []
    @State private var fusionPos: CGPoint = CGPoint(x: 150, y: 150)
    @State private var currentTrail: [CGPoint] = []
    @State private var currentPos: CGPoint = CGPoint(x: 150, y: 150)

    private let canvasSize: CGFloat = 200
    private let maxTrailLength = 80

    private var gravityVector: (x: Double, y: Double, z: Double) {
        let ax = Double(accelX)
        let ay = Double(accelY)
        let az = Double(accelZ)
        let magnitude = sqrt(ax * ax + ay * ay + az * az)
        guard magnitude > 100 else { return (0, 0, 1) }
        return (ax / magnitude, ay / magnitude, az / magnitude)
    }

    private var horizontalRotation: Double {
        let g = gravityVector
        let gx = Double(gyroX)
        let gy = Double(gyroY)
        let gz = Double(gyroZ)
        return gx * g.x + gy * g.y + gz * g.z
    }

    private var verticalRotation: Double {
        let g = gravityVector

        let horizontal: (x: Double, y: Double, z: Double)
        if abs(g.x) < 0.9 {
            let hx = 0.0
            let hy = g.z
            let hz = -g.y
            let hMag = sqrt(hx*hx + hy*hy + hz*hz)
            horizontal = hMag > 0.01 ? (hx/hMag, hy/hMag, hz/hMag) : (0, 1, 0)
        } else {
            let hx = -g.z
            let hy = 0.0
            let hz = g.x
            let hMag = sqrt(hx*hx + hy*hy + hz*hz)
            horizontal = hMag > 0.01 ? (hx/hMag, hy/hMag, hz/hMag) : (1, 0, 0)
        }

        let gx = Double(gyroX)
        let gy = Double(gyroY)
        let gz = Double(gyroZ)

        return gx * horizontal.x + gy * horizontal.y + gz * horizontal.z
    }

    private var currentDx: Double { Double(gyroZ) * 0.05 }
    private var currentDy: Double { Double(-gyroY) * 0.05 }

    private var fusionDx: Double { horizontalRotation * 0.05 }
    private var fusionDy: Double { -verticalRotation * 0.05 }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Sensor Fusion Debug")
                    .font(.headline)
                Spacer()
                Text("Gravity-aware axis projection")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Text("Uses accelerometer to determine \"up\" direction, then projects gyro rotation onto world axes.")
                .font(.caption)
                .foregroundColor(.secondary)

            VStack(alignment: .leading, spacing: 8) {
                Text("Gravity Vector (from accelerometer)")
                    .font(.subheadline)
                    .fontWeight(.medium)

                HStack(spacing: 16) {
                    GravityAxisBar(label: "Gx", value: gravityVector.x, color: .red)
                    GravityAxisBar(label: "Gy", value: gravityVector.y, color: .green)
                    GravityAxisBar(label: "Gz", value: gravityVector.z, color: .blue)
                }

                HStack {
                    Text("Controller tilt:")
                        .font(.caption)
                        .foregroundColor(.secondary)

                    let dominantAxis = [
                        (abs(gravityVector.x), "X (left/right tilt)"),
                        (abs(gravityVector.y), "Y (forward/back tilt)"),
                        (abs(gravityVector.z), "Z (upright)")
                    ].max(by: { $0.0 < $1.0 })!.1

                    Text(dominantAxis)
                        .font(.caption)
                        .fontWeight(.medium)
                        .foregroundColor(.orange)
                }
            }
            .padding(8)
            .background(Color.orange.opacity(0.1))
            .cornerRadius(6)

            VStack(alignment: .leading, spacing: 4) {
                Text("Projected Rotation")
                    .font(.subheadline)
                    .fontWeight(.medium)

                HStack(spacing: 20) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Horizontal (around gravity)")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                        Text(String(format: "%.1f", horizontalRotation))
                            .font(.system(.title3, design: .monospaced))
                            .foregroundColor(abs(horizontalRotation) > 50 ? .blue : .primary)
                    }

                    VStack(alignment: .leading, spacing: 2) {
                        Text("Vertical (perpendicular)")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                        Text(String(format: "%.1f", verticalRotation))
                            .font(.system(.title3, design: .monospaced))
                            .foregroundColor(abs(verticalRotation) > 50 ? .blue : .primary)
                    }
                }
            }

            HStack(spacing: 16) {
                VStack {
                    Text("Current Mapping")
                        .font(.caption)
                        .fontWeight(.medium)
                    Text("(Z→dx, Y→dy)")
                        .font(.caption2)
                        .foregroundColor(.secondary)

                    ComparisonCanvas(
                        pos: $currentPos,
                        trail: $currentTrail,
                        dx: currentDx,
                        dy: currentDy,
                        size: canvasSize,
                        maxTrail: maxTrailLength,
                        color: .red
                    )

                    Text(String(format: "dx: %.1f, dy: %.1f", currentDx, currentDy))
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundColor(.secondary)
                }

                VStack {
                    Text("Sensor Fusion")
                        .font(.caption)
                        .fontWeight(.medium)
                    Text("(gravity-projected)")
                        .font(.caption2)
                        .foregroundColor(.secondary)

                    ComparisonCanvas(
                        pos: $fusionPos,
                        trail: $fusionTrail,
                        dx: fusionDx,
                        dy: fusionDy,
                        size: canvasSize,
                        maxTrail: maxTrailLength,
                        color: .green
                    )

                    Text(String(format: "dx: %.1f, dy: %.1f", fusionDx, fusionDy))
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundColor(.secondary)
                }
            }

            HStack {
                Spacer()
                Button("Reset Both") {
                    currentPos = CGPoint(x: canvasSize / 2, y: canvasSize / 2)
                    currentTrail.removeAll()
                    fusionPos = CGPoint(x: canvasSize / 2, y: canvasSize / 2)
                    fusionTrail.removeAll()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }

            Text("Move controller left/right and up/down. The sensor fusion canvas should show cleaner horizontal/vertical movement regardless of controller tilt.")
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .padding()
        .background(Color.orange.opacity(0.05))
        .cornerRadius(8)
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.orange.opacity(0.3), lineWidth: 1)
        )
    }
}

struct GravityAxisBar: View {
    let label: String
    let value: Double
    let color: Color

    var body: some View {
        VStack(spacing: 2) {
            Text(label)
                .font(.caption2)
                .foregroundColor(color)

            GeometryReader { geo in
                ZStack {
                    Rectangle()
                        .fill(Color.secondary.opacity(0.2))

                    let barWidth = abs(value) * (geo.size.width / 2)
                    Rectangle()
                        .fill(color)
                        .frame(width: barWidth)
                        .offset(x: value >= 0 ? barWidth / 2 : -barWidth / 2)

                    Rectangle()
                        .fill(Color.secondary)
                        .frame(width: 1)
                }
            }
            .frame(height: 12)
            .cornerRadius(2)

            Text(String(format: "%.2f", value))
                .font(.system(size: 9, design: .monospaced))
        }
        .frame(width: 60)
    }
}

struct ComparisonCanvas: View {
    @Binding var pos: CGPoint
    @Binding var trail: [CGPoint]
    let dx: Double
    let dy: Double
    let size: CGFloat
    let maxTrail: Int
    let color: Color

    var body: some View {
        ZStack {
            Rectangle()
                .fill(Color.black.opacity(0.05))

            Canvas { context, canvasSize in
                let gridSpacing: CGFloat = 25
                context.stroke(
                    Path { path in
                        for x in stride(from: 0, through: canvasSize.width, by: gridSpacing) {
                            path.move(to: CGPoint(x: x, y: 0))
                            path.addLine(to: CGPoint(x: x, y: canvasSize.height))
                        }
                        for y in stride(from: 0, through: canvasSize.height, by: gridSpacing) {
                            path.move(to: CGPoint(x: 0, y: y))
                            path.addLine(to: CGPoint(x: canvasSize.width, y: y))
                        }
                    },
                    with: .color(.secondary.opacity(0.15)),
                    lineWidth: 1
                )

                let center = CGPoint(x: canvasSize.width / 2, y: canvasSize.height / 2)
                context.stroke(
                    Path { path in
                        path.move(to: CGPoint(x: center.x - 8, y: center.y))
                        path.addLine(to: CGPoint(x: center.x + 8, y: center.y))
                        path.move(to: CGPoint(x: center.x, y: center.y - 8))
                        path.addLine(to: CGPoint(x: center.x, y: center.y + 8))
                    },
                    with: .color(.secondary.opacity(0.5)),
                    lineWidth: 1
                )
            }

            Canvas { context, _ in
                guard trail.count > 1 else { return }
                var path = Path()
                path.move(to: trail[0])
                for point in trail.dropFirst() {
                    path.addLine(to: point)
                }
                context.stroke(path, with: .color(color.opacity(0.5)), lineWidth: 2)
            }

            Circle()
                .fill(color)
                .frame(width: 8, height: 8)
                .position(pos)
        }
        .frame(width: size, height: size)
        .cornerRadius(6)
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(color.opacity(0.3), lineWidth: 1)
        )
        .onReceive(Timer.publish(every: 1.0/30.0, on: .main, in: .common).autoconnect()) { _ in
            updatePosition()
        }
    }

    private func updatePosition() {
        guard abs(dx) > 0.3 || abs(dy) > 0.3 else { return }

        var newX = pos.x + CGFloat(dx)
        var newY = pos.y + CGFloat(dy)

        newX = max(4, min(size - 4, newX))
        newY = max(4, min(size - 4, newY))

        pos = CGPoint(x: newX, y: newY)

        trail.append(pos)
        if trail.count > maxTrail {
            trail.removeFirst()
        }
    }
}
