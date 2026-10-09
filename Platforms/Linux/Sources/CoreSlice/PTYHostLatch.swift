import Foundation
import Dispatch

final class PTYHostLatch<Value>: @unchecked Sendable {

    private let semaphore = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var value: Value?
    private var settled = false

    /// Delivers the value, once. Later calls are ignored.
    func complete(_ value: Value) {
        lock.lock()
        guard !settled else { return lock.unlock() }
        settled = true
        self.value = value
        lock.unlock()
        semaphore.signal()
    }

    /// Wakes the waiter with nothing — the link ended before an answer arrived.
    func abandon() {
        lock.lock()
        guard !settled else { return lock.unlock() }
        settled = true
        lock.unlock()
        semaphore.signal()
    }

    /// Blocks for at most `timeout` and answers what arrived, or nil.
    func wait(_ timeout: TimeInterval) -> Value? {
        _ = semaphore.wait(timeout: .now() + timeout)
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}
