import Foundation
import Network

// MARK: - HTTP Request

struct HTTPRequest {
    let method: String
    let path: String
    let headers: [String: String]
    let body: Data

    /// Header lookup is case-insensitive, so keys are lowercased on the way in.
    func header(_ name: String) -> String? {
        headers[name.lowercased()]
    }
}

// MARK: - HTTP Response

struct HTTPResponse {
    let status: Int
    let reason: String
    let contentType: String?
    let body: Data
    /// Extra response headers, empty for MCP. The remote-access server sets a handful of
    /// hardening headers (`X-Frame-Options`, `X-Content-Type-Options`, a CSP) here, since it
    /// is the one server reachable through a public tunnel.
    var extraHeaders: [String: String] = [:]
    /// Used by the remote-access server for bounded large bodies. MCP responses stay persistent.
    var closesConnection = false

    static func json(_ body: Data) -> HTTPResponse {
        HTTPResponse(status: 200, reason: "OK", contentType: "application/json", body: body)
    }

    /// The response to a JSON-RPC notification, which by definition expects no result.
    static let accepted = HTTPResponse(status: 202, reason: "Accepted", contentType: nil, body: Data())

    static func status(_ status: Int, _ reason: String) -> HTTPResponse {
        HTTPResponse(status: status, reason: reason, contentType: nil, body: Data())
    }

    var serialized: Data {
        var head = "HTTP/1.1 \(status) \(reason)\r\n"
        if let contentType {
            head += "Content-Type: \(contentType)\r\n"
        }
        for (name, value) in extraHeaders.sorted(by: { $0.key < $1.key }) {
            head += "\(name): \(value)\r\n"
        }
        head += "Content-Length: \(body.count)\r\n"
        head += "Connection: \(closesConnection ? "close" : "keep-alive")\r\n\r\n"

        return Data(head.utf8) + body
    }
}

// MARK: - MCP Connection

/// One client connection, speaking just enough HTTP/1.1 to carry MCP's streamable transport.
///
/// Only the request half of that transport is implemented: the client POSTs a JSON-RPC message
/// and gets its response in the same exchange. The optional SSE stream, which exists so a
/// server can push messages the client did not ask for, is refused — Threading never originates
/// traffic, it only answers.
final class MCPConnection {

    // MARK: - Properties

    private let connection: NWConnection
    private let queue: DispatchQueue
    private let handler: (HTTPRequest, @escaping (HTTPResponse) -> Void) -> Void
    private let onClose: (MCPConnection) -> Void

    private var buffer = Data()

    /// Requests are answered one at a time. Handling hops to the main queue and returns
    /// asynchronously, so without this a pipelined second request could be parsed and
    /// answered out of order.
    private var isHandling = false

    // MARK: - Initialization

    init(
        connection: NWConnection,
        queue: DispatchQueue,
        handler: @escaping (HTTPRequest, @escaping (HTTPResponse) -> Void) -> Void,
        onClose: @escaping (MCPConnection) -> Void
    ) {
        self.connection = connection
        self.queue = queue
        self.handler = handler
        self.onClose = onClose
    }

    // MARK: - Public Methods

