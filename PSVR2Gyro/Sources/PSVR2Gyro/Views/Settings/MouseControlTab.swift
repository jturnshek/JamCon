import SwiftUI

// MARK: - Mouse Control Tab

struct MouseControlTab: View {
    @ObservedObject var appState: AppState

    var body: some View {
        VStack(spacing: 0) {
            TabHeader(appState: appState)

            ScrollView {
                VStack(spacing: 16) {

                // Main settings
                VStack(spacing: 12) {
                    // Sensitivity (always visible)
                    SensitivitySection(appState: appState)

                    // Collapsible sections
                    FilteringSection(appState: appState)
                    AccelerationSection(appState: appState)

                    // Reset button
                    Button(action: { appState.resetGyroSettings() }) {
                        HStack {
                            Image(systemName: "arrow.counterclockwise")
                            Text("Reset to Defaults")
                        }
                        .foregroundColor(.secondary)
                    }
                    .buttonStyle(.plain)
                    .padding(.top, 8)
                }
                .padding()
                }
            }
        }
    }
}

// MARK: - Helper for Description Text

private struct DescriptionText: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.caption)
            .foregroundColor(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

// MARK: - Sensitivity Section

private struct SensitivitySection: View {
    @ObservedObject var appState: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Sensitivity")
                    .font(.subheadline.weight(.medium))
                Spacer()
                Text(String(format: "%.1f", appState.sensitivity))
                    .font(.subheadline.monospacedDigit())
                    .foregroundColor(.secondary)
            }

            Slider(value: $appState.sensitivity, in: 1...100, step: 0.5)

            DescriptionText(text: "Base multiplier for all mouse movement. Higher values make the cursor move faster for the same physical controller rotation. This is applied after all filtering and acceleration.")
        }
        .padding()
        .background(Color.secondary.opacity(0.05))
        .cornerRadius(8)
    }
}

// MARK: - Filtering Section

private struct FilteringSection: View {
    @ObservedObject var appState: AppState
    @State private var isExpanded = true

    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            VStack(alignment: .leading, spacing: 16) {
                // Enable toggle with description
                VStack(alignment: .leading, spacing: 8) {
                    Toggle("Enable One Euro Filter", isOn: $appState.filterEnabled)
                        .font(.subheadline)

                    DescriptionText(text: "The One Euro filter is an adaptive low-pass filter designed specifically for human input devices. It automatically adjusts smoothing based on how fast you're moving - heavy smoothing when stationary or moving slowly (to eliminate jitter), minimal smoothing when moving quickly (to preserve responsiveness). This is the industry-standard filter used in VR/AR systems.")
                }

                if appState.filterEnabled {
                    Divider()

                    // Min Cutoff
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("Min Cutoff (Smoothing)")
                                .font(.caption.weight(.medium))
                            Spacer()
                            Text(String(format: "%.2f Hz", appState.minCutoff))
                                .font(.caption.monospacedDigit())
                                .foregroundColor(.secondary)
                        }
                        Slider(value: $appState.minCutoff, in: 0.5...10.0, step: 0.5)
                        DescriptionText(text: "The base cutoff frequency in Hz. This controls how much smoothing is applied when you're moving slowly or holding still. Lower values = more smoothing = less jitter but more perceived lag. Higher values = less smoothing = more responsive but potentially jittery. Typical range: 0.5-3.0 Hz.")
                    }

