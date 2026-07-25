import Foundation
import GameController
import IOKit.hid

private enum ProbeIdentity {
    static let vendorID = 0xCAFE
    static let productID = 0x0001
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

private final class ObservationState: @unchecked Sendable {
    private let lock = NSLock()
    private var hidDeviceNames: Set<String> = []
    private var gameControllerIDs: Set<ObjectIdentifier> = []
    private var hidValueCount = 0
    private var gameControllerValueCount = 0
    private var hidElements: [String: (minimum: Int, maximum: Int)] = [:]
    private var gameControllerAxes: [String: ObservedRange] = [:]
    private var observedGameControllerButtons: Set<String> = []
    private var lastDetailedLogTimestamp: TimeInterval = 0

    func recordHIDDevice(_ device: IOHIDDevice) {
        let product = IOHIDDeviceGetProperty(device, kIOHIDProductKey as CFString)
            .map { String(describing: $0) } ?? "unknown"
        lock.withLock {
            if hidDeviceNames.insert(product).inserted {
                print("hid.connected product=\"\(product)\"")
            }
        }
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
        let shouldLog = lock.withLock {
            gameControllerValueCount += 1
            for (name, value) in axisValues {
                var range = gameControllerAxes[name] ?? ObservedRange()
                range.record(Double(value))
                gameControllerAxes[name] = range
            }
            for (name, pressed) in buttons where pressed {
                observedGameControllerButtons.insert(name)
            }
            let now = Date.timeIntervalSinceReferenceDate
            guard now - lastDetailedLogTimestamp >= 0.1 else { return false }
            lastDetailedLogTimestamp = now
            return true
        }
        if let element, shouldLog {
            print(
                "gamecontroller.changed element=\"\(element.debugDescription)\" "
                    + snapshotDescription(gamepad)
            )
        }
    }

    func summary() -> String {
        lock.withLock {
            "hid.devices=\(hidDeviceNames.count) "
                + "hid.values=\(hidValueCount) "
                + "hid.elements=\(hidElements.count) "
                + "gamecontroller.devices=\(gameControllerIDs.count) "
                + "gamecontroller.values=\(gameControllerValueCount) "
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
            let requiredButtons: Set<String> = [
                "a", "b", "x", "y",
                "l1", "r1", "l3", "r3",
                "menu", "options", "home",
            ]
            return hidDeviceNames.count == 1
                && hidValueCount > 0
                && gameControllerIDs.count == 1
                && gameControllerValueCount > 0
                && gameControllerAxes["lx"]?.hasBothSigns == true
                && gameControllerAxes["ly"]?.hasBothSigns == true
                && gameControllerAxes["rx"]?.hasBothSigns == true
                && gameControllerAxes["ry"]?.hasBothSigns == true
                && gameControllerAxes["dpadX"]?.hasBothSigns == true
                && gameControllerAxes["dpadY"]?.hasBothSigns == true
                && gameControllerAxes["lt"]?.hasFullTriggerRange == true
                && gameControllerAxes["rt"]?.hasFullTriggerRange == true
                && requiredButtons.isSubset(of: observedGameControllerButtons)
        }
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
                + "duration=\(String(format: "%.1f", durationSeconds))s"
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
                Data("FAIL: virtual gamepad did not satisfy the loopback checks\n".utf8)
            )
            Foundation.exit(EXIT_FAILURE)
        }
        print("PASS: virtual gamepad satisfied HID and Game Controller loopback checks")
    }
}
