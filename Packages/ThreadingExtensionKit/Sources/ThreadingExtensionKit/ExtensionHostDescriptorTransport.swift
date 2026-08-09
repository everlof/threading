import Foundation
#if canImport(Darwin)
import Darwin
#endif

#if os(WASI)
/// The only host escape hatch available to a WebAssembly extension.
///
/// The guest passes one complete HTTP-framed broker request and receives one complete response.
/// It cannot open the inherited descriptor itself: the native runner owns that descriptor and
/// implements this import. Keeping the bytes identical to descriptor mode lets the host retain
/// one authenticated router and one capability policy.
@_extern(wasm, module: "threading", name: "host_exchange")
@_extern(c)
private func threadingHostExchange(
    request: UnsafeRawPointer,
    requestLength: Int32,
    response: UnsafeMutableRawPointer,
    responseCapacity: Int32
) -> Int32
#endif

/// Carries the host's HTTP/1.1 request-response exchange over an inherited socket.
///
/// The bytes on the wire are identical to the loopback transport — same request line, same
/// bearer header, same `Content-Length` framing — so the host answers both through one router
/// and neither side has a second protocol to keep in step. Only the carrier differs, and it
/// differs for two reasons worth stating:
///
/// - A sandboxed extension needs no network authority to reach a descriptor it was handed,
///   which is what lets the supported runner deny networking outright to every extension that
///   did not declare `network.client`.
/// - There is no port to guess. A second process running as the same user cannot reach the
///   broker at all, where with a loopback port it can reach it and merely fail to authenticate.
///
/// Revocation is a `close()` on the host's end, which arrives here as end-of-file rather than
/// as a status code on the next call.
public final class ExtensionHostDescriptorTransport: @unchecked Sendable {
    /// One transport per descriptor.
    ///
    /// `ExtensionHostClient` is a value type built wherever it is needed, so two clients over
    /// one socket would interleave their requests without this. The exchange is strictly
    /// serialized: a socket carries no request identifiers, so the reply is only attributable
    /// while exactly one request is outstanding.
    public static func shared(for descriptor: Int32) -> ExtensionHostDescriptorTransport {
        registryLock.lock()
        defer { registryLock.unlock() }
        if let existing = transports[descriptor] {
            return existing
        }
        let transport = ExtensionHostDescriptorTransport(descriptor: descriptor)
        transports[descriptor] = transport
        return transport
    }

    /// Drops the cached transport for a descriptor that is being closed.
    ///
    /// An extension never needs this: its broker socket is handed over at spawn and lives as
    /// long as the process. A harness that opens and closes many sockets does, because the
    /// kernel recycles descriptor numbers and the cache is keyed by number — there is nothing
    /// else stable to key it by.
    public static func forget(descriptor: Int32) {
        registryLock.lock()
        defer { registryLock.unlock() }
        transports.removeValue(forKey: descriptor)
    }

    private static let registryLock = NSLock()
    private static var transports: [Int32: ExtensionHostDescriptorTransport] = [:]

    /// A response header block larger than this is a host that is not speaking this protocol.
    private static let maximumHeaderBytes = 64 * 1024
    /// Bounds a malformed or hostile `Content-Length` before it is used to size a read loop.
    private static let maximumBodyBytes = 8 * 1024 * 1024
    private static let headerTerminator = Data("\r\n\r\n".utf8)

    private let descriptor: Int32
#if !os(WASI)
    private let queue: DispatchQueue
#endif
    private var buffer = Data()

    init(descriptor: Int32) {
        // The descriptor belongs to the process, not to this object: closing it would revoke
        // the host connection whenever a transport happened to be released.
        self.descriptor = descriptor
#if !os(WASI)
        queue = DispatchQueue(
            label: "codes.threading.extension-host-descriptor.\(descriptor)"
        )
#endif
    }

    func send(
        method: String,
        requestTarget: String,
        bearerToken: String,
        contentType: String?,
        body: Data?
    ) async throws -> (status: Int, body: Data) {
        let request = Self.serialize(
            method: method,
            requestTarget: requestTarget,
            bearerToken: bearerToken,
            contentType: contentType,
            body: body
        )
#if os(WASI)
        return try exchange(request)
#else
        return try await withCheckedThrowingContinuation { continuation in
            queue.async { [self] in
                continuation.resume(with: Result { try exchange(request) })
            }
        }
#endif
    }

    /// The same exchange, without Swift concurrency.
    ///
    /// Storage has always been a synchronous API because it was file I/O, and an extension's
    /// serve loop is an ordinary `readLine` loop rather than an async context. Moving storage
    /// onto the broker must not force every extension that keeps a counter to become async, so
    /// the transport offers both shapes over the one serialized queue.
    func sendSynchronously(
        method: String,
        requestTarget: String,
        bearerToken: String,
        contentType: String?,
        body: Data?
    ) throws -> (status: Int, body: Data) {
        let request = Self.serialize(
            method: method,
            requestTarget: requestTarget,
            bearerToken: bearerToken,
            contentType: contentType,
            body: body
        )
#if os(WASI)
        return try exchange(request)
#else
        return try queue.sync {
            try exchange(request)
        }
#endif
    }

