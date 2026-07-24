import XCTest
@testable import JamCon

final class JoyCon2BLEInputDeviceBackendTests: XCTestCase {
    func testJoyCon2UsesIndependentProfileAndExposesCButtonOnRightOnly() throws {
        let profile = ControllerProfile.joyCon2Right

        XCTAssertEqual(profile.displayName, "Joy-Con 2 Right")
        XCTAssertEqual(profile.persistenceKey, "joyCon2.right")
        XCTAssertNotEqual(profile.persistenceKey, ControllerProfile.joyConRight.persistenceKey)
        XCTAssertTrue(JoyConLogicalButton.availableButtons(for: profile).contains(.c))
        XCTAssertFalse(JoyConLogicalButton.availableButtons(for: .joyCon2Left).contains(.c))

        var report = [UInt8](repeating: 0, count: 0x3F)
        report[5] = 1 << 6
        let controls = try XCTUnwrap(JoyCon2BLEProtocol.controlBytes(from: report))
        XCTAssertTrue(JoyConButtonMapping(isLeft: false).isPressed(.c, in: controls))
    }

    func testLegacyEncodedProfileDefaultsToStandardVariant() throws {
        let data = try XCTUnwrap("{\"kind\":\"joyCon\",\"isLeft\":false}".data(using: .utf8))
        let profile = try JSONDecoder().decode(ControllerProfile.self, from: data)

        XCTAssertEqual(profile, .joyConRight)
        XCTAssertEqual(profile.persistenceKey, "joyCon.right")
    }

    func testJoyCon2VariantCannotLeakIntoAnotherControllerFamily() throws {
        let constructed = ControllerProfile(
            kind: .sense,
            isLeft: false,
            variant: .joyCon2
        )
        let data = try XCTUnwrap(
            "{\"kind\":\"sense\",\"isLeft\":false,\"variant\":\"joyCon2\"}"
                .data(using: .utf8)
        )
        let decoded = try JSONDecoder().decode(ControllerProfile.self, from: data)
        let deviceInfo = ControllerInfo(
            id: "sense",
            name: "Sense",
            productID: 0,
            kind: .sense,
            handedness: .right,
            profileVariant: .joyCon2
        )

        XCTAssertEqual(constructed, .senseRight)
        XCTAssertEqual(decoded, .senseRight)
        XCTAssertEqual(deviceInfo.profileVariant, .standard)
    }

    func testJoyCon2RightUsesMeasuredGripAxesWithoutChangingOriginalJoyCon() {
        let original = GyroRemapper.remap(
            rawX: 100,
            rawY: 200,
            rawZ: 300,
            controllerKind: .joyCon,
            isLeft: false
        )
        let joyCon2 = GyroRemapper.remap(
            rawX: 100,
            rawY: 200,
            rawZ: 300,
            controllerKind: .joyCon,
            isLeft: false,
            profileVariant: .joyCon2
        )

        XCTAssertEqual(original.pitch, 200)
        XCTAssertEqual(original.yaw, -300)
        XCTAssertEqual(joyCon2.pitch, 100)
        XCTAssertEqual(joyCon2.yaw, 300)
        XCTAssertEqual(joyCon2.roll, 200)

        let pipeline = GyroRemapper.process(
            rawX: 100,
            rawY: 200,
            rawZ: 300,
            controllerKind: .joyCon,
            isLeft: false,
            profileVariant: .joyCon2,
            nativeScale: JoyCon2BLEProtocol.gyroScale
        )
        XCTAssertEqual(
            pipeline.normalized.pitch,
            100 * JoyCon2BLEProtocol.gyroScale,
            accuracy: 0.000_001
        )
        XCTAssertEqual(
            pipeline.normalized.yaw,
            300 * JoyCon2BLEProtocol.gyroScale,
            accuracy: 0.000_001
        )
    }

    func testAdvertisementDecoderRecognizesJoyCon2Identity() {
        var data = Data(repeating: 0, count: 13)
        data[5] = 0x7E
        data[6] = 0x05
        data[7] = 0x67
        data[8] = 0x20

        let identity = JoyCon2BLEProtocol.decodeAdvertisement(data)

        XCTAssertEqual(identity?.vendorID, JoyCon2BLEProtocol.nintendoVendorID)
        XCTAssertEqual(identity?.productID, JoyCon2BLEProtocol.leftProductID)
    }

