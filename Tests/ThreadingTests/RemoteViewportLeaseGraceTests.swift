import Network
import ThreadingRemoteKit
import XCTest
@testable import Threading

/// The grace period on a released viewport lease.
///
/// A lease change is a real `SIGWINCH` and a full TUI repaint, and backgrounding the iOS app
/// drops the socket without saying whether it will return — so a glance at a notification and a
/// return used to reflow a working agent twice. A deliberate Back, park, or `viewportRelease` is
/// different: the renderer has said it is gone, and the Mac grid must return immediately. Every
/// assertion here is on the **applied grid**, the calls the host actually made on the terminal,
/// rather than on how many requests the registry was holding: a lease that is counted but never
/// reaches the PTY costs nothing, and a lease that is dropped and re-applied at the same size
/// costs a repaint the request count cannot see.
@MainActor
final class RemoteViewportLeaseGraceTests: HostedStoreTestCase {

    /// The connection under test only ever holds an identity and a device id here: it never
    /// completes a WebSocket upgrade, so `RemoteConnection.enqueue` drops every frame and no
    /// byte reaches the unstarted `NWConnection`.
    private var connectionDelegates: [SilentConnectionDelegate] = []

    // MARK: - Session startup handoff

    func testACreatedSessionSocketWaitsForItsHostOwnedSurfaceAndThenAttaches() throws {
        let fixture = try makeFixture(grace: .zero)
        fixture.capability.setAvailable(false, for: .agentSession(fixture.sessionID))
        fixture.registry.noteSessionStarting(fixture.sessionID)

        let phone = authenticated(deviceID: "startup-phone", authorization: Self.ownerInteract)
        var didAttach = false
        let result = fixture.registry.attachOrWaitForStartup(
            phone,
            to: fixture.sessionID,
            authorization: Self.ownerInteract,
            authorizationIsCurrent: { true },
            didAttach: { didAttach = true }
        )
        guard case .waitingForStartup = result else {
            return XCTFail("a host-owned creation should hold its socket until the surface exists")
        }
        XCTAssertFalse(didAttach)
        XCTAssertFalse(fixture.registry.isAttached(phone, to: fixture.sessionID))

        fixture.capability.setAvailable(true, for: .agentSession(fixture.sessionID))
        XCTAssertNotNil(fixture.registry.beginCapturing(sessionID: fixture.sessionID))
        XCTAssertTrue(didAttach)
        XCTAssertTrue(fixture.registry.isAttached(phone, to: fixture.sessionID))
    }

    func testADormantSessionCannotInventAStartupWaitByOpeningASocket() throws {
        let fixture = try makeFixture(grace: .zero)
        fixture.capability.setAvailable(false, for: .agentSession(fixture.sessionID))
        let phone = authenticated(deviceID: "dormant-phone", authorization: Self.ownerInteract)

        let result = fixture.registry.attachOrWaitForStartup(
            phone,
            to: fixture.sessionID,
            authorization: Self.ownerInteract,
            authorizationIsCurrent: { true },
            didAttach: { XCTFail("a dormant session has no host-owned startup transaction") }
        )
        guard case .unavailable = result else {
            return XCTFail("the client must not create an unbounded wait for a dormant session")
        }
        XCTAssertFalse(fixture.registry.isAttached(phone, to: fixture.sessionID))
    }

    func testASessionStartupWaitExpiresInsteadOfBecomingAHiddenPoll() async throws {
        let fixture = try makeFixture(grace: .zero, startupWait: .milliseconds(10))
        fixture.capability.setAvailable(false, for: .agentSession(fixture.sessionID))
        fixture.registry.noteSessionStarting(fixture.sessionID)

        let phone = authenticated(deviceID: "timeout-phone", authorization: Self.ownerInteract)
        var didAttach = false
        let result = fixture.registry.attachOrWaitForStartup(
            phone,
            to: fixture.sessionID,
            authorization: Self.ownerInteract,
            authorizationIsCurrent: { true },
            didAttach: { didAttach = true }
        )
        guard case .waitingForStartup = result else {
            return XCTFail("the socket should enter the host's bounded startup transaction")
        }

        try await Task.sleep(for: .milliseconds(40))
        fixture.capability.setAvailable(true, for: .agentSession(fixture.sessionID))
        XCTAssertNotNil(fixture.registry.beginCapturing(sessionID: fixture.sessionID))
        XCTAssertFalse(didAttach, "a timed-out socket must not attach to a later surface")
        XCTAssertFalse(fixture.registry.isAttached(phone, to: fixture.sessionID))
    }

