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
        head += "Content-Length: \(body.count)\r\n"
        head += "Connection: keep-alive\r\n\r\n"

        return Data(head.utf8) + body
    }
}

// MARK: - MCP Connection

/// One client connection, speaking just enough HTTP/1.1 to carry MCP's streamable transport.
///
/// Only the request half of that transport is implemented: the client POSTs a JSON-RPC message
/// and gets its response in the same exchange. The optional SSE stream, which exists so a
/// server can push messages the client did not ask for, is refused — Skalman never originates
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
        guard !isHandling, let (request, consumed) = Self.parseRequest(from: buffer) else { return }

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

    /// Parses one request, returning it with the number of bytes it consumed.
    ///
    /// Returns nil while the request is still incomplete, which is the normal case for the
    /// first few reads of a large body.
    static func parseRequest(from buffer: Data) -> (HTTPRequest, Int)? {
        guard let headerRange = buffer.range(of: headerTerminator) else { return nil }

        let headData = buffer[buffer.startIndex..<headerRange.lowerBound]
        guard let head = String(data: headData, encoding: .utf8) else { return nil }

        var lines = head.components(separatedBy: "\r\n")
        guard !lines.isEmpty else { return nil }

        let requestLine = lines.removeFirst().split(separator: " ")
        guard requestLine.count >= 2 else { return nil }

        var headers: [String: String] = [:]
        for line in lines {
            guard let separator = line.firstIndex(of: ":") else { continue }
            let name = line[line.startIndex..<separator]
                .trimmingCharacters(in: .whitespaces)
                .lowercased()
            let value = line[line.index(after: separator)...]
                .trimmingCharacters(in: .whitespaces)
            headers[name] = value
        }

        let contentLength = headers["content-length"].flatMap(Int.init) ?? 0
        let bodyStart = headerRange.upperBound
        let bodyEnd = bodyStart + contentLength

        // The body has not all arrived yet.
        guard buffer.count >= bodyEnd - buffer.startIndex else { return nil }

        let request = HTTPRequest(
            method: String(requestLine[0]).uppercased(),
            path: String(requestLine[1]),
            headers: headers,
            body: Data(buffer[bodyStart..<bodyEnd])
        )

        return (request, bodyEnd - buffer.startIndex)
    }
}
