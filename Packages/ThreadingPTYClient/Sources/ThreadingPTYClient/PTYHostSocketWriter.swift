#if os(Linux)
import Dispatch
import Foundation
import Glibc

/// Linux's socket-local SIGPIPE policy cannot be expressed through DispatchIO.write. Keep
/// DispatchIO's read pump and serialize MSG_NOSIGNAL writes on a separate worker. The client
/// admits/bounds queued bytes before entering this leaf; no frame is accumulated on main.
final class PTYHostSocketWriter: @unchecked Sendable {
    private let descriptor: Int32
    private let queue = DispatchQueue(label: "codes.threading.ptyhost.socket-writer", qos: .userInteractive)
    private let lock = NSLock()
    private var closed = false

    init(descriptor: Int32) throws {
        // Separate descriptor ownership prevents DispatchIO cleanup/reuse racing an active send.
        let owned = fcntl(descriptor, F_DUPFD_CLOEXEC, 0)
        guard owned >= 0 else { throw PTYHostClientError.socketUnavailable(errno: errno) }
        self.descriptor = owned
    }

    deinit { if !closed { PTYHostSocket.close(descriptor) } }

    func write(_ data: Data, completion: @escaping @Sendable (Int32) -> Void) {
        lock.lock()
        guard !closed else { lock.unlock(); completion(EBADF); return }
        queue.async { [self] in
            lock.lock()
            let cancelled = closed
            lock.unlock()
            guard !cancelled else { completion(ECANCELED); return }
            do {
                try PTYHostSocket.writeAll(descriptor: descriptor, data: data,
                                           timeout: PTYHostClientDefaults.helloTimeout)
                completion(0)
            } catch PTYHostClientError.writeFailed(let code) { completion(code) }
            catch { completion(EIO) }
        }
        lock.unlock()
    }

    func close() {
        lock.lock()
        guard !closed else { lock.unlock(); return }
        closed = true
        let descriptor = descriptor
        // Socket shutdown belongs to the client and wakes any blocked poll. Closing the owned
        // descriptor follows admitted work so a reused descriptor can never receive its bytes.
        queue.async { PTYHostSocket.close(descriptor) }
        lock.unlock()
    }
}
#endif
