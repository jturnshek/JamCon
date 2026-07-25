import CoreHID
import Foundation
import os

enum VirtualGamepadOutputError: LocalizedError, Equatable {
    case unsupportedOperatingSystem
    case virtualDeviceCreationFailed

    var errorDescription: String? {
        switch self {
        case .unsupportedOperatingSystem:
            return "Virtual gamepads require macOS 15 or later."
        case .virtualDeviceCreationFailed:
            return "macOS refused to create the virtual gamepad. Verify the signed Virtual HID entitlement."
        }
    }
}

protocol VirtualGamepadReportSink: Sendable {
    func activate() async throws
    func send(_ report: VirtualGamepadHIDReport) async throws
    func deactivate() async
}

struct VirtualGamepadReportSinkFactory: Sendable {
    let make: @Sendable () async throws -> any VirtualGamepadReportSink

    static let live = VirtualGamepadReportSinkFactory {
        guard #available(macOS 15, *) else {
            throw VirtualGamepadOutputError.unsupportedOperatingSystem
        }
        return CoreHIDVirtualGamepadSink()
    }
}

enum VirtualGamepadOutputStatus: Equatable, Sendable {
    case inactive
    case activating
    case active
    case failed(String)
}

/// Low-latency asynchronous output pump. InputEngine assigns monotonically
/// increasing sequence numbers, so reports remain ordered even if Swift tasks
/// reach this actor out of order. Analog-only updates coalesce while CoreHID is
/// dispatching, but digital transitions retain ordered checkpoints.
final class VirtualGamepadOutputCoordinator: @unchecked Sendable {
    private let worker: Worker
    private let lifecycleGeneration = OSAllocatedUnfairLock(initialState: UInt64(0))

    init(factory: VirtualGamepadReportSinkFactory = .live) {
        worker = Worker(factory: factory)
    }

    func setStatusHandler(
        _ handler: @escaping @Sendable (VirtualGamepadOutputStatus) -> Void
    ) {
        Task {
            await worker.setStatusHandler(handler)
        }
    }

    func activate() {
        let generation = lifecycleGeneration.withLock { value in
            value &+= 1
            return value
        }
        Task {
            await worker.activate(generation: generation)
        }
    }

    func submit(_ report: VirtualGamepadHIDReport, sequence: UInt64) {
        let generation = lifecycleGeneration.withLock { $0 }
        Task {
            await worker.submit(report, sequence: sequence, generation: generation)
        }
    }

    func deactivate() {
        let generation = lifecycleGeneration.withLock { value in
            value &+= 1
            return value
        }
        Task {
            await worker.deactivate(generation: generation)
        }
    }

