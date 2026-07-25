import CoreHID
import Foundation

private enum ProbeError: LocalizedError {
    case virtualDeviceCreationFailed
    case unsupportedOperatingSystem

    var errorDescription: String? {
        switch self {
        case .virtualDeviceCreationFailed:
            "CoreHID refused to create the virtual gamepad. Verify the signed entitlement."
        case .unsupportedOperatingSystem:
            "The virtual gamepad probe requires macOS 15 or later."
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
        let start = ContinuousClock.now
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

        while start.duration(to: .now) < .seconds(durationSeconds) {
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
            if ContinuousClock.now >= nextSummary {
                let averageMicroseconds = Double(totalDispatchNanoseconds)
                    / Double(max(dispatchCount, 1)) / 1_000
                let maximumMicroseconds = Double(maximumDispatchNanoseconds) / 1_000
                print(
                    "frames=\(dispatchCount) dispatch.avg=\(String(format: "%.2f", averageMicroseconds))us "
                        + "dispatch.max=\(String(format: "%.2f", maximumMicroseconds))us"
                )
                nextSummary = nextSummary.advanced(by: .seconds(1))
            }
            try await Task.sleep(for: .milliseconds(8))
        }

        try await device.dispatchInputReport(
            data: VirtualGamepadHIDReport(state: VirtualGamepadState()).data,
            timestamp: SuspendingClock.now
        )
        print("complete frames=\(dispatchCount)")
        _ = delegate
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
        case 1: "south + left stick right/down in raw HID"
        case 2: "east + left stick left/up in raw HID"
        case 3: "west + L1 + right stick right/down in raw HID"
        case 4: "north + R1 + right stick left/up in raw HID"
        case 5: "stick clicks + northeast D-pad + triggers"
        case 6: "select + start + home + southwest D-pad"
        default: "neutral"
        }
    }
}
