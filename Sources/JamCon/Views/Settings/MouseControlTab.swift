import SwiftUI

// MARK: - Mouse Control Tab

struct MouseControlTab: View {
    @ObservedObject var appState: AppState

    var body: some View {
        VStack(spacing: 0) {
            if appState.configurationProfile.kind == .mouse {
                // Mouse devices don't have gyro
                NoControllerView(
                    icon: "computermouse",
                    message: "USB mice do not use gyro pointer settings."
                )
            } else {
                ScrollView {
                    VStack(spacing: 16) {
                        // Profile indicator
                        GyroProfileIndicator(appState: appState)

                        // Per-profile cursor enablement
                        CursorControlSection(appState: appState)

                        // Main settings
                        VStack(spacing: 12) {
                            // Sensitivity (always visible)
                            SensitivitySection(appState: appState)

                            // Collapsible sections
                            FilteringSection(appState: appState)
                            SamplingAndCalibrationSection(appState: appState)
                            AccelerationSection(appState: appState)

                            // Reset button
                            Button(action: { appState.resetGyroSettings() }) {
                                HStack {
                                    Image(systemName: "arrow.counterclockwise")
                                    Text("Reset All Pointer Settings")
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
        .navigationTitle("Cursor & Gyro")
    }
}

// MARK: - Cursor Control Enablement

private struct CursorControlSection: View {
    @ObservedObject var appState: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle("Enable Cursor Control", isOn: $appState.cursorControlEnabled)
                .font(.subheadline.weight(.medium))

            DescriptionText(text: "When off, this profile’s buttons still work, but its gyro and joystick will not move or scroll the pointer.")
        }
        .padding()
        .background(Color.secondary.opacity(0.05))
        .cornerRadius(8)
    }
}

// MARK: - Profile Indicator

private struct GyroProfileIndicator: View {
    @ObservedObject var appState: AppState

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "cpu")
                .foregroundColor(.blue)
            VStack(alignment: .leading, spacing: 2) {
                Text("Configuring: \(appState.configurationProfile.displayName)")
                    .font(.caption.bold())
                Text("Pointer settings are saved for this controller type.")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
            Spacer()
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
        .background(Color.blue.opacity(0.05))
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
            }

            PreciseSlider(
                value: $appState.sensitivity,
                range: 1...100,
                step: 0.5,
                fractionDigits: 1
            )

            DescriptionText(text: "Higher values move the pointer farther for the same controller rotation.")

            SectionResetButton("Sensitivity") {
                appState.resetGyroSettings(.sensitivity)
            }
        }
        .padding()
        .background(Color.secondary.opacity(0.05))
        .cornerRadius(8)
    }
}

// MARK: - Filtering Section

private struct FilteringSection: View {
    @ObservedObject var appState: AppState
    @State private var isExpanded = false

    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            VStack(alignment: .leading, spacing: 16) {
                // Enable toggle with description
                VStack(alignment: .leading, spacing: 8) {
                    Toggle("Enable One Euro Filter", isOn: $appState.filterEnabled)
                        .font(.subheadline)

                    DescriptionText(text: "Reduces small-motion jitter while relaxing smoothing during faster movement.")
                }

                if appState.filterEnabled {
                    Divider()

                    // Min Cutoff
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("Min Cutoff (Smoothing)")
                                .font(.caption.weight(.medium))
                        }
                        PreciseSlider(
                            value: $appState.minCutoff,
                            range: 0.5...10,
                            step: 0.5,
                            fractionDigits: 1,
                            suffix: "Hz"
                        )
                        DescriptionText(text: "Lower values are steadier; higher values respond faster.")
                    }

                    // Beta
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("Beta (Speed Reactivity)")
                                .font(.caption.weight(.medium))
                        }
                        PreciseSlider(
                            value: $appState.beta,
                            range: 0...2,
                            step: 0.1,
                            fractionDigits: 1
                        )
                        DescriptionText(text: "Higher values remove smoothing more quickly as movement speeds up.")
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

                SectionResetButton("Filtering") {
                    appState.resetGyroSettings(.filtering)
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
            return "Uses the same smoothing response at every movement speed."
        case .speed:
            return "Reduces smoothing as movement gets faster."
        case .speedAndJerk:
            return "Also responds quickly to sudden starts and direction changes."
        }
    }
}

