import Foundation
import CoreGraphics
import os

extension InputEngine {

    // MARK: - Shared gyro scaling

    /// Apply the user scale as a multiplier relative to the Sense reference scale so both controllers share the same pipeline.
    func effectiveGyroScale(for kind: ControllerKind, userScale: Double) -> Double {
        let reference = GyroRemapper.gyroScale(for: .sense)
        let deviceScale = GyroRemapper.gyroScale(for: kind)
        let rawMultiplier = reference != 0 ? (userScale / reference) : 1.0
        let userMultiplier = min(4.0, max(0.25, rawMultiplier))  // clamp to a sane range
        return deviceScale * userMultiplier
    }

    func mapGyroDebug(from state: GyroProcessor.DebugState?) -> DebugBuffer.GyroDebug? {
        guard let state else { return nil }
        return DebugBuffer.GyroDebug(
            biasX: state.biasX,
            biasY: state.biasY,
            biasZ: state.biasZ,
            calibrated: state.calibrated,
            observedSampleRate: state.observedSampleRate,
            lastNeutralUpdate: state.lastNeutralUpdate
        )
    }
}

