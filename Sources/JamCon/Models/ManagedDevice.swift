import Foundation

// MARK: - Managed Device

/// Represents a device that the user has chosen to manage (auto-connect when available)
struct ManagedDevice: Codable, Identifiable, Sendable {
    /// Unique identifier: "vendorId:productId:transport"
    let id: String
    let vendorId: Int
    let productId: Int
    let transport: String  // "USB" or "Bluetooth"
    let displayName: String
    var lastSeen: Date?

    init(from device: AvailableDevice) {
        self.id = device.id
        self.vendorId = device.vendorId
        self.productId = device.productId
        self.transport = device.transport
        self.displayName = device.displayName
        self.lastSeen = Date()
    }

    init(id: String, vendorId: Int, productId: Int, transport: String, displayName: String, lastSeen: Date? = nil) {
        self.id = id
        self.vendorId = vendorId
        self.productId = productId
        self.transport = transport
        self.displayName = displayName
        self.lastSeen = lastSeen
    }
}

// MARK: - Managed Device Registry

/// Persistent registry of devices the user has chosen to manage
final class ManagedDeviceRegistry: @unchecked Sendable {
    static let shared = ManagedDeviceRegistry()

    private let storageKey = "managed_devices"
    private var devices: [String: ManagedDevice] = [:]
    private let lock = NSLock()

    private init() {
        load()
    }

    // MARK: - Public API

    /// Check if a device is managed (by groupKey)
    func contains(_ groupKey: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return devices[groupKey] != nil
    }

    /// Get a managed device by groupKey
    func get(_ groupKey: String) -> ManagedDevice? {
        lock.lock()
        defer { lock.unlock() }
        return devices[groupKey]
    }

    /// Get all managed devices
    func all() -> [ManagedDevice] {
        lock.lock()
        defer { lock.unlock() }
        return Array(devices.values)
    }

    /// Add a device to the managed list
    func add(_ device: AvailableDevice) {
        lock.lock()
        defer { lock.unlock() }

        let managed = ManagedDevice(from: device)
        devices[managed.id] = managed
        save()
        print("[ManagedDeviceRegistry] Added: \(managed.displayName) (\(managed.id))")
    }

    /// Remove a device from the managed list
    func remove(_ groupKey: String) {
        lock.lock()
        defer { lock.unlock() }

        if let removed = devices.removeValue(forKey: groupKey) {
            save()
            print("[ManagedDeviceRegistry] Removed: \(removed.displayName) (\(groupKey))")
        }
    }

    /// Update the lastSeen timestamp for a device
    func updateLastSeen(_ groupKey: String) {
        lock.lock()
        defer { lock.unlock() }

        if var device = devices[groupKey] {
            device.lastSeen = Date()
            devices[groupKey] = device
            save()
        }
    }

    // MARK: - Persistence

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: storageKey) else {
            return
        }

        do {
            let decoded = try JSONDecoder().decode([ManagedDevice].self, from: data)
            for device in decoded {
                devices[device.id] = device
            }
            print("[ManagedDeviceRegistry] Loaded \(devices.count) managed devices")
        } catch {
            print("[ManagedDeviceRegistry] Failed to load: \(error)")
        }
    }

    private func save() {
        do {
            let data = try JSONEncoder().encode(Array(devices.values))
            UserDefaults.standard.set(data, forKey: storageKey)
        } catch {
            print("[ManagedDeviceRegistry] Failed to save: \(error)")
        }
    }
}
