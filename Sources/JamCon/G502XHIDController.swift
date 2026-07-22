import Foundation
import QuartzCore
import os.lock

struct G502XInterface: Equatable, Sendable {
    let device: any HIDDeviceHandle
    let properties: G502XHIDInterfaceProperties

    static func == (lhs: G502XInterface, rhs: G502XInterface) -> Bool {
        lhs.device.transportIdentifier == rhs.device.transportIdentifier
    }
}

/// A physical mouse may expose several HID interfaces with the same stable ID.
struct DiscoveredG502X: Identifiable, Equatable, Sendable {
    let id: String
    let name: String
    let productID: Int
    var interfaces: [G502XInterface]

    var info: ControllerInfo {
        ControllerInfo(id: id, name: name, productID: productID, kind: .mouse)
    }

    static func == (lhs: DiscoveredG502X, rhs: DiscoveredG502X) -> Bool {
        lhs.id == rhs.id
    }
}

struct G502XInterfaceInfo: Identifiable, Sendable {
    let id: String
    let usagePage: Int
    let usage: Int
    let maxReportSize: Int
    let isActive: Bool
    var reportCount: Int
    var lastReportBytes: [UInt8]
    let reportLength: Int
    let byteLastChanged: [Date]

    var usagePageHex: String { String(format: "0x%04X", usagePage) }
    var usageHex: String { String(format: "0x%04X", usage) }

    var interfaceType: String {
        if usagePage >= 0xFF00 {
            return "Vendor"
        } else if usagePage == 0x0001 && usage == 0x0002 {
            return "Mouse"
        } else if usagePage == 0x0001 && usage == 0x0006 {
            return "Keyboard"
        }
        return "Unknown"
    }
}

/// Logitech multi-interface lifecycle and HID++ policy. Raw IOKit values and
/// callback buffers are owned by the injected transport.
final class G502XHIDController: @unchecked Sendable {
    static let logitechVendorID = G502XHIDProtocol.logitechVendorID
    static let hidppSoftwareID: UInt8 = 0x02
    static let hidppFeatureIDFeatureSet: UInt16 = 0x0001
    static let hidppFeatureIDOnboardProfiles: UInt16 = 0x8100
    static let hidppFeatureIDMouseButtonSpy: UInt16 = 0x8110
    static let deactivationRetentionSeconds: TimeInterval = 30

    enum LifecycleState {
        case stopped
        case starting(Thread)
        case running(thread: Thread, runLoop: CFRunLoop)
        case stopping(thread: Thread, runLoop: CFRunLoop)
    }

    final class InterfaceBuffer: @unchecked Sendable {
        private static let debugByteLimit = 64
        private(set) var bytes: [UInt8]
        private var previousBytes: [UInt8]
        private(set) var byteLastChanged: [Date]
        private(set) var lastLength = 0
        let maxReportSize: Int
        let usagePage: Int
        let usage: Int
        var reportCount = 0

        init(size: Int, maxReportSize: Int, usagePage: Int, usage: Int) {
            bytes = [UInt8](repeating: 0, count: size)
            let trackedSize = min(size, Self.debugByteLimit)
            previousBytes = [UInt8](repeating: 0, count: trackedSize)
            byteLastChanged = Array(repeating: .distantPast, count: trackedSize)
            self.maxReportSize = maxReportSize
            self.usagePage = usagePage
            self.usage = usage
        }

        func update(from report: UnsafeMutablePointer<UInt8>, length: Int, at now: Date) {
            let copyLength = min(max(0, length), bytes.count)
            lastLength = copyLength
            for index in 0..<copyLength {
                let newByte = report[index]
                bytes[index] = newByte
                if index < previousBytes.count, newByte != previousBytes[index] {
                    byteLastChanged[index] = now
                    previousBytes[index] = newByte
                }
            }
        }
    }

    final class ActiveInterface: @unchecked Sendable {
        let interface: G502XInterface
        let registration: any HIDInputRegistration
        let buffer: InterfaceBuffer

        init(
            interface: G502XInterface,
            registration: any HIDInputRegistration,
            buffer: InterfaceBuffer
        ) {
            self.interface = interface
            self.registration = registration
            self.buffer = buffer
        }
    }

    struct RetiredInterface: Sendable {
        let interface: ActiveInterface
        let retiredAt: TimeInterval
    }

