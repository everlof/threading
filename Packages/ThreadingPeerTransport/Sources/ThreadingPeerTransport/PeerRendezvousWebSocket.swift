import Foundation

public struct PeerRendezvousServiceEndpoint: Equatable, Sendable {
    private let webSocketBaseURL: URL

    public init(_ baseURL: URL) throws {
        guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false),
              let scheme = components.scheme?.lowercased(),
              let host = components.host, !host.isEmpty,
              components.user == nil, components.password == nil,
              components.query == nil, components.fragment == nil else {
            throw PeerRendezvousError.invalidEndpoint
        }
        switch scheme {
        case "https", "wss":
            components.scheme = "wss"
        case "http" where Self.isLoopback(host), "ws" where Self.isLoopback(host):
            components.scheme = "ws"
        default:
            throw PeerRendezvousError.invalidEndpoint
        }
        guard let normalized = components.url else {
            throw PeerRendezvousError.invalidEndpoint
        }
        webSocketBaseURL = normalized
    }

    var hostControlURL: URL {
        route("host")
    }

    var deviceURL: URL {
        route("device")
    }

    var sessionURL: URL {
        route("session")
    }

    private func route(_ leaf: String) -> URL {
        webSocketBaseURL
            .appendingPathComponent("v1", isDirectory: true)
            .appendingPathComponent("rendezvous", isDirectory: true)
            .appendingPathComponent(leaf, isDirectory: false)
    }

    private static func isLoopback(_ host: String) -> Bool {
        host == "localhost" || host == "127.0.0.1" || host == "::1"
    }
}

/// A secret bearer value that deliberately prints only as a redaction marker.
public struct PeerRendezvousCredential: Sendable, CustomStringConvertible {
    fileprivate let rawValue: String

    public init(_ value: String) throws {
        guard !value.isEmpty,
              value.utf8.count <= PeerRendezvousBounds.maximumCredentialBytes,
              !value.unicodeScalars.contains(where: { scalar in
                scalar.value < 0x21 || scalar.value == 0x7F
              }) else {
            throw PeerRendezvousError.invalidCredential
        }
        rawValue = value
    }

    public var description: String { "<redacted>" }
}

