import SwiftUI

// MARK: - Device Debug View (Device-scoped)

struct DeviceDebugView: View {
    @ObservedObject var appState: AppState
    @ObservedObject private var telemetry: DebugTelemetryState
    let controller: ControllerInfo

    private let bytesPerRow = 8
    private let decaySeconds: Double = 5.0

    private var isManaged: Bool { appState.isDeviceManaged(controller) }

    private var liveBinding: Binding<Bool> {
        Binding(
            get: { appState.debugPollingEnabled },
            set: { enabled in
                if enabled {
                    guard isManaged else { return }
                    appState.startDebugPolling(targetKind: controller.kind)
                } else {
                    appState.stopDebugPolling()
                }
            }
        )
    }

    init(appState: AppState, controller: ControllerInfo) {
        self.appState = appState
        self.controller = controller
        _telemetry = ObservedObject(wrappedValue: appState.debugTelemetry)
    }

    private var totalBytes: Int {
        if telemetry.reportLength > 0 {
            return telemetry.reportLength
        }
        switch controller.kind {
        case .mouse:
            return 16
        case .joyCon:
            return JoyConHIDProtocol.reportLength
        case .sense:
            return SenseHIDProtocol.reportLength
        }
    }

    var body: some View {
        Group {
            if !isManaged {
                ContentUnavailableView {
                    Label("Not Managed", systemImage: "checkmark.circle.badge.xmark")
                } description: {
                    Text("Toggle Managed for this device in Devices to enable input, then turn on Live.")
                }
            } else if !appState.debugPollingEnabled {
                ContentUnavailableView {
                    Label("Live Rendering Paused", systemImage: "pause.circle")
                } description: {
                    Text("Enable Live to see real-time data.")
                }
            } else {
                switch controller.kind {
                case .mouse:
                    TimelineView(.periodic(from: .now, by: 0.1)) { timeline in
                        MouseDebugView(
                            appState: appState,
                            telemetry: telemetry,
                            bytesPerRow: bytesPerRow,
                            totalBytes: totalBytes,
                            decaySeconds: decaySeconds,
                            currentTime: timeline.date
                        )
                    }

                case .joyCon:
                    TimelineView(.periodic(from: .now, by: 0.1)) { timeline in
                        JoyConDebugView(
                            telemetry: telemetry,
                            isLeft: controller.isLeft,
                            profileVariant: controller.profileVariant,
                            bytesPerRow: bytesPerRow,
                            totalBytes: totalBytes,
                            decaySeconds: decaySeconds,
                            currentTime: timeline.date
                        )
                    }

                case .sense:
                    TimelineView(.periodic(from: .now, by: 0.1)) { timeline in
                        SenseDebugView(
                            telemetry: telemetry,
                            isLeft: controller.isLeft,
                            bytesPerRow: bytesPerRow,
                            totalBytes: totalBytes,
                            decaySeconds: decaySeconds,
                            currentTime: timeline.date
                        )
                    }
                }
            }
        }
        .navigationTitle("Live Debug")
        .toolbar {
            ToolbarItem {
                Button("Export Trace…", systemImage: "square.and.arrow.up") {
                    appState.exportHIDTrace()
                }
            }
            ToolbarItem {
                Toggle("Live", isOn: liveBinding)
                    .toggleStyle(.switch)
                    .disabled(!isManaged)
            }
        }
        .onDisappear {
            appState.stopDebugPolling()
        }
    }
}

// MARK: - Debug Tab

struct DebugTab: View {
    @ObservedObject var appState: AppState
    @ObservedObject private var telemetry: DebugTelemetryState

    private let bytesPerRow = 8
    private let decaySeconds: Double = 5.0

    init(appState: AppState) {
        self.appState = appState
        _telemetry = ObservedObject(wrappedValue: appState.debugTelemetry)
    }

    private var liveBinding: Binding<Bool> {
        Binding(
            get: { appState.debugPollingEnabled },
            set: { enabled in
                if enabled {
                    appState.startDebugPolling()
                } else {
                    appState.stopDebugPolling()
                }
            }
        )
    }

    private var isMouse: Bool { appState.activeControllerKind == .mouse }
    private var isJoyCon: Bool { appState.activeControllerKind == .joyCon }
    private var isLeft: Bool { appState.isLeftController }

    private var totalBytes: Int {
        if telemetry.reportLength > 0 {
            return telemetry.reportLength
        }
        if isMouse {
            return 16  // Default display for mouse
        }
        return isJoyCon ? JoyConHIDProtocol.reportLength : SenseHIDProtocol.reportLength
    }

    var body: some View {
        VStack(spacing: 0) {
            TabHeader(appState: appState) {
                HStack {
                    Button("Export Trace…", systemImage: "square.and.arrow.up") {
                        appState.exportHIDTrace()
                    }
                    Toggle("Live", isOn: liveBinding)
                        .toggleStyle(.switch)
                }
            }

            if appState.debugPollingEnabled && appState.isConnected {
                if isMouse {
                    TimelineView(.periodic(from: .now, by: 0.1)) { timeline in
                        MouseDebugView(
                            appState: appState,
                            telemetry: telemetry,
                            bytesPerRow: bytesPerRow,
                            totalBytes: totalBytes,
                            decaySeconds: decaySeconds,
                            currentTime: timeline.date
                        )
                    }
                } else if isJoyCon {
                    TimelineView(.periodic(from: .now, by: 0.1)) { timeline in
                        JoyConDebugView(
                            telemetry: telemetry,
                            isLeft: isLeft,
                            profileVariant: appState.configurationProfile.variant,
                            bytesPerRow: bytesPerRow,
                            totalBytes: totalBytes,
                            decaySeconds: decaySeconds,
                            currentTime: timeline.date
                        )
                    }
                } else {
                    TimelineView(.periodic(from: .now, by: 0.1)) { timeline in
                        SenseDebugView(
                            telemetry: telemetry,
                            isLeft: isLeft,
                            bytesPerRow: bytesPerRow,
                            totalBytes: totalBytes,
                            decaySeconds: decaySeconds,
                            currentTime: timeline.date
                        )
                    }
                }
            } else if !appState.isConnected {
                Spacer()
                Text("Connect a controller to see debug data")
                    .foregroundColor(.secondary)
                Spacer()
            } else {
                Spacer()
                VStack(spacing: 12) {
                    Image(systemName: "pause.circle")
                        .font(.system(size: 48))
                        .foregroundColor(.secondary.opacity(0.5))
                    Text("Live rendering is paused")
                        .font(.headline)
                        .foregroundColor(.secondary)
                    Text("Enable the toggle above to see real-time data")
                        .font(.caption)
                        .foregroundColor(.secondary.opacity(0.7))
                }
                Spacer()
            }
        }
        .onDisappear {
            // Stop polling when leaving this tab
            appState.stopDebugPolling()
        }
    }
}
