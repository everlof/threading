import Foundation
import Network

/// One remote client socket, from either side of the tunnel. It begins as HTTP/1.1 (reusing
/// `MCPConnection.parseRequest`) and, on a successful WebSocket upgrade, switches its own
/// receive loop into RFC 6455 frame parsing on the same `NWConnection`.
///
/// Everything here runs on the server's single serial queue, which is why there are no locks:
/// the PTY tap and the store live on main and hop *to* this queue to send, and this connection
/// hops to main to reach them.
/// `RemoteConnection` is safe to pass between executors only as an identity. All of its mutable
/// socket and parser state is owned by `queue`; public send operations immediately enqueue there.
/// The server never reads queue-owned properties from another executor.
final class RemoteConnection: @unchecked Sendable {

    // MARK: - Delegate

    protocol Delegate: AnyObject, Sendable {
        /// Route one HTTP request. `respond` may be called later (after a main-queue hop).
        func route(
            _ request: HTTPRequest,
            from connection: RemoteConnection,
            respond: @escaping @Sendable (RemoteRouteDecision) -> Void
        )
        /// A reassembled, non-control client message arrived on an upgraded socket.
        func handleMessage(_ message: RemoteWebSocket.Message, from connection: RemoteConnection)
        /// The socket closed for any reason.
        func didClose(_ connection: RemoteConnection)
    }

    // MARK: - Properties

    /// Assigned by the delegate after a successful auth frame. Nil while unauthenticated.
    var authorization: RemoteAuthorization?

    /// The session id parsed from a `/ws/session/<id>` upgrade path, before auth.
    private(set) var routedSessionID: String?

    /// A browser-minted device id, carried on the auth frame, used for the approval record.
    var deviceID: String?

    private let connection: NWConnection
    private let queue: DispatchQueue
    private weak var delegate: Delegate?

    private enum Mode { case http, webSocket }
    private var mode: Mode = .http

    private var buffer = Data()
    private var isHandling = false
    private var isClosed = false

    private var reassembler = RemoteWebSocket.Reassembler(maximumBytes: RemoteAccessDefaults.maximumFrameBytes)

    /// Bytes handed to `NWConnection.send` but not yet reported processed. A slow tunnel
    /// consumer is dropped rather than allowed to back up the mirror.
    private var pendingSendBytes = 0

    private var idleTimer: DispatchSourceTimer?
    private var authTimer: DispatchSourceTimer?
    private var pingTimer: DispatchSourceTimer?
    private var missedPongs = 0

    // MARK: - Initialization

    init(connection: NWConnection, queue: DispatchQueue, delegate: Delegate) {
        self.connection = connection
        self.queue = queue
        self.delegate = delegate
    }

