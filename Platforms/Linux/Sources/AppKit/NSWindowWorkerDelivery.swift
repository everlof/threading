#if os(Linux)
import Foundation

/// Complete text's serial worker delivers through the native window's installed event loop.
/// The caller waits for its receipt, so it can owe at most one UI delivery.
/// Without a native host, ordinary MainActor tasks support standalone shim contracts.
public final class NSWindowWorkerDelivery: @unchecked Sendable {
    public static let shared = NSWindowWorkerDelivery()
    private typealias Work = @MainActor @Sendable () -> Void
    private let lock = NSLock()
    private var wake: (@Sendable () -> Void)?
    private var owner: UUID?
    private var pending: Work?

    @MainActor
    public func install(wake: @escaping @Sendable () -> Void) -> UUID {
        lock.withLock {
            precondition(owner == nil, "only one native UI event loop may own worker delivery")
            let token = UUID()
            owner = token
            self.wake = wake
            return token
        }
    }

    @MainActor
    @discardableResult
    public func drain() -> Bool {
        let work = lock.withLock {
            let values = pending
            pending = nil
            return values
        }
        work?()
        return work != nil
    }

    @MainActor
    public func uninstall(_ token: UUID) {
        let work = lock.withLock { () -> Work? in
            guard owner == token else { return nil }
            owner = nil
            wake = nil
            let values = pending
            pending = nil
            return values
        }
        work?()
    }

    /// Worker-only: never wait for a UI receipt on the UI executor itself.
    func deliver(_ operation: @escaping @MainActor @Sendable () -> Void) {
        let received = DispatchSemaphore(value: 0)
        let delivery: Work = { operation(); received.signal() }
        let notify = lock.withLock { () -> (@Sendable () -> Void)? in
            guard let wake else { return nil }
            precondition(pending == nil, "the serial text worker may owe only one UI receipt")
            pending = delivery
            return wake
        }
        if let notify { notify() }
        else { Task { @MainActor in delivery() } }
        received.wait()
    }
}
#endif
