import Network
import ThreadingRemoteKit
import XCTest
@testable import Threading

/// Host-owned startup and process replacement keep a remote chat attached to its stable row.
@MainActor
final class RemoteDormantSessionStartupTests: HostedStoreTestCase {
    private var connectionDelegates: [DormantStartupConnectionDelegate] = []

    /// Share Chat's browser socket must reconnect when the checkout replaces its process.
    /// `ended` permanently disables the shipping browser's reconnect loop.
    func testSharedChatReconnectsAfterCheckoutMoveWithoutEndingOrRepeatingInput() async throws {
        let fixture = try dormantSession()
        let registry = RemoteSessionMirrorRegistry.shared
        installTerminalApplicationOnce()
        let source = try XCTUnwrap(ProjectStore.shared.project(forSessionID: fixture.sessionID))
        let sourceURL = URL(fileURLWithPath: source.folderPath)
        _ = try GitProcess.run(["init", "-b", "main"], in: sourceURL)
        _ = try GitProcess.run([
            "-c", "user.name=Fixture", "-c", "user.email=fixture@example.invalid",
            "commit", "--allow-empty", "-m", "Fixture"
        ], in: sourceURL)
        let destinationURL = sourceURL.appendingPathComponent("sibling")
        _ = try GitProcess.run([
            "worktree", "add", "-b", "shared-work", destinationURL.path
        ], in: sourceURL)
        let destination = try XCTUnwrap(GitInfo.worktreeLocation(for: destinationURL.path))
        let guest = RemoteAuthorization(
            shareID: "checkout-guest", capability: .interact,
            scope: .session(fixture.sessionID), principal: .guest,
            member: RemoteMember(id: "guest", displayName: "Guest", deviceID: "browser")
        )
        let authority = RemoteAuthorityStore()
        authority.set(guest, forToken: "checkout-token")
        let identity = RemoteIdentityTestStore.make(label: "CheckoutRelaunch")
        defer { RemoteIdentityTestStore.erase(identity.directory) }
        let server = RemoteAccessServer(
            services: RemoteAccessCoordinator.makeServerServices(appSettings: .shared),
            identityProvider: identity.store
        )
        server.authorizer = authority
        defer { server.stop() }
        let listening = expectation(description: "checkout fixture listening")
        var port: UInt16?
        server.start(configuration: RemoteListenerConfiguration(
            preferredPort: try XCTUnwrap(FreeLocalPort.quiet())
        )) { outcome in
            port = outcome.port
            listening.fulfill()
        }
        await fulfillment(of: [listening], timeout: 5)
        let link = try XCTUnwrap(RemoteConnectionLink(
            baseURL: URL(string: "http://127.0.0.1:\(try XCTUnwrap(port))")!,
            token: "checkout-token"
        ))
        let socketURL = try XCTUnwrap(link.webSocketURL(sessionID: fixture.sessionID.uuidString))
        let plan = AgentLaunchPlan(
            executable: "/bin/cat", arguments: [], resumeState: .unavailable
        )
        let original = AgentRuntime.shared.makeController(for: fixture.session)
        original.startRemoteTerminalFixture(plan: plan)
        defer { AgentRuntime.shared.discard(sessionID: fixture.sessionID) }
        registry.setInputControlFromOwner(.collaborative, sessionID: fixture.sessionID)

        let browser = try CheckoutSocketProbe(url: socketURL)
        defer { browser.stop() }
        await fulfillment(of: [browser.hello], timeout: 5)
        XCTAssertEqual(registry.submitTerminalLine(
            "", to: fixture.sessionID, device: "browser", authorization: guest,
            requestID: "before-move"
        ), .accepted)

        // Optional real-browser companion. It opens the shipping assets on this same listener
        // and asks for the move only after its guest socket has received hello.
        let browserProof = ProcessInfo.processInfo.environment["THREADING_CHECKOUT_BROWSER_PROOF"]
            .flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0, isDirectory: true) }
        if let browserProof {
            try FileManager.default.createDirectory(at: browserProof, withIntermediateDirectories: true)
            let invitation = "http://127.0.0.1:\(try XCTUnwrap(port))/#checkout-token"
            try Data(invitation.utf8).write(to: browserProof.appendingPathComponent("url"))
            try await waitForBrowserMarker("move", in: browserProof)
        }

        let moved = ProjectStore.shared.moveSessionsToCheckout(
            [fixture.sessionID], checkoutPath: destination.root.path,
            repositoryIdentity: destination.repositoryIdentity,
            worktreeIdentity: destination.worktreeIdentity, branch: "shared-work"
        )
        guard case .moved = moved else { return XCTFail("checkout move failed: \(moved)") }
        // Both foreground and background checkout-move handlers use this runtime boundary.
        AgentRuntime.shared.discardForRelaunch(sessionID: fixture.sessionID)
        await fulfillment(of: [browser.closed], timeout: 5)
        XCTAssertEqual(browser.task.closeCode, .goingAway)
        XCTAssertFalse(browser.types.contains("ended"), "ended disables browser reconnection")
        XCTAssertTrue(authority.isCurrent(guest), "moving a chat must not revoke its membership")

        let reconnect = try CheckoutSocketProbe(url: socketURL)
        defer { reconnect.stop() }
        await fulfillment(of: [reconnect.starting], timeout: 5)
        XCTAssertFalse(reconnect.types.contains("ended"), "a reconnect must wait for replacement")
        XCTAssertEqual(registry.submitTerminalLine(
            "", to: fixture.sessionID, device: "browser", authorization: guest,
            requestID: "before-move"
        ), .accepted, "a lost acknowledgement must replay even while the process is absent")

        let stored = try XCTUnwrap(ProjectStore.shared.session(withID: fixture.sessionID))
        let replacement = AgentRuntime.shared.makeController(for: stored)
        replacement.startRemoteTerminalFixture(plan: plan)
        await fulfillment(of: [reconnect.hello], timeout: 5)
        if let browserProof {
            try await waitForBrowserMarker("reconnected", in: browserProof)
        }
        XCTAssertEqual(registry.meResponse(for: guest).sessions.map(\.id), [fixture.sessionID.uuidString])
        XCTAssertEqual(ProjectStore.shared.project(forSessionID: fixture.sessionID)?.folderPath, destination.root.path)
        AgentRuntime.shared.terminalSurfaceDidEnd(original, sessionID: fixture.sessionID)
        XCTAssertEqual(registry.followers(of: fixture.sessionID).count, browserProof == nil ? 1 : 2,
                       "a late exit from the outgoing process cannot close the replacement")
        XCTAssertEqual(registry.submitTerminalLine(
            "different input", to: fixture.sessionID, device: "browser", authorization: guest,
            requestID: "before-move"
        ), .conflict, "a retry cannot become a second submission in the new checkout")
        XCTAssertEqual(registry.submitTerminalLine(
            "", to: fixture.sessionID, device: "browser", authorization: guest,
            requestID: "after-move"
        ), .accepted, "the guest must still be able to use the replacement process")

        // A real close must still end the browser's session, unlike process replacement.
        AgentRuntime.shared.discard(sessionID: fixture.sessionID)
        await fulfillment(of: [reconnect.closed], timeout: 5)
        XCTAssertTrue(reconnect.types.contains("ended"))
    }

    private func waitForBrowserMarker(_ name: String, in directory: URL) async throws {
        let deadline = ContinuousClock.now + .seconds(60)
        let marker = directory.appendingPathComponent(name)
        while !FileManager.default.fileExists(atPath: marker.path), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: marker.path), "browser missed \(name)")
    }

    func testRelaunchPreservesAnExistingStartupWaiter() throws {
        let fixture = try dormantSession()
        let registry = RemoteSessionMirrorRegistry.shared
        installTerminalApplicationOnce()
        registry.noteSessionStarting(fixture.sessionID)
        let phone = authenticatedConnection()
        var didAttach = false
        XCTAssertEqual(registry.attachOrWaitForStartup(
            phone, to: fixture.sessionID, authorization: Self.ownerInteract,
            authorizationIsCurrent: { true }, didAttach: { didAttach = true }
        ), .waitingForStartup)

        AgentRuntime.shared.discardForRelaunch(sessionID: fixture.sessionID)
        let replacement = AgentRuntime.shared.makeController(for: fixture.session)
        defer { AgentRuntime.shared.discard(sessionID: fixture.sessionID) }
        replacement.startRemoteTerminalFixture(plan: AgentLaunchPlan(
            executable: "/bin/sleep", arguments: ["30"], resumeState: .unavailable
        ))
        XCTAssertTrue(didAttach, "replacement must not cancel a socket already waiting on startup")
        XCTAssertTrue(registry.isAttached(phone, to: fixture.sessionID))
    }

    func testLateNativeExitCannotCancelReplacementStartup() throws {
        let fixture = try dormantSession()
        let project = try XCTUnwrap(ProjectStore.shared.project(forSessionID: fixture.sessionID))
        XCTAssertEqual(ProjectStore.shared.setUsesNativeUI(true, for: fixture.sessionID), .applied)
        let session = try XCTUnwrap(ProjectStore.shared.session(withID: fixture.sessionID))
        let original = try XCTUnwrap(AgentRuntime.shared.makeConversation(for: session, in: project))
        _ = original.view
        AgentRuntime.shared.discardForRelaunch(sessionID: fixture.sessionID)
        let replacement = try XCTUnwrap(AgentRuntime.shared.makeConversation(for: session, in: project))
        _ = replacement.view
        defer { AgentRuntime.shared.discard(sessionID: fixture.sessionID) }

        original.handleExit(0)
        let registry = RemoteSessionMirrorRegistry.shared
        let phone = authenticatedConnection()
        XCTAssertEqual(registry.attachOrWaitForStartup(
            phone, to: fixture.sessionID, authorization: Self.ownerInteract,
            authorizationIsCurrent: { true },
            didAttach: { XCTFail("the replacement has not started its stream") }
        ), .waitingForStartup, "the outgoing stream cannot cancel replacement startup")

        replacement.handleExit(1)
        XCTAssertEqual(registry.attachOrWaitForStartup(
            authenticatedConnection(), to: fixture.sessionID, authorization: Self.ownerInteract,
            authorizationIsCurrent: { true }, didAttach: { XCTFail("the replacement exited") }
        ), .dormant, "the current stream must still end a failed startup")
    }

    func testQueuedTerminalExitCannotDiscardItsReplacement() async throws {
        let fixture = try dormantSession()
        let container = TerminalContainerViewController(recovery: true)
        let original = AgentRuntime.shared.makeController(for: fixture.session)
        container.agentSession(original, didExitWithCode: 0)
        AgentRuntime.shared.discardForRelaunch(sessionID: fixture.sessionID)
        let replacement = AgentRuntime.shared.makeController(for: fixture.session)
        defer { AgentRuntime.shared.discard(sessionID: fixture.sessionID) }

        let outgoingExitDrained = expectation(description: "outgoing exit callback drained")
        DispatchQueue.main.async { outgoingExitDrained.fulfill() }
        await fulfillment(of: [outgoingExitDrained], timeout: 2)
        XCTAssertTrue(AgentRuntime.shared.terminalRuntimeSurface(for: fixture.sessionID) === replacement)

        container.agentSession(replacement, didExitWithCode: 0)
        let currentExitDrained = expectation(description: "current exit callback drained")
        DispatchQueue.main.async { currentExitDrained.fulfill() }
        await fulfillment(of: [currentExitDrained], timeout: 2)
        XCTAssertNil(AgentRuntime.shared.terminalRuntimeSurface(for: fixture.sessionID),
                     "the current process's exit must still discard its runtime")
    }

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
        XCTAssertEqual(asleep.refusal?.reason, "sessionDormant")

        ProjectStore.shared.setArchived(true, for: fixture.sessionID)
        let gone = registry.attachOrWaitForStartup(
            phone,
            to: fixture.sessionID,
            authorization: Self.ownerInteract,
            authorizationIsCurrent: { true },
            didAttach: { XCTFail("an archived chat has no live surface to attach to") }
        )
        XCTAssertEqual(gone, .unavailable)
        XCTAssertEqual(gone.refusal?.reason, "sessionClosed")
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
            waiting.refusal,
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

