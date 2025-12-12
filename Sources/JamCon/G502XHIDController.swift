import Foundation
import IOKit
import IOKit.hid
import QuartzCore
import os

/// Represents a discovered G502X mouse (internal use only)
/// A single physical mouse may have multiple HID interfaces
struct DiscoveredG502X: Identifiable, Equatable {
    let id: String  // Unique identifier for the physical mouse
    let name: String
    let productID: Int
    var interfaces: [IOHIDDevice]  // All HID interfaces for this mouse

    /// Convert to UI-safe info struct
    var info: ControllerInfo {
        ControllerInfo(id: id, name: name, productID: productID, kind: .mouse)
    }

    static func == (lhs: DiscoveredG502X, rhs: DiscoveredG502X) -> Bool {
        lhs.id == rhs.id
    }
}

/// UI-safe representation of an HID interface for debug display
struct G502XInterfaceInfo: Identifiable {
    let id: String  // Unique ID for SwiftUI
    let usagePage: Int
    let usage: Int
    let maxReportSize: Int
    let isActive: Bool  // Whether this interface is currently open
    var reportCount: Int  // Number of reports received from this interface
    var lastReportBytes: [UInt8]  // All bytes from last report (up to 64)
    let reportLength: Int  // Length of last report received
    let byteLastChanged: [Date]  // Per-byte last-changed timestamps for heatmap

    var usagePageHex: String { String(format: "0x%04X", usagePage) }
    var usageHex: String { String(format: "0x%04X", usage) }

    /// Human-readable interface type
    var interfaceType: String {
        if usagePage >= 0xFF00 {
            return "Vendor"
        } else if usagePage == 0x0001 && usage == 0x0002 {
            return "Mouse"
        } else if usagePage == 0x0001 && usage == 0x0006 {
            return "Keyboard"
        } else {
            return "Unknown"
        }
    }
}

/// HID controller for Logitech G502X mouse
/// Opens all HID interfaces to receive button events from both vendor and standard interfaces.
class G502XHIDController {

    // MARK: - Constants

    private static let logitechVendorID = G502XHIDProtocol.logitechVendorID
    /// HID++ 2.0 uses the low nibble of the function byte as a software ID.
    /// Solaar/BetterMouse typically use 0x02; using a non‑zero ID improves replies.
    private static let hidppSoftwareID: UInt8 = 0x02
    private static let hidppFeatureIDFeatureSet: UInt16 = 0x0001
    private static let hidppFeatureIDOnboardProfiles: UInt16 = 0x8100
    private static let hidppFeatureIDMouseButtonSpy: UInt16 = 0x8110

    // MARK: - Interface Buffer

    /// Class wrapper for report buffers - provides stable memory address for callback identification
    private class InterfaceBuffer {
        var bytes: [UInt8]
        private var previousBytes: [UInt8]
        private(set) var byteLastChanged: [Date]
        private(set) var lastLength: Int = 0
        let deviceID: ObjectIdentifier
        let usagePage: Int
        let usage: Int
        var reportCount: Int = 0

        init(size: Int, deviceID: ObjectIdentifier, usagePage: Int, usage: Int) {
            self.bytes = [UInt8](repeating: 0, count: size)
            self.previousBytes = self.bytes
            self.byteLastChanged = Array(repeating: .distantPast, count: size)
            self.deviceID = deviceID
            self.usagePage = usagePage
            self.usage = usage
        }

        func update(from report: UnsafeMutablePointer<UInt8>, length: Int, at now: Date) {
            let copyLength = min(length, bytes.count)
            lastLength = copyLength

            for i in 0..<copyLength {
                let newByte = report[i]
                if newByte != previousBytes[i] {
                    byteLastChanged[i] = now
                    previousBytes[i] = newByte
                }
                bytes[i] = newByte
            }

            if copyLength < bytes.count {
                for i in copyLength..<bytes.count {
                    if previousBytes[i] != 0 {
                        byteLastChanged[i] = now
                        previousBytes[i] = 0
                    }
                    bytes[i] = 0
                }
            }
        }
    }

    /// Check if an interface should be opened
    private func shouldOpenInterface(device: IOHIDDevice) -> Bool {
        // For debugging, observe all interfaces that can emit input reports.
        let maxReportSize = IOHIDDeviceGetProperty(device, kIOHIDMaxInputReportSizeKey as CFString) as? Int ?? 0
        return maxReportSize > 0
    }

    // MARK: - Properties

    private var hidManager: IOHIDManager?
    private var activeInterfaces: [IOHIDDevice] = []  // All open interfaces
    private var interfaceBuffers: [ObjectIdentifier: InterfaceBuffer] = [:]  // Per-interface buffer wrappers
    private var bufferPointerToDeviceID: [UnsafeMutablePointer<UInt8>: ObjectIdentifier] = [:]  // Buffer ptr -> device lookup
    private var hidRunLoop: CFRunLoop?
    private var hidThread: Thread?
    private let hidRunLoopReady = DispatchSemaphore(value: 0)

