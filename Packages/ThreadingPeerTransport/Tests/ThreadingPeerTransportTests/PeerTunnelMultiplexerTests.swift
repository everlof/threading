import Foundation
@preconcurrency import Network
import XCTest
@testable import ThreadingPeerTransport

final class PeerTunnelMultiplexerTests: XCTestCase {
    func testFrameCodecRejectsVersionAndLengthViolations() throws {
        let payload = Data(repeating: 0x42, count: PeerTunnelBounds.maximumDataBytes)
        let frame = PeerTunnelFrame.data(streamID: 1, payload: payload)
        XCTAssertEqual(try PeerTunnelFrame(decoding: frame.encoded()), frame)

        var wrongVersion = try frame.encoded()
        wrongVersion[2] = PeerTunnelFrame.version + 1
        XCTAssertThrowsError(try PeerTunnelFrame(decoding: wrongVersion)) { error in
            XCTAssertEqual(error as? PeerTunnelError, .unsupportedVersion(2))
        }

        XCTAssertThrowsError(
            try PeerTunnelFrame.data(
                streamID: 1,
                payload: Data(count: PeerTunnelBounds.maximumDataBytes + 1)
            ).encoded()
        )
    }

    func testMultiplexedStreamsAreIndependentAndFlowControlled() async throws {
        let pair = await InMemoryMessageTransport.makePair()
        let client = PeerTunnelMultiplexer(role: .client, transport: pair.left)
        let server = PeerTunnelMultiplexer(role: .server, transport: pair.right)
        try await client.start()
        try await server.start()

        async let acceptedFirst = server.acceptStream()
        async let openedFirst = client.openStream()
        let serverFirst = try await acceptedFirst
        try await serverFirst.accept()
        let clientFirst = try await openedFirst

        async let acceptedSecond = server.acceptStream()
        async let openedSecond = client.openStream()
        let serverSecond = try await acceptedSecond
        try await serverSecond.accept()
        let clientSecond = try await openedSecond

        let small = Data("second-stream".utf8)
        try await clientSecond.send(small)
        let receivedSmallValue = try await serverSecond.receive()
        let receivedSmall = try XCTUnwrap(receivedSmallValue)
        XCTAssertEqual(receivedSmall, small)
        try await serverSecond.acknowledge(receivedSmall.count)

        let chunk = Data(repeating: 0xA5, count: PeerTunnelBounds.maximumDataBytes)
        for _ in 0..<5 {
            try await clientFirst.send(chunk)
        }
        let blockedSend = Task { try await clientFirst.send(chunk) }

        let firstReceivedValue = try await serverFirst.receive()
        let firstReceived = try XCTUnwrap(firstReceivedValue)
        XCTAssertEqual(firstReceived, chunk)
        try await serverFirst.acknowledge(firstReceived.count)
        try await blockedSend.value

        for _ in 0..<5 {
            let receivedValue = try await serverFirst.receive()
            let received = try XCTUnwrap(receivedValue)
            XCTAssertEqual(received, chunk)
            try await serverFirst.acknowledge(received.count)
        }

        let response = Data("response".utf8)
        try await serverFirst.send(response)
        let receivedResponseValue = try await clientFirst.receive()
        let receivedResponse = try XCTUnwrap(receivedResponseValue)
        XCTAssertEqual(receivedResponse, response)
        try await clientFirst.acknowledge(receivedResponse.count)

        try await clientFirst.endSending()
        let serverEnd = try await serverFirst.receive()
        XCTAssertNil(serverEnd)
        try await serverFirst.endSending()
        // Let the remote END arrive before observing it; a completed stream must retain its EOF
        // tombstone until the local socket pump has actually consumed that state.
        try await Task.sleep(for: .milliseconds(10))
        let clientEnd = try await clientFirst.receive()
        XCTAssertNil(clientEnd)

        await clientSecond.reset()
        do {
            _ = try await serverSecond.receive()
            XCTFail("Expected reset to close the remote logical stream")
        } catch let error as PeerTunnelError {
            XCTAssertEqual(error, .streamClosed(serverSecond.id))
        }

        await client.close()
        await server.close()
    }

