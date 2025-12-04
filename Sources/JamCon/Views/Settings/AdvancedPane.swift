import SwiftUI

struct AdvancedPane: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        Form {
            Section("Power Management") {
                Picker("Auto Power-Off", selection: autoPowerOffBinding) {
                    Text("Off").tag(0)
                    Text("5 min").tag(5)
                    Text("15 min").tag(15)
                    Text("30 min").tag(30)
                    Text("1 hr").tag(60)
                    Text("2 hr").tag(120)
                }

                Text("Automatically disconnects Joy-Cons after inactivity to save battery.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Section("Accessibility") {
                HStack {
                    Circle()
                        .fill(appState.hasAccessibilityPermission ? Color.green : Color.orange)
                        .frame(width: 10, height: 10)
                    Text(appState.hasAccessibilityPermission ? "Permission Granted" : "Permission Required")

                    Spacer()

                    if !appState.hasAccessibilityPermission {
                        Button("Open Settings") {
                            appState.openAccessibilitySettings()
                        }
                        .buttonStyle(.bordered)
                    }
                }

                Text("Accessibility permission is required to control the mouse cursor.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Section("Debug") {
                Toggle("Collect IMU Timing Data", isOn: $appState.debugIMUEnabled)

                if appState.debugIMUEnabled {
                    imuTimingView
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Advanced")
    }

    private var autoPowerOffBinding: Binding<Int> {
        Binding(
            get: {
                if !appState.autoPowerOffEnabled {
                    return 0
                }
                let minutes = Int(appState.idleTimeoutMinutes)
                let presets = [5, 15, 30, 60, 120]
                return presets.min(by: { abs($0 - minutes) < abs($1 - minutes) }) ?? 30
            },
            set: { newValue in
                if newValue == 0 {
                    appState.autoPowerOffEnabled = false
                } else {
                    appState.autoPowerOffEnabled = true
                    appState.idleTimeoutMinutes = Double(newValue)
                }
            }
        )
    }

    private var imuTimingView: some View {
        let samples = appState.imuDtSamples
        let maxDt = samples.max() ?? 0
        let avgDt = samples.isEmpty ? 0 : samples.reduce(0, +) / Double(samples.count)
        let avgHz = avgDt > 0 ? 1.0 / avgDt : 0
        let sparkMax = max(maxDt * 1.1, 0.03)
        let histogramBins: [Double] = [0.004, 0.006, 0.008, 0.010, 0.012, 0.016, 0.020, 0.030, 0.050, 0.080]

        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("IMU Timing")
                    .font(.caption)
                    .fontWeight(.medium)
                Spacer()
                Text(String(format: "%.0f Hz avg (%.0f inst)", avgHz, appState.imuLastHz))
                    .font(.system(.caption, design: .monospaced))
                    .foregroundColor(.secondary)
            }

            // Delta time sparkline
            SparklineView(values: samples, maxValue: sparkMax, color: .blue)
                .frame(height: 32)
                .background(Color.secondary.opacity(0.08))
                .cornerRadius(4)

            // Gap indicator
            SparklineView(values: appState.imuGapFlags.map { $0 ? 1.0 : 0.0 }, maxValue: 1.0, color: .red.opacity(0.8))
                .frame(height: 12)
                .background(Color.secondary.opacity(0.08))
                .cornerRadius(4)

            // Motion magnitude sparkline
            SparklineView(values: appState.imuMotionSamples, maxValue: max(appState.imuMotionSamples.max() ?? 1, 500), color: .purple.opacity(0.8))
                .frame(height: 32)
                .background(Color.secondary.opacity(0.08))
                .cornerRadius(4)

            // Histogram
            HistogramView(values: samples, bins: histogramBins)
                .frame(height: 40)

            // Stats
            HStack(spacing: 16) {
                Text(String(format: "Max dt: %.3f s", maxDt))
                    .font(.system(.caption, design: .monospaced))
                    .foregroundColor(.secondary)
                Text(String(format: "Gaps: %d", appState.imuGapCount))
                    .font(.system(.caption, design: .monospaced))
                    .foregroundColor(.secondary)
            }
        }
    }
}

// MARK: - Debug Visualizations

private struct SparklineView: View {
    let values: [Double]
    let maxValue: Double
    var color: Color = .blue

    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            let height = geometry.size.height
            let count = values.count

            Path { path in
                guard count > 1 else { return }
                for (index, value) in values.enumerated() {
                    let x = CGFloat(Double(index) / Double(count - 1)) * width
                    let clamped = max(0.0, min(value, maxValue))
                    let normalized = clamped / maxValue
                    let y = height - CGFloat(normalized) * height
                    if index == 0 {
                        path.move(to: CGPoint(x: x, y: y))
                    } else {
                        path.addLine(to: CGPoint(x: x, y: y))
                    }
                }
            }
            .stroke(color, lineWidth: 1)
        }
    }
}

private struct HistogramView: View {
    let values: [Double]
    let bins: [Double]

    var body: some View {
        let counts = histogramCounts(values: values, bins: bins)
        let maxCount = counts.max() ?? 1
        return HStack(alignment: .bottom, spacing: 4) {
            ForEach(0..<counts.count, id: \.self) { idx in
                let heightRatio = maxCount > 0 ? Double(counts[idx]) / Double(maxCount) : 0
                Rectangle()
                    .fill(Color.green.opacity(0.7))
                    .frame(maxWidth: .infinity)
                    .frame(height: CGFloat(heightRatio) * 36)
            }
        }
    }

    private func histogramCounts(values: [Double], bins: [Double]) -> [Int] {
        var counts = Array(repeating: 0, count: bins.count + 1)
        for v in values {
            var placed = false
            for (i, edge) in bins.enumerated() {
                if v <= edge {
                    counts[i] += 1
                    placed = true
                    break
                }
            }
            if !placed { counts[counts.count - 1] += 1 }
        }
        return counts
    }
}

#Preview {
    AdvancedPane()
        .environmentObject(AppState())
        .frame(width: 500, height: 500)
}
