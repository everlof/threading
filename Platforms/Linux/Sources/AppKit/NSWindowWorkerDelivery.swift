#if os(Linux)
import Foundation

/// The native event loop owns UI delivery. Worker receipts pace producers; deferred UI work
/// shares a fixed mailbox. Without a native owner, standalone contracts use MainActor tasks.
public final class NSWindowWorkerDelivery: @unchecked Sendable {
    public static let shared = NSWindowWorkerDelivery()
    public typealias Work = @MainActor @Sendable () -> Void
    private static let capacity = 64
    private let condition = NSCondition()
    private var wake: (@Sendable () -> Void)?
    private var owner: UUID?
    private var ownerThread: Thread?
    private var pending: [Work] = []

    @MainActor
    public func install(wake: @escaping @Sendable () -> Void) -> UUID {
        condition.lock()
        defer { condition.unlock() }
        precondition(owner == nil, "only one native UI event loop may own worker delivery")
        let token = UUID()
        owner = token
        ownerThread = Thread.current
        self.wake = wake
        return token
    }

    @MainActor
    @discardableResult
    public func drain() -> Bool {
        condition.lock()
        let work = pending.isEmpty ? nil : pending.removeFirst()
        condition.broadcast()
        condition.unlock()
        work?()
        return work != nil
    }

    @MainActor
    public func uninstall(_ token: UUID) {
        condition.lock()
        guard owner == token else { condition.unlock(); return }
        owner = nil
        ownerThread = nil
        wake = nil
        let work = pending
        pending.removeAll()
        condition.broadcast()
        condition.unlock()
        work.forEach { $0() }
    }

    /// Defers without blocking the UI owner. A full mailbox reports refusal to its host.
    @discardableResult
    public func enqueue(_ operation: @escaping Work) -> Bool {
        condition.lock()
        guard let notify = wake else {
            condition.unlock()
            Task { @MainActor in operation() }
            return true
        }
        guard pending.count < Self.capacity else { condition.unlock(); return false }
        pending.append(operation)
        condition.unlock()
        notify()
        return true
    }

    /// Receipts normally arrive from workers. The owner fallback is reserved for a critical
    /// deferred callback whose mailbox admission failed; it never waits on its own executor.
    public func deliver(_ operation: @escaping Work) {
        condition.lock()
        if ownerThread === Thread.current {
            condition.unlock()
            MainActor.assumeIsolated { operation() }
            return
        }
        let received = DispatchSemaphore(value: 0)
        let delivery: Work = { operation(); received.signal() }
        while wake != nil && pending.count == Self.capacity { condition.wait() }
        let notify = wake
        if notify != nil { pending.append(delivery) }
        condition.unlock()
        if let notify { notify() }
        else { Task { @MainActor in delivery() } }
        received.wait()
    }
}
#endif
