import Foundation
import GameController
import IOKit.hid

private enum ProbeIdentity {
    static let vendorID = 0xCAFE
    static let productID = 0x0001
    static let reportID: UInt32 = 0x01
    static let reportLength = 14
    static let minimumReportRate = 110.0
    static let minimumRateObservationDuration = 3.0
    static let maximumReportGap = 0.05
}

private struct ObservedRange {
    var minimum = Double.greatestFiniteMagnitude
    var maximum = -Double.greatestFiniteMagnitude

    mutating func record(_ value: Double) {
        minimum = min(minimum, value)
        maximum = max(maximum, value)
    }

    var hasBothSigns: Bool {
        minimum < -0.5 && maximum > 0.5
    }

    var hasFullTriggerRange: Bool {
        minimum < 0.1 && maximum > 0.9
    }

    var description: String {
        guard minimum.isFinite, maximum.isFinite else { return "n/a" }
        return String(format: "%.2f...%.2f", minimum, maximum)
    }
}

private struct ExpectedGameControllerPhase {
    let description: String
    var leftX: Float = 0
    var leftY: Float = 0
    var rightX: Float = 0
    var rightY: Float = 0
    var dpadX: Float = 0
    var dpadY: Float = 0
    var leftTrigger: Float = 0
    var rightTrigger: Float = 0
    var pressedButtons: Set<String> = []

    static let all: [Self] = [
        Self(description: "neutral"),
        Self(
            description: "virtual A (physical B) + left stick right/up",
            leftX: 1,
            leftY: 1,
            pressedButtons: ["a"]
        ),
        Self(
            description: "virtual B (physical A) + left stick left/down",
            leftX: -1,
            leftY: -1,
            pressedButtons: ["b"]
        ),
        Self(
            description: "virtual X (physical Y) + L1 + right stick right/up",
            rightX: 1,
            rightY: 1,
            pressedButtons: ["x", "l1"]
        ),
        Self(
            description: "virtual Y (physical X) + R1 + right stick left/down",
            rightX: -1,
            rightY: -1,
            pressedButtons: ["y", "r1"]
        ),
        Self(
            description: "both stick clicks + D-pad up/right + ZL/ZR",
            dpadX: 1,
            dpadY: 1,
            leftTrigger: 1,
            rightTrigger: 1,
            pressedButtons: ["l3", "r3"]
        ),
        Self(
            description: "minus + plus + Home + D-pad down/left",
            dpadX: -1,
            dpadY: -1,
            pressedButtons: ["options", "menu", "home"]
        ),
        Self(description: "final neutral"),
    ]
}

private struct GameControllerSnapshot {
    let leftX: Float
    let leftY: Float
    let rightX: Float
    let rightY: Float
    let dpadX: Float
    let dpadY: Float
    let leftTrigger: Float
    let rightTrigger: Float
    let pressedButtons: Set<String>

    func matches(_ expected: ExpectedGameControllerPhase) -> Bool {
        Self.matchesAxis(leftX, expected.leftX)
            && Self.matchesAxis(leftY, expected.leftY)
            && Self.matchesAxis(rightX, expected.rightX)
            && Self.matchesAxis(rightY, expected.rightY)
            && Self.matchesAxis(dpadX, expected.dpadX)
            && Self.matchesAxis(dpadY, expected.dpadY)
            && Self.matchesTrigger(leftTrigger, expected.leftTrigger)
            && Self.matchesTrigger(rightTrigger, expected.rightTrigger)
            && pressedButtons == expected.pressedButtons
    }

    private static func matchesAxis(_ actual: Float, _ expected: Float) -> Bool {
        if expected == 0 {
            return abs(actual) < 0.15
        }
        return actual * expected > 0.9
    }

    private static func matchesTrigger(_ actual: Float, _ expected: Float) -> Bool {
        expected == 0 ? actual < 0.1 : actual > 0.9
    }
}

private final class HIDReportRegistration {
    let device: IOHIDDevice
    let buffer: UnsafeMutablePointer<UInt8>
    let capacity: Int

