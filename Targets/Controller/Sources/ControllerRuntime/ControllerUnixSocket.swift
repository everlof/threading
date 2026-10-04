import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

enum ControllerSocketError: Error, Equatable {
    case pathTooLong, notASocket, unavailable(Int32), timedOut, tooLarge, closed
}

/// The few Unix-socket calls the agent broker and its client make, each with an elapsed-time
/// deadline. Every descriptor is close-on-exec and nonblocking; nothing here blocks past its
/// deadline, installs a signal disposition, or raises SIGPIPE.
enum ControllerUnixSocket {
    #if canImport(Darwin)
    private static let streamType = SOCK_STREAM
    #else
    private static let streamType = Int32(SOCK_STREAM.rawValue)
    /// `SO_PEERCRED` on the Linux ABIs this builds for (x86_64, arm64), read into `struct ucred`
    /// ({pid, uid, gid}, three 32-bit fields) without depending on `_GNU_SOURCE` in the module map.
    private static let peerCredentialsOption: Int32 = 17
    #endif

    static func address(_ path: String) throws -> sockaddr_un {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        #if canImport(Darwin)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        #endif
        let bytes = Array(path.utf8)
        let capacity = MemoryLayout.size(ofValue: address.sun_path)
        guard !bytes.isEmpty, bytes.count < capacity, !bytes.contains(0) else { throw ControllerSocketError.pathTooLong }
        withUnsafeMutablePointer(to: &address.sun_path) { tuple in
            tuple.withMemoryRebound(to: CChar.self, capacity: capacity) { destination in
                for (index, byte) in bytes.enumerated() { destination[index] = CChar(bitPattern: byte) }
                destination[bytes.count] = 0
            }
        }
        return address
    }