                    // Beta
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("Beta (Speed Reactivity)")
                                .font(.caption.weight(.medium))
                            Spacer()
                            Text(String(format: "%.2f", appState.beta))
                                .font(.caption.monospacedDigit())
                                .foregroundColor(.secondary)
                        }
                        Slider(value: $appState.beta, in: 0.0...2.0, step: 0.1)
                        DescriptionText(text: "Controls how much the filter 'opens up' when you move fast. Higher values mean the filter will reduce smoothing more aggressively during quick movements, reducing lag during flicks and fast aiming. Lower values keep more consistent smoothing regardless of speed. 0 = static smoothing, 1+ = very reactive.")
                    }

                    // Adaptive Mode
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Adaptive Smoothing Mode")
                            .font(.caption.weight(.medium))
                        Picker("", selection: $appState.adaptiveSmoothingMode) {
                            ForEach(AdaptiveSmoothingMode.allCases, id: \.self) { mode in
                                Text(mode.displayName).tag(mode)
                            }
                        }
                        .pickerStyle(.segmented)
                        DescriptionText(text: adaptiveModeDescription)
                    }
                }
            }
            .padding(.vertical, 8)
        } label: {
            HStack {
                Image(systemName: "waveform.path")
                    .foregroundColor(.blue)
                Text("Filtering")
                    .font(.subheadline.weight(.medium))
            }
        }
        .padding()
        .background(Color.secondary.opacity(0.05))
        .cornerRadius(8)
    }

    private var adaptiveModeDescription: String {
        switch appState.adaptiveSmoothingMode {
        case .off:
            return "Static beta value - smoothing doesn't change based on motion characteristics. The filter behaves the same regardless of how you move."
        case .speed:
            return "Beta increases proportionally to angular velocity. Fast movements automatically get less smoothing, reducing lag during quick motions while maintaining stability when moving slowly."
        case .speedAndJerk:
            return "Beta increases based on both velocity AND acceleration (jerk). This mode responds to sudden direction changes, not just speed. Best for fast-paced use where you make quick, sharp movements."
        }
    }
}

// MARK: - Acceleration Section

private struct AccelerationSection: View {
    @ObservedObject var appState: AppState
    @State private var isExpanded = true

    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            VStack(alignment: .leading, spacing: 16) {
                // Curve visualization
                AccelerationCurveView(
                    exponent: appState.curveExponent,
                    rampSpeed: appState.rampSpeed,
                    cap: appState.sensitivityCap
                )
                .frame(height: 120)

                // Exponent
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Curve Shape (Exponent)")
                            .font(.caption.weight(.medium))
                        Spacer()
                        Text(String(format: "%.2f", appState.curveExponent))
                            .font(.caption.monospacedDigit())
                            .foregroundColor(.secondary)
                    }
                    Slider(value: $appState.curveExponent, in: 0.1...5.0, step: 0.05)
                    DescriptionText(text: curveShapeDescription)
                }

                // Ramp Speed
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Ramp Speed")
                            .font(.caption.weight(.medium))
                        Spacer()
                        Text(String(format: "%.0f °/s", appState.rampSpeed))
                            .font(.caption.monospacedDigit())
                            .foregroundColor(.secondary)
                    }
                    Slider(value: $appState.rampSpeed, in: 10...500, step: 5)
                    DescriptionText(text: "Speed at which gain reaches the cap. Lower = reaches cap faster, higher = more gradual ramp.")
                }

                // Cap
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Cap (Max Gain)")
                            .font(.caption.weight(.medium))
                        Spacer()
                        Text(String(format: "%.0fx", appState.sensitivityCap))
                            .font(.caption.monospacedDigit())
                            .foregroundColor(.secondary)
                    }
                    Slider(value: $appState.sensitivityCap, in: 1...1000, step: 1)
                    DescriptionText(text: "Maximum gain multiplier at high speeds. Higher = faster flicks possible.")
                }
            }
            .padding(.vertical, 8)
        } label: {
            HStack {
                Image(systemName: "speedometer")
                    .foregroundColor(.orange)
                Text("Acceleration")
                    .font(.subheadline.weight(.medium))
            }
        }
        .padding()
        .background(Color.secondary.opacity(0.05))
        .cornerRadius(8)
    }

    private var curveShapeDescription: String {
        if appState.curveExponent < 0.9 {
            return "Concave curve - ramps up quickly at low speeds, then levels off. Good for precise control with fast flick capability."
        } else if appState.curveExponent > 1.1 {
            return "Convex curve - slow at low speeds, steep at high speeds. Maximum precision at low speeds, aggressive at high."
        } else {
            return "Linear curve - constant rate of acceleration. Predictable and easy to learn."
        }
    }
}

// MARK: - Acceleration Curve View

