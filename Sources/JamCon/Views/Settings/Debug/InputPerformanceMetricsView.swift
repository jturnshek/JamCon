import SwiftUI

struct InputPerformanceMetricsView: View {
    @ObservedObject var telemetry: DebugTelemetryState

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Input Performance")
                    .font(.subheadline)
                    .fontWeight(.medium)
                    .foregroundColor(.secondary)
                Spacer()
                Text(String(format: "%.0f reports/s", telemetry.stats.reportsPerSecond))
                    .font(.caption.monospacedDigit())
                    .foregroundColor(.secondary)
            }

            if let timing = telemetry.stats.timing {
                Grid(alignment: .trailing, horizontalSpacing: 14, verticalSpacing: 4) {
                    GridRow {
                        Text("")
                        columnHeader("Latest")
                        columnHeader("Average")
                        columnHeader("P95")
                        columnHeader("Max")
                    }
                    metricRow("Input age", timing.inputAge)
                    metricRow("Queue", timing.queueDelay)
                    metricRow("Processing", timing.processing)
                }

                Text("Input age is controller report timestamp → engine completion. Queue and processing isolate JamCon overhead. Window: \(timing.sampleCount) samples.")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            } else {
                Text("Waiting for timing samples…")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
    }

    private func columnHeader(_ title: String) -> some View {
        Text(title)
            .font(.caption2)
            .foregroundColor(.secondary)
    }

    private func metricRow(_ title: String, _ summary: DebugBuffer.MetricSummary) -> some View {
        GridRow {
            Text(title)
                .font(.caption)
                .foregroundColor(.secondary)
                .gridColumnAlignment(.leading)
            value(summary.latest)
            value(summary.average)
            value(summary.p95)
            value(summary.maximum)
        }
    }

    private func value(_ milliseconds: Double) -> some View {
        Text(String(format: "%.2f ms", milliseconds))
            .font(.caption.monospacedDigit())
    }
}
