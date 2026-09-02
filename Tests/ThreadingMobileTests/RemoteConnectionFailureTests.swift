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

    private struct MutationBody: Encodable {
        let zebra: Int
        let alpha: Int
        let middle: Int
    }

    private static let bearer = String(repeating: "a", count: 43)
    private let injectedDeadline: Duration = .milliseconds(400)
    /// Generous next to the injected deadline, so a failure here means "never terminal", not
    /// "slower than expected on a loaded simulator".
    private let terminalAllowance: TimeInterval = 6

    func testMutationJSONUsesStableKeyOrderAcrossRouteRequests() throws {
        let body = MutationBody(zebra: 3, alpha: 1, middle: 2)

        let first = try RemoteClient.encodeMutationBody(body)
        let fallback = try RemoteClient.encodeMutationBody(body)

        XCTAssertEqual(first, fallback)
        XCTAssertEqual(
            String(decoding: first, as: UTF8.self),
            #"{"alpha":1,"middle":2,"zebra":3}"#
        )
    }

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

    func testDemoTerminalPairsContentFreeInputAndSubmissionLatencyEvents() async throws {
        let sessionID = UUID().uuidString.lowercased()
        let session = RemoteSessionSummaryDTO(
            id: sessionID,
            title: "Latency fixture",
            agentKind: "codex",
            surface: .terminal,
            state: .idle,
            projectName: "Fixture"
        )
        let connection = RemoteSessionConnection(
            session: session,
            client: RemoteClient(link: DemoExperience.link)
        )
        connection.connect()
        defer { connection.disconnect(markEnded: false) }

        XCTAssertEqual(connection.phase, .connected)
        connection.sendTerminalKey("z")
        let submissionID = try XCTUnwrap(connection.submitTerminalLine("status"))
        await connection.waitForInteractionDiagnosticsForTesting()

        let sessionPseudonym = MobileDiagnostics.pseudonym(sessionID, prefix: "session")
        let records = MobileDiagnostics.journal.records().filter {
            $0.fields[RemoteDiagnosticField.session.rawValue] == sessionPseudonym
        }

        try assertPairedLatencyEvents(
            started: .terminalInputProbeStarted,
            ended: .terminalInputProbeEnded,
            in: records
        )
        let promptEnd = try assertPairedLatencyEvents(
            started: .promptSubmissionStarted,
            ended: .promptSubmissionEnded,
            in: records
        )
        XCTAssertEqual(
            promptEnd.fields[RemoteDiagnosticField.trace.rawValue],
            MobileDiagnostics.pseudonym(submissionID, prefix: "trace")
        )
        XCTAssertEqual(
            promptEnd.fields[RemoteDiagnosticField.result.rawValue],
            RemotePromptSubmissionStatus.accepted.rawValue
        )

        let encoded = String(decoding: try JSONEncoder().encode(records), as: UTF8.self)
        XCTAssertFalse(encoded.contains("status"))
        XCTAssertFalse(encoded.contains("\"z\""))
    }

    // MARK: - A dead route is not dialled blind

    /// The 2026-09-02 report: Wi-Fi went, both sockets died within a millisecond, and the
    /// session socket's first retry kept the LAN origin because a hello had reset its ladder. It
    /// then dialled an address that no longer existed until the person backed out of the chat.
    /// A loss with no close frame now asks the model for a route on the very first retry, and
    /// says so in the journal.
    func testALossWithoutACloseFrameAsksTheModelForARouteOnTheFirstRetry() async throws {
        let server = try SilentTCPServer()
        defer { server.stop() }

        let sessionID = UUID().uuidString.lowercased()
        let pseudonym = MobileDiagnostics.pseudonym(sessionID, prefix: "session")
        let requests = ReconnectRequestLog()
        let connection = makeConnection(port: server.port, sessionID: sessionID) { request in
            requests.record(request)
            return nil
        }
        connection.connect()
        _ = try await terminalFailure(of: connection)
        let request = try await requests.first(within: terminalAllowance)
        connection.disconnect(markEnded: false)

        XCTAssertEqual(request, MobileSessionReconnectRequest(attempt: 0, peerSentClose: false))
        XCTAssertTrue(
            MobileConnectionRecoveryPolicy.sessionReconnectNeedsHostRecovery(
                request,
                dashboardRecoveryPending: false
            ),
            "the first retry after a wire loss goes through host recovery"
        )
        let scheduled = try XCTUnwrap(
            MobileDiagnostics.journal.records().last {
                $0.event == .socketReconnectScheduled
                    && $0.fields[RemoteDiagnosticField.session.rawValue] == pseudonym
            }
        )
        XCTAssertEqual(scheduled.fields[RemoteDiagnosticField.detail.rawValue], "routeSuspect")
    }

    /// The other half of the same report: once the dashboard socket had found the Mac over
    /// cellular, nothing told the session socket, which sat out its hello deadline on the LAN
    /// origin. A route that moves now restarts a waiting hello on the new origin, and the
    /// abandoned attempt still gets its terminal journal entry.
    func testARouteThatMovesRestartsAHelloStillWaitingOnTheOldOne() async throws {
        let oldServer = try SilentTCPServer()
        defer { oldServer.stop() }
        let newServer = try SilentTCPServer()
        defer { newServer.stop() }

        let sessionID = UUID().uuidString.lowercased()
        let pseudonym = MobileDiagnostics.pseudonym(sessionID, prefix: "session")
        let connection = makeConnection(port: oldServer.port, sessionID: sessionID)
        connection.connect()
        XCTAssertEqual(connection.phase, .connecting)

        XCTAssertFalse(
            connection.adoptRoute(makeClient(port: oldServer.port)),
            "the same origin is not a move"
        )
        XCTAssertTrue(connection.adoptRoute(makeClient(port: newServer.port)))
        XCTAssertEqual(connection.phase, .connecting)

        let failure = try await terminalFailure(of: connection)
        connection.disconnect(markEnded: false)
        XCTAssertEqual(failure.cause, .helloTimeout)

        let records = MobileDiagnostics.journal.records().filter {
            $0.fields[RemoteDiagnosticField.session.rawValue] == pseudonym
        }
        let connecting = records.filter { $0.event == .socketConnecting }
        XCTAssertEqual(connecting.count, 2, "one attempt per origin")
        let superseded = try XCTUnwrap(records.last { $0.event == .socketEnded })
        XCTAssertEqual(superseded.fields[RemoteDiagnosticField.result.rawValue], "superseded")
        XCTAssertEqual(superseded.fields[RemoteDiagnosticField.reason.rawValue], "routeChanged")
        XCTAssertEqual(superseded.fields[RemoteDiagnosticField.phase.rawValue], "hello")
        XCTAssertEqual(
            superseded.fields[RemoteDiagnosticField.trace.rawValue],
            connecting.first?.fields[RemoteDiagnosticField.trace.rawValue],
            "the abandoned attempt is the one that ends"
        )
        XCTAssertEqual(
            superseded.fields[RemoteDiagnosticField.origin.rawValue],
            originDigest(port: oldServer.port)
        )
        XCTAssertEqual(
            connecting.last?.fields[RemoteDiagnosticField.origin.rawValue],
            originDigest(port: newServer.port)
        )
        let failed = try XCTUnwrap(records.last { $0.event == .socketFailed })
        XCTAssertEqual(
            failed.fields[RemoteDiagnosticField.trace.rawValue],
            connecting.last?.fields[RemoteDiagnosticField.trace.rawValue],
            "the deadline that fires belongs to the new attempt, not the abandoned one"
        )
    }

    func testARouteThatMovesDuringBackoffDialsTheNewOneAtOnce() async throws {
        let oldServer = try SilentTCPServer()
        defer { oldServer.stop() }
        let newServer = try SilentTCPServer()
        defer { newServer.stop() }

        let sessionID = UUID().uuidString.lowercased()
        let pseudonym = MobileDiagnostics.pseudonym(sessionID, prefix: "session")
        let connection = makeConnection(port: oldServer.port, sessionID: sessionID) { _ in nil }
        connection.connect()
        _ = try await terminalFailure(of: connection)

        XCTAssertTrue(
            connection.adoptRoute(makeClient(port: newServer.port)),
            "a backoff toward the old origin is abandoned for the new one"
        )
        XCTAssertEqual(connection.phase, .connecting)
        connection.disconnect(markEnded: false)

        let records = MobileDiagnostics.journal.records().filter {
            $0.fields[RemoteDiagnosticField.session.rawValue] == pseudonym
        }
        let superseded = try XCTUnwrap(records.last { $0.event == .socketEnded })
        XCTAssertEqual(superseded.fields[RemoteDiagnosticField.result.rawValue], "superseded")
        XCTAssertEqual(superseded.fields[RemoteDiagnosticField.phase.rawValue], "backoff")
        XCTAssertEqual(
            records.last { $0.event == .socketConnecting }?
                .fields[RemoteDiagnosticField.origin.rawValue],
            originDigest(port: newServer.port)
        )
    }

    func testAConnectedSocketIsNotRestartedWhenTheRouteMoves() {
        let connection = RemoteSessionConnection(
            session: RemoteSessionSummaryDTO(
                id: UUID().uuidString.lowercased(),
                title: "Fixture",
                agentKind: "codex",
                surface: .terminal,
                state: .idle,
                projectName: "Fixture"
            ),
            client: RemoteClient(link: DemoExperience.link)
        )
        connection.connect()
        defer { connection.disconnect(markEnded: false) }
        XCTAssertEqual(connection.phase, .connected)

        XCTAssertFalse(
            connection.adoptRoute(makeClient(port: 1)),
            "a working socket is left alone; its own reconnect asks for the current route"
        )
        XCTAssertEqual(connection.phase, .connected)
    }

    // MARK: - Helpers

    private func makeConnection(
        port: UInt16,
        sessionID: String,
        reconnectClient: (
            @MainActor (MobileSessionReconnectRequest) async -> RemoteClient?
        )? = nil
    ) -> RemoteSessionConnection {
        RemoteSessionConnection(
            session: RemoteSessionSummaryDTO(
                id: sessionID,
                title: "Fixture",
                agentKind: "claude",
                surface: .terminal,
                state: .idle,
                projectName: "Fixture"
            ),
            client: makeClient(port: port),
            reconnectClient: reconnectClient,
            helloDeadline: injectedDeadline
        )
    }

    private func makeClient(port: UInt16) -> RemoteClient {
        RemoteClient(link: RemoteConnectionLink(
            baseURL: URL(string: "http://127.0.0.1:\(port)")!,
            token: Self.bearer
        )!)
    }

    private func originDigest(port: UInt16) -> String {
        MobileDiagnostics.originDigest(URL(string: "http://127.0.0.1:\(port)")!)
    }

    @discardableResult
    private func assertPairedLatencyEvents(
        started startedEvent: RemoteDiagnosticEvent,
        ended endedEvent: RemoteDiagnosticEvent,
        in records: [RemoteDiagnosticRecord]
    ) throws -> RemoteDiagnosticRecord {
        let started = try XCTUnwrap(records.last { $0.event == startedEvent })
        let ended = try XCTUnwrap(records.last { $0.event == endedEvent })
        XCTAssertEqual(
            started.fields[RemoteDiagnosticField.trace.rawValue],
            ended.fields[RemoteDiagnosticField.trace.rawValue]
        )
        XCTAssertEqual(ended.fields[RemoteDiagnosticField.phase.rawValue], "clientRoundTrip")
        XCTAssertNotNil(ended.fields[RemoteDiagnosticField.durationMS.rawValue].flatMap(Int.init))
        return ended
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

/// What a connection asked the model for, in order, readable from the test's own actor.
@MainActor
private final class ReconnectRequestLog {
    private(set) var requests: [MobileSessionReconnectRequest] = []

    func record(_ request: MobileSessionReconnectRequest) {
        requests.append(request)
    }

    func first(within allowance: TimeInterval) async throws -> MobileSessionReconnectRequest {
        let deadline = Date().addingTimeInterval(allowance)
        while Date() < deadline {
            if let first = requests.first { return first }
            try await Task.sleep(for: .milliseconds(25))
        }
        XCTFail("The connection never asked the model for a route.")
        throw XCTSkip("no reconnect request")
    }
}

/// The REST half of the same reliability boundary: HTTP status says which broad class failed,
/// while the bounded refusal code retains the host's actionable reason across the wire.
final class RemoteRESTErrorTests: XCTestCase {
    func testStructuredRefusalPreservesStatusCodeAndMachineDetail() {
        let body = try! JSONEncoder().encode(RemoteErrorDTO(
            code: .unknownModel,
            detail: "catalogChanged"
        ))
        let error = RemoteClientError.decodedRefusal(status: 422, data: body)

        XCTAssertEqual(error.statusCode, 422)
        XCTAssertEqual(error.refusalCode, RemoteRESTErrorCode.unknownModel.rawValue)
        XCTAssertEqual(error.refusalDetail, "catalogChanged")
        XCTAssertTrue(error.requiresLaunchCatalogRefresh)
        XCTAssertEqual(
            MobileDiagnostics.errorCode(error),
            "remote.refusal.unknownModel"
        )
        XCTAssertFalse(error.localizedDescription.contains("HTTP 422"))
    }

    func testLegacyAndFutureHostRefusalsRemainDiagnosable() throws {
        let legacy = RemoteClientError.decodedRefusal(status: 422, data: Data())
        XCTAssertEqual(legacy.statusCode, 422)
        XCTAssertNil(legacy.refusalCode)
        XCTAssertEqual(MobileDiagnostics.errorCode(legacy), "remote.http.422")

        let futureBody = try JSONEncoder().encode(RemoteErrorDTO(code: "futureGuard"))
        let future = RemoteClientError.decodedRefusal(status: 409, data: futureBody)
        XCTAssertEqual(future.refusalCode, "futureGuard")
        XCTAssertEqual(
            MobileDiagnostics.errorCode(future),
            "remote.refusal.futureGuard"
        )
    }

    func testGenericUnauthorizedResponseKeepsMembershipMessage() throws {
        let body = try JSONEncoder().encode(RemoteErrorDTO(code: .unauthorized))
        let error = RemoteClientError.decodedRefusal(status: 401, data: body)

        guard case .unauthorized = error else {
            return XCTFail("generic authentication refusal should keep the established case")
        }
    }

    func testAccountMoveRefusalUsesItsSafeGuardDetail() throws {
        let body = try JSONEncoder().encode(RemoteErrorDTO(
            code: .accountMoveRefused,
            detail: "missingTranscript"
        ))
        let error = RemoteClientError.decodedRefusal(status: 409, data: body)

        XCTAssertEqual(
            error.localizedDescription,
            MobileL10n.string("This session has no recorded conversation to move yet.")
        )
        XCTAssertEqual(error.refusalDetail, "missingTranscript")
    }

    func testStructuredPersistenceRefusalStopsMutationRouteFailover() throws {
        let body = try JSONEncoder().encode(RemoteErrorDTO(code: .persistenceUnavailable))
        let refusal = RemoteClientError.decodedRefusal(status: 503, data: body)

        XCTAssertFalse(
            refusal.allowsMutationRouteFailover,
            "a later route failure must not replace the Mac's authoritative persistence error"
        )
        XCTAssertTrue(
            RemoteClientError.server(status: 503).allowsMutationRouteFailover,
            "an older status-only gateway response must retain route failover"
        )
    }

    func testStorageExhaustionRefusalExplainsTheRequiredRecovery() throws {
        let body = try JSONEncoder().encode(RemoteErrorDTO(code: .storageExhausted))
        let error = RemoteClientError.decodedRefusal(status: 503, data: body)

        XCTAssertEqual(error.refusalCode, RemoteRESTErrorCode.storageExhausted.rawValue)
        XCTAssertEqual(
            error.localizedDescription,
            MobileL10n.string(
                "The Mac is out of storage space. Free up space on the Mac, then try again."
            )
        )
        XCTAssertFalse(error.allowsMutationRouteFailover)
    }

    func testOpenDraftRepairsOnlyWithdrawnProjectAndAgentChoices() {
        let catalog = RemoteNewSessionCatalogDTO(
            projects: [
                .init(id: "project-a", name: "Alpha", branch: nil, checkoutLabel: "Alpha"),
                .init(id: "project-b", name: "Beta", branch: nil, checkoutLabel: "Beta"),
            ],
            agents: [
                .init(
                    id: "claude",
                    name: "Claude",
                    models: [],
                    defaultModelID: nil,
                    supportsConversation: true
                ),
                .init(
                    id: "codex",
                    name: "Codex",
                    models: [],
                    defaultModelID: nil,
                    supportsConversation: true
                ),
            ]
        )

        XCTAssertEqual(
            SessionDraftCatalogReconciliation.projectID(
                current: "project-a",
                draftProjectName: "Beta",
                catalog: catalog
            ),
            "project-a",
            "a still-advertised choice must not be reset"
        )
        XCTAssertEqual(
            SessionDraftCatalogReconciliation.projectID(
                current: "removed-project",
                draftProjectName: "Beta",
                catalog: catalog
            ),
            "project-b"
        )
        XCTAssertEqual(
            SessionDraftCatalogReconciliation.agentID(
                current: "removed-agent",
                catalog: catalog
            ),
            "codex"
        )
    }
}
