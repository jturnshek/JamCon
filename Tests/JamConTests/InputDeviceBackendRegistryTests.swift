import XCTest
@testable import JamCon

final class InputDeviceBackendRegistryTests: XCTestCase {
    func testRegistryAggregatesDevicesAndRoutesManagementByKind() {
        let senseDevice = ControllerInfo(
            id: "sense-1",
            name: "Sense Right",
            productID: SenseHIDProtocol.rightProductID,
            kind: .sense,
            handedness: .right
        )
        let joyConDevice = ControllerInfo(
            id: "joycon-1",
            name: "Joy-Con Right",
            productID: JoyConHIDProtocol.rightProductID,
            kind: .joyCon,
            handedness: .right
        )
        let sense = FakeInputDeviceBackend(
            descriptor: descriptor(id: "test.sense", kind: .sense),
            devices: [senseDevice]
        )
        let joyCon = FakeInputDeviceBackend(
            descriptor: descriptor(id: "test.joycon", kind: .joyCon),
            devices: [joyConDevice]
        )
        let registry = InputDeviceBackendRegistry(backends: [sense, joyCon])

        XCTAssertEqual(registry.availableDevicesSnapshot(), [senseDevice, joyConDevice])
        XCTAssertTrue(registry.setDeviceManaged(id: "joycon-1", kind: .joyCon, managed: true))
        XCTAssertEqual(joyCon.managedCallsSnapshot(), [ManagedCall(id: "joycon-1", managed: true)])
        XCTAssertTrue(sense.managedCallsSnapshot().isEmpty)
        XCTAssertFalse(registry.setDeviceManaged(id: "missing", kind: .mouse, managed: true))
        XCTAssertTrue(registry.backend(id: sense.backendDescriptor.id) === sense)
        XCTAssertTrue(registry.backend(for: .joyCon) === joyCon)
    }

    func testRegistryRoutesTwoBackendsForTheSameFamilyByStableDeviceID() {
        let firstDevice = ControllerInfo(
            id: "joycon-hid",
            name: "Joy-Con (L)",
            productID: JoyConHIDProtocol.leftProductID,
            kind: .joyCon,
            handedness: .left
        )
        let secondDevice = ControllerInfo(
            id: "joycon2-ble",
            name: "Joy-Con 2 (R)",
            productID: Int(JoyCon2BLEProtocol.rightProductID),
            kind: .joyCon,
            handedness: .right
        )
        let first = FakeInputDeviceBackend(
            descriptor: descriptor(id: "test.joycon.hid", kind: .joyCon),
            devices: [firstDevice]
        )
        let second = FakeInputDeviceBackend(
            descriptor: descriptor(id: "test.joycon2.ble", kind: .joyCon),
            devices: [secondDevice]
        )
        let registry = InputDeviceBackendRegistry(backends: [first, second])

        XCTAssertEqual(registry.availableDevicesSnapshot(), [firstDevice, secondDevice])
        XCTAssertTrue(registry.setDeviceManaged(id: secondDevice.id, kind: .joyCon, managed: true))
        XCTAssertTrue(first.managedCallsSnapshot().isEmpty)
        XCTAssertEqual(second.managedCallsSnapshot(), [ManagedCall(id: secondDevice.id, managed: true)])

        XCTAssertTrue(registry.setDeviceManaged(id: secondDevice.id, kind: .joyCon, managed: false))
        XCTAssertEqual(second.managedCallsSnapshot(), [
            ManagedCall(id: secondDevice.id, managed: true),
            ManagedCall(id: secondDevice.id, managed: false),
        ])
    }

    func testRegistryFiltersInvalidDiscoveredDeviceMetadata() {
        let valid = ControllerInfo(
            id: "joycon-1",
            name: "Joy-Con Right",
            productID: JoyConHIDProtocol.rightProductID,
            kind: .joyCon,
            handedness: .right
        )
        let backend = FakeInputDeviceBackend(
            descriptor: descriptor(id: "test.joycon", kind: .joyCon),
            devices: [
                valid,
                ControllerInfo(
                    id: "",
                    name: "No Identity",
                    productID: 1,
                    kind: .joyCon,
                    handedness: .left
                ),
                ControllerInfo(
                    id: "wrong-kind",
                    name: "Wrong Kind",
                    productID: 2,
                    kind: .mouse,
                    handedness: .none
                ),
                ControllerInfo(
                    id: "missing-side",
                    name: "Missing Side",
                    productID: 3,
                    kind: .joyCon,
                    handedness: .none
                ),
                valid,
            ]
        )
        let registry = InputDeviceBackendRegistry(backends: [backend])

        XCTAssertEqual(registry.availableDevicesSnapshot(), [valid])
    }