    init(device: IOHIDDevice, capacity: Int) {
        self.device = device
        self.capacity = capacity
        buffer = .allocate(capacity: capacity)
        buffer.initialize(repeating: 0, count: capacity)
    }

    deinit {
        buffer.deinitialize(count: capacity)
        buffer.deallocate()
    }
}

private final class ObservationState: @unchecked Sendable {
    private let lock = NSLock()
    private var hidDeviceNames: Set<String> = []
    private var hidReportRegistrations: [HIDReportRegistration] = []
    private var gameControllerIDs: Set<ObjectIdentifier> = []
    private var hidValueCount = 0
    private var hidReportCount = 0
    private var firstHIDReportTimestamp: TimeInterval?
    private var lastHIDReportTimestamp: TimeInterval?
    private var maximumHIDReportGap: TimeInterval = 0
    private var gameControllerValueCount = 0
    private var hidElements: [String: (minimum: Int, maximum: Int)] = [:]
    private var gameControllerAxes: [String: ObservedRange] = [:]
    private var observedGameControllerButtons: Set<String> = []
    private var matchedPhaseCount = 0
    private var lastDetailedLogTimestamp: TimeInterval = 0

    func recordHIDDevice(_ device: IOHIDDevice) {
        let product = IOHIDDeviceGetProperty(device, kIOHIDProductKey as CFString)
            .map { String(describing: $0) } ?? "unknown"
        let maximumReportSize = (
            IOHIDDeviceGetProperty(device, kIOHIDMaxInputReportSizeKey as CFString)
                as? NSNumber
        )?.intValue ?? 64
        let registration = HIDReportRegistration(
            device: device,
            capacity: max(64, maximumReportSize)
        )
        let deviceNumber = lock.withLock {
            hidDeviceNames.insert(product)
            hidReportRegistrations.append(registration)
            return hidReportRegistrations.count
        }
        IOHIDDeviceRegisterInputReportCallback(
            device,
            registration.buffer,
            registration.capacity,
            hidReportReceived,
            Unmanaged.passUnretained(self).toOpaque()
        )
        print("hid.connected number=\(deviceNumber) product=\"\(product)\"")
    }

    func recordHIDValue(_ value: IOHIDValue) {
        let element = IOHIDValueGetElement(value)
        let usagePage = IOHIDElementGetUsagePage(element)
        let usage = IOHIDElementGetUsage(element)
        let key = String(format: "%04X:%04X", usagePage, usage)
        let integerValue = IOHIDValueGetIntegerValue(value)
        lock.withLock {
            hidValueCount += 1
            let previous = hidElements[key]
            hidElements[key] = (
                min(previous?.minimum ?? integerValue, integerValue),
                max(previous?.maximum ?? integerValue, integerValue)
            )
        }
    }

    func recordHIDReport(
        result: IOReturn,
        type: IOHIDReportType,
        reportID: UInt32,
        length: Int,
        timestamp: TimeInterval
    ) {
        guard result == kIOReturnSuccess,
              type == kIOHIDReportTypeInput,
              reportID == ProbeIdentity.reportID,
              length == ProbeIdentity.reportLength else {
            return
        }
        lock.withLock {
            hidReportCount += 1
            if firstHIDReportTimestamp == nil {
                firstHIDReportTimestamp = timestamp
            }
            if let lastHIDReportTimestamp {
                maximumHIDReportGap = max(
                    maximumHIDReportGap,
                    timestamp - lastHIDReportTimestamp
                )
            }
            lastHIDReportTimestamp = timestamp
        }
    }

