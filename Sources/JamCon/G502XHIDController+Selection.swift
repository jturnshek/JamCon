import Foundation
import IOKit
import IOKit.hid
import QuartzCore
import os.lock

extension G502XHIDController {

    // MARK: - Mouse Selection

    /// Select a mouse by ID
    func selectMouse(id: String) {
        performHIDOperation { [weak self] in
            guard let self else { return }
            guard let mouse = self.stateLock.withLock({ state in
                state.discoveredMice.first(where: { $0.id == id })
            }) else {
                self.log("Mouse \(id) not found")
                return
            }

            // Deactivate current mouse if different
            if let currentID = self.selectedMouseID, currentID != id {
                self.deactivateCurrentMouse()
            }

            // Activate the new mouse (all interfaces)
            self.activateMouse(mouse)
        }
    }

    /// Deselect the current mouse (stop receiving input)
    func deselectMouse() {
        performHIDOperation { [weak self] in
            guard let self else { return }
            self.stateLock.withLock { state in
                state.selectedMouseID = nil
                state.preferredMouseID = nil
            }
            self.deactivateCurrentMouse()
        }
	    }

	    func activateMouse(_ mouse: DiscoveredG502X) {
	        assert(Thread.current == hidThread, "G502XHIDController.activateMouse must run on the HID thread")
	        log("Activating mouse with \(mouse.interfaces.count) interface(s)...")

        // Log ALL interfaces first so we can see what's available
        log("=== Available interfaces ===")
        for (index, device) in mouse.interfaces.enumerated() {
            let usagePage = IOHIDDeviceGetProperty(device, kIOHIDPrimaryUsagePageKey as CFString) as? Int ?? 0
            let usage = IOHIDDeviceGetProperty(device, kIOHIDPrimaryUsageKey as CFString) as? Int ?? 0
            let maxInputReportSize = IOHIDDeviceGetProperty(device, kIOHIDMaxInputReportSizeKey as CFString) as? Int ?? 0
            let reportDescriptor = IOHIDDeviceGetProperty(device, kIOHIDReportDescriptorKey as CFString)
            let reportDescSize = (reportDescriptor as? Data)?.count ?? 0
            log("  [\(index)] UsagePage=0x\(String(format: "%04X", usagePage)) Usage=0x\(String(format: "%04X", usage)) MaxReportSize=\(maxInputReportSize) DescSize=\(reportDescSize)")
        }
        log("=== End interfaces ===")

        // Open all input-report interfaces for this physical mouse so the debug UI can show per-interface bytes.
        // Unified button reports are still derived only from vendor + standard mouse interfaces.
        for device in mouse.interfaces {
            let usagePage = IOHIDDeviceGetProperty(device, kIOHIDPrimaryUsagePageKey as CFString) as? Int ?? 0
            let usage = IOHIDDeviceGetProperty(device, kIOHIDPrimaryUsageKey as CFString) as? Int ?? 0

            // Check if we should open this interface
            guard shouldOpenInterface(device: device) else {
                log("  Skipping interface: UsagePage=0x\(String(format: "%04X", usagePage)) Usage=0x\(String(format: "%04X", usage))")
                continue
            }

            let deviceID = ObjectIdentifier(device)

            // Open the device in non-exclusive mode (allows system to also receive events)
            let result = IOHIDDeviceOpen(device, IOOptionBits(kIOHIDOptionsTypeNone))
            if result != kIOReturnSuccess && result != -536870201 { // Already open is OK
                log("Failed to open interface: \(result)")
                continue
            }

            // Create report buffer wrapper for this interface (size based on max input report size)
            let maxInputReportSize = IOHIDDeviceGetProperty(device, kIOHIDMaxInputReportSizeKey as CFString) as? Int ?? 0
            let bufferSize = max(64, maxInputReportSize)
            let buffer = InterfaceBuffer(size: bufferSize, maxReportSize: maxInputReportSize, deviceID: deviceID, usagePage: usagePage, usage: usage)
            interfaceBuffers[deviceID] = buffer

            // Register input report callback
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

            log("  Opened interface: UsagePage=0x\(String(format: "%04X", usagePage)) Usage=0x\(String(format: "%04X", usage))")

            // Capture the vendor HID++ interface for button reporting/config.
            if usagePage >= 0xFF00 {
                hidppLock.withLock {
                    if hidppDevice == nil { hidppDevice = device }
                }
            }
        }

        stateLock.withLock { state in
            state.selectedMouseID = mouse.id
            state.mouseName = mouse.name
            state.isConnected = !activeInterfaces.isEmpty
        }

        // Update cached interface info for debug UI
        updateCachedInterfaceInfo()

        log("Activated: \(mouseName ?? "Unknown") with \(activeInterfaces.count) interface(s)")

        // Best-effort enable HID++ button reporting so extra buttons produce down/up events.
        let hasHIDPPDevice = hidppLock.withLock { hidppDevice != nil }
        if hasHIDPPDevice {
            hidppQueue.async { [weak self] in
                self?.setupHIDPPDivertedButtons()
            }
        }

	        // Capture values before dispatching
	        let (name, mouseID) = stateLock.withLock { state in
	            (state.mouseName, state.selectedMouseID)
	        }
	        onConnectionChange?(true, name, mouseID)
	    }

	    private func deactivateCurrentMouse() {
	        assert(Thread.current == hidThread, "G502XHIDController.deactivateCurrentMouse must run on the HID thread")
	        teardownHIDPPButtonReporting()

        for device in activeInterfaces {
            let deviceID = ObjectIdentifier(device)
            if let buffer = interfaceBuffers[deviceID] {
                buffer.bytes.withUnsafeMutableBufferPointer { bufferPtr in
                    if let baseAddr = bufferPtr.baseAddress {
                        bufferPointerToDeviceID.removeValue(forKey: baseAddr)
                        IOHIDDeviceRegisterInputReportCallback(device, baseAddr, bufferPtr.count, nil, nil)
                    }
                }
            }
            IOHIDDeviceClose(device, IOOptionBits(kIOHIDOptionsTypeNone))
        }
        activeInterfaces.removeAll()
        interfaceBuffers.removeAll()
        bufferPointerToDeviceID.removeAll()
        deviceToMouseID.removeAll()

        let (name, mouseID) = stateLock.withLock { state in
            state.isConnected = false
            let name = state.mouseName
            let mouseID = state.selectedMouseID
            state.mouseName = nil
            return (name, mouseID)
        }

        // Reset HID++ state
        hidppLock.withLock {
            hidppDevice = nil
            hidppDeviceNumber = 0x01
            reprogControlsFeatureIndex = nil
            featureIndexByFeatureID.removeAll()
            onboardProfilesFeatureIndex = nil
            mouseButtonSpyFeatureIndex = nil
            mouseButtonSpyButtonCount = 0
            lastMouseButtonSpyBits = 0
            mouseButtonSpyActive = false
            onboardProfilesRestoreMode = nil
            pendingHIDPPRequest = nil

            knownCIDs.removeAll()
            pressedCIDs.removeAll()
            cidToLogicalButton.removeAll()
        }
        stableButtonBytes = [0, 0]
        lastStandardMouseReport.removeAll()

	        onConnectionChange?(false, name, mouseID)
	    }
}