    private actor Worker {
        private struct PendingReport {
            let report: VirtualGamepadHIDReport
            let sequence: UInt64
            let generation: UInt64
        }

        private enum Phase {
            case inactive
            case activating
            case active
            case failed
        }

        private let factory: VirtualGamepadReportSinkFactory
        private let maximumPendingTransitions = 32
        private var statusHandler: @Sendable (VirtualGamepadOutputStatus) -> Void = { _ in }
        private var phase: Phase = .inactive
        private var requestedActive = false
        private var generation: UInt64 = 0
        private var sink: (any VirtualGamepadReportSink)?
        private var pendingReports: [PendingReport] = []
        private var lastDigitalSignatures: [UInt64: UInt64] = [:]
        private var lastAcceptedSequence: UInt64 = 0
        private var dispatchingGeneration: UInt64?

        init(factory: VirtualGamepadReportSinkFactory) {
            self.factory = factory
        }

        func setStatusHandler(
            _ handler: @escaping @Sendable (VirtualGamepadOutputStatus) -> Void
        ) {
            statusHandler = handler
            handler(status)
        }

        func activate(generation requestedGeneration: UInt64) async {
            guard requestedGeneration >= generation else { return }

            if requestedGeneration > generation {
                generation = requestedGeneration
                requestedActive = true
                let previousSink = sink
                sink = nil
                phase = .inactive
                if let dispatchingGeneration,
                   dispatchingGeneration < requestedGeneration {
                    self.dispatchingGeneration = nil
                }
                pendingReports.removeAll { $0.generation < requestedGeneration }
                lastDigitalSignatures = lastDigitalSignatures.filter {
                    $0.key >= requestedGeneration
                }
                if let previousSink {
                    await previousSink.deactivate()
                }
                guard generation == requestedGeneration else { return }
            }

            requestedActive = true
            guard phase == .inactive || phase == .failed else { return }

            let activationGeneration = requestedGeneration
            phase = .activating
            statusHandler(.activating)

            do {
                let createdSink = try await factory.make()
                try await createdSink.activate()

                guard requestedActive, generation == activationGeneration else {
                    await createdSink.deactivate()
                    return
                }

                sink = createdSink
                phase = .active
                statusHandler(.active)
                startDrainIfNeeded(generation: activationGeneration)
            } catch {
                guard generation == activationGeneration else { return }
                sink = nil
                phase = .failed
                requestedActive = false
                pendingReports.removeAll { $0.generation <= activationGeneration }
                lastDigitalSignatures.removeValue(forKey: activationGeneration)
                statusHandler(.failed(error.localizedDescription))
            }
        }

        func submit(
            _ report: VirtualGamepadHIDReport,
            sequence: UInt64,
            generation reportGeneration: UInt64
        ) {
            guard sequence > lastAcceptedSequence else { return }
            lastAcceptedSequence = sequence
            guard reportGeneration >= generation else { return }
            let next = PendingReport(
                report: report,
                sequence: sequence,
                generation: reportGeneration
            )
            let signature = report.digitalSignature
            let digitalChanged = lastDigitalSignatures[reportGeneration] != signature
            lastDigitalSignatures[reportGeneration] = signature

            if !digitalChanged,
               let replaceIndex = pendingReports.lastIndex(where: {
                   $0.generation == reportGeneration
               }) {
                pendingReports[replaceIndex] = next
            } else {
                pendingReports.append(next)
                trimPendingTransitions(for: reportGeneration)
            }
            guard phase == .active, reportGeneration == generation else { return }
            startDrainIfNeeded(generation: reportGeneration)
        }

        func deactivate(generation requestedGeneration: UInt64) async {
            guard requestedGeneration >= generation else { return }
            requestedActive = false
            generation = requestedGeneration
            pendingReports.removeAll { $0.generation <= requestedGeneration }
            lastDigitalSignatures = lastDigitalSignatures.filter {
                $0.key > requestedGeneration
            }
            if let dispatchingGeneration,
               dispatchingGeneration <= requestedGeneration {
                self.dispatchingGeneration = nil
            }

            let activeSink = sink
            sink = nil
            phase = .inactive
            statusHandler(.inactive)
            if let activeSink {
                await activeSink.deactivate()
            }
        }

        private var status: VirtualGamepadOutputStatus {
            switch phase {
            case .inactive: return .inactive
            case .activating: return .activating
            case .active: return .active
            case .failed: return .failed("Virtual gamepad output failed.")
            }
        }

        private func startDrainIfNeeded(generation: UInt64) {
            guard dispatchingGeneration == nil,
                  pendingReports.contains(where: { $0.generation == generation }) else {
                return
            }
            dispatchingGeneration = generation
            Task {
                await drain(generation: generation)
            }
        }

        private func drain(generation drainGeneration: UInt64) async {
            while phase == .active,
                  generation == drainGeneration,
                  let activeSink = sink,
                  let nextIndex = pendingReports.firstIndex(where: {
                      $0.generation == drainGeneration
                  }) {
                let next = pendingReports.remove(at: nextIndex)
                do {
                    try await activeSink.send(next.report)
                } catch {
                    guard generation == drainGeneration else { return }
                    sink = nil
                    pendingReports.removeAll { $0.generation == drainGeneration }
                    lastDigitalSignatures.removeValue(forKey: drainGeneration)
                    phase = .failed
                    requestedActive = false
                    if dispatchingGeneration == drainGeneration {
                        dispatchingGeneration = nil
                    }
                    statusHandler(.failed(error.localizedDescription))
                    await activeSink.deactivate()
                    return
                }
            }

            guard dispatchingGeneration == drainGeneration else { return }
            dispatchingGeneration = nil
            if phase == .active,
               generation == drainGeneration,
               pendingReports.contains(where: { $0.generation == drainGeneration }) {
                startDrainIfNeeded(generation: drainGeneration)
            }
        }

        private func trimPendingTransitions(for reportGeneration: UInt64) {
            let indices = pendingReports.indices.filter {
                pendingReports[$0].generation == reportGeneration
            }
            let overflow = indices.count - maximumPendingTransitions
            guard overflow > 0 else { return }
            for index in indices.prefix(overflow).reversed() {
                pendingReports.remove(at: index)
            }
        }
    }
}

@available(macOS 15, *)
private actor CoreHIDVirtualGamepadSink: VirtualGamepadReportSink {
    private let delegate = CoreHIDVirtualGamepadDelegate()
    private var device: HIDVirtualDevice?

    func activate() async throws {
        guard device == nil else { return }
        let properties = HIDVirtualDevice.Properties(
            descriptor: VirtualGamepadHIDDescriptor.bytes,
            vendorID: VirtualGamepadHIDDescriptor.vendorID,
            productID: VirtualGamepadHIDDescriptor.productID,
            transport: .virtual,
            product: "JamCon Linked Joy-Cons",
            manufacturer: "JamCon",
            modelNumber: "LinkedGamepad-1",
            versionNumber: 1,
            serialNumber: "jamcon-linked-gamepad-1",
            uniqueID: "com.jamcon.virtual-gamepad.linked-primary"
        )
        guard let createdDevice = HIDVirtualDevice(properties: properties) else {
            throw VirtualGamepadOutputError.virtualDeviceCreationFailed
        }
        await createdDevice.activate(delegate: delegate)
        device = createdDevice
    }

    func send(_ report: VirtualGamepadHIDReport) async throws {
        guard let device else {
            throw VirtualGamepadOutputError.virtualDeviceCreationFailed
        }
        try await device.dispatchInputReport(
            data: report.data,
            timestamp: SuspendingClock.now
        )
    }

    func deactivate() async {
        guard let activeDevice = device else { return }
        try? await activeDevice.dispatchInputReport(
            data: VirtualGamepadHIDReport(state: VirtualGamepadState()).data,
            timestamp: SuspendingClock.now
        )
        device = nil
    }
}

@available(macOS 15, *)
private final class CoreHIDVirtualGamepadDelegate: HIDVirtualDeviceDelegate, @unchecked Sendable {
    func hidVirtualDevice(
        _ device: HIDVirtualDevice,
        receivedSetReportRequestOfType type: HIDReportType,
        id: HIDReportID?,
        data: Data
    ) async throws {}

    func hidVirtualDevice(
        _ device: HIDVirtualDevice,
        receivedGetReportRequestOfType type: HIDReportType,
        id: HIDReportID?,
        maxSize: Int
    ) async throws -> Data {
        Data()
    }
}
