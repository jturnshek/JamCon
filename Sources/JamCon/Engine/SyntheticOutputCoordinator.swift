import Foundation

struct ManagedDeviceKey: Hashable, Sendable, Codable {
    let kind: ControllerKind
    let id: String
}

enum SyntheticOutputRole: String, Hashable, Sendable, Codable {
    case press
    case hold
    case radialMenu
    case systemAction
}

struct SyntheticOutputOwner: Hashable, Sendable, Codable {
    let device: ManagedDeviceKey?
    let control: String
    let role: SyntheticOutputRole

    func withRole(_ role: SyntheticOutputRole, control: String? = nil) -> SyntheticOutputOwner {
        SyntheticOutputOwner(device: device, control: control ?? self.control, role: role)
    }
}

enum SyntheticOutput: Hashable {
    case mouseButton(MouseButton)
    case key(KeyCombo)
}

enum SyntheticOutputEvent: Equatable {
    case mouseButton(MouseButton, isPressed: Bool)
    case key(KeyCombo, isPressed: Bool)
}

protocol SyntheticEventBackend: AnyObject {
    func post(_ event: SyntheticOutputEvent)
}

/// Owns every synthetic down event emitted by JamCon.
///
/// An output goes down for the first owner and stays down until its final owner
/// releases it. Duplicate reports from the same owner are idempotent. Device
/// teardown can release every output for that device even if local button state
/// was lost or a physical release report never arrived.
final class SyntheticOutputCoordinator {
    private let backend: SyntheticEventBackend
    private var ownersByOutput: [SyntheticOutput: Set<SyntheticOutputOwner>] = [:]
    private var outputsByOwner: [SyntheticOutputOwner: Set<SyntheticOutput>] = [:]

    init(backend: SyntheticEventBackend) {
        self.backend = backend
    }

    func set(_ output: SyntheticOutput, pressed: Bool, owner: SyntheticOutputOwner) {
        if pressed {
            press(output, owner: owner)
        } else {
            release(output, owner: owner)
        }
    }

    func tap(_ output: SyntheticOutput, owner: SyntheticOutputOwner) {
        // If another owner is holding this output, pulse it up/down and leave it
        // held. A normal temporary owner would be swallowed by reference counting
        // and the requested tap would never reach macOS.
        if ownersByOutput[output]?.isEmpty == false {
            post(output, isPressed: false)
            post(output, isPressed: true)
            return
        }

        press(output, owner: owner)
        release(output, owner: owner)
    }

    func releaseAll(for device: ManagedDeviceKey) {
        let owners = outputsByOwner.keys.filter { $0.device == device }
        for owner in owners {
            releaseAll(for: owner)
        }
    }

    func releaseAll(for owner: SyntheticOutputOwner) {
        let outputs = outputsByOwner[owner] ?? []
        for output in outputs {
            release(output, owner: owner)
        }
    }

    func releaseAll() {
        let activeOutputs = Array(ownersByOutput.keys)
        ownersByOutput.removeAll(keepingCapacity: true)
        outputsByOwner.removeAll(keepingCapacity: true)
        for output in activeOutputs {
            post(output, isPressed: false)
        }
    }

    var activeOutputCount: Int { ownersByOutput.count }

    func ownerCount(for output: SyntheticOutput) -> Int {
        ownersByOutput[output]?.count ?? 0
    }

    private func press(_ output: SyntheticOutput, owner: SyntheticOutputOwner) {
        var owners = ownersByOutput[output] ?? []
        guard owners.insert(owner).inserted else { return }

        let shouldPost = owners.count == 1
        ownersByOutput[output] = owners
        outputsByOwner[owner, default: []].insert(output)

        if shouldPost {
            post(output, isPressed: true)
        }
    }

    private func release(_ output: SyntheticOutput, owner: SyntheticOutputOwner) {
        guard var owners = ownersByOutput[output], owners.remove(owner) != nil else { return }

        if var ownerOutputs = outputsByOwner[owner] {
            ownerOutputs.remove(output)
            if ownerOutputs.isEmpty {
                outputsByOwner.removeValue(forKey: owner)
            } else {
                outputsByOwner[owner] = ownerOutputs
            }
        }

        if owners.isEmpty {
            ownersByOutput.removeValue(forKey: output)
            post(output, isPressed: false)
        } else {
            ownersByOutput[output] = owners
        }
    }

    private func post(_ output: SyntheticOutput, isPressed: Bool) {
        switch output {
        case .mouseButton(let button):
            backend.post(.mouseButton(button, isPressed: isPressed))
        case .key(let combo):
            backend.post(.key(combo, isPressed: isPressed))
        }
    }
}