    // HID++ (Logitech vendor protocol) support.
    private let hidppQueue = DispatchQueue(label: "JamCon.G502X.HIDPP", qos: .userInitiated)
    private let hidppLock = OSAllocatedUnfairLock()
    private var hidppDevice: IOHIDDevice?
    private var hidppDeviceNumber: UInt8 = 0x01
    private var featureIndexByFeatureID: [UInt16: UInt8] = [:]
    private var onboardProfilesFeatureIndex: UInt8?
    private var mouseButtonSpyFeatureIndex: UInt8?
    private var mouseButtonSpyButtonCount: Int = 0
    private var lastMouseButtonSpyBits: UInt16 = 0
    private var mouseButtonSpyActive: Bool = false
    private var onboardProfilesRestoreMode: UInt8?

    // Legacy (REPROG_CONTROLS*) support (not present on G502X Lightspeed receiver, but keep for other devices).
    private var reprogControlsFeatureIndex: UInt8?
    private var knownCIDs: [UInt16] = []
    private var pressedCIDs: Set<UInt16> = []
    private var cidToLogicalButton: [UInt16: G502XLogicalButton] = [:]
    private let logicalButtonMapping = G502XButtonMapping()
    private var stableButtonBytes: [UInt8] = [0, 0]  // bytes 0-1 stable button state
    private var lastStandardMouseReport: [UInt8] = []

    private struct PendingHIDPPRequest {
        let featureIndex: UInt8
        /// Upper nibble of function byte (lower nibble is software ID).
        let functionHighNibble: UInt8
        let semaphore: DispatchSemaphore
        var response: [UInt8]? = nil
    }
    private var pendingHIDPPRequest: PendingHIDPPRequest?

    /// All discovered G502X mice (grouped by physical device)
    private(set) var discoveredMice: [DiscoveredG502X] = []

    /// Map from device to mouse ID for quick lookup
    private var deviceToMouseID: [ObjectIdentifier: String] = [:]

    /// Currently selected mouse ID
    private(set) var selectedMouseID: String?

    /// Preferred mouse ID (persisted from last user selection)
    var preferredMouseID: String?

    /// Input report structure for button data
    struct InputReport {
        let bytes: [UInt8]
        let length: Int
        let timestamp: TimeInterval
    }

    /// Callback for full report data (merged from all interfaces)
    var onReportData: ((_ report: InputReport) -> Void)?

    /// Callback for connection state changes
    var onConnectionChange: ((_ connected: Bool, _ name: String?, _ mouseID: String?) -> Void)?

    /// Callback when available mice list changes
    var onControllersChanged: (() -> Void)?

    /// Callback for debug/status messages
    var onDebugMessage: ((_ message: String) -> Void)?

    /// Whether a mouse is currently connected and active
    private(set) var isConnected: Bool = false

    /// Name of the connected mouse
    private(set) var mouseName: String?

    /// Whether we currently have a vendor-side mechanism that reliably reports button down/up.
    /// When true, we don't need CGEventTap fallback for releases.
    var hasReliableButtonReleaseEvents: Bool {
        hidppLock.withLock { mouseButtonSpyActive || reprogControlsFeatureIndex != nil }
    }

    /// Thread-safe cache for interface info (updated on HID thread, read from main thread)
    private let interfaceInfoLock = NSLock()
    private var cachedInterfaceInfo: [G502XInterfaceInfo] = []
    private var lastInterfaceInfoUpdate: TimeInterval = 0

    /// Get info about all discovered interfaces for the selected mouse (for debug UI)
    /// Thread-safe: returns a cached snapshot
    func getInterfaceInfo() -> [G502XInterfaceInfo] {
        interfaceInfoLock.lock()
        defer { interfaceInfoLock.unlock() }
        return cachedInterfaceInfo
    }

    /// Update the cached interface info (call from HID thread after processing reports)
    private func updateCachedInterfaceInfo() {
        guard let mouseID = selectedMouseID,
              let mouse = discoveredMice.first(where: { $0.id == mouseID }) else {
            interfaceInfoLock.lock()
            cachedInterfaceInfo = []
            interfaceInfoLock.unlock()
            return
        }

        let newInfo = mouse.interfaces.enumerated().map { index, device -> G502XInterfaceInfo in
            let usagePage = IOHIDDeviceGetProperty(device, kIOHIDPrimaryUsagePageKey as CFString) as? Int ?? 0
            let usage = IOHIDDeviceGetProperty(device, kIOHIDPrimaryUsageKey as CFString) as? Int ?? 0
            let maxReportSize = IOHIDDeviceGetProperty(device, kIOHIDMaxInputReportSizeKey as CFString) as? Int ?? 0
            let deviceID = ObjectIdentifier(device)
            let isActive = activeInterfaces.contains(where: { ObjectIdentifier($0) == deviceID })
            let buffer = interfaceBuffers[deviceID]

            let bytesSnapshot: [UInt8]
            if let buffer {
                // IMPORTANT: Deep copy so we don't share storage with the live callback buffer.
                // Sharing would trigger copy-on-write on the next update and invalidate the
                // pointer passed to IOHIDDeviceRegisterInputReportCallback, causing crashes.
                bytesSnapshot = buffer.bytes.withUnsafeBufferPointer { Array($0) }
            } else {
                bytesSnapshot = []
            }

            return G502XInterfaceInfo(
                id: "\(index)-\(usagePage)-\(usage)",
                usagePage: usagePage,
                usage: usage,
                maxReportSize: maxReportSize,
                isActive: isActive,
                reportCount: buffer?.reportCount ?? 0,
                lastReportBytes: bytesSnapshot,
                reportLength: buffer?.lastLength ?? 0,
                byteLastChanged: Array(buffer?.byteLastChanged ?? [])
            )
        }

        interfaceInfoLock.lock()
        cachedInterfaceInfo = newInfo
        interfaceInfoLock.unlock()
    }

