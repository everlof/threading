import Darwin
import Foundation

/// The host half of an inherited broker socket.
///
/// It speaks the same HTTP/1.1 framing `MCPConnection` does and answers through the same
/// router, so descriptor-carried and loopback-carried requests are one code path from
/// `ExtensionHostService.route` onwards. Reusing the parser rather than writing a second one is
/// the point: a broker with two request readers has two places to disagree about a body length.
///
/// Closing this connection is how a revoked generation learns it is revoked — the child's next
/// read returns end-of-file instead of a status code it might mistake for a transient failure.
final class ExtensionHostDescriptorConnection {
    /// The descriptor number the child sees. Fixed by convention so the extension SDK needs no
    /// negotiation: stdin, stdout and stderr are the JSONL protocol, and the broker is next.
    static let childDescriptorNumber: Int32 = 3

    /// A request larger than this is not one this host answers, and a client that never
    /// finishes one must not grow the buffer without bound.
    private static let maximumRequestBytes = MCPDefaults.maximumRequestBytes

    private let descriptor: Int32
    private let queue: DispatchQueue
    private let handler: (HTTPRequest, @escaping (HTTPResponse) -> Void) -> Void
    private let onClose: (ExtensionHostDescriptorConnection) -> Void

    private var channel: DispatchIO?
    private var buffer = Data()
    /// Requests are answered one at a time. The router answers asynchronously from the main
    /// queue, so without this a pipelined second request could be answered out of order — and a
    /// socket carries no request identifiers with which to sort them out again.
    private var isHandling = false
    private var isClosed = false

    init(
        descriptor: Int32,
        queue: DispatchQueue,
        handler: @escaping (HTTPRequest, @escaping (HTTPResponse) -> Void) -> Void,
        onClose: @escaping (ExtensionHostDescriptorConnection) -> Void
    ) {
        self.descriptor = descriptor
        self.queue = queue
        self.handler = handler
        self.onClose = onClose
    }

    /// Creates a connected socket pair, serves the host end, and returns the end to hand a
    /// child.
    ///
    /// The caller owns the returned descriptor and must close it once the child has inherited
    /// it; leaving it open in the host means the child's exit never reaches end-of-file here.
    static func makePair(
        queue: DispatchQueue,
        handler: @escaping (HTTPRequest, @escaping (HTTPResponse) -> Void) -> Void,
        onClose: @escaping (ExtensionHostDescriptorConnection) -> Void
    ) -> (connection: ExtensionHostDescriptorConnection, childDescriptor: Int32)? {
        var descriptors: [Int32] = [-1, -1]
        guard socketpair(AF_UNIX, SOCK_STREAM, 0, &descriptors) == 0 else { return nil }

        // The host end must not survive into any other child this app spawns; the child end is
        // deliberately inheritable, since being inherited is its whole purpose.
        _ = fcntl(descriptors[0], F_SETFD, FD_CLOEXEC)

        // Writing to a revoked broker must be an error, not a signal. Without this an
        // extension whose generation was revoked mid-call dies of SIGPIPE instead of reading
        // the end-of-file that says so — and so would this process, on the answering side.
        var enabled: Int32 = 1
        for descriptor in descriptors {
            _ = setsockopt(
                descriptor,
                SOL_SOCKET,
                SO_NOSIGPIPE,
                &enabled,
                socklen_t(MemoryLayout<Int32>.size)
            )
        }

        let connection = ExtensionHostDescriptorConnection(
            descriptor: descriptors[0],
            queue: queue,
            handler: handler,
            onClose: onClose
        )
        connection.start()
        return (connection, descriptors[1])
    }

    func start() {
        let channel = DispatchIO(
            type: .stream,
            fileDescriptor: descriptor,
            queue: queue
        ) { [descriptor] _ in
            Darwin.close(descriptor)
        }
        channel.setLimit(lowWater: 1)
        self.channel = channel

        channel.read(
            offset: 0,
            length: Int.max,
            queue: queue
        ) { [weak self] done, data, error in
            self?.received(data, done: done, error: error)
        }
    }

    func cancel() {
        // Synchronously, before the channel teardown is scheduled. Revocation has to be true
        // the moment it returns: a caller that revokes a generation and then asks whether the
        // extension can still reach the host must not race the queue for the answer.
        shutdown(descriptor, SHUT_RDWR)
        queue.async { [weak self] in
            self?.close()
        }
    }

    private func received(_ data: DispatchData?, done: Bool, error: Int32) {
        if let data, !data.isEmpty {
            buffer.append(contentsOf: data)
            guard buffer.count <= Self.maximumRequestBytes else {
                send(.status(413, "Payload Too Large"), thenClose: true)
                return
            }
            processBuffer()
        }

        // `done` with no error and no data is end-of-stream: the child closed or exited.
        if done || error != 0 {
            close()
        }
    }

    private func processBuffer() {
        guard !isHandling, !isClosed else { return }

        let request: HTTPRequest
        let consumed: Int

        switch MCPConnection.parseRequest(from: buffer) {
        case .incomplete:
            return

        case .malformed(let status, let reason):
            // The same rule as the loopback listener's: a request whose framing cannot be read
            // leaves no position to resume from, and this side is speaking to an *extension's*
            // process — the one peer most likely to be wrong.
            SkalmanLogger.extensions.error(
                """
                Extension host sent a malformed request: \
                \(status, privacy: .public) \(reason, privacy: .public)
                """
            )
            send(.status(status, reason), thenClose: true)
            return

        case .request(let parsed, let bytes):
            request = parsed
            consumed = bytes
        }

        buffer = Data(buffer.dropFirst(consumed))
        isHandling = true

        handler(request) { [weak self] response in
            guard let self else { return }
            self.queue.async {
                self.send(response, thenClose: false)
                self.isHandling = false
                self.processBuffer()
            }
        }
    }

    private func send(_ response: HTTPResponse, thenClose shouldClose: Bool) {
        guard let channel, !isClosed else { return }
        let bytes = response.serialized
        let data = bytes.withUnsafeBytes { raw in
            DispatchData(bytes: raw)
        }
        channel.write(offset: 0, data: data, queue: queue) { [weak self] _, _, _ in
            if shouldClose {
                self?.close()
            }
        }
    }

    private func close() {
        guard !isClosed else { return }
        isClosed = true
        // Shut the socket down before releasing the channel. Closing a `DispatchIO` runs its
        // cleanup handler once its outstanding operations have unwound, and a revocation the
        // extension learns about eventually is a revocation it can still act during.
        shutdown(descriptor, SHUT_RDWR)
        channel?.close(flags: .stop)
        channel = nil
        onClose(self)
    }
}
