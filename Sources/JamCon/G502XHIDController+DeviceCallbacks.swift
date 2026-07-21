import Foundation
import IOKit
import IOKit.hid
import QuartzCore
import os.lock

extension G502XHIDController {

    // MARK: - Device Callbacks

    func handleDeviceConnected(_ device: IOHIDDevice) {
        let vendorID = IOHIDDeviceGetProperty(device, kIOHIDVendorIDKey as CFString) as? Int ?? 0
        let productID = IOHIDDeviceGetProperty(device, kIOHIDProductIDKey as CFString) as? Int ?? 0
        let name = IOHIDDeviceGetProperty(device, kIOHIDProductKey as CFString) as? String ?? "Unknown"
        let usagePage = IOHIDDeviceGetProperty(device, kIOHIDPrimaryUsagePageKey as CFString) as? Int ?? 0
        let usage = IOHIDDeviceGetProperty(device, kIOHIDPrimaryUsageKey as CFString) as? Int ?? 0

        // Log all Logitech devices with their usage info
        log("Logitech device: \(name) (VID:0x\(String(format: "%04X", vendorID)) PID:0x\(String(format: "%04X", productID)) UsagePage:0x\(String(format: "%04X", usagePage)) Usage:0x\(String(format: "%04X", usage)))")

        // Check if it's a supported Logitech mouse
        guard vendorID == Self.logitechVendorID,
              G502XHIDProtocol.supportedProductIDs.contains(productID) else {
            return
        }

        // Create unique ID for the physical mouse (not per-interface)
        // Use locationID which is the same for all interfaces of the same USB device
        let locationID = IOHIDDeviceGetProperty(device, kIOHIDLocationIDKey as CFString) as? Int ?? 0
        // Mask out the interface number from locationID to get physical device ID
        let physicalDeviceID = locationID & 0xFFFFFF00
        let uniqueID = "loc-\(String(format: "%08X", physicalDeviceID))-pid-\(productID)"

        let update = stateLock.withLock { state -> (addedNewMouse: Bool, addedInterface: Bool, interfaceCount: Int, mouse: DiscoveredG502X?, selectedMouseID: String?, preferredMouseID: String?) in
            var addedNewMouse = false
            var addedInterface = false
            let interfaceCount: Int

            if let index = state.discoveredMice.firstIndex(where: { $0.id == uniqueID }) {
                if !state.discoveredMice[index].interfaces.contains(where: { $0 == device }) {
                    state.discoveredMice[index].interfaces.append(device)
                    addedInterface = true
                }
                interfaceCount = state.discoveredMice[index].interfaces.count
            } else {
                let mouse = DiscoveredG502X(
                    id: uniqueID,
                    name: name,
                    productID: productID,
                    interfaces: [device]
                )
                state.discoveredMice.append(mouse)
                addedNewMouse = true
                addedInterface = true
                interfaceCount = 1
            }

            let mouse = state.discoveredMice.first(where: { $0.id == uniqueID })
            return (addedNewMouse, addedInterface, interfaceCount, mouse, state.selectedMouseID, state.preferredMouseID)
        }

	        if update.addedNewMouse {
	            log("G502X mouse discovered: \(name)")
	            onControllersChanged?()
	        } else if update.addedInterface {
	            log("Added interface to existing mouse: \(name) (now \(update.interfaceCount) interfaces)")
	        }

        // Auto-select if this was previously selected
        guard let mouse = update.mouse else { return }
        if update.selectedMouseID == uniqueID {
            // Already selected, but new interface - activate it too
            if !activeInterfaces.contains(where: { $0 == device }) {
                activateInterface(device, for: mouse)
            }
        } else if update.selectedMouseID == nil && update.preferredMouseID == uniqueID {
            activateMouse(mouse)
        }
    }

