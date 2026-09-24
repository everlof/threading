import Network
import os
import XCTest
@testable import Threading

/// The HTTP idle timer bounds silence, not lifetime.
///
/// Measured from accept, it was a 60-second lifetime: a phone's pooled keep-alive connection,
/// opened by the launch refresh, was cut off when its sixtieth second fell inside a browser
/// preview capture, and the phone reported "the network connection was lost" over a page that
/// was fine. The timer is re-armed at each transition of the HTTP phase — a complete request,
/// a written response — so a connection that keeps being used lives as long as it is used,
/// while a socket that opens and says nothing, or a request that is never answered, is still
/// closed after one interval. Real loopback sockets and no window, so it stays in `fast`.
final class RemoteConnectionIdleTests: XCTestCase {

    /// Short enough that a handful of exchanges spanning several intervals cost a second or two,
    /// long enough that scheduling jitter on a loaded machine is not mistaken for silence.
    private static let idleInterval: TimeInterval = 0.5
    private static let responseTimeout: TimeInterval = 3
    /// How long a test waits for the server to close a socket it should be closing.
    private static let closeTimeout: TimeInterval = idleInterval * 5

    private var listener: NWListener!
    private var serverQueue: DispatchQueue!
    private var delegate: ScriptedDelegate!
    private let accepted = OSAllocatedUnfairLock<[RemoteConnection]>(initialState: [])
    private var client: RawHTTPClient!

    override func setUpWithError() throws {
        try super.setUpWithError()
        serverQueue = DispatchQueue(label: "RemoteConnectionIdleTests.server")
        delegate = ScriptedDelegate()

        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: parameters)
        let accepted = self.accepted
        let serverQueue = self.serverQueue!
        let delegate = self.delegate!
        listener.newConnectionHandler = { nwConnection in
            let connection = RemoteConnection(
                connection: nwConnection,
                queue: serverQueue,
                delegate: delegate,
                httpIdleInterval: Self.idleInterval
            )
            accepted.withLock { $0.append(connection) }
            connection.start()
        }
        let ready = expectation(description: "listening")
        let settled = OSAllocatedUnfairLock<Bool>(initialState: false)
        listener.stateUpdateHandler = { state in
            guard case .ready = state else { return }
            let first = settled.withLock { was -> Bool in
                defer { was = true }
                return !was
            }
            if first { ready.fulfill() }
        }
        listener.start(queue: serverQueue)
        wait(for: [ready], timeout: 5)

