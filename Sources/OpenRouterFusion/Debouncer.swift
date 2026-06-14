import Foundation

// MARK: - Debouncer
// Delays execution until a specified time has passed since the last call.
// Useful for throttling high-frequency updates like streaming content changes.

final class Debouncer {
    private let delay: TimeInterval
    private let queue: DispatchQueue
    private var workItem: DispatchWorkItem?
    
    init(delay: TimeInterval, queue: DispatchQueue = .main) {
        self.delay = delay
        self.queue = queue
    }
    
    func debounce(_ action: @escaping () -> Void) {
        workItem?.cancel()
        workItem = DispatchWorkItem { action() }
        queue.asyncAfter(deadline: .now() + delay, execute: workItem!)
    }
    
    func cancel() {
        workItem?.cancel()
        workItem = nil
    }
}
