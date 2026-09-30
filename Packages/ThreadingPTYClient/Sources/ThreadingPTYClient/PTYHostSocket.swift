import Dispatch
import Foundation
#if os(Linux)
import Glibc
#else
import Darwin
#endif

/// Platform socket setup shared by the GUI client and Linux host. The caller owns the returned
/// descriptor. No event pump, protocol handshake, process-global signal handler or journal lives
/// here; those belong to the connection owner.
enum PTYHostSocket {
    @discardableResult
    static func close(_ descriptor: Int32) -> Int32 {
        #if os(Linux)
        return Glibc.close(descriptor)
        #else
        return Darwin.close(descriptor)
        #endif
    }

    @discardableResult
    static func shutdown(_ descriptor: Int32, _ how: Int32) -> Int32 {
        #if os(Linux)
        return Glibc.shutdown(descriptor, how)
        #else
        return Darwin.shutdown(descriptor, how)
        #endif
    }

    static func read(_ descriptor: Int32, _ bytes: UnsafeMutableRawPointer?, _ count: Int) -> Int {
        #if os(Linux)
        return Glibc.read(descriptor, bytes, count)
        #else
        return Darwin.read(descriptor, bytes, count)
        #endif
    }

    /// A whole frame has one elapsed-time budget. MSG_DONTWAIT keeps a readiness race from
    /// turning send into a blocking call; Linux suppresses SIGPIPE on this send only.
    static func writeAll(descriptor: Int32, data: Data, timeout: TimeInterval) throws {
        let start = DispatchTime.now().uptimeNanoseconds
        try data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let elapsed = Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000_000
                let remaining = timeout - elapsed
                guard remaining > 0 else { throw PTYHostClientError.writeFailed(errno: ETIMEDOUT) }
                var event = pollfd(fd: descriptor, events: Int16(POLLOUT), revents: 0)
                let ready = poll(&event, 1, Int32(min(Double(Int32.max), (remaining * 1000).rounded(.up))))
                if ready < 0 && errno == EINTR { continue }
                guard ready > 0 else { throw PTYHostClientError.writeFailed(errno: ready == 0 ? ETIMEDOUT : errno) }
                #if os(Linux)
                let count = Glibc.send(descriptor, bytes.baseAddress! + offset, bytes.count - offset,
                                       Int32(MSG_DONTWAIT | MSG_NOSIGNAL))
                #else
                let count = Darwin.send(descriptor, bytes.baseAddress! + offset, bytes.count - offset, MSG_DONTWAIT)
                #endif
                if count < 0 && (errno == EINTR || errno == EAGAIN || errno == EWOULDBLOCK) { continue }
                guard count > 0 else { throw PTYHostClientError.writeFailed(errno: count == 0 ? EPIPE : errno) }
                offset += count
            }
        }
    }

    static func connect(to path: String, timeout: TimeInterval, nonblocking: Bool = false) throws -> Int32 {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        #if !os(Linux)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        #endif
        let bytes = Array(path.utf8)
        let capacity = MemoryLayout.size(ofValue: address.sun_path)
        guard bytes.count < capacity else { throw PTYHostClientError.pathTooLong(bytes: bytes.count) }
        // A Swift string can contain NUL; the kernel would silently connect to its prefix.
        guard !bytes.contains(0) else { throw PTYHostClientError.connectFailed(errno: EINVAL) }
        withUnsafeMutablePointer(to: &address.sun_path) { tuple in
            tuple.withMemoryRebound(to: CChar.self, capacity: capacity) { destination in
                for (index, byte) in bytes.enumerated() { destination[index] = CChar(bitPattern: byte) }
                destination[bytes.count] = 0
            }
        }
        #if os(Linux)
        let descriptor = socket(AF_UNIX, Int32(SOCK_STREAM.rawValue | SOCK_CLOEXEC.rawValue), 0)
        #else
        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        #endif
        guard descriptor >= 0 else { throw PTYHostClientError.socketUnavailable(errno: errno) }
        do {
            #if !os(Linux)
            let descriptorFlags = fcntl(descriptor, F_GETFD)
            guard descriptorFlags >= 0, fcntl(descriptor, F_SETFD, descriptorFlags | FD_CLOEXEC) >= 0 else {
                throw PTYHostClientError.socketUnavailable(errno: errno)
            }
            var suppressSignal: Int32 = 1
            guard setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &suppressSignal,
                             socklen_t(MemoryLayout<Int32>.size)) == 0 else {
                throw PTYHostClientError.socketUnavailable(errno: errno)
            }
            #endif
            let flags = fcntl(descriptor, F_GETFL, 0)
            guard flags >= 0, fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) >= 0 else {
                throw PTYHostClientError.connectFailed(errno: errno)
            }
            let started = withUnsafePointer(to: &address) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { generic in
                    #if os(Linux)
                    Glibc.connect(descriptor, generic, socklen_t(MemoryLayout<sockaddr_un>.size))
                    #else
                    Darwin.connect(descriptor, generic, socklen_t(MemoryLayout<sockaddr_un>.size))
                    #endif
                }
            }
            if started != 0 {
                guard errno == EINPROGRESS else { throw PTYHostClientError.connectFailed(errno: errno) }
                try waitForConnect(descriptor: descriptor, timeout: timeout)
            }
            if !nonblocking, fcntl(descriptor, F_SETFL, flags) < 0 {
                throw PTYHostClientError.connectFailed(errno: errno)
            }
            return descriptor
        } catch {
            #if os(Linux)
            Glibc.close(descriptor)
            #else
            Darwin.close(descriptor)
            #endif
            throw error
        }
    }

    private static func waitForConnect(descriptor: Int32, timeout: TimeInterval) throws {
        // The timeout bounds elapsed time, not wall-clock corrections during a connection.
        let start = DispatchTime.now().uptimeNanoseconds
        while true {
            let elapsed = Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000_000
            let remaining = timeout - elapsed
            guard remaining > 0 else { throw PTYHostClientError.connectTimedOut }
            let milliseconds = Int32(min(Double(Int32.max), (remaining * 1000).rounded(.up)))
            var event = pollfd(fd: descriptor, events: Int16(POLLOUT), revents: 0)
            let ready = poll(&event, 1, milliseconds)
            if ready < 0 {
                if errno == EINTR { continue }
                throw PTYHostClientError.connectFailed(errno: errno)
            }
            guard ready > 0 else { throw PTYHostClientError.connectTimedOut }
            var failure: Int32 = 0
            var size = socklen_t(MemoryLayout<Int32>.size)
            guard getsockopt(descriptor, SOL_SOCKET, SO_ERROR, &failure, &size) == 0 else {
                throw PTYHostClientError.connectFailed(errno: errno)
            }
            guard failure == 0 else { throw PTYHostClientError.connectFailed(errno: failure) }
            return
        }
    }
}
