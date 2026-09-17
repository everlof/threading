#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif
import Foundation

// MARK: - POSIX

/// Every call the bridge makes whose spelling differs between Darwin and Linux, and nothing else.
///
/// The bridge is one program on both systems: the Mac embeds it, and a remote execution host runs
/// a static Linux build of it so an agent there reaches Threading through a forwarded socket (see
/// `docs/feature-drafts/remote-execution-hosts.md`). What differs is spelling — the C module, a
/// `sockaddr_un` field Linux lacks, a socket option Linux does not have — and each is answered here
/// once, the way `PTYHostPOSIX` answers it for the daemon.
enum BridgePOSIX {

    /// `read(2)`, qualified: several types here have a method of their own with the same name.
    static func read(_ descriptor: Int32, _ buffer: UnsafeMutableRawPointer?, _ count: Int) -> Int {
        #if canImport(Darwin)
        return Darwin.read(descriptor, buffer, count)
        #elseif canImport(Glibc)
        return Glibc.read(descriptor, buffer, count)
        #else
        return Musl.read(descriptor, buffer, count)
        #endif
    }

    static func write(_ descriptor: Int32, _ buffer: UnsafeRawPointer, _ count: Int) -> Int {
        #if canImport(Darwin)
        return Darwin.write(descriptor, buffer, count)
        #elseif canImport(Glibc)
        return Glibc.write(descriptor, buffer, count)
        #else
        return Musl.write(descriptor, buffer, count)
        #endif
    }

    @discardableResult
    static func close(_ descriptor: Int32) -> Int32 {
        #if canImport(Darwin)
        return Darwin.close(descriptor)
        #elseif canImport(Glibc)
        return Glibc.close(descriptor)
        #else
        return Musl.close(descriptor)
        #endif
    }

    @discardableResult
    static func shutdownBoth(_ descriptor: Int32) -> Int32 {
        #if canImport(Darwin)
        return Darwin.shutdown(descriptor, SHUT_RDWR)
        #elseif canImport(Glibc)
        return Glibc.shutdown(descriptor, Int32(SHUT_RDWR))
        #else
        return Musl.shutdown(descriptor, SHUT_RDWR)
        #endif
    }

    static func connect(
        _ descriptor: Int32,
        _ address: UnsafePointer<sockaddr>,
        _ length: socklen_t
    ) -> Int32 {
        #if canImport(Darwin)
        return Darwin.connect(descriptor, address, length)
        #elseif canImport(Glibc)
        return Glibc.connect(descriptor, address, length)
        #else
        return Musl.connect(descriptor, address, length)
        #endif
    }

    /// A unix stream socket. Glibc spells the type as an enum; Darwin and musl as an integer.
    static func unixStreamSocket() -> Int32 {
        #if canImport(Glibc)
        return socket(AF_UNIX, Int32(SOCK_STREAM.rawValue), 0)
        #else
        return socket(AF_UNIX, SOCK_STREAM, 0)
        #endif
    }

    /// Sets the length field only a BSD `sockaddr_un` has.
    static func prepare(_ address: inout sockaddr_un) {
        address.sun_family = sa_family_t(AF_UNIX)
        #if canImport(Darwin)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        #endif
    }

    /// Keeps a write to a closed socket from raising `SIGPIPE`, where the system has a per-socket
    /// switch for it. Linux has none; there the process-wide `SIG_IGN` in `main` is what holds.
    static func suppressSignalOnWrite(_ descriptor: Int32) {
        #if canImport(Darwin)
        var suppress: Int32 = 1
        _ = setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &suppress, socklen_t(MemoryLayout<Int32>.size))
        #endif
    }
}
