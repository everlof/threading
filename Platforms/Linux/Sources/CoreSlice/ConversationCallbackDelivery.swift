import Dispatch
import Foundation

/// The host owns how native conversation callbacks reach its UI executor. Reading and timers
/// never need to know whether that executor is an AppKit run loop or a native Linux event loop.
struct ConversationCallbackDelivery: Sendable {
    typealias Operation = @MainActor @Sendable () -> Void
    let enqueue: @Sendable (@escaping Operation) -> Void
    /// Called by a worker. A native host may wait for a UI receipt to pace that producer.
    let receive: @Sendable (@escaping Operation) -> Void

    static let main = ConversationCallbackDelivery(
        enqueue: { operation in Task { @MainActor in operation() } },
        receive: { operation in
            DispatchQueue.main.async { MainActor.assumeIsolated { operation() } }
        })

    func after(_ seconds: TimeInterval, operation: @escaping Operation) -> ConversationCallbackDeadline {
        let deadline = ConversationCallbackDeadline()
        ConversationCallbackDeadline.queue.asyncAfter(deadline: .now() + max(0, seconds)) {
            guard !deadline.isCancelled else { return }
            receive {
                guard !deadline.isCancelled else { return }
                operation()
            }
        }
        return deadline
    }
}

/// One cancellation flag covers both a timer that has not fired and its queued UI receipt.
final class ConversationCallbackDeadline: @unchecked Sendable {
    static let queue = DispatchQueue(label: "codes.threading.conversation-deadlines", qos: .utility)
    private let cancelled = LockedState(initialState: false)
    var isCancelled: Bool { cancelled.withLock { $0 } }
    func cancel() { cancelled.withLock { $0 = true } }
}
