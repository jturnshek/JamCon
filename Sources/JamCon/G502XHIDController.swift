import Foundation
import IOKit
import IOKit.hid
import QuartzCore
import os.lock

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

    static let logitechVendorID = G502XHIDProtocol.logitechVendorID
    /// HID++ 2.0 uses the low nibble of the function byte as a software ID.
    /// Solaar/BetterMouse typically use 0x02; using a non‑zero ID improves replies.
    static let hidppSoftwareID: UInt8 = 0x02
    static let hidppFeatureIDFeatureSet: UInt16 = 0x0001
    static let hidppFeatureIDOnboardProfiles: UInt16 = 0x8100
    static let hidppFeatureIDMouseButtonSpy: UInt16 = 0x8110

    // MARK: - Interface Buffer

    /// Class wrapper for report buffers - provides stable memory address for callback identification
    final class InterfaceBuffer {
        private static let debugByteLimit = 64
        var bytes: [UInt8]
        private var previousBytes: [UInt8]
        private(set) var byteLastChanged: [Date]
        private(set) var lastLength: Int = 0
        let maxReportSize: Int
        let deviceID: ObjectIdentifier
        let usagePage: Int
        let usage: Int
        var reportCount: Int = 0

        init(size: Int, maxReportSize: Int, deviceID: ObjectIdentifier, usagePage: Int, usage: Int) {
            self.bytes = [UInt8](repeating: 0, count: size)
            let trackedSize = min(size, Self.debugByteLimit)
            self.previousBytes = [UInt8](repeating: 0, count: trackedSize)
            self.byteLastChanged = Array(repeating: .distantPast, count: trackedSize)
            self.maxReportSize = maxReportSize
            self.deviceID = deviceID
            self.usagePage = usagePage
            self.usage = usage
        }

        func update(from report: UnsafeMutablePointer<UInt8>, length: Int, at now: Date) {
            let copyLength = min(length, bytes.count)
            lastLength = copyLength

            // Only track changes for the first N bytes used by the debug UI.
            let trackedCount = min(copyLength, previousBytes.count)
            for i in 0..<trackedCount {
                let newByte = report[i]
                if newByte != previousBytes[i] {
                    byteLastChanged[i] = now
                    previousBytes[i] = newByte
                }
            }
        }
    }

    /// Check if an interface should be opened
    func shouldOpenInterface(device: IOHIDDevice) -> Bool {
        // For debugging, observe all interfaces that can emit input reports.
        let maxReportSize = IOHIDDeviceGetProperty(device, kIOHIDMaxInputReportSizeKey as CFString) as? Int ?? 0
        return maxReportSize > 0
    }

    // MARK: - Properties

    var hidManager: IOHIDManager?
    var activeInterfaces: [IOHIDDevice] = []  // All open interfaces
    var interfaceBuffers: [ObjectIdentifier: InterfaceBuffer] = [:]  // Per-interface buffer wrappers
    var bufferPointerToDeviceID: [UnsafeMutablePointer<UInt8>: ObjectIdentifier] = [:]  // Buffer ptr -> device lookup
    var hidRunLoop: CFRunLoop?
    var hidThread: Thread?
    let hidRunLoopReady = DispatchSemaphore(value: 0)

    // HID++ (Logitech vendor protocol) support.
    let hidppQueue = DispatchQueue(label: "JamCon.G502X.HIDPP", qos: .userInitiated)
    let hidppLock = OSAllocatedUnfairLock()
    var hidppDevice: IOHIDDevice?
    var hidppDeviceNumber: UInt8 = 0x01
    var featureIndexByFeatureID: [UInt16: UInt8] = [:]
    var onboardProfilesFeatureIndex: UInt8?
    var mouseButtonSpyFeatureIndex: UInt8?
    var mouseButtonSpyButtonCount: Int = 0
    var lastMouseButtonSpyBits: UInt16 = 0
    var mouseButtonSpyActive: Bool = false
    var onboardProfilesRestoreMode: UInt8?

    // Legacy (REPROG_CONTROLS*) support (not present on G502X Lightspeed receiver, but keep for other devices).
    var reprogControlsFeatureIndex: UInt8?
    var knownCIDs: [UInt16] = []
    var pressedCIDs: Set<UInt16> = []
    var cidToLogicalButton: [UInt16: G502XLogicalButton] = [:]
    let logicalButtonMapping = G502XButtonMapping()
    var stableButtonBytes: [UInt8] = [0, 0]  // bytes 0-1 stable button state
    var lastStandardMouseReport: [UInt8] = []

    struct PendingHIDPPRequest {
        let featureIndex: UInt8
        /// Upper nibble of function byte (lower nibble is software ID).
        let functionHighNibble: UInt8
        let semaphore: DispatchSemaphore
        var response: [UInt8]? = nil
    }
    var pendingHIDPPRequest: PendingHIDPPRequest?

    // MARK: - Thread-safe state (read from UI / other threads)

    struct ControllerState {
        var discoveredMice: [DiscoveredG502X] = []
        var selectedMouseID: String?
        var preferredMouseID: String?
        var isConnected: Bool = false
        var mouseName: String?
    }

    struct RuntimeConfigState {
        var interfaceDebugEnabled: Bool = false
    }

    let stateLock = OSAllocatedUnfairLock(initialState: ControllerState())
    let runtimeConfig = LockedRuntimeConfig(initialState: RuntimeConfigState())

    private struct ReportState {
        var lastReportTime: TimeInterval = 0
        var reportCount: UInt64 = 0
    }

    private let reportStateLock = OSAllocatedUnfairLock(initialState: ReportState())

    func recordReportActivity(timestamp: TimeInterval) {
        reportStateLock.withLock { state in
            state.lastReportTime = timestamp
            state.reportCount &+= 1
        }
    }

    func resetReportStats() {
        reportStateLock.withLock { state in
            state.lastReportTime = 0
            state.reportCount = 0
        }
    }

    var lastReportTime: TimeInterval {
        reportStateLock.withLock { $0.lastReportTime }
    }

    var reportCount: UInt64 {
        reportStateLock.withLock { $0.reportCount }
    }

    /// UI-safe snapshot of all discovered G502X mice.
    func mouseInfosSnapshot() -> [ControllerInfo] {
        stateLock.withLock { $0.discoveredMice.map(\.info) }
    }

    /// Map from device to mouse ID for quick lookup
    var deviceToMouseID: [ObjectIdentifier: String] = [:]

    /// Currently selected mouse ID (thread-safe).
    var selectedMouseID: String? {
        stateLock.withLock { $0.selectedMouseID }
    }

    /// Preferred mouse ID (persisted from last user selection). (thread-safe)
    var preferredMouseID: String? {
        get { stateLock.withLock { $0.preferredMouseID } }
        set { stateLock.withLock { $0.preferredMouseID = newValue } }
    }

    /// Input report structure for button data
    struct InputReport {
        let bytes: [UInt8]
        let length: Int
        let timestamp: TimeInterval
        let receivedTimestamp: TimeInterval
    }

    /// Callback for full report data (merged from all interfaces)
    var onReportData: ((_ report: InputReport) -> Void)?

    // MARK: - Callbacks
    //
    // Callback contract:
    // All callbacks are invoked on the controller's HID thread/run loop ("JamCon.G502X.HID").

    /// Callback for connection state changes
    var onConnectionChange: ((_ connected: Bool, _ name: String?, _ mouseID: String?) -> Void)?

    /// Callback when available mice list changes
    var onControllersChanged: (() -> Void)?

    /// Callback for debug/status messages
    var onDebugMessage: ((_ message: String) -> Void)?

    /// Whether a mouse is currently connected and active (thread-safe).
    var isConnected: Bool {
        stateLock.withLock { $0.isConnected }
    }

    /// Name of the connected mouse (thread-safe).
    var mouseName: String? {
        stateLock.withLock { $0.mouseName }
    }

    /// Whether we currently have a vendor-side mechanism that reliably reports button down/up.
    /// When true, we don't need CGEventTap fallback for releases.
    var hasReliableButtonReleaseEvents: Bool {
        hidppLock.withLock { mouseButtonSpyActive || reprogControlsFeatureIndex != nil }
    }

    /// Thread-safe cache for interface info (updated on HID thread, read from main thread)
    let interfaceInfoLock = NSLock()
    var cachedInterfaceInfo: [G502XInterfaceInfo] = []
    var lastInterfaceInfoUpdate: TimeInterval = 0

    /// Get info about all discovered interfaces for the selected mouse (for debug UI)
    /// Thread-safe: returns a cached snapshot
    func getInterfaceInfo() -> [G502XInterfaceInfo] {
        interfaceInfoLock.lock()
        defer { interfaceInfoLock.unlock() }
        return cachedInterfaceInfo
    }

    /// Enable/disable the expensive per-interface debug cache updates.
    /// When disabled, cached snapshots are cleared to free memory and avoid background work.
    func setInterfaceDebugEnabled(_ enabled: Bool) {
        runtimeConfig.update { config in
            config.interfaceDebugEnabled = enabled
        }
        if !enabled {
            interfaceInfoLock.lock()
            cachedInterfaceInfo.removeAll(keepingCapacity: true)
            interfaceInfoLock.unlock()
            lastInterfaceInfoUpdate = 0
        }
    }

    /// Update the cached interface info (call from HID thread after processing reports)
    func updateCachedInterfaceInfo() {
        let selectedMouseSnapshot: DiscoveredG502X? = stateLock.withLock { state in
            guard let mouseID = state.selectedMouseID else { return nil }
            return state.discoveredMice.first(where: { $0.id == mouseID })
        }

        guard let mouse = selectedMouseSnapshot else {
            interfaceInfoLock.lock()
            cachedInterfaceInfo = []
            interfaceInfoLock.unlock()
            return
        }

        let newInfo = mouse.interfaces.enumerated().map { index, device -> G502XInterfaceInfo in
            let usagePage = IOHIDDeviceGetProperty(device, kIOHIDPrimaryUsagePageKey as CFString) as? Int ?? 0
            let usage = IOHIDDeviceGetProperty(device, kIOHIDPrimaryUsageKey as CFString) as? Int ?? 0
            let deviceID = ObjectIdentifier(device)
            let isActive = activeInterfaces.contains(where: { ObjectIdentifier($0) == deviceID })
            let buffer = interfaceBuffers[deviceID]

            let maxReportSize = buffer?.maxReportSize
                ?? (IOHIDDeviceGetProperty(device, kIOHIDMaxInputReportSizeKey as CFString) as? Int ?? 0)

            let snapshotLimit = min(64, buffer?.bytes.count ?? 0)
            let bytesSnapshot: [UInt8]
            let byteLastChangedSnapshot: [Date]
            let reportLength: Int
            if let buffer {
                // IMPORTANT: Deep copy so we don't share storage with the live callback buffer.
                // Sharing would trigger copy-on-write on the next update and invalidate the
                // pointer passed to IOHIDDeviceRegisterInputReportCallback, causing crashes.
                reportLength = buffer.lastLength

                var snapshot = Array(buffer.bytes.prefix(snapshotLimit))
                if reportLength < snapshot.count {
                    for i in reportLength..<snapshot.count {
                        snapshot[i] = 0
                    }
                }
                bytesSnapshot = snapshot

                var changed = Array(buffer.byteLastChanged.prefix(snapshotLimit))
                if changed.count < snapshot.count {
                    changed += Array(repeating: .distantPast, count: snapshot.count - changed.count)
                }
                if reportLength < changed.count {
                    for i in reportLength..<changed.count {
                        changed[i] = .distantPast
                    }
                }
                byteLastChangedSnapshot = changed
            } else {
                bytesSnapshot = []
                byteLastChangedSnapshot = []
                reportLength = 0
            }

            return G502XInterfaceInfo(
                id: "\(index)-\(usagePage)-\(usage)",
                usagePage: usagePage,
                usage: usage,
                maxReportSize: maxReportSize,
                isActive: isActive,
                reportCount: buffer?.reportCount ?? 0,
                lastReportBytes: bytesSnapshot,
                reportLength: reportLength,
                byteLastChanged: byteLastChangedSnapshot
            )
        }

        interfaceInfoLock.lock()
        cachedInterfaceInfo = newInfo
        interfaceInfoLock.unlock()
    }

    // MARK: - Initialization

    init() {}

    func dispatchToHIDThread(_ work: @escaping () -> Void) {
        if Thread.current == hidThread {
            work()
            return
        }

        guard let runLoop = hidRunLoop else {
            work()
            return
        }

        CFRunLoopPerformBlock(runLoop, CFRunLoopMode.defaultMode.rawValue, work)
        CFRunLoopWakeUp(runLoop)
    }

    func performHIDOperation(_ work: @escaping () -> Void) {
        if Thread.current == hidThread {
            work()
            return
        }

        guard let runLoop = hidRunLoop else {
            // If the HID thread isn't running yet, don't perform IOKit operations on an arbitrary thread.
            return
        }

        CFRunLoopPerformBlock(runLoop, CFRunLoopMode.defaultMode.rawValue, work)
        CFRunLoopWakeUp(runLoop)
    }

    func log(_ message: String) {
        JamLog.info(.g502x, message)
    }

    deinit {
        stop()
    }

    // MARK: - Public Methods

    func start() {
        startHIDThreadIfNeeded()
    }

    func startHIDThreadIfNeeded() {
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

    func runHIDThread() {
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

    func configureHIDManager(on runLoop: CFRunLoop) {
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
            deviceToMouseID.removeAll()
            stateLock.withLock { state in
                state.discoveredMice.removeAll(keepingCapacity: true)
                state.selectedMouseID = nil
                state.isConnected = false
                state.mouseName = nil
            }
            resetReportStats()
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

            self.deviceToMouseID.removeAll()
            self.stateLock.withLock { state in
                state.discoveredMice.removeAll(keepingCapacity: true)
                state.selectedMouseID = nil
                state.isConnected = false
                state.mouseName = nil
            }
            self.resetReportStats()

            CFRunLoopStop(runLoop)
        }

        CFRunLoopWakeUp(runLoop)
    }

}