    // MARK: - The rule

    /// The case the grace exists for: the phone that went away and came straight back.
    func testTheSameDeviceReturningInsideTheWindowAppliesNoViewportChange() throws {
        let fixture = try makeFixture(grace: .seconds(30))
        try attachedWatcher(to: fixture)

        let phone = authenticated(deviceID: "phone-a", authorization: Self.ownerInteract)
        XCTAssertTrue(fixture.registry.attach(
            phone,
            to: fixture.sessionID,
            authorization: Self.ownerInteract
        ))
        fixture.registry.requestViewport(
            from: phone,
            sessionID: fixture.sessionID,
            cols: 60,
            rows: 20
        )
        XCTAssertEqual(fixture.capability.viewportCalls, [
            .init(identity: .agentSession(fixture.sessionID), grid: .init(cols: 60, rows: 20)),
        ])

        fixture.registry.detach(phone)
        XCTAssertEqual(
            fixture.capability.viewportCalls.count,
            1,
            "releasing a lease inside its grace must not reflow the program"
        )

        // A reconnecting phone is a different `RemoteConnection` object. It is the same device.
        let returning = authenticated(deviceID: "phone-a", authorization: Self.ownerInteract)
        XCTAssertTrue(fixture.registry.attach(
            returning,
            to: fixture.sessionID,
            authorization: Self.ownerInteract
        ))
        fixture.registry.requestViewport(
            from: returning,
            sessionID: fixture.sessionID,
            cols: 60,
            rows: 20
        )

        XCTAssertEqual(
            fixture.capability.viewportCalls.count,
            1,
            "a round trip inside the window cost a resize, which is the whole defect"
        )
        XCTAssertEqual(
            fixture.capability.appliedViewport(for: .agentSession(fixture.sessionID)),
            RemoteTerminalGrid(cols: 60, rows: 20)
        )
    }

    /// Nobody came back, so the promise the banner makes has to be kept.
    func testAnUnclaimedLeaseExpiresAndGivesTheMacItsOwnGridBack() async throws {
        let grace = Duration.milliseconds(40)
        let fixture = try makeFixture(grace: grace)
        try attachedWatcher(to: fixture)

        let phone = authenticated(deviceID: "phone-b", authorization: Self.ownerInteract)
        XCTAssertTrue(fixture.registry.attach(
            phone,
            to: fixture.sessionID,
            authorization: Self.ownerInteract
        ))
        fixture.registry.requestViewport(
            from: phone,
            sessionID: fixture.sessionID,
            cols: 72,
            rows: 24
        )
        fixture.registry.detach(phone)
        XCTAssertEqual(fixture.capability.viewportCalls.count, 1)

        await wait(until: { fixture.capability.viewportCalls.count > 1 })
        XCTAssertEqual(
            fixture.capability.viewportCalls.last,
            .init(identity: .agentSession(fixture.sessionID), grid: nil),
            "an expired lease restores the Mac's own frame, exactly as an immediate release did"
        )
        XCTAssertNil(fixture.capability.appliedViewport(for: .agentSession(fixture.sessionID)))
    }