    func recordGameController(_ controller: GCController) {
        let name = controller.vendorName ?? "unknown"
        let category = controller.productCategory
        guard name.localizedCaseInsensitiveContains("JamCon")
                || category.localizedCaseInsensitiveContains("JamCon") else {
            return
        }
        let identifier = ObjectIdentifier(controller)
        let isNew = lock.withLock {
            gameControllerIDs.insert(identifier).inserted
        }
        guard isNew else { return }

        print(
            "gamecontroller.connected vendor=\"\(name)\" "
                + "category=\"\(category)\" "
                + "extended=\(controller.extendedGamepad != nil)"
        )

        guard let gamepad = controller.extendedGamepad else { return }
        gamepad.valueChangedHandler = { [weak self] gamepad, element in
            self?.recordGameControllerValue(gamepad, element: element)
        }
        recordGameControllerValue(gamepad, element: nil)
    }

    private func recordGameControllerValue(
        _ gamepad: GCExtendedGamepad,
        element: GCControllerElement?
    ) {
        let axisValues: [(String, Float)] = [
            ("lx", gamepad.leftThumbstick.xAxis.value),
            ("ly", gamepad.leftThumbstick.yAxis.value),
            ("rx", gamepad.rightThumbstick.xAxis.value),
            ("ry", gamepad.rightThumbstick.yAxis.value),
            ("dpadX", gamepad.dpad.xAxis.value),
            ("dpadY", gamepad.dpad.yAxis.value),
            ("lt", gamepad.leftTrigger.value),
            ("rt", gamepad.rightTrigger.value),
        ]
        let buttons: [(String, Bool)] = [
            ("a", gamepad.buttonA.isPressed),
            ("b", gamepad.buttonB.isPressed),
            ("x", gamepad.buttonX.isPressed),
            ("y", gamepad.buttonY.isPressed),
            ("l1", gamepad.leftShoulder.isPressed),
            ("r1", gamepad.rightShoulder.isPressed),
            ("l3", gamepad.leftThumbstickButton?.isPressed == true),
            ("r3", gamepad.rightThumbstickButton?.isPressed == true),
            ("menu", gamepad.buttonMenu.isPressed),
            ("options", gamepad.buttonOptions?.isPressed == true),
            ("home", gamepad.buttonHome?.isPressed == true),
        ]
        let pressedButtons = Set(buttons.compactMap { name, pressed in
            pressed ? name : nil
        })
        let snapshot = GameControllerSnapshot(
            leftX: gamepad.leftThumbstick.xAxis.value,
            leftY: gamepad.leftThumbstick.yAxis.value,
            rightX: gamepad.rightThumbstick.xAxis.value,
            rightY: gamepad.rightThumbstick.yAxis.value,
            dpadX: gamepad.dpad.xAxis.value,
            dpadY: gamepad.dpad.yAxis.value,
            leftTrigger: gamepad.leftTrigger.value,
            rightTrigger: gamepad.rightTrigger.value,
            pressedButtons: pressedButtons
        )
        let update = lock.withLock { () -> (shouldLog: Bool, matchedPhase: Int?) in
            gameControllerValueCount += 1
            for (name, value) in axisValues {
                var range = gameControllerAxes[name] ?? ObservedRange()
                range.record(Double(value))
                gameControllerAxes[name] = range
            }
            for (name, pressed) in buttons where pressed {
                observedGameControllerButtons.insert(name)
            }
            var matchedPhase: Int?
            if matchedPhaseCount < ExpectedGameControllerPhase.all.count,
               snapshot.matches(ExpectedGameControllerPhase.all[matchedPhaseCount]) {
                matchedPhase = matchedPhaseCount
                matchedPhaseCount += 1
            }
            let now = Date.timeIntervalSinceReferenceDate
            let shouldLog = now - lastDetailedLogTimestamp >= 0.1
            if shouldLog {
                lastDetailedLogTimestamp = now
            }
            return (shouldLog, matchedPhase)
        }
        if let matchedPhase = update.matchedPhase {
            print(
                "acceptance.phase=\(matchedPhase) matched=\""
                    + "\(ExpectedGameControllerPhase.all[matchedPhase].description)\""
            )
            let nextPhase = matchedPhase + 1
            if nextPhase < ExpectedGameControllerPhase.all.count {
                print(
                    "acceptance.next=\(nextPhase) expected=\""
                        + "\(ExpectedGameControllerPhase.all[nextPhase].description)\""
                )
            }
        }
        if let element, update.shouldLog {
            print(
                "gamecontroller.changed element=\"\(element.debugDescription)\" "
                    + snapshotDescription(gamepad)
            )
        }
    }

