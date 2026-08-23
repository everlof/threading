import Darwin
import ThreadingRemoteKit
import XCTest
@testable import ThreadingMobile

/// A server that completes the TCP handshake and then says nothing at all.
///
/// This is the shape the 2026-08-17 incident produced: something accepted the connection, no
/// WebSocket upgrade ever came back, and the phone waited for it forever. `URLSessionWebSocketTask`
/// does not honour `timeoutIntervalForResource`, so nothing in URLSession ends this on its own,
/// which is why the client has to own the deadline and why this fixture is the regression
/// boundary regardless of what the original root cause turns out to have been.
final class SilentTCPServer: @unchecked Sendable {

    enum StartupError: Error {
        case socketUnavailable
        case bindFailed(Int32)
        case listenFailed(Int32)
        case addressUnavailable
    }

    let port: UInt16

    private let queue = DispatchQueue(label: "codes.threading.mobile.tests.silent-server")
    private let listenDescriptor: Int32
    private let source: DispatchSourceRead
    /// Accepted connections are retained, unread and unanswered, until the fixture stops. A
    /// closed peer would look like a refused connection rather than a silent one.
    private var accepted: [Int32] = []
    private var isStopped = false

    init() throws {
        let descriptor = socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw StartupError.socketUnavailable }

        var reuse: Int32 = 1
        setsockopt(
            descriptor,
            SOL_SOCKET,
            SO_REUSEADDR,
            &reuse,
            socklen_t(MemoryLayout<Int32>.size)
        )

        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = 0
        address.sin_addr.s_addr = inet_addr("127.0.0.1")

        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { raw in
                Darwin.bind(descriptor, raw, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0 else {
            close(descriptor)
            throw StartupError.bindFailed(errno)
        }
        guard listen(descriptor, 4) == 0 else {
            close(descriptor)
            throw StartupError.listenFailed(errno)
        }

        var assigned = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let named = withUnsafeMutablePointer(to: &assigned) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { raw in
                getsockname(descriptor, raw, &length)
            }
        }
        guard named == 0, assigned.sin_port != 0 else {
            close(descriptor)
            throw StartupError.addressUnavailable
        }

        listenDescriptor = descriptor
        port = UInt16(bigEndian: assigned.sin_port)
        source = DispatchSource.makeReadSource(fileDescriptor: descriptor, queue: queue)

        source.setEventHandler { [weak self] in
            guard let self else { return }
            let peer = accept(descriptor, nil, nil)
            guard peer >= 0 else { return }
            self.retain(peer)
        }
        source.setCancelHandler {
            close(descriptor)
        }
        source.resume()
    }

    func stop() {
        queue.sync {
            guard !isStopped else { return }
            isStopped = true
            for peer in accepted { close(peer) }
            accepted.removeAll()
        }
        source.cancel()
    }

    private func retain(_ peer: Int32) {
        if isStopped {
            close(peer)
            return
        }
        accepted.append(peer)
    }
}

@MainActor
final class RemoteConnectionFailureTests: XCTestCase {

    private static let bearer = String(repeating: "a", count: 43)
    private let injectedDeadline: Duration = .milliseconds(400)
    /// Generous next to the injected deadline, so a failure here means "never terminal", not
    /// "slower than expected on a loaded simulator".
    private let terminalAllowance: TimeInterval = 6

    // MARK: - The phone must fail instead of hanging

    func testASilentServerProducesATerminalFailureBeforeTheDeadlineElapses() async throws {
        let server = try SilentTCPServer()
        defer { server.stop() }

        let sessionID = UUID().uuidString.lowercased()
        let connection = makeConnection(port: server.port, sessionID: sessionID)
        let started = Date()
        connection.connect()

        let failure = try await terminalFailure(of: connection)
        connection.disconnect(markEnded: false)

        XCTAssertEqual(failure.cause, .helloTimeout)
        XCTAssertLessThan(
            Date().timeIntervalSince(started),
            terminalAllowance,
            "A connect that is never greeted must end in a stated failure, not an open wait."
        )
    }