private struct AccelerationCurveView: View {
    let exponent: Double
    let rampSpeed: Double
    let cap: Double

    var body: some View {
        Canvas { context, size in
            let width = size.width
            let height = size.height
            let padding: CGFloat = 24

            let plotWidth = width - padding * 2
            let plotHeight = height - padding * 2
            let plotOrigin = CGPoint(x: padding, y: padding)

            // Background
            context.fill(
                Path(CGRect(x: plotOrigin.x, y: plotOrigin.y, width: plotWidth, height: plotHeight)),
                with: .color(.secondary.opacity(0.05))
            )

            // X-axis: 0 to rampSpeed (input speed)
            // Y-axis: 1 to cap (gain)
            let effectiveRamp = max(1.0, rampSpeed)
            let effectiveCap = max(1.0, cap)

            // Helper to convert data coords to canvas coords
            func toCanvas(speed: Double, gain: Double) -> CGPoint {
                let x = plotOrigin.x + (speed / effectiveRamp) * plotWidth
                let y = plotOrigin.y + plotHeight - ((gain - 1) / (effectiveCap - 1)) * plotHeight
                return CGPoint(x: x, y: y)
            }

            // Draw curve
            var path = Path()
            let steps = 100
            for i in 0...steps {
                let speed = Double(i) / Double(steps) * effectiveRamp
                let gain = computeGain(speed: speed)
                let point = toCanvas(speed: speed, gain: gain)

                if i == 0 {
                    path.move(to: point)
                } else {
                    path.addLine(to: point)
                }
            }
            context.stroke(path, with: .color(.orange), lineWidth: 2)

            // Draw axes
            var axisPath = Path()
            // Y-axis
            axisPath.move(to: CGPoint(x: plotOrigin.x, y: plotOrigin.y))
            axisPath.addLine(to: CGPoint(x: plotOrigin.x, y: plotOrigin.y + plotHeight))
            // X-axis
            axisPath.addLine(to: CGPoint(x: plotOrigin.x + plotWidth, y: plotOrigin.y + plotHeight))
            context.stroke(axisPath, with: .color(.secondary), lineWidth: 1)

            // Labels
            let labelFont = Font.system(size: 9)

            // Y-axis labels (gain)
            context.draw(
                Text("1.0").font(labelFont).foregroundColor(.secondary),
                at: CGPoint(x: plotOrigin.x - 12, y: plotOrigin.y + plotHeight),
                anchor: .trailing
            )
            context.draw(
                Text(String(format: "%.0f", effectiveCap)).font(labelFont).foregroundColor(.secondary),
                at: CGPoint(x: plotOrigin.x - 12, y: plotOrigin.y),
                anchor: .trailing
            )
            context.draw(
                Text("Gain").font(labelFont).foregroundColor(.secondary),
                at: CGPoint(x: plotOrigin.x - 12, y: plotOrigin.y + plotHeight / 2),
                anchor: .trailing
            )

            // X-axis labels (speed)
            context.draw(
                Text("0").font(labelFont).foregroundColor(.secondary),
                at: CGPoint(x: plotOrigin.x, y: plotOrigin.y + plotHeight + 10),
                anchor: .top
            )
            context.draw(
                Text(String(format: "%.0f", effectiveRamp)).font(labelFont).foregroundColor(.secondary),
                at: CGPoint(x: plotOrigin.x + plotWidth, y: plotOrigin.y + plotHeight + 10),
                anchor: .top
            )
            context.draw(
                Text("Speed (°/s)").font(labelFont).foregroundColor(.secondary),
                at: CGPoint(x: plotOrigin.x + plotWidth / 2, y: plotOrigin.y + plotHeight + 10),
                anchor: .top
            )
        }
        .background(Color.secondary.opacity(0.02))
        .cornerRadius(8)
    }

    private func computeGain(speed: Double) -> Double {
        let effectiveRamp = max(1.0, rampSpeed)
        let effectiveCap = max(1.0, cap)
        let normalized = min(1.0, speed / effectiveRamp)
        let curved = pow(normalized, exponent)
        return 1.0 + curved * (effectiveCap - 1.0)
    }
}