    func start() {
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed, .cancelled:
                self?.close()
            default:
                break
            }
        }

        connection.start(queue: queue)
        receive()
    }

    func cancel() {
        connection.cancel()
    }

    // MARK: - Private Methods

    private static let chunkSize = 65536

    private func receive() {
        let maxChunk = Self.chunkSize

        connection.receive(minimumIncompleteLength: 1, maximumLength: maxChunk) { [weak self] data, _, done, error in
            self?.received(data, isComplete: done, error: error)
        }
    }

    private func received(_ data: Data?, isComplete: Bool, error: NWError?) {
        if let data, !data.isEmpty {
            buffer.append(data)

            // A client that never completes a request must not grow the buffer forever.
            guard buffer.count <= MCPDefaults.maximumRequestBytes else {
                send(.status(413, "Payload Too Large"), thenClose: true)
                return
            }

            processBuffer()
        }

        guard !isComplete, error == nil else {
            close()
            return
        }

        receive()
    }

    /// Answers one complete request if the buffer holds one, leaving any remainder for later.
    private func processBuffer() {
        guard !isHandling else { return }

        let request: HTTPRequest
        let consumed: Int

        switch Self.parseRequest(from: buffer) {
        case .incomplete:
            return

        case .malformed(let status, let reason):
            // Closed rather than skipped. A framing error is the one error with no recovery:
            // the next request's first byte is exactly the thing that could not be located.
            ThreadingLogger.mcp.error(
                "Refused a malformed request: \(status, privacy: .public) \(reason, privacy: .public)"
            )
            send(.status(status, reason), thenClose: true)
            return

        case .request(let parsed, let bytes):
            request = parsed
            consumed = bytes
        }

        // Rebased rather than mutated in place: a Data slice carries its parent's indices,
        // and the parser reads positions relative to `startIndex`.
        buffer = Data(buffer.dropFirst(consumed))
        isHandling = true

        handler(request) { [weak self] response in
            guard let self else { return }

            // Back onto the connection's own queue: the handler answered from the main queue.
            self.queue.async {
                self.send(response, thenClose: false)
                self.isHandling = false

                // A pipelined request may already be waiting behind the one just answered.
                self.processBuffer()
            }
        }
    }

    private func send(_ response: HTTPResponse, thenClose shouldClose: Bool) {
        connection.send(content: response.serialized, completion: .contentProcessed { [weak self] _ in
            if shouldClose {
                self?.close()
            }
        })
    }

    private func close() {
        connection.cancel()
        onClose(self)
    }

    // MARK: - Parsing

    private static let headerTerminator = Data("\r\n\r\n".utf8)

    /// What one pass over the buffer found.
    ///
    /// The third case is the one that earns the type. The parser used to answer `nil` for *both*
    /// "not all here yet" and "this can never be a request", so bytes it could not read were
    /// waited on forever, and framing it could not trust was accepted with a default: a
    /// `Content-Length` that was missing or unreadable became a body of **zero**, which leaves
    /// the real body sitting at the head of the buffer to be read as the *next request's* start
    /// line. Malformed framing has to end the connection, because once the boundary is unknown
    /// there is no position from which to resume.
    enum ParseOutcome {
        /// Not all of the request has arrived — the normal case for the first reads of a body.
        case incomplete
        case request(HTTPRequest, consumed: Int)
        /// Answered with this status, then closed.
        case malformed(status: Int, reason: String)
    }

    /// Methods that carry a body here. A request of one of these with no declared length is a
    /// client this server does not understand, and guessing "empty" is the framing hazard above.
    private static let bodyBearingMethods: Set<String> = ["POST", "PUT", "PATCH"]

    /// Parses one request, returning it with the number of bytes it consumed.
    static func parseRequest(from buffer: Data) -> ParseOutcome {
        guard let headerRange = buffer.range(of: headerTerminator) else { return .incomplete }

        let headData = buffer[buffer.startIndex..<headerRange.lowerBound]
        guard let head = String(data: headData, encoding: .utf8) else {
            return .malformed(status: 400, reason: "Bad Request")
        }

        var lines = head.components(separatedBy: "\r\n")
        guard !lines.isEmpty else { return .malformed(status: 400, reason: "Bad Request") }

        let requestLine = lines.removeFirst().split(separator: " ")
        guard requestLine.count >= 2 else {
            return .malformed(status: 400, reason: "Bad Request")
        }

        var headers: [String: String] = [:]
        for line in lines {
            guard let separator = line.firstIndex(of: ":") else { continue }
            let name = line[line.startIndex..<separator]
                .trimmingCharacters(in: .whitespaces)
                .lowercased()
            let value = line[line.index(after: separator)...]
                .trimmingCharacters(in: .whitespaces)
            // A proxy and an origin choosing different Content-Length values is request
            // smuggling. Even equal duplicates have no value for these single-message local
            // transports, so refuse the ambiguity before either server sees the request.
            if name == "content-length", headers[name] != nil {
                return .malformed(status: 400, reason: "Bad Request")
            }
            headers[name] = value
        }

        // Chunked framing is not implemented, and a chunked body read as though it were not
        // chunked puts its own size line where the next request's method belongs.
        if headers["transfer-encoding"] != nil {
            return .malformed(status: 501, reason: "Not Implemented")
        }

        let method = String(requestLine[0]).uppercased()
        let contentLength: Int

        if let declared = headers["content-length"] {
            guard let length = Int(declared), length >= 0 else {
                // A negative length also *crashed* the slice below, since a range whose end
                // precedes its start is a programmer error rather than a runtime one.
                return .malformed(status: 400, reason: "Bad Request")
            }
            guard length <= MCPDefaults.maximumRequestBytes else {
                return .malformed(status: 413, reason: "Payload Too Large")
            }
            contentLength = length
        } else if bodyBearingMethods.contains(method) {
            return .malformed(status: 411, reason: "Length Required")
        } else {
            // A request with neither a length nor a body-bearing method has no body, which is
            // what HTTP/1.1 says and what a client's `GET` of the refused SSE stream sends.
            contentLength = 0
        }

        let bodyStart = headerRange.upperBound
        let bodyEnd = bodyStart + contentLength

        // The body has not all arrived yet.
        guard buffer.count >= bodyEnd - buffer.startIndex else { return .incomplete }

        let request = HTTPRequest(
            method: method,
            path: String(requestLine[1]),
            headers: headers,
            body: Data(buffer[bodyStart..<bodyEnd])
        )

        return .request(request, consumed: bodyEnd - buffer.startIndex)
    }
}