    func testStreamAndWriteCapsRefuseBeforeAllocationOrSend() async throws {
        let pair = await InMemoryMessageTransport.makePair()
        let client = PeerTunnelMultiplexer(role: .client, transport: pair.left)
        let server = PeerTunnelMultiplexer(role: .server, transport: pair.right)
        try await client.start()
        try await server.start()

        var streams: [PeerTunnelStream] = []
        for _ in 0..<PeerTunnelBounds.maximumStreams {
            async let accepted = server.acceptStream()
            async let opened = client.openStream()
            let serverStream = try await accepted
            try await serverStream.accept()
            streams.append(try await opened)
        }

        do {
            _ = try await client.openStream()
            XCTFail("Expected the logical-stream cap to be enforced")
        } catch let error as PeerTunnelError {
            XCTAssertEqual(error, .tooManyStreams(limit: PeerTunnelBounds.maximumStreams))
        }

        let oversized = Data(count: PeerTunnelBounds.maximumDataBytes + 1)
        do {
            try await streams[0].send(oversized)
            XCTFail("Expected the per-write cap to be enforced")
        } catch let error as PeerTunnelError {
            XCTAssertEqual(
                error,
                .writeTooLarge(
                    actual: oversized.count,
                    limit: PeerTunnelBounds.maximumDataBytes
                )
            )
        }

        await client.close()
        await server.close()
    }

    func testLoopbackProxyBridgesAFlowControlledTCPStream() async throws {
        let echo = try await LoopbackEchoServer.start()
        defer { echo.stop() }

        let pair = await InMemoryMessageTransport.makePair()
        let clientMultiplexer = PeerTunnelMultiplexer(role: .client, transport: pair.left)
        let serverMultiplexer = PeerTunnelMultiplexer(role: .server, transport: pair.right)
        let bridge = try PeerTunnelLoopbackBridge(
            multiplexer: serverMultiplexer,
            targetPort: echo.port
        )
        try await bridge.start()
        defer { bridge.stop() }

        let proxy = PeerTunnelLocalProxy(multiplexer: clientMultiplexer)
        let origin = try await proxy.start()
        defer { proxy.stop() }
        let port = try XCTUnwrap(origin.port.flatMap(UInt16.init(exactly:)))
        let socket = TestSocket(
            NWConnection(
                host: "127.0.0.1",
                port: try XCTUnwrap(NWEndpoint.Port(rawValue: port)),
                using: .tcp
            )
        )
        try await socket.start()
        defer { socket.cancel() }

        let payload = Data((0..<(1 * 1_024 * 1_024)).map { UInt8($0 % 251) })
        try await socket.send(payload, isComplete: false)
        let echoed = try await socket.receiveExactly(payload.count)
        XCTAssertEqual(echoed, payload)
    }
}

private actor InMemoryMessageTransport: PeerMessageTransport {
    private var peer: InMemoryMessageTransport?
    private var messages: [Data] = []
    private var head = 0
    private var pendingReceive: CheckedContinuation<Data, Error>?
    private var isClosed = false

    static func makePair() async -> (left: InMemoryMessageTransport, right: InMemoryMessageTransport) {
        let left = InMemoryMessageTransport()
        let right = InMemoryMessageTransport()
        await left.connect(to: right)
        await right.connect(to: left)
        return (left, right)
    }

    func connect(to peer: InMemoryMessageTransport) {
        self.peer = peer
    }

    func sendWhenWritable(_ data: Data) async throws {
        guard !isClosed, let peer else { throw PeerTunnelError.closed }
        try await peer.enqueue(data)
    }

    func receive() async throws -> Data {
        if head < messages.count {
            let data = messages[head]
            head += 1
            if head == messages.count {
                messages.removeAll(keepingCapacity: true)
                head = 0
            }
            return data
        }
        guard !isClosed else { throw PeerTunnelError.closed }
        guard pendingReceive == nil else { throw PeerTransportError.operationAlreadyPending }
        return try await withCheckedThrowingContinuation { continuation in
            pendingReceive = continuation
        }
    }

    func close() async {
        guard !isClosed else { return }
        isClosed = true
        pendingReceive?.resume(throwing: PeerTunnelError.closed)
        pendingReceive = nil
        if let peer { await peer.peerClosed() }
    }

    private func enqueue(_ data: Data) throws {
        guard !isClosed else { throw PeerTunnelError.closed }
        if let continuation = pendingReceive {
            pendingReceive = nil
            continuation.resume(returning: data)
        } else {
            messages.append(data)
        }
    }

    private func peerClosed() {
        isClosed = true
        pendingReceive?.resume(throwing: PeerTunnelError.closed)
        pendingReceive = nil
    }
}