    /// The device key, stated as the thing it changes: the pending lease is claimed by its own
    /// device and stops constraining the intersection at that moment. Keyed by connection this
    /// would be impossible — the returning object is not the one that released.
    func testAReconnectingPhoneClaimsItsOwnPendingLeaseRatherThanWaitingForIt() throws {
        let fixture = try makeFixture(grace: .seconds(30))
        try attachedWatcher(to: fixture)

        let phone = authenticated(deviceID: "phone-c", authorization: Self.ownerInteract)
        XCTAssertTrue(fixture.registry.attach(
            phone,
            to: fixture.sessionID,
            authorization: Self.ownerInteract
        ))
        fixture.registry.requestViewport(
            from: phone,
            sessionID: fixture.sessionID,
            cols: 50,
            rows: 20
        )
        fixture.registry.detach(phone)

        // A second, wider device joins while the first one's lease is still held. The
        // intersection is the held grid, which is what proves it is still counted.
        let tablet = authenticated(deviceID: "tablet-c", authorization: Self.ownerInteract)
        XCTAssertTrue(fixture.registry.attach(
            tablet,
            to: fixture.sessionID,
            authorization: Self.ownerInteract
        ))
        fixture.registry.requestViewport(
            from: tablet,
            sessionID: fixture.sessionID,
            cols: 90,
            rows: 30
        )
        XCTAssertEqual(
            fixture.capability.appliedViewport(for: .agentSession(fixture.sessionID)),
            RemoteTerminalGrid(cols: 50, rows: 20),
            "a held lease still settles the shared PTY, or the grace would not remove a resize"
        )

        // The first device returns on a new connection object and asks for the wider grid. Its
        // own pending lease is claimed, so the narrow grid stops applying now rather than in
        // thirty seconds.
        let returning = authenticated(deviceID: "phone-c", authorization: Self.ownerInteract)
        XCTAssertTrue(fixture.registry.attach(
            returning,
            to: fixture.sessionID,
            authorization: Self.ownerInteract
        ))
        fixture.registry.requestViewport(
            from: returning,
            sessionID: fixture.sessionID,
            cols: 90,
            rows: 30
        )
        XCTAssertEqual(
            fixture.capability.appliedViewport(for: .agentSession(fixture.sessionID)),
            RemoteTerminalGrid(cols: 90, rows: 30),
            "the returning device did not match its own pending lease"
        )
    }

    /// Nothing can be held for a client that cannot be recognised when it comes back, so that
    /// release stays exactly as it was.
    func testAConnectionWithNoDeviceIdentityReleasesImmediately() throws {
        let fixture = try makeFixture(grace: .seconds(30))
        try attachedWatcher(to: fixture)

        let anonymous = authenticated(deviceID: nil, authorization: Self.ownerInteract)
        XCTAssertTrue(fixture.registry.attach(
            anonymous,
            to: fixture.sessionID,
            authorization: Self.ownerInteract
        ))
        fixture.registry.requestViewport(
            from: anonymous,
            sessionID: fixture.sessionID,
            cols: 64,
            rows: 22
        )
        fixture.registry.detach(anonymous)

        XCTAssertEqual(fixture.capability.viewportCalls, [
            .init(identity: .agentSession(fixture.sessionID), grid: .init(cols: 64, rows: 22)),
            .init(identity: .agentSession(fixture.sessionID), grid: nil),
        ])
    }

    /// Leaving the terminal view is an explicit renderer decision, not a transport failure.
    /// Applying reconnect grace here is what left the desktop at phone size after Back.
    func testExplicitReleaseRestoresTheMacGridWithoutReconnectGrace() throws {
        let fixture = try makeFixture(grace: .seconds(30))
        try attachedWatcher(to: fixture)

        let phone = authenticated(deviceID: "phone-release", authorization: Self.ownerInteract)
        XCTAssertTrue(fixture.registry.attach(
            phone,
            to: fixture.sessionID,
            authorization: Self.ownerInteract
        ))
        fixture.registry.requestViewport(
            from: phone,
            sessionID: fixture.sessionID,
            cols: 62,
            rows: 21
        )

        fixture.registry.releaseViewport(from: phone, sessionID: fixture.sessionID)

        XCTAssertEqual(fixture.capability.viewportCalls, [
            .init(identity: .agentSession(fixture.sessionID), grid: .init(cols: 62, rows: 21)),
            .init(identity: .agentSession(fixture.sessionID), grid: nil),
        ])
    }