    func summary() -> String {
        lock.withLock {
            let reportDuration = hidReportObservationDuration
            let reportRate = observedHIDReportRate
            return "hid.devices=\(hidReportRegistrations.count) "
                + "hid.values=\(hidValueCount) "
                + "hid.elements=\(hidElements.count) "
                + "hid.reports=\(hidReportCount) "
                + "hid.reportDuration=\(String(format: "%.2f", reportDuration))s "
                + "hid.reportRate=\(String(format: "%.1f", reportRate))/s "
                + "hid.maxGap=\(String(format: "%.2f", maximumHIDReportGap * 1_000))ms "
                + "gamecontroller.devices=\(gameControllerIDs.count) "
                + "gamecontroller.values=\(gameControllerValueCount) "
                + "phases=\(matchedPhaseCount)/\(ExpectedGameControllerPhase.all.count) "
                + "lx=\(gameControllerAxes["lx"]?.description ?? "n/a") "
                + "ly=\(gameControllerAxes["ly"]?.description ?? "n/a") "
                + "rx=\(gameControllerAxes["rx"]?.description ?? "n/a") "
                + "ry=\(gameControllerAxes["ry"]?.description ?? "n/a") "
                + "dpadX=\(gameControllerAxes["dpadX"]?.description ?? "n/a") "
                + "dpadY=\(gameControllerAxes["dpadY"]?.description ?? "n/a") "
                + "lt=\(gameControllerAxes["lt"]?.description ?? "n/a") "
                + "rt=\(gameControllerAxes["rt"]?.description ?? "n/a") "
                + "buttons=\(observedGameControllerButtons.sorted().joined(separator: ","))"
        }
    }

    func acceptancePassed() -> Bool {
        lock.withLock {
            hidReportRegistrations.count == 1
                && hidValueCount > 0
                && hidReportObservationDuration >= ProbeIdentity.minimumRateObservationDuration
                && observedHIDReportRate >= ProbeIdentity.minimumReportRate
                && maximumHIDReportGap <= ProbeIdentity.maximumReportGap
                && gameControllerIDs.count == 1
                && gameControllerValueCount > 0
                && matchedPhaseCount == ExpectedGameControllerPhase.all.count
        }
    }

    private var hidReportObservationDuration: TimeInterval {
        guard let firstHIDReportTimestamp,
              let lastHIDReportTimestamp else { return 0 }
        return max(0, lastHIDReportTimestamp - firstHIDReportTimestamp)
    }

    private var observedHIDReportRate: Double {
        let duration = hidReportObservationDuration
        guard hidReportCount > 1, duration > 0 else { return 0 }
        return Double(hidReportCount - 1) / duration
    }

    private func snapshotDescription(_ gamepad: GCExtendedGamepad) -> String {
        String(
            format: "lx=%.3f ly=%.3f rx=%.3f ry=%.3f dpad=(%.1f,%.1f) "
                + "triggers=(%.2f,%.2f) face=(%d,%d,%d,%d)",
            gamepad.leftThumbstick.xAxis.value,
            gamepad.leftThumbstick.yAxis.value,
            gamepad.rightThumbstick.xAxis.value,
            gamepad.rightThumbstick.yAxis.value,
            gamepad.dpad.xAxis.value,
            gamepad.dpad.yAxis.value,
            gamepad.leftTrigger.value,
            gamepad.rightTrigger.value,
            gamepad.buttonA.isPressed ? 1 : 0,
            gamepad.buttonB.isPressed ? 1 : 0,
            gamepad.buttonX.isPressed ? 1 : 0,
            gamepad.buttonY.isPressed ? 1 : 0
        )
    }
}