    func testInitializationUsesOnlyRequiredFeaturesAndPrefersFastestRate() {
        XCTAssertEqual(
            Array(JoyCon2BLEProtocol.setPlayerOneLED),
            [
                0x09, 0x91, 0x01, 0x07, 0x00, 0x08, 0x00, 0x00,
                0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
            ]
        )
        XCTAssertEqual(JoyCon2BLEProtocol.featureMask, 0x07)
        XCTAssertEqual(JoyCon2BLEProtocol.setFeatureMask[8], 0x07)
        XCTAssertEqual(JoyCon2BLEProtocol.enableFeatures[8], 0x07)
        XCTAssertEqual(JoyCon2BLEProtocol.preferredReportRate, .hz133)
        XCTAssertEqual(JoyCon2BLEProtocol.productionReportRate, .hz66)
        XCTAssertEqual(
            JoyCon2BLEProtocol.gyroScale,
            0.060_850_646_292_161_775,
            accuracy: 0.000_000_001
        )
        XCTAssertEqual(
            JoyCon2BLEProtocol.reportRateDescriptorUUID,
            "679D5510-5A24-4DEE-9557-95DF80486ECB"
        )
        XCTAssertEqual(JoyCon2BLEReportRate.hz133.descriptorValue, Data([0x85, 0x00]))
        XCTAssertEqual(JoyCon2BLEReportRate.hz66.descriptorValue, Data([0x42, 0x00]))
        XCTAssertEqual(JoyCon2BLEReportRate.hz133.coreBluetoothIntervalOverride, 6)
        XCTAssertEqual(JoyCon2BLEReportRate.hz66.coreBluetoothIntervalOverride, 12)
        XCTAssertEqual(
            JoyCon2BLEConnectionPolicy.highPerformance.coreBluetoothIntervalOverride,
            6
        )
        XCTAssertEqual(
            JoyCon2BLEConnectionPolicy.standardLowLatency.coreBluetoothIntervalOverride,
            12
        )
        XCTAssertNil(JoyCon2BLEConnectionPolicy.compatible.coreBluetoothIntervalOverride)
    }

    func testCadenceEstimatorAdaptsBetweenSupportedRatesAndIgnoresStalls() {
        var estimator = JoyCon2BLECadenceEstimator(fallbackRate: 133)

        XCTAssertEqual(estimator.record(timestamp: 1), 133)
        for index in 1...9 {
            _ = estimator.record(timestamp: 1 + Double(index) / 66.0)
        }
        XCTAssertTrue(estimator.hasStableEstimate)
        XCTAssertEqual(estimator.estimatedRate, 66, accuracy: 0.01)

        _ = estimator.record(timestamp: 2)
        XCTAssertEqual(estimator.estimatedRate, 66, accuracy: 0.01)

        var timestamp = 2.0
        var rate = 0.0
        for _ in 0..<9 {
            timestamp += 1.0 / 133.0
            rate = estimator.record(timestamp: timestamp)
        }
        XCTAssertEqual(rate, 133, accuracy: 0.01)
    }

    func testCommandResponsesMustMatchAndReportControllerSuccess() {
        let command = JoyCon2BLEProtocol.enableFeatures
        var response = Data([command[0], 0x01, 0x00, command[3]])

        XCTAssertEqual(JoyCon2BLEProtocol.commandResponseSucceeded(response, for: command), true)
        response[1] = 0x00
        XCTAssertEqual(JoyCon2BLEProtocol.commandResponseSucceeded(response, for: command), false)
        response[3] &+= 1
        XCTAssertNil(JoyCon2BLEProtocol.commandResponseSucceeded(response, for: command))
    }

    func testControlLayoutNormalizesSharedReportWithoutReplacingRawDiagnostics() {
        var report = [UInt8](repeating: 0, count: 0x3E)
        report[4] = 0xA5
        report[5] = 0x5A
        report[6] = 0xC3
        report[10...15] = [1, 2, 3, 4, 5, 6]

        let controls = JoyCon2BLEProtocol.controlBytes(from: report)

        XCTAssertEqual(controls?[3...5], [0xA5, 0x5A, 0xC3])
        XCTAssertEqual(controls?[6...11], [1, 2, 3, 4, 5, 6])
        XCTAssertEqual(report[4], 0xA5)
    }

