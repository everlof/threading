import Darwin
import Foundation

// MARK: - Errors

enum UnixHTTPError: Error, CustomStringConvertible {
    case pathTooLong(Int)
    case socketUnavailable(Int32)
    case connectFailed(Int32)
    case connectTimedOut
    case writeFailed(Int32)
    case readFailed(Int32)
    /// The peer went away before a complete response head or body arrived.
    case closedEarly
    case malformedResponse
    case oversizedResponse
    /// The app answered, but not with what this request needs — a revoked token is a 404 here.
    case unexpectedStatus(Int)

    var description: String {
        switch self {
        case .pathTooLong(let count):
            return "socket path is \(count) bytes, longer than sockaddr_un allows"
        case .socketUnavailable(let code):
            return "socket() failed: \(String(cString: strerror(code)))"
        case .connectFailed(let code):
            return "connect() failed: \(String(cString: strerror(code)))"
        case .connectTimedOut:
            return "connect() timed out after \(BridgeDefaults.connectTimeout)s"
        case .writeFailed(let code):
            return "write() failed: \(String(cString: strerror(code)))"
        case .readFailed(let code):
            return "read() failed: \(String(cString: strerror(code)))"
        case .closedEarly:
            return "the app closed the connection before answering"
        case .malformedResponse:
            return "the response could not be parsed as HTTP/1.1"
        case .oversizedResponse:
            return "the response exceeded \(BridgeDefaults.maximumMessageBytes) bytes"
        case .unexpectedStatus(let status):
            return "the app answered \(status)"
        }
    }
}

// MARK: - Response head

/// The part of a response the bridge reads before deciding what to do with the rest.
struct UnixHTTPResponseHead {
    let status: Int
    /// Lowercased names, as HTTP header lookup is case-insensitive.
    let headers: [String: String]

    /// `nil` for the event stream, which by design declares no length.
    var contentLength: Int? {
        headers["content-length"].flatMap(Int.init)
    }

    var isEventStream: Bool {
        headers["content-type"]?.hasPrefix(BridgeDefaults.eventStreamContentType) == true
    }
}

// MARK: - Request

/// The two requests the bridge makes, written out rather than assembled by URLSession.
///
/// `URLSession` cannot address a unix socket, and `curl --unix-socket` would put a process
/// launch on the path of every tool call. Both requests are three lines and a body.
enum UnixHTTPRequest {
    static func post(path: String, body: Data) -> Data {
        var head = "POST \(path) HTTP/1.1\r\n"
        head += "Host: \(BridgeDefaults.hostHeader)\r\n"
        head += "Content-Type: \(BridgeDefaults.jsonContentType)\r\n"
        head += "Accept: \(BridgeDefaults.requestAccept)\r\n"
        head += "Content-Length: \(body.count)\r\n"
        // The app answers `Connection: keep-alive` regardless and leaves the socket open; the
        // bridge closes it itself once the declared length has arrived. Saying `close` states
        // the intent for anything that ever sits between the two.
        head += "Connection: close\r\n\r\n"
        return Data(head.utf8) + body
    }

    static func get(path: String, accept: String) -> Data {
        var head = "GET \(path) HTTP/1.1\r\n"
        head += "Host: \(BridgeDefaults.hostHeader)\r\n"
        head += "Accept: \(accept)\r\n"
        head += "Connection: keep-alive\r\n\r\n"
        return Data(head.utf8)
    }
}

// MARK: - Connection

/// One connection to the app's unix-domain MCP listener, speaking the narrow HTTP/1.1 dialect
/// `MCPConnection` writes.
///
/// **Blocking POSIX sockets, one per request, on the caller's thread.** Network.framework was the
/// alternative and is the wrong shape here: every operation is "write a request, then read until
/// a declared length is satisfied", which a blocking read expresses directly and a callback API
/// only expresses through a state machine that would then have to grow a queue, a timeout table
/// and a cancellation rule of its own. A blocking read also states the one property that matters
/// most — *there is no timeout on a tool call* — as the absence of code rather than as a very
/// large number. The cost is a thread per in-flight request, which `maximumConcurrentRequests`
/// bounds.
///
/// Not thread-safe: one connection belongs to one thread for its whole life. The single exception
/// is `shutdownReads()`, which exists so a stopping bridge can wake a thread blocked in `read`.
final class UnixSocketConnection {

