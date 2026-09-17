import Foundation
import Network
import XCTest
@testable import ThreadingPeerTransport

/// The Mac's hosted control socket notices a dead path, because nothing else will.
///
/// On 2026-09-17 a phone away from the Mac's network was refused with `hostOffline` for hours after
/// the Mac woke: the socket had died in sleep, `URLSessionWebSocketTask.receive()` never returned,
/// and the listener went on reporting itself ready. These run the real listener and the real
/// `URLSession` socket against a WebSocket server in this process that can stop answering, which is
/// what a half-open connection looks like from the Mac: frames go out and nothing comes back.
final class PeerHostedHostKeepaliveTests: XCTestCase {
    private static let hostID = "host-keepalive-test"

    func testAnsweredKeepalivesKeepTheListenerUp() async throws {
        let service = try await KeepaliveRendezvousService.start()
        defer { service.stop() }
        let listener = try service.listener(
            hostID: Self.hostID,
            keepalive: PeerRendezvousKeepalive(interval: 0.05, answerDeadline: 0.5)
        )

        try await listener.start()
        try await service.waitForKeepalives(4, timeout: 10)
        await listener.stop()

        let events = await Self.drain(listener.events)
        XCTAssertEqual(events.first, .ready)
        XCTAssertFalse(events.contains { if case .listenerFailed = $0 { true } else { false } },
                       "An answered keepalive is not a failure, and its answer is not an envelope")
    }

    func testAnUnansweredKeepaliveEndsTheListenerAsUnresponsive() async throws {
        let service = try await KeepaliveRendezvousService.start()
        defer { service.stop() }
        service.answersKeepalives = false
        let listener = try service.listener(
            hostID: Self.hostID,
            keepalive: PeerRendezvousKeepalive(interval: 0.05, answerDeadline: 0.2)
        )

        try await listener.start()

        let reason = await Self.firstFailure(of: listener, within: 10)
        XCTAssertEqual(reason, .unresponsive)

        // An ended listener is finished: it stops asking, and reconnecting is the owner's job.
        let askedBeforeEnding = service.keepalivesReceived
        try await Task.sleep(nanoseconds: 300_000_000)
        await listener.checkLiveness()
        XCTAssertEqual(service.keepalivesReceived, askedBeforeEnding)
    }

    func testCheckLivenessEndsASilentListenerWithoutWaitingForTheInterval() async throws {
        let service = try await KeepaliveRendezvousService.start()
        defer { service.stop() }
        service.answersKeepalives = false
        let listener = try service.listener(
            hostID: Self.hostID,
            // An interval no test outlives: only the explicit check can ask.
            keepalive: PeerRendezvousKeepalive(interval: 3_600, answerDeadline: 0.2)
        )
        try await listener.start()

        let askedAt = Date()
        await listener.checkLiveness()

        XCTAssertLessThan(Date().timeIntervalSince(askedAt), 5)
        XCTAssertEqual(service.keepalivesReceived, 1)
        let reason = await Self.firstFailure(of: listener, within: 1)
        XCTAssertEqual(reason, .unresponsive)
    }

    func testCheckLivenessLeavesAnAnsweringListenerAlone() async throws {
        let service = try await KeepaliveRendezvousService.start()
        defer { service.stop() }
        let listener = try service.listener(
            hostID: Self.hostID,
            keepalive: PeerRendezvousKeepalive(interval: 3_600, answerDeadline: 0.3)
        )
        try await listener.start()

        // Concurrent checks share one question, as a wake and a path change arriving together do.
        async let first: Void = listener.checkLiveness()
        async let second: Void = listener.checkLiveness()
        _ = await (first, second)
        XCTAssertEqual(service.keepalivesReceived, 1)

        // Still listening: a second check asks again and is answered again.
        await listener.checkLiveness()
        XCTAssertEqual(service.keepalivesReceived, 2)
        await listener.stop()

        let events = await Self.drain(listener.events)
        XCTAssertEqual(events, [.ready])
    }

    /// Opt-in: the real Workers runtime rather than this file's stand-in, which is the only way
    /// to know its auto-response reaches `URLSessionWebSocketTask` as the text this socket
    /// consumes. Run `npm run dev` in `Service/ThreadingControlPlane`, then
    /// `THREADING_RENDEZVOUS_LIVE_URL=http://127.0.0.1:8787 swift test --filter
    /// PeerHostedHostKeepaliveTests`.
    func testTheLocalServiceAnswersTheKeepalive() async throws {
        let configured = ProcessInfo.processInfo.environment[Self.liveServiceVariable]
        try XCTSkipUnless(configured != nil, "Set \(Self.liveServiceVariable) to a local service")
        let endpoint = try PeerControlPlaneServiceEndpoint(
            XCTUnwrap(URL(string: XCTUnwrap(configured)))
        )
        let client = PeerControlPlaneClient(endpoint: endpoint)
        let session = try await client.signInForLocalDevelopment()
        let hostID = "host-keepalive-\(UUID().uuidString.lowercased())"
        let enrolled = try await client.enrollHost(
            accessToken: session.accessToken,
            hostID: hostID,
            displayName: "Keepalive Test"
        )
        let listener = PeerHostedHostListener(
            endpoint: endpoint.rendezvousEndpoint,
            hostID: hostID,
            credential: try enrolled.credential.withValue { try PeerRendezvousCredential($0) },
            targetPort: 1,
            keepalive: PeerRendezvousKeepalive(interval: 0.2, answerDeadline: 1)
        )

        try await listener.start()
        for _ in 0..<3 {
            await listener.checkLiveness()
        }
        await listener.stop()

        let events = await Self.drain(listener.events)
        XCTAssertEqual(events, [.ready], "The service's answer must keep the listener up")
    }