    private static func makeSocket() throws -> Int32 {
        let descriptor = socket(AF_UNIX, streamType, 0)
        guard descriptor >= 0 else { throw ControllerSocketError.unavailable(errno) }
        let flags = fcntl(descriptor, F_GETFL, 0)
        guard fcntl(descriptor, F_SETFD, FD_CLOEXEC) == 0, flags >= 0, fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) == 0 else {
            let failure = errno
            close(descriptor)
            throw ControllerSocketError.unavailable(failure)
        }
        #if canImport(Darwin)
        var suppress: Int32 = 1
        _ = setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &suppress, socklen_t(MemoryLayout<Int32>.size))
        #endif
        return descriptor
    }

    /// Binds a listener. A leftover *socket* at the path is replaced (the caller holds the lock
    /// that makes it the only listener); anything else there is refused, never deleted.
    static func listen(path: String, mode: mode_t, backlog: Int32) throws -> Int32 {
        var address = try address(path)
        var info = stat()
        if lstat(path, &info) == 0 {
            guard info.st_mode & S_IFMT == S_IFSOCK else { throw ControllerSocketError.notASocket }
            unlink(path)
        }
        let descriptor = try makeSocket()
        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        // The socket is created under the process umask (owner-only for the service), then
        // widened to exactly `mode`: the window in between is narrower, never wider.
        guard bound == 0, chmod(path, mode) == 0, systemListen(descriptor, backlog) == 0 else {
            let failure = errno
            close(descriptor)
            throw ControllerSocketError.unavailable(failure)
        }
        return descriptor
    }

    static func connect(path: String, timeout: TimeInterval) throws -> Int32 {
        var address = try address(path)
        let descriptor = try makeSocket()
        let started = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                systemConnect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        if started != 0 {
            // A Unix socket whose backlog is full answers EAGAIN rather than EINPROGRESS on Linux.
            guard errno == EINPROGRESS else {
                let failure = errno
                close(descriptor)
                throw ControllerSocketError.unavailable(failure)
            }
            do {
                try wait(descriptor, for: Int16(POLLOUT), until: deadline(after: timeout))
                var failure: Int32 = 0
                var size = socklen_t(MemoryLayout<Int32>.size)
                guard getsockopt(descriptor, SOL_SOCKET, SO_ERROR, &failure, &size) == 0, failure == 0 else {
                    throw ControllerSocketError.unavailable(failure)
                }
            } catch {
                close(descriptor)
                throw error
            }
        }
        return descriptor
    }

    static func deadline(after seconds: TimeInterval) -> UInt64 {
        DispatchTime.now().uptimeNanoseconds + UInt64(max(0, seconds) * 1_000_000_000)
    }

    /// Waits for readiness until `deadline` (uptime nanoseconds).
    static func wait(_ descriptor: Int32, for events: Int16, until deadline: UInt64) throws {
        while true {
            let now = DispatchTime.now().uptimeNanoseconds
            guard now < deadline else { throw ControllerSocketError.timedOut }
            let milliseconds = Int32(min(UInt64(Int32.max), (deadline - now + 999_999) / 1_000_000))
            var event = pollfd(fd: descriptor, events: events, revents: 0)
            let ready = poll(&event, 1, milliseconds)
            if ready < 0 {
                if errno == EINTR { continue }
                throw ControllerSocketError.unavailable(errno)
            }
            if ready > 0 { return }
        }
    }

    /// Reads up to the first newline, which is not returned. More than `maximum` bytes before it
    /// is `tooLarge`; end of stream before it is `closed`.
    static func readLine(_ descriptor: Int32, maximum: Int, until deadline: UInt64) throws -> Data {
        var line = Data()
        var buffer = [UInt8](repeating: 0, count: 16_384)
        while true {
            try wait(descriptor, for: Int16(POLLIN), until: deadline)
            let count = read(descriptor, &buffer, buffer.count)
            if count < 0 {
                if errno == EINTR || errno == EAGAIN || errno == EWOULDBLOCK { continue }
                throw ControllerSocketError.unavailable(errno)
            }
            guard count > 0 else { throw ControllerSocketError.closed }
            if let newline = buffer[..<count].firstIndex(of: 10) {
                line.append(contentsOf: buffer[..<newline])
                guard line.count <= maximum else { throw ControllerSocketError.tooLarge }
                return line
            }
            line.append(contentsOf: buffer[..<count])
            guard line.count <= maximum else { throw ControllerSocketError.tooLarge }
        }
    }

    static func writeAll(_ descriptor: Int32, _ data: Data, until deadline: UInt64) throws {
        try data.withUnsafeBytes { bytes in
            guard let base = bytes.baseAddress else { return }
            var offset = 0
            while offset < bytes.count {
                try wait(descriptor, for: Int16(POLLOUT), until: deadline)
                #if canImport(Darwin)
                let count = send(descriptor, base + offset, bytes.count - offset, 0)
                #else
                let count = send(descriptor, base + offset, bytes.count - offset, Int32(MSG_NOSIGNAL))
                #endif
                if count < 0 {
                    if errno == EINTR || errno == EAGAIN || errno == EWOULDBLOCK { continue }
                    throw ControllerSocketError.closed
                }
                offset += count
            }
        }
    }

    /// The connecting process's effective uid, as the kernel recorded it at connect.
    static func peerUID(_ descriptor: Int32) -> UInt32? {
        #if canImport(Darwin)
        var uid: uid_t = 0
        var gid: gid_t = 0
        return getpeereid(descriptor, &uid, &gid) == 0 ? uid : nil
        #else
        var credentials: (Int32, UInt32, UInt32) = (0, 0, 0)
        var size = socklen_t(MemoryLayout<(Int32, UInt32, UInt32)>.size)
        return getsockopt(descriptor, SOL_SOCKET, peerCredentialsOption, &credentials, &size) == 0 ? credentials.1 : nil
        #endif
    }

    static func close(_ descriptor: Int32) {
        #if canImport(Darwin)
        _ = Darwin.close(descriptor)
        #else
        _ = Glibc.close(descriptor)
        #endif
    }

    private static func systemListen(_ descriptor: Int32, _ backlog: Int32) -> Int32 {
        #if canImport(Darwin)
        Darwin.listen(descriptor, backlog)
        #else
        Glibc.listen(descriptor, backlog)
        #endif
    }

    private static func systemConnect(_ descriptor: Int32, _ address: UnsafePointer<sockaddr>, _ length: socklen_t) -> Int32 {
        #if canImport(Darwin)
        Darwin.connect(descriptor, address, length)
        #else
        Glibc.connect(descriptor, address, length)
        #endif
    }
}
