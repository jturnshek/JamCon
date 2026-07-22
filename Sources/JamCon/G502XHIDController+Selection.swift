import Foundation
import QuartzCore

extension G502XHIDController {
    func selectMouse(id: String) {
        stateLock.withLock { $0.selectedMouseID = id }
        performHIDOperation { [weak self] in
            guard let self else { return }
            guard let mouse = self.stateLock.withLock({ state in
                state.discoveredMice.first(where: { $0.id == id })
            }) else {
                // The desired selection is retained and will activate on discovery.
                return
            }
            self.activateMouse(mouse)
        }
    }

    func deselectMouse() {
        stateLock.withLock { $0.selectedMouseID = nil }
        performHIDOperation { [weak self] in
            self?.deactivateActiveMouse(publishConnectionChange: true)
        }
    }

    func recoverFromStall(expectedMouseID: String, reason: String) {
        guard start() else { return }
        performHIDOperation { [weak self] in
            guard let self else { return }
            guard self.selectedMouseID == expectedMouseID,
                  let mouse = self.stateLock.withLock({ state in
                      state.discoveredMice.first(where: { $0.id == expectedMouseID })
                  }) else {
                return
            }
            self.log("G502X stall recovery: \(reason) — reinitializing \(mouse.name)")
            self.deactivateActiveMouse(publishConnectionChange: true)
            self.activateMouse(mouse)
        }
    }

    func activateSelectedMouseIfNeeded() {
        assertOnHIDThread()
        let mouse: DiscoveredG502X? = stateLock.withLock { state in
            guard let selectedID = state.selectedMouseID else { return nil }
            return state.discoveredMice.first(where: { $0.id == selectedID })
        }
        if let mouse {
            activateMouse(mouse)
        }
    }

    func activateMouse(_ requestedMouse: DiscoveredG502X) {
        assertOnHIDThread()
        guard let mouse = stateLock.withLock({ state -> DiscoveredG502X? in
            guard state.selectedMouseID == requestedMouse.id else { return nil }
            return state.discoveredMice.first(where: { $0.id == requestedMouse.id })
        }) else {
            return
        }

        let currentActiveID = stateLock.withLock { $0.activeMouseID }
        if let currentActiveID, currentActiveID != mouse.id {
            deactivateActiveMouse(publishConnectionChange: true)
        }

        log("Activating \(mouse.name) with \(mouse.interfaces.count) interface(s)")
        for (index, interface) in mouse.interfaces.enumerated() {
            let properties = interface.properties
            log(
                "  [\(index)] UsagePage=0x\(String(format: "%04X", properties.usagePage)) "
                    + "Usage=0x\(String(format: "%04X", properties.usage)) "
                    + "MaxReportSize=\(properties.maximumInputReportSize) "
                    + "DescSize=\(properties.reportDescriptorSize)"
            )
            activateInterface(interface, for: mouse.id)
        }

        let activeCount = activeInterfaces.count
        guard activeCount > 0 else {
            log("No usable interfaces could be opened for \(mouse.name)")
            return
        }

        let shouldPublish = stateLock.withLock { state in
            guard state.selectedMouseID == mouse.id else { return false }
            let changed = !state.isConnected || state.activeMouseID != mouse.id
            state.activeMouseID = mouse.id
            state.isConnected = true
            state.mouseName = mouse.name
            return changed
        }
        updateCachedInterfaceInfo()
        scheduleHIDPPSetupIfNeeded()

        if shouldPublish {
            onConnectionChange?(true, mouse.name, mouse.id)
            log("Activated: \(mouse.name) with \(activeCount) interface(s)")
        }
    }

