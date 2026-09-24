#if os(Linux)
@testable import CoreSlice
import Foundation
import Glibc
import ThreadingPTYHostKit

/// Bridges the shared client's serial callbacks into the CLI's poll loop. One connection owns
/// one inbox; output rate and lifetime are unbounded, retained work is not. Overflow is fatal,
/// never a dropped byte followed by a success status. No callback waits for the consumer.
final class HostEventInbox: @unchecked Sendable {
    enum Event {
        case delivery(PTYHostHandshake.Delivery)
        case closed(PTYHostClientError?)
    }
    enum Failure: Error { case notification(Int32), overflow, controlEncoding }
    let descriptor: Int32
    private let notifier: Int32
    private let lock = NSLock()
    private let maximumBytes: Int
    private let maximumEvents: Int
    private var pending: [Event] = []
    private var bytes = 0
    private var notified = false
    private var ended = false
    private var failure: Failure?

    init(maximumBytes: Int = 4 * 1024 * 1024, maximumEvents: Int = 1024) throws {
        precondition(maximumBytes > 0 && maximumEvents > 0)
        var pair: [Int32] = [-1, -1]
        guard socketpair(AF_UNIX, Int32(SOCK_STREAM.rawValue | SOCK_CLOEXEC.rawValue | SOCK_NONBLOCK.rawValue),
                         0, &pair) == 0 else { throw Failure.notification(errno) }
        descriptor = pair[0]
        notifier = pair[1]
        self.maximumBytes = maximumBytes
        self.maximumEvents = maximumEvents
    }
    deinit { Glibc.close(descriptor); Glibc.close(notifier) }

    var events: PTYHostClient.Events {
        PTYHostClient.Events(frame: { [self] frame in
            // Controls are infrequent. Charge their encoded size as well as bounding entry count;
            // output is charged directly without a copy or a codec pass.
            guard let size = try? JSONEncoder().encode(frame).count else {
                lock.lock(); failLocked(.controlEncoding); lock.unlock(); return
            }
            append(.delivery(.control(frame)), cost: size)
        }, output: { [self] bytes in
            append(.delivery(.output(bytes, standardError: false)), cost: bytes.count)
        }, standardError: { [self] bytes in
            append(.delivery(.output(bytes, standardError: true)), cost: bytes.count)
        }, closed: { [self] error in
            append(.closed(error), cost: 0, final: true)
        })
    }

    private func append(_ event: Event, cost: Int, final: Bool = false) {
        lock.lock(); defer { lock.unlock() }
        guard !ended else { return }
        guard pending.count < maximumEvents, cost <= maximumBytes - bytes else {
            failLocked(.overflow); return
        }
        pending.append(event)
        bytes += cost
        ended = final
        notifyLocked()
    }
    private func failLocked(_ error: Failure) {
        guard !ended else { return }
        failure = error
        ended = true
        pending.removeAll(keepingCapacity: false)
        bytes = 0
        notifyLocked()
    }
    private func notifyLocked() {
        guard !notified else { return }
        var byte: UInt8 = 1
        var result: Int
        repeat { result = Glibc.send(notifier, &byte, 1, Int32(MSG_NOSIGNAL)) }
        while result < 0 && errno == EINTR
        if result != 1 {
            failure = .notification(errno)
            ended = true
            // Wake poll even if its byte could not be sent.
            _ = Glibc.shutdown(notifier, Int32(SHUT_WR))
        }
        notified = true
    }

    /// A single consumer drains the notification under the same lock as the batch swap. A new
    /// producer therefore either joins this batch or sends the next wakeup; none can be lost.
    func take() throws -> [Event] {
        lock.lock(); defer { lock.unlock() }
        if notified {
            var byte: UInt8 = 0
            var result: Int
            repeat { result = Glibc.read(descriptor, &byte, 1) }
            while result < 0 && errno == EINTR
            notified = false
        }
        if let failure { throw failure }
        let result = pending
        pending = []
        bytes = 0
        return result
    }
}
#endif