    // MARK: - Helpers

    private static let liveServiceVariable = "THREADING_RENDEZVOUS_LIVE_URL"

    private static func drain(
        _ events: AsyncStream<PeerHostedHostEvent>
    ) async -> [PeerHostedHostEvent] {
        var collected: [PeerHostedHostEvent] = []
        for await event in events { collected.append(event) }
        return collected
    }

    private static func firstFailure(
        of listener: PeerHostedHostListener,
        within timeout: TimeInterval
    ) async -> PeerHostedFailure? {
        await withTaskGroup(of: PeerHostedFailure?.self) { group in
            group.addTask {
                for await event in listener.events {
                    if case .listenerFailed(let reason) = event { return reason }
                }
                return nil
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
    }
}

/// Just enough of `HostRendezvous` for a host control socket: it answers `hostHello` with
/// `hostReady`, and answers the keepalive text frame the way the service's auto-response does
/// until told to go quiet. Bound to loopback only.
private final class KeepaliveRendezvousService: @unchecked Sendable {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "KeepaliveRendezvousService")
    private let lock = NSLock()
    private var connections: [NWConnection] = []
    private var answers = true
    private var received = 0
    private var didSettleListen = false

    private init(listener: NWListener) {
        self.listener = listener
    }

    var answersKeepalives: Bool {
        get { lock.withLock { answers } }
        set { lock.withLock { answers = newValue } }
    }

    var keepalivesReceived: Int {
        lock.withLock { received }
    }

    static func start() async throws -> KeepaliveRendezvousService {
        let websocket = NWProtocolWebSocket.Options()
        websocket.autoReplyPing = true
        let parameters = NWParameters(tls: nil, tcp: NWProtocolTCP.Options())
        parameters.defaultProtocolStack.applicationProtocols.insert(websocket, at: 0)
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
        let service = KeepaliveRendezvousService(listener: try NWListener(using: parameters))
        try await service.listen()
        return service
    }

    func listener(
        hostID: String,
        keepalive: PeerRendezvousKeepalive
    ) throws -> PeerHostedHostListener {
        let port = try XCTUnwrap(listener.port?.rawValue)
        return PeerHostedHostListener(
            endpoint: try PeerRendezvousServiceEndpoint(
                XCTUnwrap(URL(string: "http://127.0.0.1:\(port)"))
            ),
            hostID: hostID,
            credential: try PeerRendezvousCredential("keepalive-test-credential"),
            targetPort: 1,
            keepalive: keepalive
        )
    }

    /// Polls rather than parks a continuation, so a listener that stops asking fails the test at
    /// the deadline instead of hanging it.
    func waitForKeepalives(_ count: Int, timeout: TimeInterval) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while keepalivesReceived < count, Date() < deadline {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertGreaterThanOrEqual(keepalivesReceived, count)
    }

    func stop() {
        listener.cancel()
        let open = lock.withLock { () -> [NWConnection] in
            defer { connections.removeAll() }
            return connections
        }
        open.forEach { $0.cancel() }
    }

    private func listen() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            listener.newConnectionHandler = { [weak self] connection in
                self?.accept(connection)
            }
            listener.stateUpdateHandler = { [weak self] state in
                let outcome: Result<Void, Error>
                switch state {
                case .ready: outcome = .success(())
                case .failed(let error): outcome = .failure(error)
                case .cancelled: outcome = .failure(CancellationError())
                default: return
                }
                guard let self, self.claimListenOutcome() else { return }
                continuation.resume(with: outcome)
            }
            listener.start(queue: queue)
        }
    }

    /// The listener reports states for as long as it lives; only the first settles `listen()`.
    private func claimListenOutcome() -> Bool {
        lock.withLock {
            guard !didSettleListen else { return false }
            didSettleListen = true
            return true
        }
    }

    private func accept(_ connection: NWConnection) {
        lock.withLock { connections.append(connection) }
        connection.start(queue: queue)
        receive(on: connection)
    }

    private func receive(on connection: NWConnection) {
        connection.receiveMessage { [weak self] content, context, _, error in
            guard let self, error == nil else { return }
            let metadata = context?.protocolMetadata(definition: NWProtocolWebSocket.definition)
                as? NWProtocolWebSocket.Metadata
            switch metadata?.opcode {
            case .text:
                if let content,
                   String(decoding: content, as: UTF8.self) == PeerRendezvousKeepalive.pingMessage {
                    self.recordKeepalive(on: connection)
                }
            case .binary:
                if let content,
                   let hello = try? PeerRendezvousEnvelope.decode(content),
                   hello.kind == .hostHello,
                   let ready = try? PeerRendezvousEnvelope(kind: .hostReady, hostID: hello.hostID)
                    .encoded() {
                    self.send(ready, opcode: .binary, on: connection)
                }
            case .close:
                return
            default:
                break
            }
            self.receive(on: connection)
        }
    }

    private func recordKeepalive(on connection: NWConnection) {
        let answer = lock.withLock { () -> Bool in
            received += 1
            return answers
        }
        guard answer else { return }
        send(Data(PeerRendezvousKeepalive.pongMessage.utf8), opcode: .text, on: connection)
    }

    private func send(_ data: Data, opcode: NWProtocolWebSocket.Opcode, on connection: NWConnection) {
        let context = NWConnection.ContentContext(
            identifier: "rendezvous",
            metadata: [NWProtocolWebSocket.Metadata(opcode: opcode)]
        )
        connection.send(
            content: data,
            contentContext: context,
            isComplete: true,
            completion: .idempotent
        )
    }
}
