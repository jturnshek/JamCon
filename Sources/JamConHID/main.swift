import Foundation
import IOKit
import IOKit.hid
import Darwin

// MARK: - HID Daemon

/// Privileged daemon that seizes HID devices (including keyboard interfaces)
/// and forwards events to clients via Unix socket
class HIDDaemon {
    static let socketPath = "/var/run/jamcon-hid.sock"

    private var hidManager: IOHIDManager?
    private var serverSocket: Int32 = -1
    private var clientSockets: [Int32] = []
    private let clientLock = NSLock()

    // Device we're targeting
    private let targetVendorId: Int = 0x25A7   // ZY.Ltd
    private let targetProductId: Int = 0x1048  // ZY RMC (DinoStrike)

    // Track seized devices
    private var seizedDevices: Set<IOHIDDevice> = []

    func start() {
        print("[JamConHID] Starting daemon...")
        print("[JamConHID] Target device: VendorID=0x\(String(targetVendorId, radix: 16)) ProductID=0x\(String(targetProductId, radix: 16))")

        // Remove stale socket
        unlink(HIDDaemon.socketPath)

        setupSocket()
        setupHIDManager()

        print("[JamConHID] Daemon running. Waiting for devices and clients...")

        // Run the event loop
        CFRunLoopRun()
    }

    // MARK: - Socket Setup

    private func setupSocket() {
        serverSocket = socket(AF_UNIX, SOCK_STREAM, 0)
        guard serverSocket >= 0 else {
            print("[JamConHID] ERROR: Failed to create socket: \(errno)")
            exit(1)
        }

        // Allow socket reuse
        var reuse: Int32 = 1
        setsockopt(serverSocket, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))