        let port = try XCTUnwrap(listener.port?.rawValue, "the listener should bind a loopback port")
        client = RawHTTPClient(port: port)
        try client.connect(timeout: 5)
    }

    override func tearDown() {
        // NWConnection and NWListener release their local ports asynchronously. The next
        // test binds another ephemeral loopback port immediately, so leaving either cancellation
        // in flight can make its client's connectx fail with EADDRINUSE before idle logic runs.
        if let client {
            XCTAssertTrue(client.cancelAndWait(timeout: 5), "the client released its socket")
        }
        serverQueue?.sync {
            accepted.withLock { $0 }.forEach { $0.cancel() }
        }
        if let listener {
            let cancelled = DispatchSemaphore(value: 0)
            listener.stateUpdateHandler = { state in
                if case .cancelled = state { cancelled.signal() }
            }
            listener.cancel()
            XCTAssertEqual(
                cancelled.wait(timeout: .now() + 5), .success,
                "the listener released its loopback port before the next test"
            )
        }
        super.tearDown()
    }

    // MARK: - A connection in use is not cut off

    func testAKeepAliveConnectionServingRequestsOutlivesTheIdleInterval() throws {
        // Four exchanges spread over two intervals; every silence between them is shorter
        // than one, so none of them is idleness.
        for turn in 1...4 {
            client.send(Self.request(path: "/turn/\(turn)"))
            let response = try XCTUnwrap(
                client.nextResponse(timeout: Self.responseTimeout),
                "turn \(turn) should be answered on the same connection"
            )
            XCTAssertTrue(response.hasPrefix("HTTP/1.1 200"), response)
            Thread.sleep(forTimeInterval: Self.idleInterval * 0.5)
        }
        XCTAssertFalse(client.hasEnded, "a connection that keeps being used is not closed for being old")
    }

    func testARequestAnsweredPastTheConnectionsFirstIntervalIsNotCutOff() throws {
        // The report's shape: one quick exchange, a pause, then a request whose answer takes
        // long enough that the connection's first interval elapses while it is being handled.
        client.send(Self.request(path: "/workspace"))
        XCTAssertNotNil(client.nextResponse(timeout: Self.responseTimeout))
        Thread.sleep(forTimeInterval: Self.idleInterval * 0.6)

        delegate.responseDelay = Self.idleInterval * 0.6
        client.send(Self.request(path: "/browser-preview"))
        let response = try XCTUnwrap(
            client.nextResponse(timeout: Self.responseTimeout),
            "the preview should arrive rather than the socket closing underneath it"
        )
        XCTAssertTrue(response.hasPrefix("HTTP/1.1 200"), response)
    }

    // MARK: - Silence is still bounded

    func testAClosingResponseDrainsUntilThePeerClosesWithoutRoutingMoreRequests() throws {
        delegate.closesResponses = true
        client.send(Self.request(path: "/attachment") + Self.request(path: "/pipelined"))
        let response = try XCTUnwrap(client.nextResponse(timeout: Self.responseTimeout))
        XCTAssertTrue(response.contains("Connection: close"))
        XCTAssertTrue(response.hasSuffix("/attachment"))
        XCTAssertTrue(client.waitForEnd(timeout: Self.responseTimeout), "the response ends the write stream")
        XCTAssertFalse(
            delegate.waitForClose(timeout: 0),
            "processing the send is not permission to cancel both directions before the peer finishes"
        )

        client.send(Self.request(path: "/late"))
        client.finishWriting()
        XCTAssertTrue(delegate.waitForClose(timeout: Self.responseTimeout))
        XCTAssertEqual(delegate.requestCount, 1, "pipelined and draining input must not be routed")
    }

    func testAClosingResponseStillReleasesAPeerThatNeverCloses() throws {
        delegate.closesResponses = true
        client.send(Self.request(path: "/attachment"))
        XCTAssertNotNil(client.nextResponse(timeout: Self.responseTimeout))
        XCTAssertTrue(client.waitForEnd(timeout: Self.responseTimeout))
        XCTAssertFalse(delegate.waitForClose(timeout: 0))
        XCTAssertTrue(
            delegate.waitForClose(timeout: Self.closeTimeout),
            "the existing HTTP deadline also bounds the final drain"
        )
    }

    func testASocketThatSaysNothingIsClosedAfterOneInterval() {
        let opened = Date()
        XCTAssertTrue(client.waitForEnd(timeout: Self.closeTimeout), "a silent probe is closed")
        XCTAssertGreaterThanOrEqual(
            Date().timeIntervalSince(opened),
            Self.idleInterval * 0.5,
            "closed for silence, not on sight"
        )
    }

    func testARequestThatIsNeverAnsweredIsClosedAfterOneInterval() {
        delegate.answers = false
        client.send(Self.request(path: "/never"))
        XCTAssertTrue(client.waitForEnd(timeout: Self.closeTimeout), "an unanswered request does not hold a socket forever")
    }

    func testAnIdleKeepAliveConnectionIsClosedOneIntervalAfterItsLastResponse() throws {
        client.send(Self.request(path: "/once"))
        XCTAssertNotNil(client.nextResponse(timeout: Self.responseTimeout))
        let answered = Date()
        XCTAssertTrue(client.waitForEnd(timeout: Self.closeTimeout), "a keep-alive connection nobody uses is released")
        XCTAssertGreaterThanOrEqual(Date().timeIntervalSince(answered), Self.idleInterval * 0.5)
    }

    // MARK: - Fixtures

    private static func request(path: String) -> String {
        "GET \(path) HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n"
    }

    /// Answers every request with a 200 after a configurable delay, off the connection's queue
    /// the way the server's main-actor hop does, or not at all.
    private final class ScriptedDelegate: RemoteConnection.Delegate, @unchecked Sendable {
        private struct Script {
            var delay: TimeInterval = 0
            var answers = true
            var closesResponses = false
            var requestCount = 0
        }
        private let script = OSAllocatedUnfairLock(initialState: Script())
        private let closed = DispatchSemaphore(value: 0)

        var closesResponses: Bool {
            get { script.withLock { $0.closesResponses } }
            set { script.withLock { $0.closesResponses = newValue } }
        }

        var requestCount: Int { script.withLock { $0.requestCount } }

        func waitForClose(timeout: TimeInterval) -> Bool {
            closed.wait(timeout: .now() + timeout) == .success
        }

        var responseDelay: TimeInterval {
            get { script.withLock { $0.delay } }
            set { script.withLock { $0.delay = newValue } }
        }

        var answers: Bool {
            get { script.withLock { $0.answers } }
            set { script.withLock { $0.answers = newValue } }
        }

        func route(
            _ request: HTTPRequest,
            from connection: RemoteConnection,
            respond: @escaping @Sendable (RemoteRouteDecision) -> Void
        ) {
            let script = script.withLock {
                $0.requestCount += 1
                return $0
            }
            guard script.answers else { return }
            var response = HTTPResponse(
                status: 200,
                reason: "OK",
                contentType: "text/plain",
                body: Data(request.path.utf8)
            )
            response.closesConnection = script.closesResponses
            let answer = response
            DispatchQueue.global().asyncAfter(deadline: .now() + script.delay) {
                respond(.respond(answer))
            }
        }

        func handleMessage(_ message: RemoteWebSocket.Message, from connection: RemoteConnection) {}

        func didClose(_ connection: RemoteConnection) { closed.signal() }
    }

    /// A raw HTTP/1.1 client over one TCP socket: sends request text, frames responses by
    /// `Content-Length`, and reports when the peer closes the socket.
    private final class RawHTTPClient: @unchecked Sendable {
        enum ClientError: Error { case connectFailed }

        private let connection: NWConnection
        private let queue = DispatchQueue(label: "RemoteConnectionIdleTests.client")
        private let cancelled = DispatchSemaphore(value: 0)
        private let condition = NSCondition()
        private var buffer = Data()
        private var responses: [String] = []
        private var ended = false

        init(port: UInt16) {
            connection = NWConnection(
                host: "127.0.0.1",
                port: NWEndpoint.Port(rawValue: port)!,
                using: .tcp
            )
        }

        func connect(timeout: TimeInterval) throws {
            let settled = DispatchSemaphore(value: 0)
            let outcome = OSAllocatedUnfairLock<Bool?>(initialState: nil)
            connection.stateUpdateHandler = { [weak self] state in
                switch state {
                case .ready:
                    outcome.withLock { if $0 == nil { $0 = true; settled.signal() } }
                case .failed:
                    outcome.withLock { if $0 == nil { $0 = false; settled.signal() } }
                    self?.markEnded()
                case .cancelled:
                    outcome.withLock { if $0 == nil { $0 = false; settled.signal() } }
                    self?.markEnded()
                    self?.cancelled.signal()
                default:
                    break
                }
            }
            connection.start(queue: queue)
            guard settled.wait(timeout: .now() + timeout) == .success,
                  outcome.withLock({ $0 }) == true else {
                throw ClientError.connectFailed
            }
            receiveLoop()
        }

        func send(_ request: String) {
            connection.send(content: Data(request.utf8), completion: .contentProcessed { _ in })
        }

        func finishWriting() {
            connection.send(content: nil, contentContext: .finalMessage, isComplete: true,
                            completion: .contentProcessed { _ in })
        }

        func nextResponse(timeout: TimeInterval) -> String? {
            condition.lock()
            defer { condition.unlock() }
            let deadline = Date().addingTimeInterval(timeout)
            while responses.isEmpty, !ended {
                guard condition.wait(until: deadline) else { break }
            }
            return responses.isEmpty ? nil : responses.removeFirst()
        }

        var hasEnded: Bool {
            condition.lock()
            defer { condition.unlock() }
            return ended
        }

        func waitForEnd(timeout: TimeInterval) -> Bool {
            condition.lock()
            defer { condition.unlock() }
            let deadline = Date().addingTimeInterval(timeout)
            while !ended {
                guard condition.wait(until: deadline) else { break }
            }
            return ended
        }

        func cancelAndWait(timeout: TimeInterval) -> Bool {
            connection.cancel()
            return cancelled.wait(timeout: .now() + timeout) == .success
        }

        private func receiveLoop() {
            connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) {
                [weak self] data, _, isComplete, error in
                guard let self else { return }
                if let data, !data.isEmpty { self.append(data) }
                if isComplete || error != nil {
                    self.markEnded()
                    return
                }
                self.receiveLoop()
            }
        }

        private func append(_ data: Data) {
            condition.lock()
            defer { condition.unlock() }
            buffer.append(data)
            while let response = Self.takeResponse(from: &buffer) {
                responses.append(response)
            }
            condition.broadcast()
        }

        private func markEnded() {
            condition.lock()
            ended = true
            condition.broadcast()
            condition.unlock()
        }

        /// Removes one complete response from the front of `buffer`, or leaves it untouched.
        private static func takeResponse(from buffer: inout Data) -> String? {
            guard let headEnd = buffer.range(of: Data("\r\n\r\n".utf8)) else { return nil }
            let head = String(decoding: buffer[buffer.startIndex..<headEnd.lowerBound], as: UTF8.self)
            let lengthPrefix = "content-length:"
            let length = head.split(separator: "\r\n")
                .first { $0.lowercased().hasPrefix(lengthPrefix) }
                .flatMap { Int($0.dropFirst(lengthPrefix.count).trimmingCharacters(in: .whitespaces)) }
                ?? 0
            let total = (headEnd.upperBound - buffer.startIndex) + length
            guard buffer.count >= total else { return nil }
            let response = String(decoding: buffer.prefix(total), as: UTF8.self)
            buffer = Data(buffer.dropFirst(total))
            return response
        }
    }
}