    func testMotionDecoderUsesJoyCon2IMUOffsets() {
        var report = [UInt8](repeating: 0, count: 0x3C)
        writeInt16(101, to: &report, at: 0x30)
        writeInt16(-202, to: &report, at: 0x32)
        writeInt16(303, to: &report, at: 0x34)
        writeInt16(-404, to: &report, at: 0x36)
        writeInt16(505, to: &report, at: 0x38)
        writeInt16(-606, to: &report, at: 0x3A)

        XCTAssertEqual(JoyCon2BLEProtocol.decodeMotion(report), IMUSample(
            accelX: 101,
            accelY: -202,
            accelZ: 303,
            gyroX: -404,
            gyroY: 505,
            gyroZ: -606
        ))
    }

    func testBackendFollowsDiscoveryManagementReadyAndFrameContract() {
        let session = FakeJoyCon2BLESession()
        let backend = JoyCon2BLEInputDeviceBackend(session: session)
        let harness = InputDeviceBackendContractHarness(backend: backend)
        XCTAssertTrue(harness.start())

        let device = JoyCon2BLEDevice(
            id: "joycon2.ble:test-left",
            name: "Joy-Con 2 (L)",
            productID: JoyCon2BLEProtocol.leftProductID,
            handedness: .left
        )
        session.emitDiscovered(device)
        XCTAssertEqual(harness.availableDevicesSnapshot(), [device.controllerInfo])
        XCTAssertEqual(device.controllerInfo.profileVariant, .joyCon2)
        XCTAssertEqual(harness.changedBackendsSnapshot(), [backend.backendDescriptor])

        XCTAssertTrue(harness.setDeviceManaged(id: device.id, kind: .joyCon, managed: true))
        XCTAssertEqual(session.connectCallsSnapshot(), [device.id])
        session.emitReady(deviceID: device.id)
        XCTAssertEqual(harness.connectionEventsSnapshot().map(\.connected), [true])

        var report = [UInt8](repeating: 0, count: 0x3C)
        writeInt16(4096, to: &report, at: 0x34)
        writeInt16(120, to: &report, at: 0x38)
        session.emitInput(deviceID: device.id, bytes: report, timestamp: 42)

        let frame = try! XCTUnwrap(harness.inputFramesSnapshot().first)
        XCTAssertEqual(frame.backend, backend.backendDescriptor)
        XCTAssertEqual(frame.deviceID, device.id)
        XCTAssertEqual(frame.reportID, JoyCon2BLEProtocol.inputReportID)
        XCTAssertEqual(frame.bytes, report)
        XCTAssertEqual(frame.motion.latest?.gyroY, 120)
        XCTAssertEqual(frame.gyroScale, JoyCon2BLEProtocol.gyroScale)
        XCTAssertEqual(frame.motionSampleRate, JoyCon2BLEProtocol.productionReportRate.hertz)

        XCTAssertTrue(harness.setDeviceManaged(id: device.id, kind: .joyCon, managed: false))
        XCTAssertEqual(session.disconnectCallsSnapshot(), [device.id])
        XCTAssertEqual(harness.connectionEventsSnapshot().map(\.connected), [true, false])
        harness.stop()
    }

    private func writeInt16(_ value: Int16, to bytes: inout [UInt8], at offset: Int) {
        let raw = UInt16(bitPattern: value)
        bytes[offset] = UInt8(raw & 0xFF)
        bytes[offset + 1] = UInt8(raw >> 8)
    }
}

private final class FakeJoyCon2BLESession: JoyCon2BLESessioning, @unchecked Sendable {
    private let lock = NSLock()
    private var handlers: JoyCon2BLESessionHandlers?
    private var connectCalls: [String] = []
    private var disconnectCalls: [String] = []

    func start(handlers: JoyCon2BLESessionHandlers) -> Bool {
        locked { self.handlers = handlers }
        return true
    }

    func stop() {
        locked { handlers = nil }
    }

    func connect(deviceID: String) {
        locked { connectCalls.append(deviceID) }
    }

    func disconnect(deviceID: String) {
        locked { disconnectCalls.append(deviceID) }
    }

    func connectCallsSnapshot() -> [String] {
        locked { connectCalls }
    }

    func disconnectCallsSnapshot() -> [String] {
        locked { disconnectCalls }
    }

    func emitDiscovered(_ device: JoyCon2BLEDevice) {
        locked { handlers }?.discovered(device)
    }

    func emitReady(deviceID: String) {
        locked { handlers }?.ready(deviceID)
    }

    func emitInput(deviceID: String, bytes: [UInt8], timestamp: TimeInterval) {
        locked { handlers }?.input(deviceID, bytes, timestamp)
    }

    private func locked<Value>(_ body: () -> Value) -> Value {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }
}