/// Reads the actual browser wire through the real server, with all state confined to main.
@MainActor
private final class CheckoutSocketProbe {
    let task: URLSessionWebSocketTask
    let hello = XCTestExpectation(description: "browser receives hello")
    let starting = XCTestExpectation(description: "browser waits for replacement")
    let closed = XCTestExpectation(description: "browser socket closes")
    private(set) var types: [String] = []
    private var reader: Task<Void, Never>?

    init(url: URL) throws {
        task = URLSession.shared.webSocketTask(with: url)
        let auth = RemoteClientMessage(
            type: "auth", token: "checkout-token", device: "browser",
            protocolVersion: RemoteProtocol.current,
            protocolMinimum: RemoteProtocol.minimumSupported
        )
        let text = String(decoding: try JSONEncoder().encode(auth), as: UTF8.self)
        task.resume()
        reader = Task { [weak self, task] in
            do {
                try await task.send(.string(text))
                while !Task.isCancelled {
                    let message = try await task.receive()
                    guard let self, case .string(let text) = message,
                          let object = try JSONSerialization.jsonObject(with: Data(text.utf8))
                            as? [String: Any],
                          let type = object["type"] as? String else { continue }
                    let first = !types.contains(type)
                    types.append(type)
                    if first && type == "hello" { hello.fulfill() }
                    if first && type == "sessionStarting" { starting.fulfill() }
                }
            } catch {
                self?.closed.fulfill()
            }
        }
    }

    func stop() {
        reader?.cancel()
        task.cancel(with: .normalClosure, reason: nil)
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
