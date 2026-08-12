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
            throw PeerRendezvousError.service(error.localizedDescription)
        }
    }

    public func receive() async throws -> PeerRendezvousEnvelope {
        guard let task, !isClosed else { throw PeerRendezvousError.connectionClosed }
        do {
            let message = try await task.receive()
            let data: Data
            switch message {
            case .data(let received):
                data = received
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
        } catch let error as PeerRendezvousError {
            throw error
        } catch {
            if didTimeOut { throw PeerRendezvousError.timedOut }
            throw PeerRendezvousError.service(error.localizedDescription)
        }
    }

    public func receive(timeout: TimeInterval) async throws -> PeerRendezvousEnvelope {
        guard timeout > 0 else { throw PeerRendezvousError.timedOut }
        let timeoutTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
            await self?.timeoutConnection()
        }
        defer { timeoutTask.cancel() }
        return try await receive()
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

    private func timeoutConnection() {
        guard !isClosed else { return }
        didTimeOut = true
        isClosed = true
        task?.cancel(with: .policyViolation, reason: nil)
        task = nil
        session.invalidateAndCancel()
    }
}