private let hidReportReceived: IOHIDReportCallback = {
    context,
    result,
    _,
    type,
    reportID,
    _,
    reportLength in
    guard let context else {
        return
    }
    let state = Unmanaged<ObservationState>.fromOpaque(context).takeUnretainedValue()
    state.recordHIDReport(
        result: result,
        type: type,
        reportID: reportID,
        length: reportLength,
        timestamp: ProcessInfo.processInfo.systemUptime
    )
}

private let hidDeviceMatched: IOHIDDeviceCallback = { context, _, _, device in
    guard let context else {
        return
    }
    let state = Unmanaged<ObservationState>.fromOpaque(context).takeUnretainedValue()
    state.recordHIDDevice(device)
}

private let hidValueReceived: IOHIDValueCallback = { context, _, _, value in
    guard let context else {
        return
    }
    let state = Unmanaged<ObservationState>.fromOpaque(context).takeUnretainedValue()
    state.recordHIDValue(value)
}

@main
private enum VirtualGamepadObserver {
    static func main() {
        let durationSeconds = CommandLine.arguments.dropFirst().first
            .flatMap(Double.init) ?? 60
        let state = ObservationState()
        let context = Unmanaged.passUnretained(state).toOpaque()

        let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        let matching: [String: Any] = [
            kIOHIDVendorIDKey: ProbeIdentity.vendorID,
            kIOHIDProductIDKey: ProbeIdentity.productID,
        ]
        IOHIDManagerSetDeviceMatching(manager, matching as CFDictionary)
        IOHIDManagerRegisterDeviceMatchingCallback(manager, hidDeviceMatched, context)
        IOHIDManagerRegisterInputValueCallback(manager, hidValueReceived, context)
        IOHIDManagerScheduleWithRunLoop(
            manager,
            CFRunLoopGetMain(),
            CFRunLoopMode.defaultMode.rawValue
        )
        let openResult = IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        guard openResult == kIOReturnSuccess else {
            FileHandle.standardError.write(
                Data("VirtualGamepadObserver: IOHIDManagerOpen failed: \(openResult)\n".utf8)
            )
            Foundation.exit(EXIT_FAILURE)
        }

        let notificationCenter = NotificationCenter.default
        let observer = notificationCenter.addObserver(
            forName: .GCControllerDidConnect,
            object: nil,
            queue: .main
        ) { notification in
            guard let controller = notification.object as? GCController else {
                return
            }
            state.recordGameController(controller)
        }

        GCController.controllers().forEach(state.recordGameController)
        GCController.startWirelessControllerDiscovery()

        print(
            "observing vid=0x\(String(ProbeIdentity.vendorID, radix: 16)) "
                + "pid=0x\(String(ProbeIdentity.productID, radix: 16)) "
                + "duration=\(String(format: "%.1f", durationSeconds))s "
                + "minimumRate=\(String(format: "%.1f", ProbeIdentity.minimumReportRate))/s"
        )
        print(
            "acceptance.next=0 expected=\""
                + "\(ExpectedGameControllerPhase.all[0].description)\""
        )

        let deadline = Date().addingTimeInterval(durationSeconds)
        var nextSummary = Date().addingTimeInterval(1)
        while Date() < deadline {
            RunLoop.main.run(until: min(deadline, nextSummary))
            if Date() >= nextSummary {
                print(state.summary())
                nextSummary.addTimeInterval(1)
            }
        }

        GCController.stopWirelessControllerDiscovery()
        notificationCenter.removeObserver(observer)
        IOHIDManagerUnscheduleFromRunLoop(
            manager,
            CFRunLoopGetMain(),
            CFRunLoopMode.defaultMode.rawValue
        )
        IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        print("complete \(state.summary())")
        guard state.acceptancePassed() else {
            FileHandle.standardError.write(
                Data(
                    (
                        "FAIL: virtual gamepad did not satisfy exact semantic "
                            + "mapping and report-rate checks\n"
                    ).utf8
                )
            )
            Foundation.exit(EXIT_FAILURE)
        }
        print(
            "PASS: virtual gamepad satisfied exact HID cadence and "
                + "Game Controller semantic mapping checks"
        )
    }
}