    struct PendingHIDPPRequest: @unchecked Sendable {
        let requestID: UInt64
        let featureIndex: UInt8
        let functionHighNibble: UInt8
        let semaphore: DispatchSemaphore
        var response: [UInt8]?
    }

    struct ControllerState: Sendable {
        var discoveredMice: [DiscoveredG502X] = []
        /// Desired selection; retained through transport stop/start and disconnect.
        var selectedMouseID: String?
        var activeMouseID: String?
        var isConnected = false
        var mouseName: String?
    }

    struct RuntimeConfigState: Sendable {
        var interfaceDebugEnabled = false
    }

    struct ReportState: Sendable {
        var lastReportTime: TimeInterval = 0
        var reportCount: UInt64 = 0
    }

    let lifecycleCondition = NSCondition()
    var lifecycleState: LifecycleState = .stopped
    let transport: any G502XHIDTransport

    let stateLock = OSAllocatedUnfairLock(initialState: ControllerState())
    let runtimeConfig = LockedRuntimeConfig(initialState: RuntimeConfigState())
    private let reportStateLock = OSAllocatedUnfairLock(initialState: ReportState())

    /// HID-thread-owned active and recently retired input registrations.
    var activeInterfaces: [ObjectIdentifier: ActiveInterface] = [:]
    var retiredInterfaces: [RetiredInterface] = []
    var lastInterfaceInfoUpdate: TimeInterval = 0

    let hidppQueue = DispatchQueue(label: "JamCon.G502X.HIDPP", qos: .userInitiated)
    let hidppLock = OSAllocatedUnfairLock()
    var hidppDevice: (any HIDDeviceHandle)?
    var hidppDeviceNumber: UInt8 = 0x01
    var featureIndexByFeatureID: [UInt16: UInt8] = [:]
    var onboardProfilesFeatureIndex: UInt8?
    var mouseButtonSpyFeatureIndex: UInt8?
    var mouseButtonSpyButtonCount = 0
    var lastMouseButtonSpyBits: UInt16 = 0
    var mouseButtonSpyActive = false
    var onboardProfilesRestoreMode: UInt8?
    var reprogControlsFeatureIndex: UInt8?
    var knownCIDs: [UInt16] = []
    var pressedCIDs: Set<UInt16> = []
    var cidToLogicalButton: [UInt16: G502XLogicalButton] = [:]
    let logicalButtonMapping = G502XButtonMapping()
    var stableButtonBytes: [UInt8] = [0, 0]
    var lastStandardMouseReport: [UInt8] = []
    var pendingHIDPPRequest: PendingHIDPPRequest?
    var hidppRequestSequence: UInt64 = 0
    var hidppGeneration: UInt64 = 0
    var hidppSetupInFlight = false

    let interfaceInfoLock = NSLock()
    var cachedInterfaceInfo: [G502XInterfaceInfo] = []

    struct InputReport: Sendable {
        let bytes: [UInt8]
        let length: Int
        let timestamp: TimeInterval
        let receivedTimestamp: TimeInterval
        let inputTimestamp: TimeInterval?
        let timestampSource: InputTimestampSource
    }

    // Set before start and invoked from the dedicated HID thread.
    var onReportData: (@Sendable (_ report: InputReport) -> Void)?
    var onConnectionChange: (@Sendable (_ connected: Bool, _ name: String?, _ mouseID: String?) -> Void)?
    var onControllersChanged: (@Sendable () -> Void)?
    var onDebugMessage: (@Sendable (_ message: String) -> Void)?

    init(transport: any G502XHIDTransport = IOKitG502XHIDTransport()) {
        self.transport = transport
    }

    deinit {
        stop()
    }

    func mouseInfosSnapshot() -> [ControllerInfo] {
        stateLock.withLock { $0.discoveredMice.map(\.info) }
    }

    var selectedMouseID: String? {
        stateLock.withLock { $0.selectedMouseID }
    }

    var isConnected: Bool {
        stateLock.withLock { $0.isConnected }
    }

    var mouseName: String? {
        stateLock.withLock { $0.mouseName }
    }

    var hasReliableButtonReleaseEvents: Bool {
        hidppLock.withLock { mouseButtonSpyActive || reprogControlsFeatureIndex != nil }
    }

    var lastReportTime: TimeInterval {
        reportStateLock.withLock { $0.lastReportTime }
    }

    var reportCount: UInt64 {
        reportStateLock.withLock { $0.reportCount }
    }

