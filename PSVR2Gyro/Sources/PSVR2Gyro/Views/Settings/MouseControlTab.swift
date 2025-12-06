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
                    DeadzoneSection(appState: appState)

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
                        Slider(value: $appState.minCutoff, in: 0.01...10.0, step: 0.01)
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
                        Slider(value: $appState.beta, in: 0.0...2.0, step: 0.01)
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
                // Curve type
                VStack(alignment: .leading, spacing: 8) {
                    Text("Curve Type")
                        .font(.caption.weight(.medium))
                    Picker("", selection: $appState.accelerationCurve) {
                        ForEach(AccelerationCurve.allCases, id: \.self) { curve in
                            Text(curve.displayName).tag(curve)
                        }
                    }
                    .pickerStyle(.segmented)
                    DescriptionText(text: appState.accelerationCurve.description)
                }

                if appState.accelerationCurve != .off {
                    Divider()

                    // Strength
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("Acceleration Strength")
                                .font(.caption.weight(.medium))
                            Spacer()
                            Text(String(format: "%.1fx", appState.accelerationStrength))
                                .font(.caption.monospacedDigit())
                                .foregroundColor(.secondary)
                        }
                        Slider(value: $appState.accelerationStrength, in: 0.0...20.0, step: 0.1)
                        DescriptionText(text: "Multiplier for the acceleration curve's effect. At 0, the curve is effectively disabled (acts like 'Off'). At 1.0, the curve behaves as designed. Values above 1.0 exaggerate the curve's effect, making acceleration kick in earlier and more aggressively. Useful for tuning how quickly you reach the sensitivity cap.")
                    }

                    // Sensitivity Cap
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("Sensitivity Cap")
                                .font(.caption.weight(.medium))
                            Spacer()
                            Text(String(format: "%.1fx", appState.sensitivityCap))
                                .font(.caption.monospacedDigit())
                                .foregroundColor(.secondary)
                        }
                        Slider(value: $appState.sensitivityCap, in: 1.0...100.0, step: 0.5)
                        DescriptionText(text: "The maximum gain multiplier that acceleration can reach. A cap of 2.0x means fast movements can be up to twice as fast as slow movements. A cap of 100x means extreme flicks can move the cursor 100 times faster than precise micro-adjustments. Higher caps give you more dynamic range but require more muscle memory to master.")
                    }
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
}

// MARK: - Deadzone Section

private struct DeadzoneSection: View {
    @ObservedObject var appState: AppState
    @State private var isExpanded = false

    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            VStack(alignment: .leading, spacing: 16) {
                // Cutoff Threshold
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Cutoff Threshold")
                            .font(.caption.weight(.medium))
                        Spacer()
                        Text(String(format: "%.2f °/s", appState.softCutoffThreshold))
                            .font(.caption.monospacedDigit())
                            .foregroundColor(.secondary)
                    }
                    Slider(value: $appState.softCutoffThreshold, in: 0.0...5.0, step: 0.05)
                    DescriptionText(text: "The angular velocity (in degrees per second) below which NO cursor movement occurs. This eliminates drift from sensor noise and hand tremor when you're trying to hold still. Set this just above your natural hand shake level. Too high = cursor feels 'sticky' and hard to start moving.")
                }

                // Recovery Threshold
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Recovery Threshold")
                            .font(.caption.weight(.medium))
                        Spacer()
                        Text(String(format: "%.2f °/s", appState.recoveryThreshold))
                            .font(.caption.monospacedDigit())
                            .foregroundColor(.secondary)
                    }
                    Slider(value: $appState.recoveryThreshold, in: 0.1...10.0, step: 0.1)
                    DescriptionText(text: "The angular velocity at which full sensitivity is restored. Between the cutoff and recovery thresholds, sensitivity ramps up linearly (soft cutoff). This creates a smooth transition instead of an abrupt jump. Set this higher than cutoff to create a gentle 'easing in' zone.")
                }

                // Visual indicator
                VStack(alignment: .leading, spacing: 4) {
                    Text("Deadzone Visualization")
                        .font(.caption.weight(.medium))
                    DeadzoneVisualizer(
                        cutoff: appState.softCutoffThreshold,
                        recovery: appState.recoveryThreshold
                    )
                }
            }
            .padding(.vertical, 8)
        } label: {
            HStack {
                Image(systemName: "circle.dashed")
                    .foregroundColor(.green)
                Text("Deadzone")
                    .font(.subheadline.weight(.medium))
            }
        }
        .padding()
        .background(Color.secondary.opacity(0.05))
        .cornerRadius(8)
    }
}

// MARK: - Deadzone Visualizer

private struct DeadzoneVisualizer: View {
    let cutoff: Double
    let recovery: Double

    var body: some View {
        GeometryReader { geo in
            let width = geo.size.width
            let maxSpeed = 10.0
            let cutoffX = cutoff / maxSpeed * width
            let recoveryX = recovery / maxSpeed * width

            ZStack(alignment: .leading) {
                // Background
                Rectangle()
                    .fill(Color.secondary.opacity(0.1))

                // Dead zone (red)
                Rectangle()
                    .fill(Color.red.opacity(0.3))
                    .frame(width: max(0, cutoffX))

                // Transition zone (yellow)
                Rectangle()
                    .fill(Color.yellow.opacity(0.3))
                    .frame(width: max(0, recoveryX - cutoffX))
                    .offset(x: cutoffX)

                // Active zone (green)
                Rectangle()
                    .fill(Color.green.opacity(0.3))
                    .frame(width: max(0, width - recoveryX))
                    .offset(x: recoveryX)

                // Labels
                HStack {
                    Text("Dead")
                        .font(.system(size: 9))
                        .foregroundColor(.secondary)
                    Spacer()
                    Text("Transition")
                        .font(.system(size: 9))
                        .foregroundColor(.secondary)
                    Spacer()
                    Text("Full")
                        .font(.system(size: 9))
                        .foregroundColor(.secondary)
                }
                .padding(.horizontal, 4)
            }
        }
        .frame(height: 24)
        .cornerRadius(4)
    }
}
