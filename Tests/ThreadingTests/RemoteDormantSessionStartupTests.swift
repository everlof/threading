import Network
import ThreadingRemoteKit
import XCTest
@testable import Threading

/// The host-owned handoff from a dormant row to its first live terminal mirror.
@MainActor
final class RemoteDormantSessionStartupTests: HostedStoreTestCase {
    private var connectionDelegates: [DormantStartupConnectionDelegate] = []

    func testWaitingSocketAttachesWhenDormantTerminalProcessStarts() throws {
        let previousRemoteAccess = AppSettings.shared.remoteAccessEnabled
        AppSettings.shared.remoteAccessEnabled = true
        defer { AppSettings.shared.remoteAccessEnabled = previousRemoteAccess }

        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(
            "threading-dormant-startup-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: temporary,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: temporary) }

        let project = try XCTUnwrap(ProjectStore.shared.addProject(folderURL: temporary))
        let storedSession = try XCTUnwrap(ProjectStore.shared.addSession(
            to: project.id,
            kind: .claude,
            usesNativeUI: false
        ))
        let registry = RemoteSessionMirrorRegistry.shared
        installTerminalApplicationOnce()
        registry.noteSessionStarting(storedSession.id)

        let phone = authenticatedConnection()
        var didAttach = false
        let initial = registry.attachOrWaitForStartup(
            phone,
            to: storedSession.id,
            authorization: Self.ownerInteract,
            authorizationIsCurrent: { true },
            didAttach: { didAttach = true }
        )
        guard case .waitingForStartup = initial else {
            return XCTFail("the dormant startup should hold its already-open socket")
        }
        XCTAssertFalse(didAttach)

        let controller = AgentRuntime.shared.makeController(for: storedSession)
        defer { AgentRuntime.shared.discard(sessionID: storedSession.id) }
        controller.startRemoteTerminalFixture(plan: AgentLaunchPlan(
            executable: "/bin/sleep",
            arguments: ["30"],
            resumeState: .unavailable
        ))

        XCTAssertTrue(controller.isRunning)
        XCTAssertTrue(
            didAttach,
            "the process-start edge must create the mirror and complete the waiting socket"
        )
        XCTAssertTrue(registry.isAttached(phone, to: storedSession.id))
    }

    /// A parked socket being pushed back into a chat whose agent has stopped.
    ///
    /// From the shake report of 12 Sep 2026: the phone said "this chat closed on the Mac", and the
    /// same chat opened normally eight seconds later. The chat had not closed. The host answered a
    /// warm `sessionResume` through a bare attach, which fails identically for a chat that is gone
    /// and for one that is merely asleep, and had one word — `sessionClosed` — for both. Dormant
    /// and gone are different facts, and only one of them is worth telling a person about.
    func testAWarmResumeSeparatesAChatThatIsAsleepFromOneThatIsGone() throws {
        let fixture = try dormantSession()
        let registry = RemoteSessionMirrorRegistry.shared
        installTerminalApplicationOnce()

        let controller = AgentRuntime.shared.makeController(for: fixture.session)
        controller.startRemoteTerminalFixture(plan: AgentLaunchPlan(
            executable: "/bin/sleep",
            arguments: ["30"],
            resumeState: .unavailable
        ))
        let phone = authenticatedConnection()
        XCTAssertTrue(registry.attach(
            phone,
            to: fixture.sessionID,
            authorization: Self.ownerInteract
        ))

        // The phone leaves the chat. Parking runs the whole detach path, so this socket is no
        // longer a subscriber and hears nothing the mirror broadcasts afterwards.
        XCTAssertTrue(registry.park(phone, sessionID: fixture.sessionID))
        XCTAssertFalse(registry.isAttached(phone, to: fixture.sessionID))

        // The agent stops while the transport is held — it exited, was stopped, or was handed to
        // `threading-ptyd`. The row, its transcript and its resume route are all still there.
        AgentRuntime.shared.discard(sessionID: fixture.sessionID)
        XCTAssertFalse(AgentRuntime.shared.isRunning(sessionID: fixture.sessionID))

        let asleep = registry.attachOrWaitForStartup(
            phone,
            to: fixture.sessionID,
            authorization: Self.ownerInteract,
            authorizationIsCurrent: { true },
            didAttach: { XCTFail("a dormant chat has no live surface to attach to") }
        )
        XCTAssertEqual(asleep, .dormant)
        XCTAssertEqual(asleep.parkedResumeRefusal?.reason, "sessionDormant")

        ProjectStore.shared.setArchived(true, for: fixture.sessionID)
        let gone = registry.attachOrWaitForStartup(
            phone,
            to: fixture.sessionID,
            authorization: Self.ownerInteract,
            authorizationIsCurrent: { true },
            didAttach: { XCTFail("an archived chat has no live surface to attach to") }
        )
        XCTAssertEqual(gone, .unavailable)
        XCTAssertEqual(gone.parkedResumeRefusal?.reason, "sessionClosed")
    }

    /// The other half of the same report: a warm transport must be a saved handshake, never a
    /// second and weaker way to reach a session. A socket that rejoins while the Mac is starting
    /// the chat again waits for that startup exactly as a cold socket does, instead of being
    /// refused a second before the process it was waiting for exists.
    func testAWarmResumeArrivingDuringAWakeWaitsForItRatherThanBeingRefused() throws {
        let fixture = try dormantSession()
        let registry = RemoteSessionMirrorRegistry.shared
        installTerminalApplicationOnce()
        registry.noteSessionStarting(fixture.sessionID)

        let phone = authenticatedConnection()
        var didAttach = false
        let waiting = registry.attachOrWaitForStartup(
            phone,
            to: fixture.sessionID,
            authorization: Self.ownerInteract,
            authorizationIsCurrent: { true },
            didAttach: { didAttach = true }
        )
        XCTAssertEqual(waiting, .waitingForStartup)
        XCTAssertNil(
            waiting.parkedResumeRefusal,
            "a socket the host is holding has not been refused and must be told nothing"
        )

        let controller = AgentRuntime.shared.makeController(for: fixture.session)
        defer { AgentRuntime.shared.discard(sessionID: fixture.sessionID) }
        controller.startRemoteTerminalFixture(plan: AgentLaunchPlan(
            executable: "/bin/sleep",
            arguments: ["30"],
            resumeState: .unavailable
        ))

        XCTAssertTrue(didAttach, "the wake must complete the socket it was holding")
        XCTAssertTrue(registry.isAttached(phone, to: fixture.sessionID))
    }

    /// One dormant chat: a stored row with no running agent, in a temporary project folder.
    private func dormantSession() throws -> (session: AgentSession, sessionID: SessionID) {
        let previousRemoteAccess = AppSettings.shared.remoteAccessEnabled
        AppSettings.shared.remoteAccessEnabled = true
        addTeardownBlock { @MainActor in
            AppSettings.shared.remoteAccessEnabled = previousRemoteAccess
        }

        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(
            "threading-dormant-resume-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: temporary) }

        let project = try XCTUnwrap(ProjectStore.shared.addProject(folderURL: temporary))
        let session = try XCTUnwrap(ProjectStore.shared.addSession(
            to: project.id,
            kind: .claude,
            usesNativeUI: false
        ))
        XCTAssertFalse(AgentRuntime.shared.isRunning(sessionID: session.id))
        return (session, session.id)
    }

    /// The registry is a singleton whose terminal capability installs exactly once, and these
    /// tests share one hosted process. The second class member to ask must therefore reuse what
    /// the first installed rather than trip the precondition.
    private static var didInstallTerminalApplication = false

    private func installTerminalApplicationOnce() {
        guard !Self.didInstallTerminalApplication else { return }
        Self.didInstallTerminalApplication = true
        RemoteSessionMirrorRegistry.shared.installTerminalApplication(
            LiveRemoteTerminalApplicationCapability(surfaces: AgentRuntime.shared)
        )
    }

    private static let ownerInteract = RemoteAuthorization(
        shareID: "dormant-startup-owner",
        capability: .interact,
        scope: .allSessions
    )

    private func authenticatedConnection() -> RemoteConnection {
        let delegate = DormantStartupConnectionDelegate()
        connectionDelegates.append(delegate)
        let connection = RemoteConnection(
            connection: NWConnection(host: "127.0.0.1", port: 9, using: .tcp),
            queue: DispatchQueue(label: "remote-dormant-startup-test"),
            delegate: delegate
        )
        XCTAssertTrue(connection.authenticate(
            authorization: Self.ownerInteract,
            deviceID: "dormant-startup-phone",
            deviceName: nil,
            terminalReplayBudget: nil
        ))
        // The registry is process-wide state. A fixture socket left subscribed would follow this
        // test into the next one in the same hosted run.
        addTeardownBlock { @MainActor [connection] in
            RemoteSessionMirrorRegistry.shared.detach(connection)
        }
        return connection
    }
}

/// The socket never upgrades, so the registry can exercise attachment without network traffic.
private final class DormantStartupConnectionDelegate: RemoteConnection.Delegate,
    @unchecked Sendable {
    func route(
        _ request: HTTPRequest,
        from connection: RemoteConnection,
        respond: @escaping @Sendable (RemoteRouteDecision) -> Void
    ) {}

    func handleMessage(
        _ message: RemoteWebSocket.Message,
        from connection: RemoteConnection
    ) {}

    func didClose(_ connection: RemoteConnection) {}
}