    /// The second half of the same fix: a terminal *event*, not only a terminal phase. The
    /// incident's support bundle stopped after `socketConnecting` because nothing downstream of
    /// it ever ran.
    func testEveryConnectReachesATerminalEventInTheDiagnosticsJournal() async throws {
        let server = try SilentTCPServer()
        defer { server.stop() }

        let sessionID = UUID().uuidString.lowercased()
        let pseudonym = MobileDiagnostics.pseudonym(sessionID, prefix: "session")
        let connection = makeConnection(port: server.port, sessionID: sessionID)
        connection.connect()
        _ = try await terminalFailure(of: connection)
        connection.disconnect(markEnded: false)

        let records = MobileDiagnostics.journal.records().filter {
            $0.fields[RemoteDiagnosticField.session.rawValue] == pseudonym
        }
        XCTAssertTrue(
            records.contains { $0.event == .socketConnecting },
            "The connect attempt itself must be recorded."
        )
        let terminal = try XCTUnwrap(records.last { $0.event == .socketFailed })
        let connecting = try XCTUnwrap(records.last { $0.event == .socketConnecting })
        XCTAssertEqual(
            terminal.fields[RemoteDiagnosticField.reason.rawValue],
            RemoteConnectionFailure.Cause.helloTimeout.rawValue
        )
        XCTAssertEqual(
            terminal.fields[RemoteDiagnosticField.trace.rawValue],
            connecting.fields[RemoteDiagnosticField.trace.rawValue]
        )
        XCTAssertEqual(
            terminal.fields[RemoteDiagnosticField.timeoutMS.rawValue],
            "400"
        )
        XCTAssertNotNil(terminal.fields[RemoteDiagnosticField.durationMS.rawValue])
        XCTAssertEqual(terminal.fields[RemoteDiagnosticField.phase.rawValue], "hello")
    }

    /// `endpointKind` and a hash of the address, on both ends of the attempt. Without them
    /// "wrong address" and "right address, host down" are the same record and have opposite
    /// fixes.
    func testConnectAndFailureRecordsCarryTheEndpointKindAndAnOriginHash() async throws {
        let server = try SilentTCPServer()
        defer { server.stop() }

        let sessionID = UUID().uuidString.lowercased()
        let pseudonym = MobileDiagnostics.pseudonym(sessionID, prefix: "session")
        let connection = makeConnection(port: server.port, sessionID: sessionID)
        connection.connect()
        _ = try await terminalFailure(of: connection)
        connection.disconnect(markEnded: false)

        let records = MobileDiagnostics.journal.records().filter {
            $0.fields[RemoteDiagnosticField.session.rawValue] == pseudonym
        }
        for event in [RemoteDiagnosticEvent.socketConnecting, .socketFailed] {
            let record = try XCTUnwrap(records.last { $0.event == event })
            XCTAssertNotNil(record.fields[RemoteDiagnosticField.transport.rawValue])
            let origin = try XCTUnwrap(record.fields[RemoteDiagnosticField.origin.rawValue])
            XCTAssertTrue(origin.hasPrefix("origin-"))
            XCTAssertFalse(origin.contains("127.0.0.1"))
            XCTAssertFalse(origin.contains(String(server.port)))
        }
    }

    func testTheSocketSessionDoesNotWaitForConnectivity() {
        XCTAssertFalse(
            RemoteClient.socketWaitsForConnectivity,
            "A socket that waits for connectivity has no failure path at all."
        )
    }

    func testTheRequestSessionDoesNotWaitForConnectivity() {
        XCTAssertFalse(
            RemoteClient.requestWaitsForConnectivity,
            "A waiting REST candidate prevents the route walk from trying the next door."
        )
    }

    // MARK: - A dead address must say so

    func testABadServerResponseOnTheSocketAsksForAFreshPairingCode() {
        let failure = RemoteConnectionFailure.transport(
            URLError(.badServerResponse),
            host: "example.trycloudflare.com"
        )

        XCTAssertEqual(failure.cause, .addressChanged)
        XCTAssertEqual(failure.recovery, .pairAgain)
        XCTAssertEqual(
            failure.message,
            "This Mac’s address has changed. Scan its QR code again."
        )
    }

    func testALocalNetworkDenialIsItsOwnStateRatherThanAChangedAddress() {
        let denial = URLError(
            .cannotConnectToHost,
            userInfo: [NSUnderlyingErrorKey: NSError(
                domain: NSPOSIXErrorDomain,
                code: Int(EHOSTUNREACH)
            )]
        )
        let failure = RemoteConnectionFailure.transport(denial, host: "192.168.1.42")

        XCTAssertEqual(failure.cause, .localNetworkDenied)
        XCTAssertEqual(failure.recovery, .openLocalNetworkSettings)
        XCTAssertEqual(
            failure.message,
            "Threading needs Local Network access to reach this Mac on Wi-Fi. Turn it on in Settings."
        )
    }