    /// A warm parked socket deliberately leaves host fan-out. It must keep the transport, not
    /// the renderer's geometry.
    func testParkingAChatRestoresTheMacGridWithoutReconnectGrace() throws {
        let fixture = try makeFixture(grace: .seconds(30))
        try attachedWatcher(to: fixture)

        let phone = authenticated(deviceID: "phone-park", authorization: Self.ownerInteract)
        XCTAssertTrue(fixture.registry.attach(
            phone,
            to: fixture.sessionID,
            authorization: Self.ownerInteract
        ))
        fixture.registry.requestViewport(
            from: phone,
            sessionID: fixture.sessionID,
            cols: 58,
            rows: 19
        )

        XCTAssertTrue(fixture.registry.park(phone, sessionID: fixture.sessionID))

        XCTAssertFalse(fixture.registry.isAttached(phone, to: fixture.sessionID))
        XCTAssertEqual(fixture.capability.viewportCalls, [
            .init(identity: .agentSession(fixture.sessionID), grid: .init(cols: 58, rows: 19)),
            .init(identity: .agentSession(fixture.sessionID), grid: nil),
        ])
    }

    /// The release frame and socket close are dispatched independently. If close wins, it has
    /// already converted the active request into a held lease; the explicit release must still
    /// find that device-keyed hold and return the desktop grid.
    func testExplicitReleaseDropsAHeldLeaseCreatedByEarlierSocketTeardown() throws {
        let fixture = try makeFixture(grace: .seconds(30))
        try attachedWatcher(to: fixture)

        let phone = authenticated(deviceID: "phone-release-race", authorization: Self.ownerInteract)
        XCTAssertTrue(fixture.registry.attach(
            phone,
            to: fixture.sessionID,
            authorization: Self.ownerInteract
        ))
        fixture.registry.requestViewport(
            from: phone,
            sessionID: fixture.sessionID,
            cols: 54,
            rows: 18
        )
        fixture.registry.detach(phone)
        XCTAssertEqual(fixture.capability.viewportCalls.count, 1)

        fixture.registry.releaseViewport(from: phone, sessionID: fixture.sessionID)

        XCTAssertEqual(fixture.capability.viewportCalls.last, .init(
            identity: .agentSession(fixture.sessionID),
            grid: nil
        ))
    }

    // MARK: - What a held lease is not

    /// Discard and archival are authorization changes. The timer is not a place where one of
    /// those outlives its check, and a grid nobody is holding is not an audience.
    func testDiscardingASessionDropsAHeldLeaseAndNeverShowsItAsAFollower() async throws {
        let grace = Duration.milliseconds(40)
        let fixture = try makeFixture(grace: grace)
        let watcher = try attachedWatcher(to: fixture)

        let phone = authenticated(deviceID: "phone-d", authorization: Self.ownerInteract)
        XCTAssertTrue(fixture.registry.attach(
            phone,
            to: fixture.sessionID,
            authorization: Self.ownerInteract
        ))
        fixture.registry.requestViewport(
            from: phone,
            sessionID: fixture.sessionID,
            cols: 58,
            rows: 18
        )
        fixture.registry.detach(phone)

        let followers = fixture.registry.followers(of: fixture.sessionID)
        XCTAssertEqual(followers.count, 1, "only the still-attached watcher is an audience")
        let follower = try XCTUnwrap(followers.first)
        XCTAssertEqual(follower.id, ObjectIdentifier(watcher))
        XCTAssertNil(
            follower.viewport?.cols,
            "a held grid belongs to a device that has gone and must not be reported as watching"
        )

        fixture.registry.sessionDiscarded(fixture.sessionID)
        XCTAssertNil(fixture.capability.appliedViewport(for: .agentSession(fixture.sessionID)))

        // And the expiry it would have fired is gone with it, rather than reaching a mirror that
        // no longer exists.
        let callsAtDiscard = fixture.capability.viewportCalls.count
        try? await Task.sleep(for: grace * 6)
        XCTAssertEqual(
            fixture.capability.viewportCalls.count,
            callsAtDiscard,
            "a dropped lease must not still be holding a timer"
        )
    }