/// One authenticated signaling socket. It has no automatic retry or unbounded message queue;
/// reconnect policy belongs to the app-facing host/device coordinators.
public actor PeerRendezvousWebSocket {
    private let request: URLRequest
    private let session: URLSession
    private var task: URLSessionWebSocketTask?
    private var isClosed = false
    private var didTimeOut = false
    /// When anything last arrived, on the uptime clock `Task.sleep(nanoseconds:)` also uses.
    private var lastReceivedUptimeNanoseconds: UInt64?

    public init(url: URL, credential: PeerRendezvousCredential) throws {
        guard url.scheme == "wss" || url.scheme == "ws" else {
            throw PeerRendezvousError.invalidEndpoint
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = PeerTransportBounds.negotiationTimeout
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        request.setValue("Bearer \(credential.rawValue)", forHTTPHeaderField: "Authorization")
        request.setValue(
            String(PeerRendezvousBounds.protocolVersion),
            forHTTPHeaderField: "X-Threading-Rendezvous-Version"
        )
        self.request = request

        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        configuration.timeoutIntervalForRequest = PeerTransportBounds.negotiationTimeout
        configuration.timeoutIntervalForResource = PeerRendezvousBounds.maximumSessionLifetime
        session = URLSession(configuration: configuration)
    }

    deinit {
        task?.cancel(with: .goingAway, reason: nil)
        session.invalidateAndCancel()
    }

    public func connect() throws {
        guard task == nil, !isClosed else { throw PeerRendezvousError.connectionClosed }
        let task = session.webSocketTask(with: request)
        self.task = task
        task.resume()
    }

    public func send(_ envelope: PeerRendezvousEnvelope) async throws {
        guard let task, !isClosed else { throw PeerRendezvousError.connectionClosed }
        do {
            try await task.send(.data(envelope.encoded()))
        } catch {
            throw transportError(error, task: task)
        }
    }

    /// The next envelope. A keepalive answer is consumed here, never returned: it is evidence
    /// the path works (`hasReceived(sinceUptimeNanoseconds:)`), not a message for the protocol.
    public func receive() async throws -> PeerRendezvousEnvelope {
        guard let task, !isClosed else { throw PeerRendezvousError.connectionClosed }
        do {
            while true {
                let message = try await task.receive()
                lastReceivedUptimeNanoseconds = DispatchTime.now().uptimeNanoseconds
                let data: Data
                switch message {
                case .data(let received):
                    data = received
                case .string(PeerRendezvousKeepalive.pongMessage):
                    continue
                case .string(let received):
                    guard received.utf8.count <= PeerRendezvousBounds.maximumEnvelopeBytes else {
                        throw PeerRendezvousError.envelopeTooLarge(
                            actual: received.utf8.count,
                            limit: PeerRendezvousBounds.maximumEnvelopeBytes
                        )
                    }
                    data = Data(received.utf8)
                @unknown default:
                    throw PeerRendezvousError.invalidEnvelope
                }
                return try PeerRendezvousEnvelope.decode(data)
            }
        } catch let error as PeerRendezvousError {
            throw error
        } catch {
            if didTimeOut { throw PeerRendezvousError.timedOut }
            throw transportError(error, task: task)
        }
    }

    public func receive(timeout: TimeInterval) async throws -> PeerRendezvousEnvelope {
        guard timeout > 0 else { throw PeerRendezvousError.timedOut }
        let timeoutTask = Self.scheduleTimeout(after: timeout) { [weak self] in
            await self?.timeoutConnection()
        }
        defer { timeoutTask.cancel() }
        return try await receive()
    }

    /// Returns without running `onTimeout` when the waiter is cancelled. Swallowing
    /// `CancellationError` and then continuing would close a healthy WebSocket as soon as the
    /// awaited message arrived and the caller cancelled its no-longer-needed timeout task.
    static func scheduleTimeout(
        after timeout: TimeInterval,
        onTimeout: @escaping @Sendable () async -> Void
    ) -> Task<Void, Never> {
        Task {
            do {
                try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
            } catch is CancellationError {
                return
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            await onTimeout()
        }
    }

    /// Asks the service to answer. The answer arrives through whoever is receiving, so this only
    /// works on a socket with a receive loop; `hasReceived(sinceUptimeNanoseconds:)` reads it.
    public func sendKeepalive() async throws {
        guard let task, !isClosed else { throw PeerRendezvousError.connectionClosed }
        do {
            try await task.send(.string(PeerRendezvousKeepalive.pingMessage))
        } catch {
            throw PeerRendezvousError.service(error.localizedDescription)
        }
    }

    /// Whether anything, a keepalive answer included, has arrived since `instant`, read from
    /// `DispatchTime.now().uptimeNanoseconds`.
    public func hasReceived(sinceUptimeNanoseconds instant: UInt64) -> Bool {
        guard let lastReceivedUptimeNanoseconds else { return false }
        return lastReceivedUptimeNanoseconds >= instant
    }

    public func ping() async throws {
        guard let task, !isClosed else { throw PeerRendezvousError.connectionClosed }
        do {
            try await withCheckedThrowingContinuation {
                (continuation: CheckedContinuation<Void, Error>) in
                task.sendPing { error in
                    if let error {
                        continuation.resume(throwing: error)
                    } else {
                        continuation.resume()
                    }
                }
            }
        } catch {
            throw PeerRendezvousError.service(error.localizedDescription)
        }
    }

    public func close() {
        guard !isClosed else { return }
        isClosed = true
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
        session.invalidateAndCancel()
    }

    private func transportError(_ error: Error, task: URLSessionWebSocketTask) -> PeerRendezvousError {
        // URLSession reports a rejected WebSocket upgrade as a transport error. Its HTTP
        // response still tells us when the invitation credential was refused.
        if (task.response as? HTTPURLResponse)?.statusCode == 401 {
            return .unauthorized
        }
        return .service(error.localizedDescription)
    }

    private func timeoutConnection() {
        guard !isClosed else { return }
        didTimeOut = true
        isClosed = true
        task?.cancel(with: .policyViolation, reason: nil)
        task = nil
        session.invalidateAndCancel()
    }
}