private final class LoopbackEchoServer: @unchecked Sendable {
    private(set) var port: UInt16
    private let listener: NWListener
    private let queue = DispatchQueue(label: "codes.threading.peer-tunnel.tests.echo")
    private var connections: [NWConnection] = []

    private init(listener: NWListener, port: UInt16) {
        self.listener = listener
        self.port = port
    }

    static func start() async throws -> LoopbackEchoServer {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        let listener = try NWListener(using: parameters)
        let server = LoopbackEchoServer(listener: listener, port: 0)
        listener.newConnectionHandler = { [weak server] connection in
            server?.accept(connection)
        }
        let port = try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<UInt16, Error>) in
            let gate = TestContinuationGate(continuation)
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    if let port = listener.port?.rawValue {
                        server.port = port
                        gate.succeed(port)
                    }
                case .failed(let error):
                    gate.fail(error)
                default:
                    break
                }
            }
            listener.start(queue: DispatchQueue(label: "codes.threading.peer-tunnel.tests.start"))
        }
        precondition(server.port == port)
        return server
    }

    func stop() {
        queue.async { [self] in
            listener.cancel()
            connections.forEach { $0.cancel() }
            connections.removeAll()
        }
    }

    private func accept(_ connection: NWConnection) {
        queue.async { [self] in
            connections.append(connection)
            connection.start(queue: queue)
            receive(on: connection)
        }
    }

    private func receive(on connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1_024) {
            [weak self, weak connection] data, _, isComplete, error in
            guard let self, let connection else { return }
            if let data, !data.isEmpty {
                connection.send(content: data, completion: .contentProcessed { [weak self] error in
                    guard let self else { return }
                    if error != nil || isComplete {
                        connection.send(
                            content: nil,
                            contentContext: .finalMessage,
                            isComplete: true,
                            completion: .contentProcessed { _ in connection.cancel() }
                        )
                    } else {
                        self.receive(on: connection)
                    }
                })
            } else if isComplete || error != nil {
                connection.cancel()
            } else {
                receive(on: connection)
            }
        }
    }
}

private final class TestSocket: @unchecked Sendable {
    private let connection: NWConnection
    private let queue = DispatchQueue(label: "codes.threading.peer-tunnel.tests.client")

    init(_ connection: NWConnection) {
        self.connection = connection
    }

    func start() async throws {
        try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<Void, Error>) in
            let gate = TestContinuationGate(continuation)
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready: gate.succeed(())
                case .failed(let error): gate.fail(error)
                case .cancelled: gate.fail(PeerTunnelError.closed)
                default: break
                }
            }
            connection.start(queue: queue)
        }
    }

    func send(_ data: Data, isComplete: Bool) async throws {
        try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<Void, Error>) in
            connection.send(
                content: data,
                contentContext: isComplete ? .finalMessage : .defaultMessage,
                isComplete: isComplete,
                completion: .contentProcessed { error in
                    if let error { continuation.resume(throwing: error) }
                    else { continuation.resume() }
                }
            )
        }
    }

    func receiveExactly(_ count: Int) async throws -> Data {
        var result = Data()
        while result.count < count {
            let data = try await withCheckedThrowingContinuation {
                (continuation: CheckedContinuation<Data, Error>) in
                connection.receive(
                    minimumIncompleteLength: 1,
                    maximumLength: min(64 * 1_024, count - result.count)
                ) { data, _, isComplete, error in
                    if let error {
                        continuation.resume(throwing: error)
                    } else if let data, !data.isEmpty {
                        continuation.resume(returning: data)
                    } else if isComplete {
                        continuation.resume(throwing: PeerTunnelError.closed)
                    } else {
                        continuation.resume(returning: Data())
                    }
                }
            }
            result.append(data)
        }
        return result
    }

    func cancel() {
        connection.cancel()
    }
}

private final class TestContinuationGate<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Value, Error>?

    init(_ continuation: CheckedContinuation<Value, Error>) {
        self.continuation = continuation
    }

    func succeed(_ value: sending Value) {
        take()?.resume(returning: value)
    }

    func fail(_ error: Error) {
        take()?.resume(throwing: error)
    }

    private func take() -> CheckedContinuation<Value, Error>? {
        lock.withLock {
            defer { continuation = nil }
            return continuation
        }
    }
}