    // MARK: - Properties

    private var descriptor: Int32
    private var buffer = Data()

    // MARK: - Initialization

    /// Connects, or throws. `timeout` bounds the connect alone; nothing afterwards is timed.
    init(path: String, timeout: TimeInterval = BridgeDefaults.connectTimeout) throws {
        descriptor = try Self.connectedDescriptor(to: path, timeout: timeout)
    }

    deinit {
        close()
    }

    // MARK: - Public Methods

    func send(_ data: Data) throws {
        try data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            var offset = 0
            while offset < raw.count {
                let written = Darwin.write(descriptor, base + offset, raw.count - offset)
                if written > 0 {
                    offset += written
                    continue
                }
                if written < 0 && errno == EINTR { continue }
                throw UnixHTTPError.writeFailed(errno)
            }
        }
    }

    /// Reads until the header terminator, leaving any body bytes already received buffered.
    func readHead() throws -> UnixHTTPResponseHead {
        while true {
            if let terminator = buffer.range(of: Self.headerTerminator) {
                let head = Data(buffer[buffer.startIndex..<terminator.lowerBound])
                buffer = Data(buffer[terminator.upperBound...])
                return try Self.parse(head: head)
            }
            guard buffer.count <= BridgeDefaults.maximumMessageBytes else {
                throw UnixHTTPError.oversizedResponse
            }
            guard try fill() else { throw UnixHTTPError.closedEarly }
        }
    }

    /// Reads exactly `length` bytes of body. Unbounded in time on purpose: this is where a
    /// `tools/call` waits while a person answers a permission prompt.
    func readBody(length: Int) throws -> Data {
        guard length <= BridgeDefaults.maximumMessageBytes else {
            throw UnixHTTPError.oversizedResponse
        }
        while buffer.count < length {
            guard try fill() else { throw UnixHTTPError.closedEarly }
        }
        let body = Data(buffer.prefix(length))
        buffer = Data(buffer.dropFirst(length))
        return body
    }

    /// The next available bytes of an unbounded response, or `nil` at end of stream.
    ///
    /// Whatever has arrived is returned; the caller reassembles frames. Nothing here knows how
    /// large an event is, which is what keeps a stream that never ends from being buffered.
    func nextBytes() throws -> Data? {
        while buffer.isEmpty {
            guard try fill() else { return nil }
        }
        let bytes = buffer
        buffer = Data()
        return bytes
    }

    /// Wakes a thread blocked in `read` without freeing the descriptor number.
    ///
    /// `close` from another thread would race: the number can be handed to the next socket
    /// between the close and the blocked reader noticing, and the reader would then be reading
    /// somebody else's connection. `shutdown` returns the blocked read and leaves the number
    /// this connection's until it closes itself.
    func shutdownReads() {
        guard descriptor >= 0 else { return }
        _ = Darwin.shutdown(descriptor, SHUT_RDWR)
    }

    func close() {
        guard descriptor >= 0 else { return }
        _ = Darwin.close(descriptor)
        descriptor = -1
    }

    // MARK: - Private Methods

    private static let headerTerminator = Data("\r\n\r\n".utf8)

    /// Appends one read's worth of bytes. `false` means the peer closed cleanly.
    private func fill() throws -> Bool {
        var chunk = [UInt8](repeating: 0, count: BridgeDefaults.socketReadChunk)
        let count = chunk.withUnsafeMutableBytes { raw -> Int in
            Darwin.read(descriptor, raw.baseAddress, raw.count)
        }
        if count > 0 {
            buffer.append(contentsOf: chunk[0..<count])
            return true
        }
        if count == 0 { return false }
        if errno == EINTR { return true }
        throw UnixHTTPError.readFailed(errno)
    }

    private static func parse(head: Data) throws -> UnixHTTPResponseHead {
        guard let text = String(data: head, encoding: .utf8) else {
            throw UnixHTTPError.malformedResponse
        }
        var lines = text.components(separatedBy: "\r\n")
        guard !lines.isEmpty else { throw UnixHTTPError.malformedResponse }

        let statusLine = lines.removeFirst().split(separator: " ")
        guard statusLine.count >= 2, let status = Int(statusLine[1]) else {
            throw UnixHTTPError.malformedResponse
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

        return UnixHTTPResponseHead(status: status, headers: headers)
    }

    // MARK: - Connecting

    private static func connectedDescriptor(to path: String, timeout: TimeInterval) throws -> Int32 {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)

        let pathBytes = Array(path.utf8)
        let capacity = MemoryLayout.size(ofValue: address.sun_path)
        guard pathBytes.count < capacity else { throw UnixHTTPError.pathTooLong(pathBytes.count) }
        withUnsafeMutablePointer(to: &address.sun_path) { tuple in
            tuple.withMemoryRebound(to: CChar.self, capacity: capacity) { destination in
                for (index, byte) in pathBytes.enumerated() {
                    destination[index] = CChar(bitPattern: byte)
                }
                destination[pathBytes.count] = 0
            }
        }

        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw UnixHTTPError.socketUnavailable(errno) }

        // Without this, writing to a socket the app has already closed raises SIGPIPE and kills
        // the bridge — which would look to the CLI exactly like the server crashing.
        var suppressSignal: Int32 = 1
        _ = setsockopt(
            descriptor,
            SOL_SOCKET,
            SO_NOSIGPIPE,
            &suppressSignal,
            socklen_t(MemoryLayout<Int32>.size)
        )

        do {
            try connect(descriptor: descriptor, to: &address, timeout: timeout)
        } catch {
            _ = Darwin.close(descriptor)
            throw error
        }
        return descriptor
    }

    /// Connects with a deadline, by asking for a non-blocking connect and polling it.
    ///
    /// `SO_SNDTIMEO` does not bound a blocking `connect`, so the deadline has to be expressed
    /// this way. The descriptor is put back into blocking mode afterwards, because everything
    /// past the connect is deliberately untimed.
    private static func connect(
        descriptor: Int32,
        to address: inout sockaddr_un,
        timeout: TimeInterval
    ) throws {
        let flags = fcntl(descriptor, F_GETFL, 0)
        guard flags >= 0, fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) >= 0 else {
            throw UnixHTTPError.connectFailed(errno)
        }

        let started = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { generic in
                Darwin.connect(descriptor, generic, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }

        if started != 0 {
            guard errno == EINPROGRESS else { throw UnixHTTPError.connectFailed(errno) }
            try waitForConnect(descriptor: descriptor, timeout: timeout)
        }

        guard fcntl(descriptor, F_SETFL, flags) >= 0 else {
            throw UnixHTTPError.connectFailed(errno)
        }
    }

    private static func waitForConnect(descriptor: Int32, timeout: TimeInterval) throws {
        let deadline = Date().addingTimeInterval(timeout)
        while true {
            let remaining = deadline.timeIntervalSinceNow
            guard remaining > 0 else { throw UnixHTTPError.connectTimedOut }

            var event = pollfd(fd: descriptor, events: Int16(POLLOUT), revents: 0)
            let ready = poll(&event, 1, Int32((remaining * 1000).rounded(.up)))
            if ready < 0 {
                // A signal during the wait is not a failure to connect; the deadline above is
                // what ends this loop.
                if errno == EINTR { continue }
                throw UnixHTTPError.connectFailed(errno)
            }
            guard ready > 0 else { throw UnixHTTPError.connectTimedOut }

            var failure: Int32 = 0
            var size = socklen_t(MemoryLayout<Int32>.size)
            guard getsockopt(descriptor, SOL_SOCKET, SO_ERROR, &failure, &size) == 0 else {
                throw UnixHTTPError.connectFailed(errno)
            }
            guard failure == 0 else { throw UnixHTTPError.connectFailed(failure) }
            return
        }
    }
}