    // MARK: - Initialization

    init() {}

    private func log(_ message: String) {
        print("[G502X] \(message)")
        DispatchQueue.main.async {
            self.onDebugMessage?(message)
        }
    }

    deinit {
        stop()
    }

    // MARK: - Public Methods

    func start() {
        startHIDThreadIfNeeded()
    }

    private func startHIDThreadIfNeeded() {
        guard hidThread == nil else { return }

        let thread = Thread { [weak self] in
            self?.runHIDThread()
        }
        thread.name = "JamCon.G502X.HID"
        thread.qualityOfService = .userInteractive
        hidThread = thread
        thread.start()

        // Wait until the HID run loop is ready
        hidRunLoopReady.wait()
    }

    private func runHIDThread() {
        hidRunLoop = CFRunLoopGetCurrent()
        hidRunLoopReady.signal()

        configureHIDManager(on: hidRunLoop ?? CFRunLoopGetCurrent())

        // Run loop with periodic autorelease pool drain
        while !Thread.current.isCancelled {
            _ = autoreleasepool {
                CFRunLoopRunInMode(.defaultMode, 1.0, false)
            }
        }

        // Cleanup after the run loop stops
        hidRunLoop = nil
        hidThread = nil
    }

    private func configureHIDManager(on runLoop: CFRunLoop) {
        guard hidManager == nil else { return }

        log("Creating HID manager...")
        hidManager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        guard let manager = hidManager else {
            log("Failed to create HID manager")
            return
        }

        // Match Logitech devices
        let matching: [String: Any] = [
            kIOHIDVendorIDKey as String: G502XHIDProtocol.logitechVendorID
        ]
        IOHIDManagerSetDeviceMatching(manager, matching as CFDictionary)

        // Set up device callbacks
        let context = Unmanaged.passUnretained(self).toOpaque()

        IOHIDManagerRegisterDeviceMatchingCallback(manager, { context, result, sender, device in
            guard let ctx = context else { return }
            let controller = Unmanaged<G502XHIDController>.fromOpaque(ctx).takeUnretainedValue()
            controller.handleDeviceConnected(device)
        }, context)

        IOHIDManagerRegisterDeviceRemovalCallback(manager, { context, result, sender, device in
            guard let ctx = context else { return }
            let controller = Unmanaged<G502XHIDController>.fromOpaque(ctx).takeUnretainedValue()
            controller.handleDeviceDisconnected(device)
        }, context)

        // Schedule with run loop
        IOHIDManagerScheduleWithRunLoop(manager, runLoop, CFRunLoopMode.defaultMode.rawValue)

        // Open the manager
        let result = IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        if result != kIOReturnSuccess {
            log("Failed to open HID manager: \(result)")
        } else {
            log("HID manager started, scanning for Logitech mice...")
        }
    }

