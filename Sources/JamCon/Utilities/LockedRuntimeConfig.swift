import Foundation
import os.lock

/// Small lock-protected container for controller-local runtime config.
///
/// Use this for hot settings that may be updated from the UI/main thread and read from
/// controller/HID threads. Semantics are intentionally last-writer-wins and asynchronous:
/// readers see the most recently committed value available at the moment of each snapshot.
final class LockedRuntimeConfig<State: Sendable>: @unchecked Sendable {
    private let lock: OSAllocatedUnfairLock<State>

    init(initialState: State) {
        self.lock = OSAllocatedUnfairLock(initialState: initialState)
    }

    func snapshot() -> State {
        lock.withLock { $0 }
    }

    func update(_ body: (inout State) -> Void) {
        lock.withLock { body(&$0) }
    }
}