    // MARK: - Lifecycle

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
        armIdleTimer()
        receive()
    }

    func cancel() {
        close()
    }

    /// Marks the socket authenticated: cancels the auth deadline and begins keepalive pings.
    /// Called by the delegate once the first frame's token has been verified.
    func markAuthenticated() {
        authTimer?.cancel()
        authTimer = nil
        armPingTimer()
    }

    // MARK: - Sending (any caller; hops to the server queue)

    func sendText(_ text: String) { enqueue(RemoteWebSocket.textFrame(text)) }
    func sendBinary(_ data: Data) { enqueue(RemoteWebSocket.binaryFrame(data)) }

    func sendClose(code: UInt16, reason: String = "") {
        queue.async { [weak self] in
            guard let self, !self.isClosed else { return }
            self.write(RemoteWebSocket.closeFrame(code: code, reason: reason), thenClose: true)
        }
    }

    private func enqueue(_ frame: Data) {
        queue.async { [weak self] in
            guard let self, !self.isClosed, self.mode == .webSocket else { return }
            self.write(frame, thenClose: false)
        }
    }

    // MARK: - Receiving

    private func receive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            self?.received(data, isComplete: isComplete, error: error)
        }
    }

    private func received(_ data: Data?, isComplete: Bool, error: NWError?) {
        if let data, !data.isEmpty {
            buffer.append(data)
            guard buffer.count <= RemoteAccessDefaults.maximumRequestBytes else {
                if mode == .http {
                    write(HTTPResponse.status(413, "Payload Too Large").serialized, thenClose: true)
                } else {
                    write(RemoteWebSocket.closeFrame(code: RemoteWebSocket.CloseCode.messageTooBig), thenClose: true)
                }
                return
            }
            switch mode {
            case .http: processHTTP()
            case .webSocket: processFrames()
            }
        }

        guard !isComplete, error == nil else {
            close()
            return
        }
        receive()
    }

    // MARK: - HTTP phase

    private func processHTTP() {
        guard !isHandling else { return }

        switch MCPConnection.parseRequest(from: buffer) {
        case .incomplete:
            return
        case .malformed(let status, let reason):
            write(HTTPResponse.status(status, reason).serialized, thenClose: true)
        case .request(let request, let consumed):
            buffer = Data(buffer.dropFirst(consumed))
            isHandling = true
            handle(request)
        }
    }

    private func handle(_ request: HTTPRequest) {
        delegate?.route(request, from: self) { [weak self] decision in
            guard let self else { return }
            self.queue.async {
                guard !self.isClosed else { return }
                switch decision {
                case .respond(let response):
                    self.write(
                        response.serialized,
                        thenClose: response.closesConnection,
                        limit: response.closesConnection
                            ? RemoteAccessDefaults.maximumAttachmentResponseBytes
                            : RemoteAccessDefaults.outboundHighWaterBytes
                    )
                    guard !response.closesConnection else { return }
                    self.isHandling = false
                    self.processHTTP()
                case .upgrade(let sessionID):
                    self.upgrade(to: sessionID, request: request)
                }
            }
        }
    }

    private func upgrade(to sessionID: String, request: HTTPRequest) {
        guard let response = RemoteWebSocket.upgradeResponseData(for: request) else {
            write(HTTPResponse.status(400, "Bad Request").serialized, thenClose: true)
            return
        }
        routedSessionID = sessionID
        mode = .webSocket
        isHandling = false
        idleTimer?.cancel()
        idleTimer = nil
        write(response, thenClose: false)
        armAuthTimer()
        // Any bytes already buffered past the request head are the first frames.
        processFrames()
    }

    // MARK: - WebSocket phase

    private func processFrames() {
        while !isClosed {
            switch RemoteWebSocket.decodeFrame(from: buffer, maximumPayload: RemoteAccessDefaults.maximumFrameBytes) {
            case .incomplete:
                return
            case .protocolError(let code, let reason):
                write(RemoteWebSocket.closeFrame(code: code, reason: reason), thenClose: true)
                return
            case .frame(let frame, let consumed):
                buffer = Data(buffer.dropFirst(consumed))
                switch reassembler.accept(frame) {
                case .buffered:
                    continue
                case .protocolError(let code, let reason):
                    write(RemoteWebSocket.closeFrame(code: code, reason: reason), thenClose: true)
                    return
                case .message(let message):
                    dispatch(message)
                }
            }
        }
    }

    private func dispatch(_ message: RemoteWebSocket.Message) {
        switch message {
        case .ping(let payload):
            write(RemoteWebSocket.pongFrame(payload), thenClose: false)
        case .pong:
            missedPongs = 0
        case .close(let payload):
            write(RemoteWebSocket.closeFrame(payload: payload), thenClose: true)
        case .text, .binary:
            delegate?.handleMessage(message, from: self)
        }
    }

    // MARK: - Writing

    /// Whether one more write fits without taking the outstanding send backlog past its cap.
    ///
    /// Subtraction after validating `pendingBytes` avoids an integer overflow when the next
    /// frame is unexpectedly large. Equality is admitted: the high-water mark is the largest
    /// valid backlog, not the first invalid one.
    static func canEnqueueOutbound(
        pendingBytes: Int,
        nextBytes: Int,
        limit: Int = RemoteAccessDefaults.outboundHighWaterBytes
    ) -> Bool {
        guard pendingBytes >= 0, nextBytes >= 0, pendingBytes <= limit else { return false }
        return nextBytes <= limit - pendingBytes
    }

    private func write(
        _ data: Data,
        thenClose shouldClose: Bool,
        limit: Int = RemoteAccessDefaults.outboundHighWaterBytes
    ) {
        guard !isClosed else { return }

        // Drop a consumer whose unsent backlog has grown past the high-water mark: a live
        // terminal must never back-pressure the mirror that feeds every other viewer.
        guard Self.canEnqueueOutbound(
            pendingBytes: pendingSendBytes,
            nextBytes: data.count,
            limit: limit
        ) else {
            ThreadingLogger.remote.error("Dropping a slow remote connection over the send high-water mark")
            forceClose()
            return
        }

        pendingSendBytes += data.count
        connection.send(content: data, completion: .contentProcessed { [weak self] _ in
            guard let self else { return }
            self.pendingSendBytes = max(0, self.pendingSendBytes - data.count)
            if shouldClose { self.close() }
        })
    }

    // MARK: - Timers

    private func armIdleTimer() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + RemoteAccessDefaults.httpIdleSeconds)
        timer.setEventHandler { [weak self] in
            guard let self, self.mode == .http else { return }
            self.forceClose()
        }
        timer.resume()
        idleTimer = timer
    }

    private func armAuthTimer() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + RemoteAccessDefaults.authDeadlineSeconds)
        timer.setEventHandler { [weak self] in
            guard let self, self.authorization == nil else { return }
            self.write(RemoteWebSocket.closeFrame(code: 4001, reason: "Authentication timeout"), thenClose: true)
        }
        timer.resume()
        authTimer = timer
    }

    private func armPingTimer() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(
            deadline: .now() + RemoteAccessDefaults.pingIntervalSeconds,
            repeating: RemoteAccessDefaults.pingIntervalSeconds
        )
        timer.setEventHandler { [weak self] in
            guard let self, !self.isClosed else { return }
            self.missedPongs += 1
            if self.missedPongs > RemoteAccessDefaults.missedPongLimit {
                self.write(RemoteWebSocket.closeFrame(code: RemoteWebSocket.CloseCode.goingAway), thenClose: true)
                return
            }
            self.write(RemoteWebSocket.pingFrame(), thenClose: false)
        }
        timer.resume()
        pingTimer = timer
    }

    // MARK: - Closing

    /// Cancels the socket immediately, without a graceful close frame.
    private func forceClose() {
        close()
    }

    private func close() {
        guard !isClosed else { return }
        isClosed = true
        idleTimer?.cancel(); idleTimer = nil
        authTimer?.cancel(); authTimer = nil
        pingTimer?.cancel(); pingTimer = nil
        connection.cancel()
        delegate?.didClose(self)
    }
}
