import Foundation
import Network

/// One cleartext gRPC connection to a loopback endpoint, driving `HTTP2ClientConnection` from a
/// single serial queue. Every piece of mutable state below is touched only on `queue`; callbacks
/// handed in by callers are invoked there too and must not block.
///
/// It is deliberately small: unary and server-streaming calls, a PING for liveness, and close.
/// The Android emulator's control service is the only peer.
public final class GRPCChannel: @unchecked Sendable {
    public enum Failure: Error, Equatable, Sendable, LocalizedError {
        case notConnected
        case connectFailed(String)
        case connectionLost(String)
        case timedOut
        case malformedResponse(String)

        public var errorDescription: String? {
            switch self {
            case .notConnected: return "The emulator control connection is not open."
            case .connectFailed(let detail): return "Couldn’t reach the emulator control service: \(detail)"
            case .connectionLost(let detail): return "The emulator control connection closed: \(detail)"
            case .timedOut: return "The emulator control service did not answer in time."
            case .malformedResponse(let detail): return "The emulator returned a malformed response: \(detail)"
            }
        }
    }

    /// A server-streaming call in flight. Cancelling resets its stream; the end callback then
    /// reports `.cancelled`.
    public final class CallHandle: @unchecked Sendable {
        fileprivate weak var channel: GRPCChannel?
        fileprivate var streamID: UInt32?

        public func cancel() {
            guard let channel else { return }
            channel.queue.async { [weak self] in
                guard let self, let streamID = self.streamID else { return }
                channel.cancel(streamID)
            }
        }
    }

    private struct Call {
        var deframer: GRPCMessageDeframer
        let onMessage: ([UInt8]) -> Void
        let onEnd: (GRPCStatus) -> Void
        var responseHeaders: [HTTP2Header]?
    }

    public let port: UInt16
    private let host: String
    private let maximumMessageSize: Int
    fileprivate let queue: DispatchQueue
    private var connection: NWConnection?
    private var protocolState = HTTP2ClientConnection()
    private var calls: [UInt32: Call] = [:]
    private var pings: [[UInt8]: (Result<Void, Error>) -> Void] = [:]
    private var closedError: Failure?
    private var onClosed: [(Failure) -> Void] = []

    public init(host: String = "127.0.0.1", port: UInt16, maximumMessageSize: Int = 16 << 20) {
        self.host = host
        self.port = port
        self.maximumMessageSize = maximumMessageSize
        self.queue = DispatchQueue(label: "codes.threading.android-grpc.\(port)", qos: .userInteractive)
    }

    deinit { connection?.cancel() }

    /// Calls `handler` once, on the channel queue, when the connection closes for any reason.
    public func whenClosed(_ handler: @escaping @Sendable (Failure) -> Void) {
        queue.async {
            if let closedError = self.closedError { handler(closedError) } else { self.onClosed.append(handler) }
        }
    }