    func stop() {
        hidThread?.cancel()

        guard let runLoop = hidRunLoop else {
            // Fallback cleanup
            teardownHIDPPButtonReporting()
            for device in activeInterfaces {
                IOHIDDeviceClose(device, IOOptionBits(kIOHIDOptionsTypeNone))
            }
            activeInterfaces.removeAll()
            if let manager = hidManager {
                IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone))
                hidManager = nil
            }
            discoveredMice.removeAll()
            deviceToMouseID.removeAll()
            selectedMouseID = nil
            isConnected = false
            mouseName = nil
            return
        }

        CFRunLoopPerformBlock(runLoop, CFRunLoopMode.defaultMode.rawValue) { [weak self] in
            guard let self else { return }

            self.teardownHIDPPButtonReporting()

            for device in self.activeInterfaces {
                let deviceID = ObjectIdentifier(device)
                // Unregister callback by passing nil callback function with the same buffer
                if let buffer = self.interfaceBuffers[deviceID] {
                    buffer.bytes.withUnsafeMutableBufferPointer { bufferPtr in
                        if let baseAddr = bufferPtr.baseAddress {
                            self.bufferPointerToDeviceID.removeValue(forKey: baseAddr)
                            IOHIDDeviceRegisterInputReportCallback(device, baseAddr, bufferPtr.count, nil, nil)
                        }
                    }
                }
                IOHIDDeviceClose(device, IOOptionBits(kIOHIDOptionsTypeNone))
            }
            self.activeInterfaces.removeAll()
            self.interfaceBuffers.removeAll()
            self.bufferPointerToDeviceID.removeAll()

            if let manager = self.hidManager {
                IOHIDManagerUnscheduleFromRunLoop(manager, runLoop, CFRunLoopMode.defaultMode.rawValue)
                IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone))
                self.hidManager = nil
            }

            self.discoveredMice.removeAll()
            self.deviceToMouseID.removeAll()
            self.selectedMouseID = nil
            self.isConnected = false
            self.mouseName = nil

            CFRunLoopStop(runLoop)
        }

        CFRunLoopWakeUp(runLoop)
    }

    // MARK: - Mouse Selection

    /// Select a mouse by ID
    func selectMouse(id: String) {
        guard let mouse = discoveredMice.first(where: { $0.id == id }) else {
            log("Mouse \(id) not found")
            return
        }

        // Deactivate current mouse if different
        if let currentID = selectedMouseID, currentID != id {
            deactivateCurrentMouse()
        }

        // Activate the new mouse (all interfaces)
        activateMouse(mouse)
    }

    /// Deselect the current mouse (stop receiving input)
    func deselectMouse() {
        selectedMouseID = nil
        preferredMouseID = nil
        deactivateCurrentMouse()
    }

    private func activateMouse(_ mouse: DiscoveredG502X) {
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
            let buffer = InterfaceBuffer(size: bufferSize, deviceID: deviceID, usagePage: usagePage, usage: usage)
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

        self.selectedMouseID = mouse.id
        self.mouseName = mouse.name
        self.isConnected = !activeInterfaces.isEmpty

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
        let name = self.mouseName
        let mouseID = self.selectedMouseID
        DispatchQueue.main.async {
            self.onConnectionChange?(true, name, mouseID)
        }
    }

    private func deactivateCurrentMouse() {
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

        isConnected = false
        let name = mouseName
        let mouseID = selectedMouseID
        mouseName = nil

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

        DispatchQueue.main.async {
            self.onConnectionChange?(false, name, mouseID)
        }
    }

    // MARK: - Device Callbacks

    private func handleDeviceConnected(_ device: IOHIDDevice) {
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

        // Check if this mouse already exists
        if let index = discoveredMice.firstIndex(where: { $0.id == uniqueID }) {
            // Add this interface to existing mouse
            if !discoveredMice[index].interfaces.contains(where: { $0 == device }) {
                discoveredMice[index].interfaces.append(device)
                log("Added interface to existing mouse: \(name) (now \(discoveredMice[index].interfaces.count) interfaces)")
            }
        } else {
            // New mouse - create entry
            let mouse = DiscoveredG502X(
                id: uniqueID,
                name: name,
                productID: productID,
                interfaces: [device]
            )
            discoveredMice.append(mouse)
            log("G502X mouse discovered: \(name)")

            DispatchQueue.main.async {
                self.onControllersChanged?()
            }
        }

        // Auto-select if this was previously selected
        if let mouse = discoveredMice.first(where: { $0.id == uniqueID }) {
            if selectedMouseID == uniqueID {
                // Already selected, but new interface - activate it too
                if !activeInterfaces.contains(where: { $0 == device }) {
                    activateInterface(device, for: mouse)
                }
            } else if selectedMouseID == nil && preferredMouseID == uniqueID {
                activateMouse(mouse)
            }
        }
    }

    /// Activate a single additional interface for an already-selected mouse
    private func activateInterface(_ device: IOHIDDevice, for mouse: DiscoveredG502X) {
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
        let buffer = InterfaceBuffer(size: bufferSize, deviceID: deviceID, usagePage: usagePage, usage: usage)
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

    private func handleDeviceDisconnected(_ device: IOHIDDevice) {
        // Find which mouse this interface belongs to
        for i in discoveredMice.indices {
            if let interfaceIndex = discoveredMice[i].interfaces.firstIndex(where: { $0 == device }) {
                let mouse = discoveredMice[i]
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

                // Remove interface from mouse
                discoveredMice[i].interfaces.remove(at: interfaceIndex)

                // If no more interfaces, remove the mouse entirely
                if discoveredMice[i].interfaces.isEmpty {
                    log("G502X mouse disconnected: \(mouse.name)")
                    discoveredMice.remove(at: i)

                    DispatchQueue.main.async {
                        self.onControllersChanged?()
                    }

                    // If this was the active mouse, deactivate
                    if mouse.id == selectedMouseID {
                        isConnected = false
                        mouseName = nil
                        DispatchQueue.main.async {
                            self.onConnectionChange?(false, mouse.name, mouse.id)
                        }
                    }
                } else if mouse.id == selectedMouseID && activeInterfaces.isEmpty {
                    // All active interfaces gone but mouse still has interfaces
                    isConnected = false
                }

                return
            }
        }
    }

    // MARK: - HID++ setup

    private func teardownHIDPPButtonReporting() {
        let (device, spyIdx, spyActive, onboardIdx, restoreMode, devNumber): (IOHIDDevice?, UInt8?, Bool, UInt8?, UInt8?, UInt8) = hidppLock.withLock {
            return (
                hidppDevice,
                mouseButtonSpyFeatureIndex,
                mouseButtonSpyActive,
                onboardProfilesFeatureIndex,
                onboardProfilesRestoreMode,
                hidppDeviceNumber
            )
        }

        guard let device else { return }

        // Stop MouseButtonSpy if we started it.
        if let spyIdx, spyActive {
            sendHIDPPRequest(reportID: 0x10, deviceNumber: devNumber, featureIndex: spyIdx, function: 0x20, params: [], on: device)
        }

        // Restore OnboardProfiles mode if we changed it.
        if let onboardIdx, let restoreMode {
            sendHIDPPRequest(reportID: 0x10, deviceNumber: devNumber, featureIndex: onboardIdx, function: 0x10, params: [restoreMode], on: device)
        }
    }

    /// Configure the mouse so we can observe all physical button presses/releases.
    ///
    /// For G502X via Lightspeed receiver, G9 defaults to switching on-board profiles (HID++ 0x8100),
    /// which produces profile-change events instead of a button down/up. BetterMouse-style behavior is:
    /// 1) Switch OnboardProfiles to Host mode (disable on-board mode)
    /// 2) Start MouseButtonSpy (HID++ 0x8110) which reports a 16-bit pressed-bitfield
    private func setupHIDPPDivertedButtons() {
        let (device, initialDevNumber) = hidppLock.withLock { (hidppDevice, hidppDeviceNumber) }
        guard let device else { return }

        var devNumbersToTry: [UInt8] = []
        for dev in [initialDevNumber, 0x01, 0xFF] where !devNumbersToTry.contains(dev) {
            devNumbersToTry.append(dev)
        }

        // 1) Enumerate HID++ features via FEATURE_SET so we can find vendor gaming features (0x8100/0x8110).
        var devNumberUsed: UInt8?
        var features: [UInt16: UInt8] = [:]

        for dev in devNumbersToTry {
            if let mapping = enumerateHIDPPFeatures(deviceNumber: dev, on: device) {
                features = mapping
                devNumberUsed = dev
                break
            }
        }

        if let devNumberUsed {
            hidppLock.withLock {
                hidppDeviceNumber = devNumberUsed
            }
        }

        let onboardIdx = features[Self.hidppFeatureIDOnboardProfiles]
        let spyIdx = features[Self.hidppFeatureIDMouseButtonSpy]

        let featuresSnapshot = features
        hidppLock.withLock {
            featureIndexByFeatureID = featuresSnapshot
            onboardProfilesFeatureIndex = onboardIdx
            mouseButtonSpyFeatureIndex = spyIdx
        }

        let activeDevNumberForLog = hidppLock.withLock { hidppDeviceNumber }
        if onboardIdx != nil || spyIdx != nil {
            let onboardStr = onboardIdx.map { String(format: "0x%02X", $0) } ?? "n/a"
            let spyStr = spyIdx.map { String(format: "0x%02X", $0) } ?? "n/a"
            log("HID++: features: OnboardProfiles=\(onboardStr) MouseButtonSpy=\(spyStr) dev=0x\(String(format: "%02X", activeDevNumberForLog))")
        }

        // 2) Switch OnboardProfiles to Host mode (2) so G9 becomes a button, not a profile switch.
        if let onboardIdx {
            // GetMode: function 2 -> 0x20
            if let modePayload = performHIDPPRequest(featureIndex: onboardIdx, function: 0x20, params: [], on: device),
               let mode = modePayload.first {
                if mode != 0x02 {
                    hidppLock.withLock {
                        onboardProfilesRestoreMode = mode
                    }
                    _ = performHIDPPRequest(featureIndex: onboardIdx, function: 0x10, params: [0x02], on: device)
                    log("HID++: OnboardProfiles mode \(mode) -> Host (2)")
                } else {
                    log("HID++: OnboardProfiles already Host mode")
                }
            } else {
                log("HID++: failed to read OnboardProfiles mode")
            }
        }

        // 3) Start MouseButtonSpy which reports a 16-bit pressed-bitfield (event0).
        if let spyIdx {
            let buttonCount: Int = {
                if let countPayload = performHIDPPRequest(featureIndex: spyIdx, function: 0x00, params: [], on: device),
                   let countByte = countPayload.first {
                    return Int(countByte)
                }
                return 0
            }()
            hidppLock.withLock { mouseButtonSpyButtonCount = buttonCount }
            _ = performHIDPPRequest(featureIndex: spyIdx, function: 0x10, params: [], on: device)
            hidppLock.withLock { mouseButtonSpyActive = true }
            log("HID++: MouseButtonSpy started (buttons=\(buttonCount))")
            return
        }

        // 4) Fallback: REPROG_CONTROLS_V4 (0x1B04) for devices that expose it.
        // G502X via Lightspeed does not expose 0x1B04, but some Logitech devices do.
        var reprogIndex: UInt8?
        var reprogDevNumber: UInt8?
        for dev in devNumbersToTry {
            if let idx = requestRootFeatureIndex(featureID: 0x1B04, deviceNumber: dev, on: device), idx != 0 {
                reprogIndex = idx
                reprogDevNumber = dev
                break
            }
        }

        guard let reprogIndex, let reprogDevNumber else {
            return
        }

        hidppLock.withLock {
            hidppDeviceNumber = reprogDevNumber
            reprogControlsFeatureIndex = reprogIndex
        }
        log("HID++: REPROG_CONTROLS_V4 index=0x\(String(format: "%02X", reprogIndex)) dev=0x\(String(format: "%02X", reprogDevNumber))")

        // Get count of reprogrammable controls
        guard let countPayload = performHIDPPRequest(featureIndex: reprogIndex, function: 0x00, params: [], on: device),
              let countByte = countPayload.first else {
            log("HID++: failed to read control count")
            return
        }

        let count = Int(countByte)
        if count == 0 {
            log("HID++: control count is 0")
            return
        }

        var cids: [UInt16] = []
        cids.reserveCapacity(count)

        // Enumerate controls and collect CIDs
        for index in 0..<count {
            if let keyPayload = performHIDPPRequest(featureIndex: reprogIndex, function: 0x10, params: [UInt8(index)], on: device),
               keyPayload.count >= 2 {
                let cid = (UInt16(keyPayload[0]) << 8) | UInt16(keyPayload[1])
                if cid != 0 {
                    cids.append(cid)
                }
            }
        }

        knownCIDs = cids
        if !cids.isEmpty {
            let list = cids.map { String(format: "0x%04X", $0) }.joined(separator: ", ")
            log("HID++: discovered CIDs: [\(list)]")
        }

        // Divert all controls so notifications include down/up state.
        // HID++ expects a bitfield with “valid” bits; Solaar sets:
        //  - DIVERTED => 0x01 + 0x02 = 0x03
        //  - PERSISTENTLY_DIVERTED => 0x04 + 0x08 = 0x0C
        // Some devices don’t support persistent diversion, so we apply DIVERTED first,
        // then try to upgrade to persistent.
        let divertedFlags: UInt8 = 0x03
        let persistentFlags: UInt8 = 0x0C

        for cid in cids {
            let hi = UInt8((cid >> 8) & 0xFF)
            let lo = UInt8(cid & 0xFF)

            let divertPkt: [UInt8] = [hi, lo, divertedFlags, 0x00, 0x00]
            sendHIDPPNoReply(featureIndex: reprogIndex, function: 0x30, params: divertPkt, on: device)

            let persistPkt: [UInt8] = [hi, lo, persistentFlags, 0x00, 0x00]
            sendHIDPPNoReply(featureIndex: reprogIndex, function: 0x30, params: persistPkt, on: device)
        }
    }

    private func enumerateHIDPPFeatures(deviceNumber: UInt8, on device: IOHIDDevice) -> [UInt16: UInt8]? {
        guard let featureSetIndex = requestRootFeatureIndex(featureID: Self.hidppFeatureIDFeatureSet, deviceNumber: deviceNumber, on: device),
              featureSetIndex != 0 else {
            return nil
        }

        guard let countPayload = performHIDPPRequest(
            deviceNumber: deviceNumber,
            featureIndex: featureSetIndex,
            function: 0x00,
            params: [],
            timeout: 0.8,
            on: device
        ),
        let countByte = countPayload.first else {
            return nil
        }

        // Solaar: ROOT not included in count.
        let count = min(Int(countByte) + 1, 64)
        var mapping: [UInt16: UInt8] = [:]
        mapping[Self.hidppFeatureIDFeatureSet] = featureSetIndex

        for featureIndex in 1..<count {
            if let info = performHIDPPRequest(
                deviceNumber: deviceNumber,
                featureIndex: featureSetIndex,
                function: 0x10,
                params: [UInt8(featureIndex)],
                timeout: 0.8,
                on: device
            ),
            info.count >= 2 {
                let featureID = (UInt16(info[0]) << 8) | UInt16(info[1])
                mapping[featureID] = UInt8(featureIndex)
            }
        }

        return mapping
    }

    private func requestRootFeatureIndex(featureID: UInt16, deviceNumber: UInt8, on device: IOHIDDevice) -> UInt8? {
        let params = [UInt8((featureID >> 8) & 0xFF), UInt8(featureID & 0xFF)]
        guard let payload = performHIDPPRequest(
            reportID: 0x10,
            deviceNumber: deviceNumber,
            featureIndex: 0x00,
            function: 0x00,
            params: params,
            on: device
        ) else {
            return nil
        }
        return payload.first
    }

    /// Perform a HID++ request and synchronously wait for the matching response.
    /// Returns payload bytes (starting at byte 4 of the report).
    private func performHIDPPRequest(
        reportID: UInt8? = nil,
        deviceNumber: UInt8? = nil,
        featureIndex: UInt8,
        function: UInt8,
        params: [UInt8],
        timeout: TimeInterval = 0.5,
        on device: IOHIDDevice
    ) -> [UInt8]? {
        let reportIDToUse: UInt8 = reportID ?? (params.count <= 3 ? 0x10 : 0x11)

        let semaphore = DispatchSemaphore(value: 0)
        let devNumber: UInt8 = hidppLock.withLock {
            let dev = deviceNumber ?? hidppDeviceNumber
            pendingHIDPPRequest = PendingHIDPPRequest(
                featureIndex: featureIndex,
                functionHighNibble: function & 0xF0,
                semaphore: semaphore,
                response: nil
            )
            return dev
        }

        sendHIDPPRequest(reportID: reportIDToUse, deviceNumber: devNumber, featureIndex: featureIndex, function: function, params: params, on: device)

        _ = semaphore.wait(timeout: .now() + timeout)

        let response: [UInt8]? = hidppLock.withLock {
            let resp = pendingHIDPPRequest?.response
            pendingHIDPPRequest = nil
            return resp
        }

        guard let response, response.count >= 4 else { return nil }
        let payloadStart = 4
        let payload = Array(response.dropFirst(payloadStart))
        return payload
    }

    private func sendHIDPPNoReply(featureIndex: UInt8, function: UInt8, params: [UInt8], on device: IOHIDDevice) {
        let reportID: UInt8 = params.count <= 3 ? 0x10 : 0x11
        let devNumber = hidppLock.withLock { hidppDeviceNumber }
        sendHIDPPRequest(reportID: reportID, deviceNumber: devNumber, featureIndex: featureIndex, function: function, params: params, on: device)
    }

    private func sendHIDPPRequest(
        reportID: UInt8,
        deviceNumber: UInt8,
        featureIndex: UInt8,
        function: UInt8,
        params: [UInt8],
        on device: IOHIDDevice
    ) {
        let totalLength = reportID == 0x10 ? 7 : 20
        var report = [UInt8](repeating: 0, count: totalLength)
        report[0] = reportID
        report[1] = deviceNumber
        report[2] = featureIndex
        report[3] = (function & 0xF0) | Self.hidppSoftwareID
        for (i, b) in params.enumerated() where (4 + i) < totalLength {
            report[4 + i] = b
        }

        // HID++ over USB is typically carried on Feature reports (0x10/0x11).
        // Some receivers accept Output reports; try Feature first, then fallback.
        let featureResult = report.withUnsafeMutableBytes { ptr -> IOReturn in
            guard let base = ptr.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return kIOReturnError }
            return IOHIDDeviceSetReport(device, kIOHIDReportTypeFeature, CFIndex(reportID), base, CFIndex(ptr.count))
        }

        if featureResult != kIOReturnSuccess {
            let outputResult = report.withUnsafeMutableBytes { ptr -> IOReturn in
                guard let base = ptr.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return kIOReturnError }
                return IOHIDDeviceSetReport(device, kIOHIDReportTypeOutput, CFIndex(reportID), base, CFIndex(ptr.count))
            }

            if outputResult != kIOReturnSuccess {
                log("HID++ write failed id=0x\(String(format: "%02X", reportID)) feat=0x\(String(format: "%02X", featureIndex)) fn=0x\(String(format: "%02X", function)) featureErr=\(featureResult) outputErr=\(outputResult)")
            }
        }
    }

    private func logicalButton(forCID cid: UInt16) -> G502XLogicalButton? {
        if let mapped = cidToLogicalButton[cid] { return mapped }

        // Seed some common CIDs (from Logitech HID++ control list) on demand.
        // These IDs are stable across many mice.
        let seeded: [UInt16: G502XLogicalButton] = [
            0x0050: .left,
            0x0051: .right,
            0x0052: .middle,
            0x0053: .back,
            0x0056: .forward,
            0x005B: .scrollTiltLeft,
            0x005D: .scrollTiltRight,
        ]
        if let seed = seeded[cid] {
            cidToLogicalButton[cid] = seed
            return seed
        }

        // Assign remaining unknown CIDs in a deterministic order to discoverable buttons.
        let candidates: [G502XLogicalButton] = [.g9, .dpiUp, .dpiDown, .dpiShift, .scrollTiltLeft, .scrollTiltRight]
        if let next = candidates.first(where: { !cidToLogicalButton.values.contains($0) }) {
            cidToLogicalButton[cid] = next
            log("HID++: mapped CID 0x\(String(format: "%04X", cid)) -> \(next.displayName)")
            return next
        }

        return nil
    }

    // MARK: - Input Report Processing

    private func handleInputReport(report: UnsafeMutablePointer<UInt8>, length: Int, reportID: UInt32) {
        let now = Date()
        let timestamp = CACurrentMediaTime()

        // Look up which interface sent this report using the buffer pointer
        guard let deviceID = bufferPointerToDeviceID[report],
              let buffer = interfaceBuffers[deviceID] else {
            return
        }

        // Update this interface's stored bytes + per-byte change tracking
        buffer.update(from: report, length: length, at: now)
        let copyLength = buffer.lastLength

        // Log first 5 reports from each interface for debugging
        buffer.reportCount += 1
        if buffer.reportCount <= 5 {
            let bytesHex = (0..<min(8, copyLength)).map { String(format: "%02X", buffer.bytes[$0]) }.joined(separator: " ")
            log("Report #\(buffer.reportCount) id=0x\(String(format: "%02X", reportID)) from UsagePage=0x\(String(format: "%04X", buffer.usagePage)) Usage=0x\(String(format: "%04X", buffer.usage)): [\(bytesHex)...]")
        }

        // Update cached interface info for debug UI (thread-safe), throttled to reduce overhead.
        if timestamp - lastInterfaceInfoUpdate > (1.0 / 30.0) {
            updateCachedInterfaceInfo()
            lastInterfaceInfoUpdate = timestamp
        }

        // Only forward unified button reports from relevant interfaces (vendor + standard mouse).
        let isVendor = buffer.usagePage >= 0xFF00
        let isStandardMouse = buffer.usagePage == 0x0001 && buffer.usage == 0x0002
        guard isVendor || isStandardMouse else { return }

        if isVendor, copyLength >= 4 {
            let rid = buffer.bytes[0]

            // HID++ short/long messages (0x10/0x11) from the Lightspeed receiver.
            if rid == 0x10 || rid == 0x11 {
                let devNumber = buffer.bytes[1]
                let featureIndex = buffer.bytes[2]
                let function = buffer.bytes[3]
                let functionHigh = function & 0xF0

                // Match pending HID++ request (used during setup) and snapshot feature indexes.
                let (spyIdx, onboardIdx, reprogIdx): (UInt8?, UInt8?, UInt8?) = hidppLock.withLock {
                    hidppDeviceNumber = devNumber

                    let spy = mouseButtonSpyFeatureIndex
                    let onboard = onboardProfilesFeatureIndex
                    let reprog = reprogControlsFeatureIndex

                    if var pending = pendingHIDPPRequest,
                       pending.featureIndex == featureIndex,
                       pending.functionHighNibble == functionHigh {
                        var resp: [UInt8] = []
                        resp.reserveCapacity(copyLength)
                        for i in 0..<copyLength { resp.append(buffer.bytes[i]) }
                        pending.response = resp
                        pendingHIDPPRequest = pending
                        pending.semaphore.signal()
                    }

                    return (spy, onboard, reprog)
                }

                // MouseButtonSpy (0x8110) event0: pressed buttons bitfield (big-endian u16)
                if let spyIdx,
                   featureIndex == spyIdx,
                   functionHigh == 0x00,
                   copyLength >= 6 {
                    let bits = (UInt16(buffer.bytes[4]) << 8) | UInt16(buffer.bytes[5])
                    let previousBits: UInt16 = hidppLock.withLock {
                        let prev = lastMouseButtonSpyBits
                        lastMouseButtonSpyBits = bits
                        return prev
                    }
                    if previousBits != bits {
                        log("HID++: MouseButtonSpy bits=0x\(String(format: "%04X", bits))")
                    }
                    applyMouseButtonSpyBits(bits)
                    emitUnifiedReport(timestamp: timestamp)
                    return
                }

                // OnboardProfiles (0x8100) event0: currentProfileChanged (memoryType, profileIndex)
                if let onboardIdx,
                   featureIndex == onboardIdx,
                   functionHigh == 0x00,
                   copyLength >= 6 {
                    let memType = buffer.bytes[4]
                    let profileIndex = buffer.bytes[5]
                    log("HID++: profile changed mem=\(memType) index=\(profileIndex)")
                    // Not a physical button down/up event.
                    return
                }

                // Reprogrammable-controls notification: payload[0..7] contains up to 4 pressed CIDs.
                if let reprogIndex = reprogIdx,
                   featureIndex == reprogIndex,
                   functionHigh == 0x00,
                   copyLength >= 12 {
                    var newPressed: Set<UInt16> = []
                    let payloadStart = 4
                    for offset in stride(from: 0, to: 8, by: 2) {
                        let hi = buffer.bytes[payloadStart + offset]
                        let lo = buffer.bytes[payloadStart + offset + 1]
                        let cid = (UInt16(hi) << 8) | UInt16(lo)
                        if cid != 0 { newPressed.insert(cid) }
                    }

                    let pressedNow = newPressed.subtracting(pressedCIDs)
                    let releasedNow = pressedCIDs.subtracting(newPressed)
                    pressedCIDs = newPressed

                    for cid in pressedNow {
                        if let button = logicalButton(forCID: cid) {
                            setStableButton(button, pressed: true)
                        }
                    }
                    for cid in releasedNow {
                        if let button = logicalButton(forCID: cid) {
                            setStableButton(button, pressed: false)
                        }
                    }

                    emitUnifiedReport(timestamp: timestamp)
                }

                // Don't forward raw HID++ frames directly.
                return
            }

            // Legacy vendor bitfield reports (if diversion isn't active).
            if copyLength >= 2 {
                stableButtonBytes[0] = buffer.bytes[0]
                stableButtonBytes[1] = buffer.bytes[1]
                emitUnifiedReport(timestamp: timestamp)
            }
            return
        }

        if isStandardMouse {
            lastStandardMouseReport = Array(buffer.bytes.prefix(copyLength))
            emitUnifiedReport(timestamp: timestamp)
            return
        }
    }

    private func setStableButton(_ button: G502XLogicalButton, pressed: Bool) {
        guard let loc = logicalButtonMapping.buttonLocation(for: button) else { return }
        if loc.byte >= stableButtonBytes.count {
            stableButtonBytes += Array(repeating: 0, count: loc.byte - stableButtonBytes.count + 1)
        }
        let mask = UInt8(1 << loc.bit)
        if pressed {
            stableButtonBytes[loc.byte] |= mask
        } else {
            stableButtonBytes[loc.byte] &= ~mask
        }
    }

    private func applyMouseButtonSpyBits(_ bits: UInt16) {
        // MouseButtonSpy reports a 16-bit bitfield where bit 0 = button 1, bit 1 = button 2, etc.
        // Logitech G HUB numbering matches common mouse buttons:
        //  1=Left, 2=Right, 3=Middle, 4=Back, 5=Forward, 6=DPI Shift, 7=DPI Down, 8=DPI Up, 9=G9, 10/11=Tilts.
        let mapping: [(bit: Int, button: G502XLogicalButton)] = [
            (0, .left),
            (1, .right),
            (2, .middle),
            (3, .back),
            (4, .forward),
            (5, .dpiShift),
            (6, .dpiDown),
            (7, .dpiUp),
            (8, .g9),
            (9, .scrollTiltLeft),
            (10, .scrollTiltRight),
        ]

        for entry in mapping {
            let pressed = (bits & (UInt16(1) << UInt16(entry.bit))) != 0
            setStableButton(entry.button, pressed: pressed)
        }
    }

    private func emitUnifiedReport(timestamp: TimeInterval) {
        if !lastStandardMouseReport.isEmpty {
            var unified = lastStandardMouseReport
            for i in 0..<min(2, unified.count, stableButtonBytes.count) {
                unified[i] |= stableButtonBytes[i]
            }
            onReportData?(InputReport(bytes: unified, length: unified.count, timestamp: timestamp))
        } else {
            onReportData?(InputReport(bytes: stableButtonBytes, length: stableButtonBytes.count, timestamp: timestamp))
        }
    }
}