    func testRegistryStartsAndStopsBackendsInRegistrationOrder() {
        let events = LockedBackendValue<[String]>([])
        let sense = FakeInputDeviceBackend(
            descriptor: descriptor(id: "test.sense", kind: .sense),
            startResult: true,
            sharedEvents: events
        )
        let mouse = FakeInputDeviceBackend(
            descriptor: descriptor(id: "test.mouse", kind: .mouse),
            startResult: false,
            sharedEvents: events
        )
        let registry = InputDeviceBackendRegistry(backends: [sense, mouse])

        let results = registry.startAll()
        registry.stopAll()

        XCTAssertEqual(results, [
            InputDeviceBackendStartResult(backend: sense.backendDescriptor, started: true),
            InputDeviceBackendStartResult(backend: mouse.backendDescriptor, started: false),
        ])
        XCTAssertEqual(events.snapshot(), [
            "start:test.sense",
            "start:test.mouse",
            "stop:test.sense",
            "stop:test.mouse",
        ])
    }

    func testRegistryEnrichesLifecycleCallbacksWithBackendDescriptor() {
        let backend = FakeInputDeviceBackend(
            descriptor: descriptor(id: "test.joycon", kind: .joyCon)
        )
        let harness = InputDeviceBackendContractHarness(backend: backend)
        XCTAssertTrue(harness.start())

        backend.emitDevicesChanged()
        backend.emitConnection(connected: true, name: "Joy-Con", id: "joycon-1")
        let frame = InputDeviceFrame(
            backend: backend.backendDescriptor,
            deviceID: "joycon-1",
            reportID: JoyConHIDProtocol.inputReportID,
            bytes: [0x30],
            motion: .none,
            timestamp: 10,
            receivedTimestamp: 10,
            inputTimestamp: nil,
            timestampSource: .hostReceipt
        )
        backend.emitInputFrame(frame)

        XCTAssertEqual(harness.changedBackendsSnapshot(), [backend.backendDescriptor])
        XCTAssertEqual(harness.connectionEventsSnapshot(), [
            InputDeviceBackendConnectionEvent(
                backend: backend.backendDescriptor,
                connected: true,
                deviceName: "Joy-Con",
                deviceID: "joycon-1"
            ),
        ])
        XCTAssertEqual(harness.inputFramesSnapshot(), [frame])
        harness.stop()
    }

    func testRegistryConnectionStateIsAggregate() {
        let sense = FakeInputDeviceBackend(
            descriptor: descriptor(id: "test.sense", kind: .sense)
        )
        let mouse = FakeInputDeviceBackend(
            descriptor: descriptor(id: "test.mouse", kind: .mouse)
        )
        let registry = InputDeviceBackendRegistry(backends: [sense, mouse])

        XCTAssertFalse(registry.isConnected)
        mouse.setConnected(true)
        XCTAssertTrue(registry.isConnected)
        mouse.setConnected(false)
        XCTAssertFalse(registry.isConnected)
    }

    func testRegistryRejectsFrameWhoseDescriptorDoesNotMatchItsBackend() {
        let backend = FakeInputDeviceBackend(
            descriptor: descriptor(id: "test.joycon", kind: .joyCon)
        )
        let harness = InputDeviceBackendContractHarness(backend: backend)
        XCTAssertTrue(harness.start())

        backend.emitInputFrame(InputDeviceFrame(
            backend: descriptor(id: "other.joycon", kind: .joyCon),
            deviceID: "joycon-1",
            reportID: JoyConHIDProtocol.inputReportID,
            bytes: [0x30],
            motion: .none,
            timestamp: 10,
            receivedTimestamp: 10,
            inputTimestamp: nil,
            timestampSource: .hostReceipt
        ))

        XCTAssertTrue(harness.inputFramesSnapshot().isEmpty)
        harness.stop()
    }

    func testRegistryRejectsEveryCommonFrameContractViolation() {
        let backend = FakeInputDeviceBackend(
            descriptor: descriptor(id: "test.joycon", kind: .joyCon)
        )
        let harness = InputDeviceBackendContractHarness(backend: backend)
        XCTAssertTrue(harness.start())

        let valid = frame(backend: backend.backendDescriptor)
        let invalidFrames = [
            frame(backend: backend.backendDescriptor, deviceID: ""),
            frame(backend: backend.backendDescriptor, timestamp: .nan),
            frame(backend: backend.backendDescriptor, receivedTimestamp: .infinity),
            frame(backend: backend.backendDescriptor, inputTimestamp: -.infinity),
            frame(backend: backend.backendDescriptor, gyroScale: .nan),
            frame(backend: backend.backendDescriptor, gyroScale: 0),
            frame(backend: backend.backendDescriptor, motionSampleRate: .infinity),
            frame(backend: backend.backendDescriptor, motionSampleRate: 0),
            frame(backend: backend.backendDescriptor, motion: .batch([])),
            frame(
                backend: backend.backendDescriptor,
                motion: .single(IMUSample(
                    accelX: 0,
                    accelY: 0,
                    accelZ: 0,
                    gyroX: 0,
                    gyroY: 0,
                    gyroZ: 0
                ))
            ),
        ]

        invalidFrames.forEach(backend.emitInputFrame)
        backend.emitInputFrame(valid)

        XCTAssertEqual(harness.inputFramesSnapshot(), [valid])
        harness.stop()
    }