// MARK: - Sampling and Calibration

private struct SamplingAndCalibrationSection: View {
    @ObservedObject var appState: AppState
    @State private var isExpanded = false

    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            VStack(alignment: .leading, spacing: 16) {
                if appState.configurationProfile.kind == .joyCon {
                    VStack(alignment: .leading, spacing: 8) {
                        Toggle(
                            "Average Joy-Con gyro samples",
                            isOn: $appState.joyConUseAveragedGyroSamples
                        )
                        .font(.subheadline)
                        DescriptionText(
                            text: "Averages the three gyro samples in each Joy-Con report. Leave off for the freshest response."
                        )
                    }
                }

                VStack(alignment: .leading, spacing: 8) {
                    Toggle("Auto-tune nominal sample rate", isOn: $appState.autoTuneSampleRate)
                        .font(.subheadline)
                    DescriptionText(
                        text: "Learns small differences in normal report cadence while ignoring stalls."
                    )
                }

                VStack(alignment: .leading, spacing: 8) {
                    Toggle("Auto-calibrate when very still", isOn: $appState.autoNeutralEnabled)
                        .font(.subheadline)
                    DescriptionText(
                        text: "Refreshes gyro neutral after the controller remains genuinely still."
                    )
                }

                SectionResetButton("Sampling & Calibration") {
                    appState.resetGyroSettings(.samplingAndCalibration)
                }
            }
            .padding(.vertical, 8)
        } label: {
            HStack {
                Image(systemName: "metronome")
                    .foregroundColor(.blue)
                Text("Sampling & Calibration")
                    .font(.subheadline.weight(.medium))
            }
        }
        .padding()
        .background(Color.secondary.opacity(0.05))
        .cornerRadius(8)
    }
}

// MARK: - Acceleration Section

private struct AccelerationSection: View {
    @ObservedObject var appState: AppState
    @State private var isExpanded = false

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
                    }
                    PreciseSlider(
                        value: $appState.curveExponent,
                        range: 0.1...5,
                        step: 0.05,
                        fractionDigits: 2
                    )
                    DescriptionText(text: curveShapeDescription)
                }

                // Ramp Speed
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Ramp Speed")
                            .font(.caption.weight(.medium))
                    }
                    PreciseSlider(
                        value: $appState.rampSpeed,
                        range: 10...500,
                        step: 5,
                        fractionDigits: 0,
                        suffix: "°/s"
                    )
                    DescriptionText(text: "Lower values reach maximum gain sooner; higher values ramp more gradually.")
                }

                // Cap
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Cap (Max Gain)")
                            .font(.caption.weight(.medium))
                    }
                    PreciseSlider(
                        value: $appState.sensitivityCap,
                        range: 1...1000,
                        step: 1,
                        fractionDigits: 0,
                        suffix: "×"
                    )
                    DescriptionText(text: "Limits the gain applied during the fastest movements.")
                }

                SectionResetButton("Acceleration") {
                    appState.resetGyroSettings(.acceleration)
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
            return "Ramps quickly at lower speeds, then levels off."
        } else if appState.curveExponent > 1.1 {
            return "Preserves low-speed precision, then ramps more sharply."
        } else {
            return "Uses a predictable linear acceleration ramp."
        }
    }
}

private struct SectionResetButton: View {
    let sectionName: String
    let action: () -> Void

    init(_ sectionName: String, action: @escaping () -> Void) {
        self.sectionName = sectionName
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            Label("Reset \(sectionName)", systemImage: "arrow.counterclockwise")
                .font(.caption)
        }
        .buttonStyle(.plain)
        .foregroundColor(.secondary)
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
