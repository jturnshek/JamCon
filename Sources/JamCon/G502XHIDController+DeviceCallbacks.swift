import Foundation

extension G502XHIDController {
    func handleDeviceConnected(_ device: any HIDDeviceHandle) {
        assertOnHIDThread()
        guard let properties = transport.interfaceProperties(for: device) else {
            JamLog.error(.g502x, "Ignoring Logitech interface with unreadable properties")
            return
        }
        let base = properties.device
        log(
            "Logitech device: \(base.name) VID=0x\(String(format: "%04X", base.vendorID)) "
                + "PID=0x\(String(format: "%04X", base.productID)) "
                + "UsagePage=0x\(String(format: "%04X", properties.usagePage)) "
                + "Usage=0x\(String(format: "%04X", properties.usage))"
        )
        guard base.vendorID == Self.logitechVendorID,
              G502XHIDProtocol.supportedProductIDs.contains(base.productID) else {
            return
        }

        let mouseID = G502XDeviceIdentity.identifier(for: base)
        let interface = G502XInterface(device: device, properties: properties)
        let update = stateLock.withLock { state -> (
            mouse: DiscoveredG502X,
            addedMouse: Bool,
            addedInterface: Bool,
            selected: Bool,
            alreadyActive: Bool
        ) in
            var addedMouse = false
            var addedInterface = false
            if let index = state.discoveredMice.firstIndex(where: { $0.id == mouseID }) {
                if !state.discoveredMice[index].interfaces.contains(interface) {
                    state.discoveredMice[index].interfaces.append(interface)
                    addedInterface = true
                }
            } else {
                state.discoveredMice.append(DiscoveredG502X(
                    id: mouseID,
                    name: base.name,
                    productID: base.productID,
                    interfaces: [interface]
                ))
                addedMouse = true
                addedInterface = true
            }
            let mouse = state.discoveredMice.first(where: { $0.id == mouseID })!
            return (
                mouse,
                addedMouse,
                addedInterface,
                state.selectedMouseID == mouseID,
                state.activeMouseID == mouseID
            )
        }

        if update.addedMouse {
            log("G502X mouse discovered: \(base.name)")
            onControllersChanged?()
        } else if update.addedInterface {
            log("Added interface to \(base.name) (\(update.mouse.interfaces.count) total)")
        }
        guard update.addedInterface, update.selected, isHIDBackendRunning else { return }

        if update.alreadyActive {
            if activateInterface(interface, for: mouseID) {
                updateCachedInterfaceInfo()
                scheduleHIDPPSetupIfNeeded()
            }
        } else {
            // This is either initial activation or a reconnect. Publishing is
            // centralized in activateMouse so connection state cannot go stale.
            activateMouse(update.mouse)
        }
    }

    func handleDeviceDisconnected(_ device: any HIDDeviceHandle) {
        assertOnHIDThread()
        let identifier = device.transportIdentifier
        let removal = stateLock.withLock { state -> (
            mouse: DiscoveredG502X,
            removedMouse: Bool,
            wasSelected: Bool,
            wasActive: Bool
        )? in
            guard let mouseIndex = state.discoveredMice.firstIndex(where: { mouse in
                mouse.interfaces.contains(where: { $0.device.transportIdentifier == identifier })
            }),
            let interfaceIndex = state.discoveredMice[mouseIndex].interfaces.firstIndex(where: {
                $0.device.transportIdentifier == identifier
            }) else {
                return nil
            }

            let mouse = state.discoveredMice[mouseIndex]
            state.discoveredMice[mouseIndex].interfaces.remove(at: interfaceIndex)
            let removedMouse = state.discoveredMice[mouseIndex].interfaces.isEmpty
            if removedMouse {
                state.discoveredMice.remove(at: mouseIndex)
            }
            return (
                mouse,
                removedMouse,
                state.selectedMouseID == mouse.id,
                state.activeMouseID == mouse.id
            )
        }
        guard let removal else { return }

        let removedHIDPP = hidppLock.withLock {
            hidppDevice?.transportIdentifier == identifier
        }
        if removedHIDPP {
            // The physical interface is already gone, so restoration writes are
            // not useful. Invalidate pending setup and vendor state immediately.
            resetHIDPPState()
        }

        if let active = activeInterfaces.removeValue(forKey: identifier) {
            closeActiveInterface(active)
        }
        log("Interface disconnected from \(removal.mouse.name)")

        if removal.removedMouse {
            log("G502X mouse disconnected: \(removal.mouse.name)")
            onControllersChanged?()
        }

        guard removal.wasSelected, removal.wasActive else { return }
        if activeInterfaces.isEmpty {
            let wasConnected = stateLock.withLock { state in
                let wasConnected = state.isConnected
                state.activeMouseID = nil
                state.isConnected = false
                state.mouseName = nil
                return wasConnected
            }
            stableButtonBytes = [0, 0]
            lastStandardMouseReport.removeAll(keepingCapacity: true)
            resetReportStats()
            if wasConnected {
                onConnectionChange?(false, removal.mouse.name, removal.mouse.id)
            }
        } else {
            updateCachedInterfaceInfo()
            if removedHIDPP {
                let replacement = activeInterfaces.values.first(where: {
                    $0.interface.properties.usagePage >= 0xFF00
                })?.interface.device
                if let replacement {
                    hidppLock.withLock {
                        hidppDevice = replacement
                        hidppGeneration &+= 1
                    }
                    scheduleHIDPPSetupIfNeeded()
                }
            }
        }
    }
}
