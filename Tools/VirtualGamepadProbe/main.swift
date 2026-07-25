import CoreHID
import Foundation

private enum ProbeError: LocalizedError {
    case virtualDeviceCreationFailed
    case unsupportedOperatingSystem
    case insufficientReportRate(Double)

    var errorDescription: String? {
        switch self {
        case .virtualDeviceCreationFailed:
            "CoreHID refused to create the virtual gamepad. Verify the signed entitlement."
        case .unsupportedOperatingSystem:
            "The virtual gamepad probe requires macOS 15 or later."
        case let .insufficientReportRate(rate):
            "The virtual gamepad probe emitted only \(String(format: "%.1f", rate)) reports/s."
        }
    }
}

@available(macOS 15, *)
private final class ProbeDelegate: HIDVirtualDeviceDelegate, @unchecked Sendable {
    func hidVirtualDevice(
        _ device: HIDVirtualDevice,
        receivedSetReportRequestOfType type: HIDReportType,
        id: HIDReportID?,
        data: Data
    ) async throws {
        print("set-report type=\(type) id=\(String(describing: id)) bytes=\(data.count)")
    }

    func hidVirtualDevice(
        _ device: HIDVirtualDevice,
        receivedGetReportRequestOfType type: HIDReportType,
        id: HIDReportID?,
        maxSize: Int
    ) async throws -> Data {
        print("get-report type=\(type) id=\(String(describing: id)) maxSize=\(maxSize)")
        return Data()
    }
}