    /// The held authorization narrows and never grants: the moment this device would no longer
    /// be allowed to write, the grid it was holding stops applying.
    func testLosingWritePermissionDropsAHeldLeaseImmediately() throws {
        let fixture = try makeFixture(grace: .seconds(30))
        try attachedWatcher(to: fixture)

        let guest = RemoteAuthorization(
            shareID: "guest-share",
            capability: .interact,
            scope: .session(fixture.sessionID),
            principal: .guest
        )
        let phone = authenticated(deviceID: "phone-e", authorization: guest)
        XCTAssertTrue(fixture.registry.attach(
            phone,
            to: fixture.sessionID,
            authorization: guest
        ))
        fixture.registry.requestViewport(
            from: phone,
            sessionID: fixture.sessionID,
            cols: 56,
            rows: 20
        )
        fixture.registry.detach(phone)
        XCTAssertEqual(
            fixture.capability.appliedViewport(for: .agentSession(fixture.sessionID)),
            RemoteTerminalGrid(cols: 56, rows: 20)
        )

        // Focused mode on the Mac owner: the guest that left can no longer write, so it can no
        // longer hold the shared PTY's size either — and not thirty seconds from now.
        XCTAssertEqual(
            fixture.registry.setInputControlFromOwner(.focused, sessionID: fixture.sessionID),
            .applied
        )
        XCTAssertNil(
            fixture.capability.appliedViewport(for: .agentSession(fixture.sessionID)),
            "a lease that would no longer be allowed to write must end at the check, not at expiry"
        )
    }

    // MARK: - Standalone project terminals

    /// A shell drawer's own remote lease answers the same rule through the same implementation.
    func testAProjectTerminalLeaseIsHeldAndReclaimedByTheSameDevice() throws {
        let fixture = try makeFixture(grace: .seconds(30))
        let watcher = authenticated(deviceID: "watcher-t", authorization: Self.ownerView)
        XCTAssertTrue(fixture.registry.attach(
            watcher,
            to: fixture.terminalID,
            authorization: Self.ownerView
        ))

        let phone = authenticated(deviceID: "phone-t", authorization: Self.ownerInteract)
        XCTAssertTrue(fixture.registry.attach(
            phone,
            to: fixture.terminalID,
            authorization: Self.ownerInteract
        ))
        fixture.registry.requestViewport(
            from: phone,
            terminalID: fixture.terminalID,
            cols: 66,
            rows: 21
        )
        XCTAssertEqual(fixture.capability.viewportCalls, [
            .init(identity: .projectTerminal(fixture.terminalID), grid: .init(cols: 66, rows: 21)),
        ])

        fixture.registry.detach(phone)
        let returning = authenticated(deviceID: "phone-t", authorization: Self.ownerInteract)
        XCTAssertTrue(fixture.registry.attach(
            returning,
            to: fixture.terminalID,
            authorization: Self.ownerInteract
        ))
        fixture.registry.requestViewport(
            from: returning,
            terminalID: fixture.terminalID,
            cols: 66,
            rows: 21
        )

        XCTAssertEqual(
            fixture.capability.viewportCalls.count,
            1,
            "a standalone terminal round trip cost a resize the session mirror does not"
        )
        XCTAssertEqual(
            fixture.capability.appliedViewport(for: .projectTerminal(fixture.terminalID)),
            RemoteTerminalGrid(cols: 66, rows: 21)
        )
    }

    // MARK: - The window itself

    func testTheWindowDefaultsToTwoMinutesAndClampsRatherThanRefuses() throws {
        let suiteName = "RemoteViewportLeaseGraceTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.register(defaults: AppSettingDefinitions.registeredDefaults)
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let settings = AppSettings(defaults: defaults)

        XCTAssertEqual(RemoteAccessDefaults.viewportLeaseGraceSeconds, 120)
        XCTAssertEqual(settings.remoteViewportLeaseGraceSeconds, 120)

        // A number is what somebody meant by it, so the nearest allowed delay is the answer
        // rather than a refusal that leaves the old value silently in place.
        defaults.set(10_000, forKey: "remoteViewportLeaseGraceSeconds")
        XCTAssertEqual(
            settings.remoteViewportLeaseGraceSeconds,
            RemoteAccessDefaults.maximumViewportLeaseGraceSeconds
        )
        defaults.set(-30, forKey: "remoteViewportLeaseGraceSeconds")
        XCTAssertEqual(
            settings.remoteViewportLeaseGraceSeconds,
            RemoteAccessDefaults.minimumViewportLeaseGraceSeconds
        )

        // Zero is a value and not an absence: the shared `.range` helper folds it back to the
        // default, which would leave the kill switch unreachable through the key.
        settings.remoteViewportLeaseGraceSeconds = 0
        XCTAssertEqual(settings.remoteViewportLeaseGraceSeconds, 0)
        XCTAssertEqual(defaults.object(forKey: "remoteViewportLeaseGraceSeconds") as? Int, 0)
    }