    func recordReportActivity(timestamp: TimeInterval) {
        reportStateLock.withLock {
            $0.lastReportTime = timestamp
            $0.reportCount &+= 1
        }
    }

    func resetReportStats() {
        reportStateLock.withLock {
            $0.lastReportTime = 0
            $0.reportCount = 0
        }
    }

    func getInterfaceInfo() -> [G502XInterfaceInfo] {
        interfaceInfoLock.lock()
        defer { interfaceInfoLock.unlock() }
        return cachedInterfaceInfo
    }

    func setInterfaceDebugEnabled(_ enabled: Bool) {
        runtimeConfig.update { $0.interfaceDebugEnabled = enabled }
        if !enabled {
            interfaceInfoLock.lock()
            cachedInterfaceInfo.removeAll(keepingCapacity: true)
            interfaceInfoLock.unlock()
        }
    }

    func updateCachedInterfaceInfo() {
        assertOnHIDThread()
        let selectedMouse: DiscoveredG502X? = stateLock.withLock { state in
            guard let mouseID = state.selectedMouseID else { return nil }
            return state.discoveredMice.first(where: { $0.id == mouseID })
        }

        guard let selectedMouse else {
            interfaceInfoLock.lock()
            cachedInterfaceInfo = []
            interfaceInfoLock.unlock()
            return
        }

        let newInfo = selectedMouse.interfaces.enumerated().map { index, interface in
            let identifier = interface.device.transportIdentifier
            let active = activeInterfaces[identifier]
            let buffer = active?.buffer
            let snapshotLimit = min(64, buffer?.bytes.count ?? 0)
            var bytes = Array(buffer?.bytes.prefix(snapshotLimit) ?? [])
            var changed = Array(buffer?.byteLastChanged.prefix(snapshotLimit) ?? [])
            let reportLength = buffer?.lastLength ?? 0
            if reportLength < bytes.count {
                for index in reportLength..<bytes.count { bytes[index] = 0 }
            }
            if changed.count < bytes.count {
                changed += Array(repeating: .distantPast, count: bytes.count - changed.count)
            }
            if reportLength < changed.count {
                for index in reportLength..<changed.count { changed[index] = .distantPast }
            }
            let properties = interface.properties
            return G502XInterfaceInfo(
                id: "\(index)-\(properties.usagePage)-\(properties.usage)",
                usagePage: properties.usagePage,
                usage: properties.usage,
                maxReportSize: properties.maximumInputReportSize,
                isActive: active != nil,
                reportCount: buffer?.reportCount ?? 0,
                lastReportBytes: bytes,
                reportLength: reportLength,
                byteLastChanged: changed
            )
        }

        interfaceInfoLock.lock()
        cachedInterfaceInfo = newInfo
        interfaceInfoLock.unlock()
    }

    func performHIDOperation(_ work: @escaping @Sendable () -> Void) {
        lifecycleCondition.lock()
        let target: (thread: Thread, runLoop: CFRunLoop)?
        if case let .running(thread, runLoop) = lifecycleState {
            target = (thread, runLoop)
        } else {
            target = nil
        }
        lifecycleCondition.unlock()

        guard let target else { return }
        if Thread.current === target.thread {
            work()
            return
        }
        CFRunLoopPerformBlock(target.runLoop, CFRunLoopMode.defaultMode.rawValue, work)
        CFRunLoopWakeUp(target.runLoop)
    }

    func assertOnHIDThread(file: StaticString = #fileID, line: UInt = #line) {
        lifecycleCondition.lock()
        let thread: Thread?
        switch lifecycleState {
        case let .starting(candidate), let .running(candidate, _), let .stopping(candidate, _):
            thread = candidate
        case .stopped:
            thread = nil
        }
        lifecycleCondition.unlock()
        assert(
            Thread.current === thread,
            "G502XHIDController operation must run on the HID thread",
            file: file,
            line: line
        )
    }

    var isHIDBackendRunning: Bool {
        lifecycleCondition.lock()
        defer { lifecycleCondition.unlock() }
        if case .running = lifecycleState { return true }
        return false
    }