	    /// Activate a single additional interface for an already-selected mouse
	    private func activateInterface(_ device: IOHIDDevice, for mouse: DiscoveredG502X) {
	        assert(Thread.current == hidThread, "G502XHIDController.activateInterface must run on the HID thread")
	        let usagePage = IOHIDDeviceGetProperty(device, kIOHIDPrimaryUsagePageKey as CFString) as? Int ?? 0
	        let usage = IOHIDDeviceGetProperty(device, kIOHIDPrimaryUsageKey as CFString) as? Int ?? 0

        // Check if we should open this interface
        guard shouldOpenInterface(device: device) else {
            log("  Skipping interface: UsagePage=0x\(String(format: "%04X", usagePage)) Usage=0x\(String(format: "%04X", usage))")
            return
        }

        let deviceID = ObjectIdentifier(device)

        let result = IOHIDDeviceOpen(device, IOOptionBits(kIOHIDOptionsTypeNone))
        if result != kIOReturnSuccess && result != -536870201 {
            log("Failed to open additional interface: \(result)")
            return
        }

        let maxInputReportSize = IOHIDDeviceGetProperty(device, kIOHIDMaxInputReportSizeKey as CFString) as? Int ?? 0
        let bufferSize = max(64, maxInputReportSize)
        let buffer = InterfaceBuffer(size: bufferSize, maxReportSize: maxInputReportSize, deviceID: deviceID, usagePage: usagePage, usage: usage)
        interfaceBuffers[deviceID] = buffer

        let context = Unmanaged.passUnretained(self).toOpaque()
        buffer.bytes.withUnsafeMutableBufferPointer { bufferPtr in
            guard let baseAddr = bufferPtr.baseAddress else { return }
            self.bufferPointerToDeviceID[baseAddr] = deviceID

            IOHIDDeviceRegisterInputReportCallback(
                device,
                baseAddr,
                bufferPtr.count,
                { context, result, sender, type, reportID, report, length in
                    guard let ctx = context else { return }
                    let controller = Unmanaged<G502XHIDController>.fromOpaque(ctx).takeUnretainedValue()
                    controller.handleInputReport(report: report, length: length, reportID: reportID)
                },
                context
            )
        }

        activeInterfaces.append(device)
        deviceToMouseID[deviceID] = mouse.id

        log("Activated additional interface: UsagePage=0x\(String(format: "%04X", usagePage)) Usage=0x\(String(format: "%04X", usage))")
    }

    func handleDeviceDisconnected(_ device: IOHIDDevice) {
        struct RemovalResult {
            let mouse: DiscoveredG502X
            let didRemoveMouse: Bool
            let wasSelectedMouse: Bool
        }

        let removal: RemovalResult? = stateLock.withLock { state in
            guard let mouseIndex = state.discoveredMice.firstIndex(where: { $0.interfaces.contains(where: { $0 == device }) }) else {
                return nil
            }
            guard let interfaceIndex = state.discoveredMice[mouseIndex].interfaces.firstIndex(where: { $0 == device }) else {
                return nil
            }

            let mouse = state.discoveredMice[mouseIndex]
            state.discoveredMice[mouseIndex].interfaces.remove(at: interfaceIndex)

            let didRemoveMouse: Bool
            if state.discoveredMice[mouseIndex].interfaces.isEmpty {
                state.discoveredMice.remove(at: mouseIndex)
                didRemoveMouse = true
            } else {
                didRemoveMouse = false
            }

            let wasSelectedMouse = (mouse.id == state.selectedMouseID)
            if wasSelectedMouse && didRemoveMouse {
                state.isConnected = false
                state.mouseName = nil
            }

            return RemovalResult(mouse: mouse, didRemoveMouse: didRemoveMouse, wasSelectedMouse: wasSelectedMouse)
        }

        guard let removal else { return }
        let mouse = removal.mouse

        log("Interface disconnected from: \(mouse.name)")

        // Close the device
        IOHIDDeviceClose(device, IOOptionBits(kIOHIDOptionsTypeNone))

        // Remove from active interfaces if present
        if let activeIndex = activeInterfaces.firstIndex(where: { $0 == device }) {
            activeInterfaces.remove(at: activeIndex)
        }
        let deviceID = ObjectIdentifier(device)
        // Clean up buffer pointer mapping
        if let buffer = interfaceBuffers[deviceID] {
            buffer.bytes.withUnsafeMutableBufferPointer { bufferPtr in
                if let baseAddr = bufferPtr.baseAddress {
                    bufferPointerToDeviceID.removeValue(forKey: baseAddr)
                }
            }
        }
        interfaceBuffers.removeValue(forKey: deviceID)
        deviceToMouseID.removeValue(forKey: deviceID)

        // If no more interfaces, remove the mouse entirely
        if removal.didRemoveMouse {
            log("G502X mouse disconnected: \(mouse.name)")
            onControllersChanged?()

            // If this was the active mouse, report disconnect
            if removal.wasSelectedMouse {
                resetReportStats()
                onConnectionChange?(false, mouse.name, mouse.id)
            }
        } else if removal.wasSelectedMouse && activeInterfaces.isEmpty {
            // All active interfaces gone but mouse still has interfaces
            stateLock.withLock { state in
                state.isConnected = false
            }
            resetReportStats()
        }
    }
}