        // Bind to path
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)

        let pathBytes = HIDDaemon.socketPath.utf8CString
        withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
            ptr.withMemoryRebound(to: CChar.self, capacity: 104) { sunPath in
                for (i, byte) in pathBytes.enumerated() where i < 104 {
                    sunPath[i] = byte
                }
            }
        }

        let bindResult = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
                bind(serverSocket, sockaddrPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }

        guard bindResult == 0 else {
            print("[JamConHID] ERROR: Failed to bind socket: \(errno)")
            exit(1)
        }

        // Make socket accessible by user processes
        chmod(HIDDaemon.socketPath, 0o777)

        // Listen for connections
        guard listen(serverSocket, 5) == 0 else {
            print("[JamConHID] ERROR: Failed to listen: \(errno)")
            exit(1)
        }

        print("[JamConHID] Socket listening at \(HIDDaemon.socketPath)")

        // Accept connections on background thread
        DispatchQueue.global(qos: .utility).async { [weak self] in
            self?.acceptLoop()
        }
    }

    private func acceptLoop() {
        while true {
            var clientAddr = sockaddr_un()
            var addrLen = socklen_t(MemoryLayout<sockaddr_un>.size)

            let clientSocket = withUnsafeMutablePointer(to: &clientAddr) { ptr in
                ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
                    accept(serverSocket, sockaddrPtr, &addrLen)
                }
            }

            if clientSocket >= 0 {
                clientLock.lock()
                clientSockets.append(clientSocket)
                clientLock.unlock()
                print("[JamConHID] Client connected (socket \(clientSocket))")

                // Start reading from client (for future commands)
                DispatchQueue.global(qos: .utility).async { [weak self] in
                    self?.readFromClient(clientSocket)
                }
            }
        }
    }

    private func readFromClient(_ socket: Int32) {
        var buffer = [UInt8](repeating: 0, count: 256)
        while true {
            let bytesRead = read(socket, &buffer, buffer.count)
            if bytesRead <= 0 {
                // Client disconnected
                clientLock.lock()
                clientSockets.removeAll { $0 == socket }
                clientLock.unlock()
                close(socket)
                print("[JamConHID] Client disconnected (socket \(socket))")
                break
            }
            // Future: handle commands from client
        }
    }

    private func broadcast(_ message: String) {
        let data = message.data(using: .utf8)!
        let bytes = [UInt8](data) + [0x0A] // Add newline

        clientLock.lock()
        let sockets = clientSockets
        clientLock.unlock()

        for socket in sockets {
            _ = bytes.withUnsafeBytes { ptr in
                write(socket, ptr.baseAddress!, bytes.count)
            }
        }
    }

    // MARK: - HID Setup

    private func setupHIDManager() {
        hidManager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        guard let manager = hidManager else {
            print("[JamConHID] ERROR: Failed to create HID manager")
            exit(1)
        }

        // Match our target device
        let criteria: [String: Any] = [
            kIOHIDVendorIDKey as String: targetVendorId,
            kIOHIDProductIDKey as String: targetProductId
        ]
        IOHIDManagerSetDeviceMatching(manager, criteria as CFDictionary)

        // Register callbacks
        let context = Unmanaged.passUnretained(self).toOpaque()

        IOHIDManagerRegisterDeviceMatchingCallback(manager, { context, result, sender, device in
            guard let context = context else { return }
            let daemon = Unmanaged<HIDDaemon>.fromOpaque(context).takeUnretainedValue()
            daemon.handleDeviceConnected(device)
        }, context)

        IOHIDManagerRegisterDeviceRemovalCallback(manager, { context, result, sender, device in
            guard let context = context else { return }
            let daemon = Unmanaged<HIDDaemon>.fromOpaque(context).takeUnretainedValue()
            daemon.handleDeviceRemoved(device)
        }, context)

        IOHIDManagerRegisterInputValueCallback(manager, { context, result, sender, value in
            guard let context = context else { return }
            let daemon = Unmanaged<HIDDaemon>.fromOpaque(context).takeUnretainedValue()
            daemon.handleInputValue(value)
        }, context)

        // Schedule with run loop
        IOHIDManagerScheduleWithRunLoop(manager, CFRunLoopGetCurrent(), CFRunLoopMode.defaultMode.rawValue)

        // Open manager (not seizing at manager level)
        let openResult = IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        if openResult != kIOReturnSuccess {
            print("[JamConHID] ERROR: Failed to open HID manager: \(openResult)")
            exit(1)
        }

        print("[JamConHID] HID manager initialized, scanning for devices...")
    }

    private func handleDeviceConnected(_ device: IOHIDDevice) {
        let vendorId = IOHIDDeviceGetProperty(device, kIOHIDVendorIDKey as CFString) as? Int ?? 0
        let productId = IOHIDDeviceGetProperty(device, kIOHIDProductIDKey as CFString) as? Int ?? 0
        let productName = IOHIDDeviceGetProperty(device, kIOHIDProductKey as CFString) as? String ?? "Unknown"
        let usagePage = IOHIDDeviceGetProperty(device, kIOHIDPrimaryUsagePageKey as CFString) as? Int ?? 0
        let usage = IOHIDDeviceGetProperty(device, kIOHIDPrimaryUsageKey as CFString) as? Int ?? 0

        print("[JamConHID] Device connected: \(productName)")
        print("[JamConHID]   VendorID: 0x\(String(vendorId, radix: 16))")
        print("[JamConHID]   ProductID: 0x\(String(productId, radix: 16))")
        print("[JamConHID]   UsagePage: 0x\(String(usagePage, radix: 16)) Usage: 0x\(String(usage, radix: 16))")

        // Try to seize this device with exclusive access
        let seizeResult = IOHIDDeviceOpen(device, IOOptionBits(kIOHIDOptionsTypeSeizeDevice))

        if seizeResult == kIOReturnSuccess {
            seizedDevices.insert(device)
            print("[JamConHID]   ✓ SEIZED successfully!")

            // Notify clients
            let msg = """
            {"type":"device_connected","name":"\(productName)","vendorId":\(vendorId),"productId":\(productId),"usagePage":\(usagePage),"usage":\(usage),"seized":true}
            """
            broadcast(msg)
        } else {
            print("[JamConHID]   ✗ Failed to seize: 0x\(String(format: "%08X", UInt32(bitPattern: seizeResult)))")

            // Try non-exclusive open as fallback
            let openResult = IOHIDDeviceOpen(device, IOOptionBits(kIOHIDOptionsTypeNone))
            if openResult == kIOReturnSuccess {
                print("[JamConHID]   ⚠ Opened non-exclusively (events will also go to system)")
            }
        }
    }

    private func handleDeviceRemoved(_ device: IOHIDDevice) {
        let productName = IOHIDDeviceGetProperty(device, kIOHIDProductKey as CFString) as? String ?? "Unknown"
        print("[JamConHID] Device removed: \(productName)")
        seizedDevices.remove(device)

        let msg = """
        {"type":"device_disconnected","name":"\(productName)"}
        """
        broadcast(msg)
    }

    private func handleInputValue(_ value: IOHIDValue) {
        let element = IOHIDValueGetElement(value)
        let usagePage = Int(IOHIDElementGetUsagePage(element))
        let usage = Int(IOHIDElementGetUsage(element))
        let intValue = IOHIDValueGetIntegerValue(value)

        // Skip zero values for most things (reduces noise)
        if intValue == 0 && usagePage != 0x09 { // Always report button releases
            return
        }

        // Log interesting events
        let pageNames: [Int: String] = [
            0x01: "GenericDesktop",
            0x07: "Keyboard",
            0x09: "Button",
            0x0C: "Consumer"
        ]
        let pageName = pageNames[usagePage] ?? "0x\(String(usagePage, radix: 16))"

        if intValue != 0 || usagePage == 0x09 {
            print("[JamConHID] Input: page=\(pageName) usage=0x\(String(usage, radix: 16)) value=\(intValue)")
        }

        // Send to clients
        let msg = """
        {"type":"input","page":\(usagePage),"usage":\(usage),"value":\(intValue)}
        """
        broadcast(msg)
    }
}

// MARK: - Signal Handling

func setupSignalHandlers() {
    signal(SIGINT) { _ in
        print("\n[JamConHID] Shutting down...")
        unlink(HIDDaemon.socketPath)
        exit(0)
    }
    signal(SIGTERM) { _ in
        print("\n[JamConHID] Terminating...")
        unlink(HIDDaemon.socketPath)
        exit(0)
    }
}

// MARK: - Main

print("===========================================")
print("  JamConHID - Privileged HID Daemon")
print("===========================================")

// Check if running as root
if getuid() != 0 {
    print("[JamConHID] WARNING: Not running as root. Keyboard seizure may fail.")
}

setupSignalHandlers()

let daemon = HIDDaemon()
daemon.start()
