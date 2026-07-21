import Foundation

protocol HoldScheduling: AnyObject {
    func schedule(_ workItem: DispatchWorkItem, after delay: TimeInterval, on queue: DispatchQueue)
}

final class DispatchHoldScheduler: HoldScheduling {
    func schedule(_ workItem: DispatchWorkItem, after delay: TimeInterval, on queue: DispatchQueue) {
        queue.asyncAfter(deadline: .now() + delay, execute: workItem)
    }
}