    @discardableResult
    func start() -> Bool {
        lifecycleCondition.lock()
        while true {
            switch lifecycleState {
            case .running:
                lifecycleCondition.unlock()
                return true
            case .starting, .stopping:
                lifecycleCondition.wait()
            case .stopped:
                let thread = Thread { [weak self] in self?.runHIDThread() }
                thread.name = "JamCon.G502X.HID"
                thread.qualityOfService = .userInteractive
                lifecycleState = .starting(thread)
                lifecycleCondition.unlock()
                thread.start()

                lifecycleCondition.lock()
                while case .starting = lifecycleState {
                    lifecycleCondition.wait()
                }
                let started = if case .running = lifecycleState { true } else { false }
                lifecycleCondition.unlock()
                return started
            }
        }
    }

    func stop() {
        lifecycleCondition.lock()
        while case .starting = lifecycleState {
            lifecycleCondition.wait()
        }
        switch lifecycleState {
        case .stopped:
            lifecycleCondition.unlock()
        case .stopping:
            while case .stopping = lifecycleState {
                lifecycleCondition.wait()
            }
            lifecycleCondition.unlock()
        case let .running(thread, runLoop):
            lifecycleState = .stopping(thread: thread, runLoop: runLoop)
            thread.cancel()
            lifecycleCondition.unlock()
            if Thread.current === thread {
                CFRunLoopStop(runLoop)
                return
            }
            CFRunLoopPerformBlock(runLoop, CFRunLoopMode.defaultMode.rawValue) {
                CFRunLoopStop(runLoop)
            }
            CFRunLoopWakeUp(runLoop)
            lifecycleCondition.lock()
            while case .stopping = lifecycleState {
                lifecycleCondition.wait()
            }
            lifecycleCondition.unlock()
        case .starting:
            lifecycleCondition.unlock()
        }
    }

    private func runHIDThread() {
        let currentThread = Thread.current
        guard let runLoop = CFRunLoopGetCurrent() else {
            finishStartupFailure(message: "Failed to obtain G502 HID run loop")
            return
        }
        lifecycleCondition.lock()
        guard case let .starting(thread) = lifecycleState, thread === currentThread else {
            lifecycleState = .stopped
            lifecycleCondition.broadcast()
            lifecycleCondition.unlock()
            return
        }
        lifecycleCondition.unlock()

        let result = transport.startDiscovery(
            on: runLoop,
            deviceConnected: { [weak self] in self?.handleDeviceConnected($0) },
            deviceDisconnected: { [weak self] in self?.handleDeviceDisconnected($0) }
        )
        guard case .success = result else {
            cleanupHIDResources(on: runLoop)
            if case let .failure(error) = result {
                finishStartupFailure(message: "G502 HID backend did not start: \(error)")
            } else {
                finishStartupFailure(message: "G502 HID backend did not start")
            }
            return
        }

        log("HID manager started, scanning for supported Logitech mice")
        activateSelectedMouseIfNeeded()

        // Do not publish a running backend until its retained selection has
        // been reconciled; callers can rely on start() returning a ready state.
        lifecycleCondition.lock()
        lifecycleState = .running(thread: currentThread, runLoop: runLoop)
        lifecycleCondition.broadcast()
        lifecycleCondition.unlock()

        while !Thread.current.isCancelled {
            _ = autoreleasepool { CFRunLoopRunInMode(.defaultMode, 1, false) }
        }
        cleanupHIDResources(on: runLoop)
        lifecycleCondition.lock()
        lifecycleState = .stopped
        lifecycleCondition.broadcast()
        lifecycleCondition.unlock()
    }

    private func finishStartupFailure(message: String) {
        lifecycleCondition.lock()
        lifecycleState = .stopped
        lifecycleCondition.broadcast()
        lifecycleCondition.unlock()
        JamLog.error(.g502x, message)
    }

    private func cleanupHIDResources(on runLoop: CFRunLoop) {
        assertOnHIDThread()
        deactivateActiveMouse(publishConnectionChange: false)
        transport.stopDiscovery(on: runLoop)
        stateLock.withLock {
            $0.discoveredMice.removeAll(keepingCapacity: true)
            $0.activeMouseID = nil
            $0.isConnected = false
            $0.mouseName = nil
        }
        retiredInterfaces.removeAll(keepingCapacity: true)
        lastInterfaceInfoUpdate = 0
        interfaceInfoLock.lock()
        cachedInterfaceInfo.removeAll(keepingCapacity: true)
        interfaceInfoLock.unlock()
        resetReportStats()
    }

    func log(_ message: String) {
        JamLog.info(.g502x, message)
    }
}
