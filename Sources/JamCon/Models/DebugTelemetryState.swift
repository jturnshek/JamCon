import Combine
import Foundation

/// Debug-only, high-frequency telemetry for the settings UI.
///
/// Kept separate from `AppState` so rapid updates (e.g. 30Hz polling) don't invalidate
/// the rest of the settings UI.
@MainActor
final class DebugTelemetryState: ObservableObject {
    struct Snapshot {
        var sample: DebugBuffer.Sample?
        var stats: DebugBuffer.Stats
        var byteLastChanged: [Date]
        var bitLastChanged: [[Date]]
        var buttonStates: [LogicalButton: Bool]

        static let empty = Snapshot(
            sample: nil,
            stats: .init(),
            byteLastChanged: [],
            bitLastChanged: [],
            buttonStates: [:]
        )
    }

    @Published private(set) var snapshot: Snapshot = .empty

    func update(sample: DebugBuffer.Sample?, stats: DebugBuffer.Stats, byteLastChanged: [Date], bitLastChanged: [[Date]]) {
        var states: [LogicalButton: Bool] = [:]
        if let sample {
            for (index, button) in LogicalButton.allCases.enumerated() where index < sample.buttonStates.count {
                states[button] = sample.buttonStates[index]
            }
        }

        snapshot = Snapshot(
            sample: sample,
            stats: stats,
            byteLastChanged: byteLastChanged,
            bitLastChanged: bitLastChanged,
            buttonStates: states
        )
    }

    func reset() {
        snapshot = .empty
    }

    var reportBytes: [UInt8] { snapshot.sample?.reportBytes ?? [] }
    var reportLength: Int { snapshot.sample?.reportLength ?? 0 }

    var rawGyroX: Int16 { snapshot.sample?.rawGyro.x ?? 0 }
    var rawGyroY: Int16 { snapshot.sample?.rawGyro.y ?? 0 }
    var rawGyroZ: Int16 { snapshot.sample?.rawGyro.z ?? 0 }

    var remappedPitch: Int16 { snapshot.sample?.remappedGyro.pitch ?? 0 }
    var remappedYaw: Int16 { snapshot.sample?.remappedGyro.yaw ?? 0 }
    var remappedRoll: Int16 { snapshot.sample?.remappedGyro.roll ?? 0 }

    var normalizedPitch: Double { snapshot.sample?.normalizedGyro.pitch ?? 0 }
    var normalizedYaw: Double { snapshot.sample?.normalizedGyro.yaw ?? 0 }
    var normalizedRoll: Double { snapshot.sample?.normalizedGyro.roll ?? 0 }

    var accelX: Int16 { snapshot.sample?.accel.x ?? 0 }
    var accelY: Int16 { snapshot.sample?.accel.y ?? 0 }
    var accelZ: Int16 { snapshot.sample?.accel.z ?? 0 }

    var gyroDebug: DebugBuffer.GyroDebug? { snapshot.sample?.gyroDebug }
    var buttonStates: [LogicalButton: Bool] { snapshot.buttonStates }

    var byteLastChanged: [Date] { snapshot.byteLastChanged }
    var bitLastChanged: [[Date]] { snapshot.bitLastChanged }

    var stats: DebugBuffer.Stats { snapshot.stats }

    func safeReportByte(_ index: Int) -> UInt8 {
        let bytes = reportBytes
        guard index >= 0 && index < bytes.count else { return 0 }
        return bytes[index]
    }
}
