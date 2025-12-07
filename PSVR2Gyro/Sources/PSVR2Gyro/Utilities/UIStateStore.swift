import Foundation

/// Thread-safe store for coarse UI state, updated by HID callbacks and polled by the UI.
actor UIStateStore {
    struct Snapshot {
        var isConnected: Bool
        var controllerName: String
        var batteryLevel: Int
        var selectedControllerID: String?
        var activeControllerKind: ControllerKind
        var isLeftController: Bool
    }

    private var state = Snapshot(
        isConnected: false,
        controllerName: "Not connected",
        batteryLevel: 0,
        selectedControllerID: nil,
        activeControllerKind: .psvr2,
        isLeftController: false
    )

    func updateSelection(id: String?, kind: ControllerKind, isLeft: Bool) {
        state.selectedControllerID = id
        state.activeControllerKind = kind
        state.isLeftController = isLeft
    }

    func updateConnection(isConnected: Bool, name: String?, id: String?, kind: ControllerKind, isLeft: Bool) {
        state.isConnected = isConnected
        state.controllerName = name ?? "Not connected"
        if let id { state.selectedControllerID = id }
        state.activeControllerKind = kind
        state.isLeftController = isLeft
    }

    func updateBattery(level: Int?) {
        guard let level else { return }
        state.batteryLevel = level
    }

    func snapshot() -> Snapshot {
        state
    }
}