    /// The kill switch, asserted where it matters: at zero, a release is the release this
    /// registry made before the grace existed.
    func testAZeroWindowReleasesTheLeaseImmediately() throws {
        let fixture = try makeFixture(grace: .zero)
        try attachedWatcher(to: fixture)

        let phone = authenticated(deviceID: "phone-z", authorization: Self.ownerInteract)
        XCTAssertTrue(fixture.registry.attach(
            phone,
            to: fixture.sessionID,
            authorization: Self.ownerInteract
        ))
        fixture.registry.requestViewport(
            from: phone,
            sessionID: fixture.sessionID,
            cols: 44,
            rows: 16
        )
        fixture.registry.detach(phone)

        XCTAssertEqual(fixture.capability.viewportCalls, [
            .init(identity: .agentSession(fixture.sessionID), grid: .init(cols: 44, rows: 16)),
            .init(identity: .agentSession(fixture.sessionID), grid: nil),
        ])
    }

    // MARK: - Fixture

    private struct Fixture {
        let capability: LeaseCapability
        let registry: RemoteSessionMirrorRegistry
        let sessionID: SessionID
        let terminalID: TerminalID
    }

    private static let ownerInteract = RemoteAuthorization(
        shareID: "owner-device",
        capability: .interact,
        scope: .allSessions
    )

    private static let ownerView = RemoteAuthorization(
        shareID: "owner-device-view",
        capability: .view,
        scope: .allSessions
    )

    private func makeFixture(
        grace: Duration,
        startupWait: Duration = .seconds(60)
    ) throws -> Fixture {
        let store = ProjectStore.shared
        // A folder of its own: `addProject` returns the existing project for a folder it already
        // knows, so a shared temporary directory would hand this test a sibling's project.
        let project = try XCTUnwrap(store.addProject(
            folderURL: URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("threading-viewport-lease-\(UUID().uuidString)")
        ))
        let session = try XCTUnwrap(store.addSession(to: project.id, kind: .claude))
        let terminal = try XCTUnwrap(store.addTerminal(to: project.id))
        let capability = LeaseCapability(sessionID: session.id, terminalID: terminal.id)
        let registry = RemoteSessionMirrorRegistry(
            terminalApplication: capability,
            sessionStartupMaximumWait: startupWait,
            viewportLeaseGrace: { grace }
        )
        // Which mode a shared chat starts in is an ordinary user setting, and in Focused mode a
        // guest may not hold a lease at all. Pin it so this suite asserts against its own state
        // rather than against the developer's choice.
        registry.setInputControlFromOwner(.collaborative, sessionID: session.id)
        return Fixture(
            capability: capability,
            registry: registry,
            sessionID: session.id,
            terminalID: terminal.id
        )
    }

    /// A second, view-only socket that stays for the whole test.
    ///
    /// It is not decoration: `detach` tears the mirror down when its last subscriber leaves and
    /// Remote Access is off, and this suite must not switch the developer's own Remote Access on
    /// to keep a mirror alive. A watcher is also the honest shape of the case — somebody else is
    /// still looking while the phone steps away.
    @discardableResult
    private func attachedWatcher(to fixture: Fixture) throws -> RemoteConnection {
        let watcher = authenticated(deviceID: "watcher", authorization: Self.ownerView)
        XCTAssertTrue(fixture.registry.attach(
            watcher,
            to: fixture.sessionID,
            authorization: Self.ownerView
        ))
        return watcher
    }