    @discardableResult
    func activateInterface(_ interface: G502XInterface, for mouseID: String) -> Bool {
        assertOnHIDThread()
        let identifier = interface.device.transportIdentifier
        guard activeInterfaces[identifier] == nil else { return true }

        let stillSelected = stateLock.withLock { state in
            state.selectedMouseID == mouseID
                && state.discoveredMice.first(where: { $0.id == mouseID })?.interfaces.contains(interface) == true
        }
        guard stillSelected else { return false }

        let properties = interface.properties
        guard properties.maximumInputReportSize > 0 else {
            log(
                "Skipping interface UsagePage=0x\(String(format: "%04X", properties.usagePage)) "
                    + "Usage=0x\(String(format: "%04X", properties.usage)): no input reports"
            )
            return false
        }
        guard let runLoop = CFRunLoopGetCurrent() else { return false }

        let buffer = InterfaceBuffer(
            size: max(64, properties.maximumInputReportSize),
            maxReportSize: properties.maximumInputReportSize,
            usagePage: properties.usagePage,
            usage: properties.usage
        )
        let result = transport.openInput(
            for: interface.device,
            on: runLoop,
            reportLength: max(64, properties.maximumInputReportSize),
            handler: { [weak self] reportID, report, length in
                self?.handleInputReport(
                    interfaceID: identifier,
                    report: report,
                    length: length,
                    reportID: reportID
                )
            }
        )
        guard case let .success(registration) = result else {
            if case let .failure(error) = result {
                JamLog.error(.g502x, "Failed to open Logitech interface: \(error)")
            }
            return false
        }

        let active = ActiveInterface(interface: interface, registration: registration, buffer: buffer)
        let remainsSelected = stateLock.withLock { state in
            state.selectedMouseID == mouseID
                && state.discoveredMice.first(where: { $0.id == mouseID })?.interfaces.contains(interface) == true
        }
        guard remainsSelected, activeInterfaces[identifier] == nil else {
            _ = transport.closeInput(registration)
            return false
        }
        activeInterfaces[identifier] = active

        if properties.usagePage >= 0xFF00 {
            hidppLock.withLock {
                if hidppDevice == nil {
                    hidppDevice = interface.device
                    hidppGeneration &+= 1
                    hidppSetupInFlight = false
                }
            }
        }
        log(
            "Opened interface UsagePage=0x\(String(format: "%04X", properties.usagePage)) "
                + "Usage=0x\(String(format: "%04X", properties.usage))"
        )
        return true
    }

    func deactivateActiveMouse(publishConnectionChange: Bool) {
        assertOnHIDThread()
        let connection = stateLock.withLock { state in
            (state.isConnected, state.mouseName, state.activeMouseID)
        }

        teardownHIDPPButtonReporting()
        for active in Array(activeInterfaces.values) {
            closeActiveInterface(active)
        }
        activeInterfaces.removeAll(keepingCapacity: true)
        resetHIDPPState()
        stableButtonBytes = [0, 0]
        lastStandardMouseReport.removeAll(keepingCapacity: true)
        lastInterfaceInfoUpdate = 0
        resetReportStats()

        stateLock.withLock {
            $0.activeMouseID = nil
            $0.isConnected = false
            $0.mouseName = nil
        }
        interfaceInfoLock.lock()
        cachedInterfaceInfo.removeAll(keepingCapacity: true)
        interfaceInfoLock.unlock()

        if publishConnectionChange, connection.0 {
            onConnectionChange?(false, connection.1, connection.2)
        }
    }

    func closeActiveInterface(_ active: ActiveInterface) {
        assertOnHIDThread()
        if case let .failure(error) = transport.closeInput(active.registration) {
            JamLog.errorThrottled(
                .g502x,
                key: "interface.close.\(active.interface.device.transportIdentifier)",
                interval: 2,
                "Failed to close Logitech interface: \(error)"
            )
        }
        let now = CACurrentMediaTime()
        retiredInterfaces.append(RetiredInterface(interface: active, retiredAt: now))
        retiredInterfaces.removeAll { now - $0.retiredAt > Self.deactivationRetentionSeconds }
    }

    func resetHIDPPState() {
        hidppLock.withLock {
            hidppGeneration &+= 1
            hidppSetupInFlight = false
            hidppDevice = nil
            hidppDeviceNumber = 0x01
            reprogControlsFeatureIndex = nil
            featureIndexByFeatureID.removeAll(keepingCapacity: true)
            onboardProfilesFeatureIndex = nil
            mouseButtonSpyFeatureIndex = nil
            mouseButtonSpyButtonCount = 0
            lastMouseButtonSpyBits = 0
            mouseButtonSpyActive = false
            onboardProfilesRestoreMode = nil
            pendingHIDPPRequest?.semaphore.signal()
            pendingHIDPPRequest = nil
            knownCIDs.removeAll(keepingCapacity: true)
            cidToLogicalButton.removeAll(keepingCapacity: true)
        }
        pressedCIDs.removeAll(keepingCapacity: true)
    }

    func scheduleHIDPPSetupIfNeeded() {
        let generation: UInt64? = hidppLock.withLock {
            guard hidppDevice != nil, !hidppSetupInFlight else { return nil }
            hidppSetupInFlight = true
            return hidppGeneration
        }
        guard let generation else { return }
        hidppQueue.async { [weak self] in
            guard let self else { return }
            self.setupHIDPPDivertedButtons(expectedGeneration: generation)
            self.hidppLock.withLock {
                if self.hidppGeneration == generation {
                    self.hidppSetupInFlight = false
                }
            }
        }
    }
}