    /// Writes one request and reads exactly one response. Runs on `queue`, which is what makes
    /// the pairing safe.
    ///
    /// The syscalls are used directly rather than through `FileHandle`, for two reasons that
    /// each cost a debugging session to find: `read(upToCount:)` blocks on a socket until it
    /// has the *whole* count, so a chunk-sized read waits for bytes the host was never going to
    /// send; and `FileHandle` reports an I/O error by raising an Objective-C exception, which a
    /// revoked connection would turn into a crash instead of a thrown `hostClosed`.
    private func exchange(_ request: Data) throws -> (status: Int, body: Data) {
#if os(WASI)
        return try exchangeOverWasmImport(request)
#else
        try writeAll(request)

        var chunk = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            if let response = try Self.parseResponse(from: &buffer) {
                return response
            }
            guard buffer.count <= Self.maximumHeaderBytes + Self.maximumBodyBytes else {
                throw ExtensionHostClientError.invalidResponse
            }

            let read = chunk.withUnsafeMutableBytes { raw -> Int in
                var result = 0
                repeat {
                    result = Darwin.read(descriptor, raw.baseAddress, raw.count)
                } while result < 0 && errno == EINTR
                return result
            }
            guard read > 0 else {
                // Zero is end-of-file, which is how a revoked generation is told. An error is
                // reported the same way: either way the host is gone.
                throw ExtensionHostClientError.hostClosed
            }
            buffer.append(contentsOf: chunk[0..<read])
        }
#endif
    }

#if os(WASI)
    /// Executes one broker exchange through the runner's sole imported function.
    ///
    /// A fixed protocol cap is intentional. It bounds guest allocation before native code sees
    /// a pointer and matches the descriptor parser's existing header/body limits.
    private func exchangeOverWasmImport(
        _ request: Data
    ) throws -> (status: Int, body: Data) {
        guard request.count <= Int(Int32.max) else {
            throw ExtensionHostClientError.invalidResponse
        }

        let responseCapacity = Self.maximumHeaderBytes + Self.maximumBodyBytes
        var response = Data(count: responseCapacity)
        let count: Int32 = request.withUnsafeBytes { requestBytes in
            response.withUnsafeMutableBytes { responseBytes in
                threadingHostExchange(
                    request: requestBytes.baseAddress!,
                    requestLength: Int32(requestBytes.count),
                    response: responseBytes.baseAddress!,
                    responseCapacity: Int32(responseBytes.count)
                )
            }
        }
        guard count >= 0 else {
            throw ExtensionHostClientError.hostClosed
        }
        guard Int(count) <= responseCapacity else {
            throw ExtensionHostClientError.invalidResponse
        }

        response.count = Int(count)
        var framedResponse = response
        guard let parsed = try Self.parseResponse(from: &framedResponse),
              framedResponse.isEmpty else {
            throw ExtensionHostClientError.invalidResponse
        }
        return parsed
    }
#else
    private func writeAll(_ data: Data) throws {
        try data.withUnsafeBytes { raw in
            var offset = 0
            while offset < raw.count {
                var written = 0
                repeat {
                    written = Darwin.write(
                        descriptor,
                        raw.baseAddress.map { $0 + offset },
                        raw.count - offset
                    )
                } while written < 0 && errno == EINTR
                guard written > 0 else {
                    throw ExtensionHostClientError.hostClosed
                }
                offset += written
            }
        }
    }
#endif

    static func serialize(
        method: String,
        requestTarget: String,
        bearerToken: String,
        contentType: String?,
        body: Data?
    ) -> Data {
        var head = "\(method) \(requestTarget) HTTP/1.1\r\n"
        head += "Host: threading-extension-host\r\n"
        head += "Authorization: Bearer \(bearerToken)\r\n"
        if let contentType {
            head += "Content-Type: \(contentType)\r\n"
        }
        head += "Content-Length: \(body?.count ?? 0)\r\n"
        head += "Connection: keep-alive\r\n\r\n"
        return Data(head.utf8) + (body ?? Data())
    }

    /// Returns one complete response and removes its bytes from `buffer`, or nil while the
    /// response is still arriving.
    static func parseResponse(from buffer: inout Data) throws -> (status: Int, body: Data)? {
        guard let terminator = buffer.range(of: headerTerminator) else {
            guard buffer.count <= maximumHeaderBytes else {
                throw ExtensionHostClientError.invalidResponse
            }
            return nil
        }
        guard let head = String(
            data: buffer[buffer.startIndex..<terminator.lowerBound],
            encoding: .utf8
        ) else {
            throw ExtensionHostClientError.invalidResponse
        }

        var lines = head.components(separatedBy: "\r\n")
        guard !lines.isEmpty else {
            throw ExtensionHostClientError.invalidResponse
        }
        let statusLine = lines.removeFirst().split(separator: " ", maxSplits: 2)
        guard statusLine.count >= 2,
              statusLine[0].hasPrefix("HTTP/1."),
              let status = Int(statusLine[1]) else {
            throw ExtensionHostClientError.invalidResponse
        }

        var headers: [String: String] = [:]
        for line in lines {
            guard let separator = line.firstIndex(of: ":") else { continue }
            let name = line[line.startIndex..<separator]
                .trimmingCharacters(in: .whitespaces)
                .lowercased()
            headers[name] = line[line.index(after: separator)...]
                .trimmingCharacters(in: .whitespaces)
        }

        // The host always states a length. A response without one cannot be delimited without
        // closing the socket, which this transport keeps open for the next call.
        guard let rawLength = headers["content-length"],
              let length = Int(rawLength),
              length >= 0,
              length <= maximumBodyBytes else {
            throw ExtensionHostClientError.invalidResponse
        }

        let bodyStart = terminator.upperBound
        let bodyEnd = bodyStart + length
        guard buffer.count >= bodyEnd - buffer.startIndex else { return nil }

        let body = Data(buffer[bodyStart..<bodyEnd])
        buffer = Data(buffer[bodyEnd...])
        return (status, body)
    }
}