    public func connect(timeout: TimeInterval = 3) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            queue.async {
                guard self.connection == nil, let endpointPort = NWEndpoint.Port(rawValue: self.port) else {
                    continuation.resume(throwing: Failure.connectFailed("already connected"))
                    return
                }
                let parameters = NWParameters.tcp
                if let tcp = parameters.defaultProtocolStack.transportProtocol as? NWProtocolTCP.Options {
                    tcp.noDelay = true
                }
                // Loopback only: the emulator binds gRPC to localhost and nothing here may leave it.
                parameters.requiredInterfaceType = .loopback
                let connection = NWConnection(host: NWEndpoint.Host(self.host), port: endpointPort, using: parameters)
                self.connection = connection
                var resumed = false
                let finish: (Result<Void, Error>) -> Void = { result in
                    guard !resumed else { return }
                    resumed = true
                    continuation.resume(with: result)
                }
                self.queue.asyncAfter(deadline: .now() + timeout) {
                    if !resumed {
                        finish(.failure(Failure.timedOut))
                        self.fail(.timedOut)
                    }
                }
                connection.stateUpdateHandler = { [weak self] state in
                    guard let self else { return }
                    switch state {
                    case .ready:
                        self.protocolState.start()
                        self.flushOutput()
                        self.receiveLoop()
                        finish(.success(()))
                    case .failed(let error):
                        finish(.failure(Failure.connectFailed(error.localizedDescription)))
                        self.fail(.connectionLost(error.localizedDescription))
                    case .waiting(let error):
                        finish(.failure(Failure.connectFailed(error.localizedDescription)))
                        self.fail(.connectFailed(error.localizedDescription))
                    case .cancelled:
                        self.fail(.connectionLost("cancelled"))
                    default:
                        break
                    }
                }
                connection.start(queue: self.queue)
            }
        }
    }

    /// Starts a server-streaming (or unary) call. `onMessage` receives each response message in
    /// order; `onEnd` receives the final status exactly once.
    @discardableResult
    public func call(
        _ path: String, request: [UInt8], metadata: [HTTP2Header] = [],
        onMessage: @escaping @Sendable ([UInt8]) -> Void,
        onEnd: @escaping @Sendable (GRPCStatus) -> Void
    ) -> CallHandle {
        let handle = CallHandle()
        handle.channel = self
        queue.async {
            if let closedError = self.closedError {
                onEnd(GRPCStatus(code: .unavailable, message: closedError.localizedDescription))
                return
            }
            guard self.connection != nil else {
                onEnd(GRPCStatus(code: .unavailable, message: Failure.notConnected.localizedDescription))
                return
            }
            do {
                let authority = "\(self.host):\(self.port)"
                let streamID = try self.protocolState.openStream(
                    headers: GRPCRequestHeaders.make(authority: authority, path: path, metadata: metadata),
                    endStream: false
                )
                try self.protocolState.send(GRPCMessageDeframer.frame(request), on: streamID, endStream: true)
                self.calls[streamID] = Call(
                    deframer: GRPCMessageDeframer(maximumMessageSize: self.maximumMessageSize),
                    onMessage: onMessage, onEnd: onEnd
                )
                handle.streamID = streamID
                self.flushOutput()
            } catch {
                onEnd(GRPCStatus(code: .unavailable, message: "\(error)"))
            }
        }
        return handle
    }

    /// One request, one response.
    public func unary(
        _ path: String, request: [UInt8], metadata: [HTTP2Header] = [], timeout: TimeInterval = 5
    ) async throws -> [UInt8] {
        let box = UnaryBox()
        return try await withCheckedThrowingContinuation { continuation in
            box.continuation = continuation
            let handle = call(path, request: request, metadata: metadata, onMessage: { message in
                box.response = message
            }, onEnd: { status in
                guard status.isOK else { box.finish(.failure(status)); return }
                guard let response = box.response else {
                    box.finish(.failure(Failure.malformedResponse("\(path) returned no message")))
                    return
                }
                box.finish(.success(response))
            })
            queue.asyncAfter(deadline: .now() + timeout) {
                if box.finish(.failure(Failure.timedOut)) { handle.cancel() }
            }
        }
    }

    /// Round-trips an HTTP/2 PING. Use sparingly: gRPC servers enforce a minimum ping interval
    /// and close a connection that pings more often ("too_many_pings"), so periodic liveness
    /// belongs in a cheap unary call instead.
    public func ping(timeout: TimeInterval = 2) async throws {
        let payload = (0..<8).map { _ in UInt8.random(in: 0...255) }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            queue.async {
                guard self.closedError == nil, self.connection != nil else {
                    continuation.resume(throwing: self.closedError ?? Failure.notConnected)
                    return
                }
                var resumed = false
                self.pings[payload] = { result in
                    guard !resumed else { return }
                    resumed = true
                    continuation.resume(with: result)
                }
                self.protocolState.ping(payload)
                self.flushOutput()
                self.queue.asyncAfter(deadline: .now() + timeout) {
                    self.pings.removeValue(forKey: payload)?(.failure(Failure.timedOut))
                }
            }
        }
    }

    public func close() {
        queue.async {
            guard self.closedError == nil else { return }
            self.protocolState.goAway()
            self.flushOutput()
            self.fail(.connectionLost("closed by Threading"))
        }
    }

    // MARK: - Queue-owned

    private func cancel(_ streamID: UInt32) {
        guard let call = calls.removeValue(forKey: streamID) else { return }
        protocolState.reset(streamID)
        flushOutput()
        call.onEnd(GRPCStatus(code: .cancelled))
    }

    private func receiveLoop() {
        connection?.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let data, !data.isEmpty {
                do {
                    let events = try self.protocolState.receive([UInt8](data))
                    for event in events { self.handle(event) }
                    self.flushOutput()
                } catch {
                    self.fail(.malformedResponse("\(error)"))
                    return
                }
            }
            if let error {
                self.fail(.connectionLost(error.localizedDescription))
            } else if isComplete {
                self.fail(.connectionLost("the emulator closed the connection"))
            } else {
                self.receiveLoop()
            }
        }
    }

    private func handle(_ event: HTTP2Event) {
        switch event {
        case .headers(let streamID, let headers, let endStream):
            guard var call = calls[streamID] else { return }
            if call.responseHeaders == nil {
                call.responseHeaders = headers
                calls[streamID] = call
                if headers.first(where: { $0.name == ":status" })?.value != "200" {
                    end(streamID, GRPCStatus(code: .unavailable, message: "HTTP status \(headers.first { $0.name == ":status" }?.value ?? "?")"))
                    return
                }
                // A trailers-only response carries its status in the first and only block.
                if endStream { end(streamID, GRPCStatus.from(trailers: headers) ?? GRPCStatus(code: .unknown)) }
            } else {
                end(streamID, GRPCStatus.from(trailers: headers) ?? GRPCStatus(code: .unknown, message: "missing grpc-status"))
            }

        case .data(let streamID, let bytes, let endStream):
            guard var call = calls[streamID] else { return }
            do {
                let messages = try call.deframer.append(bytes)
                calls[streamID] = call
                for message in messages { call.onMessage(message) }
            } catch {
                protocolState.reset(streamID)
                end(streamID, GRPCStatus(code: .resourceExhausted, message: "\(error)"))
                return
            }
            if endStream { end(streamID, GRPCStatus(code: .internalError, message: "stream ended without trailers")) }

        case .streamReset(let streamID, let errorCode):
            end(streamID, GRPCStatus(code: .unavailable, message: "stream reset (\(errorCode))"))

        case .goAway(_, let errorCode):
            if calls.isEmpty { fail(.connectionLost("GOAWAY \(errorCode)")) }

        case .pingAcknowledged(let payload):
            pings.removeValue(forKey: payload)?(.success(()))
        }
    }

    private func end(_ streamID: UInt32, _ status: GRPCStatus) {
        calls.removeValue(forKey: streamID)?.onEnd(status)
    }

    private func flushOutput() {
        let bytes = protocolState.takeOutput()
        guard !bytes.isEmpty, let connection else { return }
        connection.send(content: Data(bytes), completion: .contentProcessed { [weak self] error in
            if let error { self?.fail(.connectionLost(error.localizedDescription)) }
        })
    }

    private func fail(_ failure: Failure) {
        guard closedError == nil else { return }
        closedError = failure
        connection?.stateUpdateHandler = nil
        connection?.cancel()
        let pending = calls
        calls.removeAll()
        for (_, call) in pending { call.onEnd(GRPCStatus(code: .unavailable, message: failure.localizedDescription)) }
        let waiting = pings
        pings.removeAll()
        for (_, ping) in waiting { ping(.failure(failure)) }
        let observers = onClosed
        onClosed.removeAll()
        for observer in observers { observer(failure) }
    }
}

/// One unary call's single-resumption guard. Touched from the channel queue only.
private final class UnaryBox: @unchecked Sendable {
    var continuation: CheckedContinuation<[UInt8], Error>?
    var response: [UInt8]?

    @discardableResult
    func finish(_ result: Result<[UInt8], Error>) -> Bool {
        guard let continuation else { return false }
        self.continuation = nil
        continuation.resume(with: result)
        return true
    }
}