@main
private enum VirtualGamepadProbe {
    static func main() async {
        do {
            guard #available(macOS 15, *) else {
                throw ProbeError.unsupportedOperatingSystem
            }
            try await runProbe()
        } catch {
            FileHandle.standardError.write(Data("VirtualGamepadProbe: \(error.localizedDescription)\n".utf8))
            Foundation.exit(EXIT_FAILURE)
        }
    }

    @available(macOS 15, *)
    private static func runProbe() async throws {
        let properties = HIDVirtualDevice.Properties(
            descriptor: VirtualGamepadHIDDescriptor.bytes,
            vendorID: VirtualGamepadHIDDescriptor.vendorID,
            productID: VirtualGamepadHIDDescriptor.productID,
            transport: .virtual,
            product: "JamCon Virtual Gamepad Probe",
            manufacturer: "JamCon",
            modelNumber: "Probe-1",
            versionNumber: 1,
            serialNumber: "jamcon-probe-1",
            uniqueID: "com.jamcon.virtual-gamepad.probe"
        )
        guard let device = HIDVirtualDevice(properties: properties) else {
            throw ProbeError.virtualDeviceCreationFailed
        }

        let delegate = ProbeDelegate()
        await device.activate(delegate: delegate)
        try await Task.sleep(for: .milliseconds(250))

        let durationSeconds = CommandLine.arguments.dropFirst().first
            .flatMap(Double.init) ?? 60
        let clock = ContinuousClock()
        let start = clock.now
        let reportInterval = Duration.milliseconds(8)
        var nextReportDeadline = start
        var nextSummary = start.advanced(by: .seconds(1))
        var frame = 0
        var dispatchCount = 0
        var totalDispatchNanoseconds: UInt64 = 0
        var maximumDispatchNanoseconds: UInt64 = 0
        var lastPhase = -1

        print(
            "ready product=\"JamCon Virtual Gamepad Probe\" "
                + "vid=0x\(String(VirtualGamepadHIDDescriptor.vendorID, radix: 16)) "
                + "pid=0x\(String(VirtualGamepadHIDDescriptor.productID, radix: 16)) "
                + "reportBytes=\(VirtualGamepadHIDDescriptor.reportLength)"
        )

        while start.duration(to: clock.now) < .seconds(durationSeconds) {
            let phase = (frame / 63) % 8
            if phase != lastPhase {
                lastPhase = phase
                print("phase=\(phase) expected=\"\(phaseDescription(phase))\"")
            }
            let report = VirtualGamepadHIDReport(state: state(for: phase))

            let dispatchStarted = DispatchTime.now().uptimeNanoseconds
            try await device.dispatchInputReport(
                data: report.data,
                timestamp: SuspendingClock.now
            )
            let dispatchNanoseconds = DispatchTime.now().uptimeNanoseconds - dispatchStarted
            dispatchCount += 1
            totalDispatchNanoseconds += dispatchNanoseconds
            maximumDispatchNanoseconds = max(maximumDispatchNanoseconds, dispatchNanoseconds)

            frame += 1
            if clock.now >= nextSummary {
                let averageMicroseconds = Double(totalDispatchNanoseconds)
                    / Double(max(dispatchCount, 1)) / 1_000
                let maximumMicroseconds = Double(maximumDispatchNanoseconds) / 1_000
                let elapsedSeconds = max(
                    0.001,
                    Self.seconds(start.duration(to: clock.now))
                )
                print(
                    "frames=\(dispatchCount) rate="
                        + "\(String(format: "%.1f", Double(dispatchCount) / elapsedSeconds))/s "
                        + "dispatch.avg=\(String(format: "%.2f", averageMicroseconds))us "
                        + "dispatch.max=\(String(format: "%.2f", maximumMicroseconds))us"
                )
                nextSummary = nextSummary.advanced(by: .seconds(1))
            }
            nextReportDeadline = nextReportDeadline.advanced(by: reportInterval)
            if clock.now < nextReportDeadline {
                try await clock.sleep(until: nextReportDeadline)
            }
        }

        try await device.dispatchInputReport(
            data: VirtualGamepadHIDReport(state: VirtualGamepadState()).data,
            timestamp: SuspendingClock.now
        )
        let elapsedSeconds = max(0.001, Self.seconds(start.duration(to: clock.now)))
        let achievedRate = Double(dispatchCount) / elapsedSeconds
        print(
            "complete frames=\(dispatchCount) "
                + "rate=\(String(format: "%.1f", achievedRate))/s"
        )
        guard achievedRate >= 110 else {
            throw ProbeError.insufficientReportRate(achievedRate)
        }
        _ = delegate
    }

    private static func seconds(_ duration: Duration) -> Double {
        let components = duration.components
        return Double(components.seconds)
            + Double(components.attoseconds) / 1_000_000_000_000_000_000
    }

    private static func state(for phase: Int) -> VirtualGamepadState {
        switch phase {
        case 0:
            return VirtualGamepadState()
        case 1:
            return VirtualGamepadState(
                buttons: [.button(.south)],
                leftX: .max,
                leftY: -.max
            )
        case 2:
            return VirtualGamepadState(
                buttons: [.button(.east)],
                leftX: -.max,
                leftY: .max
            )
        case 3:
            return VirtualGamepadState(
                buttons: [.button(.west), .button(.leftShoulder)],
                rightX: .max,
                rightY: -.max
            )
        case 4:
            return VirtualGamepadState(
                buttons: [.button(.north), .button(.rightShoulder)],
                rightX: -.max,
                rightY: .max
            )
        case 5:
            return VirtualGamepadState(
                buttons: [.button(.leftStick), .button(.rightStick)],
                hat: .northEast,
                leftTrigger: .max,
                rightTrigger: .max
            )
        case 6:
            return VirtualGamepadState(
                buttons: [.button(.select), .button(.start), .button(.home)],
                hat: .southWest
            )
        default:
            return VirtualGamepadState()
        }
    }

    private static func phaseDescription(_ phase: Int) -> String {
        switch phase {
        case 0: "neutral"
        case 1: "A + left stick right/up in Game Controller"
        case 2: "B + left stick left/down in Game Controller"
        case 3: "X + L1 + right stick right/up in Game Controller"
        case 4: "Y + R1 + right stick left/down in Game Controller"
        case 5: "L3 + R3 + northeast D-pad + both triggers"
        case 6: "Options + Menu + Home + southwest D-pad"
        default: "neutral"
        }
    }
}