    /// The same POSIX code off a routable address is an unreachable host, not a permission the
    /// user can grant. Naming it "turn on Local Network access" would send them somewhere that
    /// changes nothing.
    func testTheSameNoRouteErrorOnAPublicAddressIsNotBlamedOnLocalNetworkPermission() {
        let error = URLError(
            .cannotConnectToHost,
            userInfo: [NSUnderlyingErrorKey: NSError(
                domain: NSPOSIXErrorDomain,
                code: Int(EHOSTUNREACH)
            )]
        )

        XCTAssertEqual(
            RemoteConnectionFailure.transport(error, host: "abc.trycloudflare.com").cause,
            .transport
        )
        XCTAssertEqual(
            RemoteConnectionFailure.transport(error, host: "203.0.113.10").cause,
            .transport
        )
    }

    func testPrivateAddressRecognition() {
        for host in ["192.168.1.42", "10.0.0.5", "172.16.4.1", "172.31.255.254",
                     "169.254.10.10", "studio.local", "fe80::1", "fd00::1"] {
            XCTAssertTrue(RemoteLocalNetworkAddress.isPrivate(host), host)
        }
        for host in ["127.0.0.1", "203.0.113.10", "172.32.0.1", "8.8.8.8",
                     "example.trycloudflare.com", "mac.ts.net", "::1"] {
            XCTAssertFalse(RemoteLocalNetworkAddress.isPrivate(host), host)
        }
    }

    // MARK: - A rejected viewport must not fail the session

    func testARefusedViewportIsReportedWithoutFailingTheSession() {
        let connection = makeConnection(port: 1, sessionID: UUID().uuidString.lowercased())

        connection.receiveServerTextForTesting(
            #"{"type":"error","code":"invalidViewport","detail":"columnsOutOfRange"}"#
        )

        XCTAssertEqual(connection.phase, .connecting)
        XCTAssertNil(connection.phase.failure)
    }

    func testAnUnlistedRefusalStillFailsTheSession() {
        let connection = makeConnection(port: 1, sessionID: UUID().uuidString.lowercased())

        connection.receiveServerTextForTesting(#"{"type":"error","code":"forbidden"}"#)

        XCTAssertEqual(connection.phase.failure?.cause, .remoteAction)
        XCTAssertEqual(connection.phase.failure?.recovery, .reconnect)
    }

    func testAHostStartupTimeoutEndsTheRouteInsteadOfStartingReconnectRecovery() throws {
        let connection = makeConnection(port: 1, sessionID: UUID().uuidString.lowercased())
        let ended = RemoteEndedDTO(reason: "sessionStartupTimedOut")
        let frame = String(decoding: try JSONEncoder().encode(ended), as: UTF8.self)

        connection.receiveServerTextForTesting(frame)

        XCTAssertEqual(connection.phase, .ended(MobileL10n.string("Couldn’t start session")))
        XCTAssertNil(connection.phase.failure)
    }

    func testAPermissionRaceStillDoesNotFailTheSession() {
        let connection = makeConnection(port: 1, sessionID: UUID().uuidString.lowercased())

        connection.receiveServerTextForTesting(
            #"{"type":"error","code":"permissionNotPending"}"#
        )

        XCTAssertEqual(connection.phase, .connecting)
    }

    // MARK: - Helpers

    private func makeConnection(
        port: UInt16,
        sessionID: String
    ) -> RemoteSessionConnection {
        let link = RemoteConnectionLink(
            baseURL: URL(string: "http://127.0.0.1:\(port)")!,
            token: Self.bearer
        )!
        return RemoteSessionConnection(
            session: RemoteSessionSummaryDTO(
                id: sessionID,
                title: "Fixture",
                agentKind: "claude",
                surface: .terminal,
                state: .idle,
                projectName: "Fixture"
            ),
            client: RemoteClient(link: link),
            helloDeadline: injectedDeadline
        )
    }

    private func terminalFailure(
        of connection: RemoteSessionConnection
    ) async throws -> RemoteConnectionFailure {
        let deadline = Date().addingTimeInterval(terminalAllowance)
        while Date() < deadline {
            if let failure = connection.phase.failure { return failure }
            try await Task.sleep(for: .milliseconds(25))
        }
        XCTFail("The connection never reached a terminal state.")
        throw XCTSkip("no terminal state")
    }
}
