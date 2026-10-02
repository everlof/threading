@testable import CoreSlice
@testable import ThreadingPTYClient
import Foundation
#if os(Linux)
import Glibc

func runSocketContracts() throws {
    let directory = URL(fileURLWithPath: "/tmp").appendingPathComponent("ts-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
                                           attributes: [.posixPermissions: 0o700])
    defer { try? FileManager.default.removeItem(at: directory) }
    let path = directory.appendingPathComponent("socket").path
    let listener = socket(AF_UNIX, Int32(SOCK_STREAM.rawValue | SOCK_CLOEXEC.rawValue), 0)
    try require(listener >= 0, "socket fixture")
    defer { Glibc.close(listener) }
    var address = sockaddr_un()
    address.sun_family = sa_family_t(AF_UNIX)
    let capacity = MemoryLayout.size(ofValue: address.sun_path)
    let bytes = Array(path.utf8)
    try require(bytes.count < capacity, "fixture path bound")
    withUnsafeMutablePointer(to: &address.sun_path) { tuple in
        tuple.withMemoryRebound(to: UInt8.self, capacity: capacity) { destination in
            for (index, byte) in bytes.enumerated() { destination[index] = byte }
        }
    }
    let bound = withUnsafePointer(to: &address) { pointer in
        pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            Glibc.bind(listener, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
        }
    }
    try require(bound == 0 && listen(listener, 4) == 0, "listen fixture")
    for nonblocking in [false, true] {
        let descriptor = try PTYHostSocket.connect(to: path, timeout: 1, nonblocking: nonblocking)
        defer { Glibc.close(descriptor) }
        try require(fcntl(descriptor, F_GETFD) & FD_CLOEXEC != 0, "socket must close across exec")
        try require((fcntl(descriptor, F_GETFL) & O_NONBLOCK != 0) == nonblocking, "requested socket mode")
    }
    do {
        _ = try PTYHostSocket.connect(to: path + "\0suffix", timeout: 1)
        throw ContractFailure.failed("embedded NUL connected to path prefix")
    } catch PTYHostClientError.connectFailed(let code) { try require(code == EINVAL, "NUL refusal cause") }
    do {
        _ = try PTYHostSocket.connect(to: path + "-absent", timeout: 1)
        throw ContractFailure.failed("missing socket connected")
    } catch PTYHostClientError.connectFailed(let code) { try require(code == ENOENT, "missing path cause") }
    do {
        _ = try PTYHostSocket.connect(to: String(repeating: "x", count: capacity), timeout: 1)
        throw ContractFailure.failed("oversize socket path accepted")
    } catch PTYHostClientError.pathTooLong(let count) { try require(count == capacity, "path bound count") }
    print("PASS shared Unix connector: blocking/nonblocking modes, close-on-exec and exact path refusal")
}
#else
func runSocketContracts() throws { }
#endif