    func testRegistryAcceptsMotionWhenBackendDeclaresCapability() {
        let descriptor = InputDeviceBackendDescriptor(
            id: InputDeviceBackendID(rawValue: "test.motion"),
            kind: .sense,
            displayName: "Motion Test",
            capabilities: [.motion]
        )
        let backend = FakeInputDeviceBackend(descriptor: descriptor)
        let harness = InputDeviceBackendContractHarness(backend: backend)
        XCTAssertTrue(harness.start())
        let motionFrame = frame(
            backend: descriptor,
            motion: .single(IMUSample(
                accelX: 1,
                accelY: 2,
                accelZ: 3,
                gyroX: 4,
                gyroY: 5,
                gyroZ: 6
            ))
        )

        backend.emitInputFrame(motionFrame)

        XCTAssertEqual(harness.inputFramesSnapshot(), [motionFrame])
        harness.stop()
    }

    func testRegistrySuppressesCallbacksBeforeStartAndAfterStop() {
        let backend = FakeInputDeviceBackend(
            descriptor: descriptor(id: "test.joycon", kind: .joyCon)
        )
        let harness = InputDeviceBackendContractHarness(backend: backend)
        let validFrame = frame(backend: backend.backendDescriptor)

        backend.emitDevicesChanged()
        backend.emitConnection(connected: true, name: "Joy-Con", id: "joycon-1")
        backend.emitInputFrame(validFrame)
        XCTAssertTrue(harness.changedBackendsSnapshot().isEmpty)
        XCTAssertTrue(harness.connectionEventsSnapshot().isEmpty)
        XCTAssertTrue(harness.inputFramesSnapshot().isEmpty)

        XCTAssertTrue(harness.start())
        backend.emitDevicesChanged()
        backend.emitConnection(connected: true, name: "Joy-Con", id: "joycon-1")
        backend.emitInputFrame(validFrame)
        XCTAssertEqual(harness.changedBackendsSnapshot().count, 1)
        XCTAssertEqual(harness.connectionEventsSnapshot().count, 1)
        XCTAssertEqual(harness.inputFramesSnapshot(), [validFrame])

        harness.stop()
        backend.emitDevicesChanged()
        backend.emitConnection(connected: false, name: "Joy-Con", id: "joycon-1")
        backend.emitInputFrame(validFrame)
        XCTAssertEqual(harness.changedBackendsSnapshot().count, 1)
        XCTAssertEqual(harness.connectionEventsSnapshot().count, 1)
        XCTAssertEqual(harness.inputFramesSnapshot(), [validFrame])
    }

    func testFailedBackendCannotEmitWhileAnotherBackendIsRunning() {
        let failed = FakeInputDeviceBackend(
            descriptor: descriptor(id: "test.failed", kind: .joyCon),
            startResult: false
        )
        let running = FakeInputDeviceBackend(
            descriptor: descriptor(id: "test.running", kind: .sense)
        )
        let registry = InputDeviceBackendRegistry(backends: [failed, running])
        let receivedFrames = LockedBackendValue<[InputDeviceFrame]>([])
        registry.setEventHandlers(
            devicesChanged: { _ in },
            connectionChanged: { _ in },
            inputFrame: { frame in receivedFrames.update { $0.append(frame) } }
        )
        let results = registry.startAll()
        let failedFrame = frame(backend: failed.backendDescriptor)
        let runningFrame = frame(backend: running.backendDescriptor)

        failed.emitInputFrame(failedFrame)
        running.emitInputFrame(runningFrame)

        XCTAssertEqual(results.map(\.started), [false, true])
        XCTAssertEqual(receivedFrames.snapshot(), [runningFrame])
        registry.stopAll()
    }

    func testControllerInfoUsesBackendSuppliedHandedness() {
        let info = ControllerInfo(
            id: "future-device",
            name: "Future Device",
            productID: 0,
            kind: .sense,
            handedness: .left
        )

        XCTAssertTrue(info.isLeft)
        XCTAssertEqual(info.side, "Left")
    }

    private func descriptor(
        id: String,
        kind: ControllerKind
    ) -> InputDeviceBackendDescriptor {
        InputDeviceBackendDescriptor(
            id: InputDeviceBackendID(rawValue: id),
            kind: kind,
            displayName: id
        )
    }

    private func frame(
        backend: InputDeviceBackendDescriptor,
        deviceID: String = "device-1",
        motion: InputDeviceMotionSamples = .none,
        timestamp: TimeInterval = 10,
        receivedTimestamp: TimeInterval = 10,
        inputTimestamp: TimeInterval? = nil,
        gyroScale: Double? = nil,
        motionSampleRate: Double? = nil
    ) -> InputDeviceFrame {
        InputDeviceFrame(
            backend: backend,
            deviceID: deviceID,
            reportID: 1,
            bytes: [1],
            motion: motion,
            timestamp: timestamp,
            receivedTimestamp: receivedTimestamp,
            inputTimestamp: inputTimestamp,
            timestampSource: .hostReceipt,
            gyroScale: gyroScale,
            motionSampleRate: motionSampleRate
        )
    }
}