    private func authenticated(
        deviceID: String?,
        authorization: RemoteAuthorization
    ) -> RemoteConnection {
        let delegate = SilentConnectionDelegate()
        connectionDelegates.append(delegate)
        let connection = RemoteConnection(
            connection: NWConnection(host: "127.0.0.1", port: 9, using: .tcp),
            queue: DispatchQueue(label: "remote-viewport-lease-test"),
            delegate: delegate
        )
        XCTAssertTrue(connection.authenticate(
            authorization: authorization,
            deviceID: deviceID,
            deviceName: nil,
            terminalReplayBudget: nil
        ))
        return connection
    }

    private func wait(
        until condition: @MainActor () -> Bool,
        timeout: Duration = .seconds(3),
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if condition() { return }
            try? await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertTrue(
            condition(),
            "timed out waiting for the lease to expire",
            file: file,
            line: line
        )
    }
}

// MARK: - Doubles

/// A terminal capability that answers like the real one: what it reports as its applied
/// viewport is what was last set on it, so `applyViewport`'s "is this already the grid?"
/// guard behaves as it does in the app and a recorded call is a real resize.
@MainActor
private final class LeaseCapability: RemoteTerminalApplicationCapability {
    struct ViewportCall: Equatable {
        let identity: TerminalInstanceIdentity
        let grid: RemoteTerminalGrid?
    }

    private(set) var viewportCalls: [ViewportCall] = []
    private var appliedViewports: [TerminalInstanceIdentity: RemoteTerminalGrid] = [:]
    private var unavailableIdentities: Set<TerminalInstanceIdentity> = []
    let identities: Set<TerminalInstanceIdentity>

    init(sessionID: SessionID, terminalID: TerminalID) {
        identities = [.agentSession(sessionID), .projectTerminal(terminalID)]
    }

    func appliedViewport(for identity: TerminalInstanceIdentity) -> RemoteTerminalGrid? {
        appliedViewports[identity]
    }

    func setAvailable(_ isAvailable: Bool, for identity: TerminalInstanceIdentity) {
        if isAvailable {
            unavailableIdentities.remove(identity)
        } else {
            unavailableIdentities.insert(identity)
        }
    }

    func state(for identity: TerminalInstanceIdentity) -> RemoteTerminalStateResult {
        guard identities.contains(identity), !unavailableIdentities.contains(identity) else {
            return .unavailable
        }
        return .available(RemoteTerminalState(
            grid: Self.macGrid,
            title: "Lease fixture",
            remoteViewport: appliedViewports[identity]
        ))
    }

    func currentSnapshot(
        for identity: TerminalInstanceIdentity
    ) -> RemoteTerminalCaptureResult {
        guard identities.contains(identity), !unavailableIdentities.contains(identity) else {
            return .unavailable
        }
        return .captured(snapshot(for: identity))
    }

    func beginCapture(
        for identity: TerminalInstanceIdentity,
        output: @escaping RemoteTerminalOutputSink
    ) -> RemoteTerminalCaptureResult {
        guard identities.contains(identity), !unavailableIdentities.contains(identity) else {
            return .unavailable
        }
        return .captured(snapshot(for: identity))
    }

    func endCapture(
        for identity: TerminalInstanceIdentity
    ) -> RemoteTerminalMutationResult {
        identities.contains(identity) ? .applied : .unavailable
    }

    func sendInput(
        _ bytes: [UInt8],
        to identity: TerminalInstanceIdentity
    ) -> RemoteTerminalMutationResult {
        identities.contains(identity) ? .applied : .unavailable
    }

    func setViewport(
        _ grid: RemoteTerminalGrid?,
        for identity: TerminalInstanceIdentity
    ) -> RemoteTerminalMutationResult {
        guard identities.contains(identity) else { return .unavailable }
        viewportCalls.append(ViewportCall(identity: identity, grid: grid))
        appliedViewports[identity] = grid
        return .applied
    }

    private static let macGrid = RemoteTerminalGrid(cols: 120, rows: 40)

    private func snapshot(for identity: TerminalInstanceIdentity) -> RemoteTerminalSnapshot {
        RemoteTerminalSnapshot(
            grid: Self.macGrid,
            title: "Lease fixture",
            screenSeed: Data("seed".utf8),
            remoteViewport: appliedViewports[identity]
        )
    }
}

/// The socket never upgrades, so nothing is routed and nothing is sent.
private final class SilentConnectionDelegate: RemoteConnection.Delegate,
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
