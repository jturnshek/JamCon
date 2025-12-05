import SwiftUI

// MARK: - Buttons Tab

struct ButtonsTab: View {
    @ObservedObject var appState: AppState
    @StateObject private var keyCaptureManager = KeyCaptureManager()

    private var isLeft: Bool { appState.isLeftController }
    private var side: String { isLeft ? "Left" : "Right" }

    private var byte11: UInt8 { appState.safeReportByte(11) }
    private var faceTopTouch: Bool { isLeft ? (byte11 & 0x01) != 0 : (byte11 & 0x04) != 0 }
    private var faceBottomTouch: Bool { (byte11 & 0x02) != 0 }
    private var stickTouch: Bool { (byte11 & 0x04) != 0 }

    private var batteryLevel: Int { Int(appState.safeReportByte(43) & 0x0F) * 10 }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("\(side) Controller")
                    .font(.headline)
                Spacer()
                if appState.isConnected {
                    BatteryIndicator(level: batteryLevel)
                }
                ConnectionIndicator(isConnected: appState.isConnected)
            }
            .padding(.horizontal)
            .padding(.vertical, 10)
            .background(Color.secondary.opacity(0.05))

            ScrollView {
                VStack(spacing: 16) {
                    if appState.isConnected {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Input Status")
                                .font(.subheadline)
                                .fontWeight(.medium)
                                .foregroundColor(.secondary)

                            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 8) {
                                GridRow {
                                    Text(isLeft ? "Triangle" : "Circle")
                                        .font(.system(size: 12, weight: .medium))
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                    TouchIndicator(active: faceTopTouch)
                                    Arrow()
                                    PressIndicator(active: appState.buttonStates[.faceTop] ?? false)
                                }

                                GridRow {
                                    Text(isLeft ? "Square" : "X")
                                        .font(.system(size: 12, weight: .medium))
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                    TouchIndicator(active: faceBottomTouch)
                                    Arrow()
                                    PressIndicator(active: appState.buttonStates[.faceBottom] ?? false)
                                }

                                GridRow {
                                    Text(isLeft ? "L1 Grip" : "R1 Grip")
                                        .font(.system(size: 12, weight: .medium))
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                    AnalogBar(value: appState.safeReportByte(6), color: .orange)
                                    Arrow()
                                    PressIndicator(active: appState.buttonStates[.bumper] ?? false)
                                }

                                GridRow {
                                    Text(isLeft ? "L2 Trigger" : "R2 Trigger")
                                        .font(.system(size: 12, weight: .medium))
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                    AnalogBar(value: appState.safeReportByte(5), color: .orange)
                                    Arrow()
                                    AnalogBar(value: appState.safeReportByte(4), color: .blue)
                                }

                                GridRow {
                                    Text(isLeft ? "L3 Stick" : "R3 Stick")
                                        .font(.system(size: 12, weight: .medium))
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                    TouchIndicator(active: stickTouch)
                                    Arrow()
                                    PressIndicator(active: appState.buttonStates[.stickClick] ?? false)
                                }

                                GridRow {
                                    Text(isLeft ? "L4 Create" : "R4 Options")
                                        .font(.system(size: 12, weight: .medium))
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                    Color.clear.gridCellUnsizedAxes(.horizontal)
                                    Arrow()
                                    PressIndicator(active: appState.buttonStates[.menuButton] ?? false)
                                }

                                GridRow {
                                    Text(isLeft ? "L5 PS" : "R5 PS")
                                        .font(.system(size: 12, weight: .medium))
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                    Color.clear.gridCellUnsizedAxes(.horizontal)
                                    Arrow()
                                    PressIndicator(active: appState.buttonStates[.playStation] ?? false)
                                }
                            }
                        }
                        .padding()
                        .background(Color.secondary.opacity(0.03))
                        .cornerRadius(8)
                    }

                    ButtonMappingsSection(
                        appState: appState,
                        keyCaptureManager: keyCaptureManager,
                        isLeft: isLeft
                    )
                }
                .padding()
            }

            if !appState.isConnected {
                Text("Connect a controller to see button states")
                    .foregroundColor(.secondary)
                    .frame(maxHeight: .infinity)
            }
        }
        .onAppear {
            keyCaptureManager.onCapture = { button, combo, isHold in
                if isHold {
                    appState.buttonMappingProfile.setHoldAction(.keyPress(combo), for: button)
                } else {
                    appState.buttonMappingProfile.setPressAction(.keyPress(combo), for: button)
                }
            }
        }
    }
}
