import CryptoKit
import XCTest
import ThreadingPeerTransport
import ThreadingRemoteKit
@testable import Threading

/// Boots the real `RemoteAccessServer` on a loopback port and probes it over an actual socket.
/// This is where the isolation invariant is pinned: the tunnel-facing server must not route any
/// MCP, permission or lifecycle path — those belong to a different server the tunnel never
/// reaches — and an unauthenticated API call must be refused.
@MainActor
final class RemoteServerIntegrationTests: HostedStoreTestCase {

    private var server: RemoteAccessServer!
    private var authority: RemoteAuthorityStore!
    private var sessionCommands: RecordingRemoteSessionCommands!
    private var sessionAccess: RecordingRemoteSessionAccess!
    private var runtimeStatus: RecordingRemoteRuntimeStatus!
    private var settingsMutator: RecordingRemoteSettingsMutator!
    private var appSettings: AppSettings!
    private var appSettingsDefaults: UserDefaults!
    private var appSettingsSuiteName: String!
    private var eventRecorder: RecordingRemoteEventRecorder!
    private var identityStore: RemoteAccessIdentityStore!
    private var identityDirectory: URL!
    private var port: UInt16!

    override func setUp() async throws {
        try await super.setUp()
        authority = RemoteAuthorityStore()
        authority.set(
            RemoteAuthorization(shareID: "test", capability: .interact, scope: .allSessions),
            forToken: "goodtoken"
        )
        appSettingsSuiteName = "RemoteServerIntegrationTests.\(UUID().uuidString)"
        appSettingsDefaults = try! XCTUnwrap(UserDefaults(suiteName: appSettingsSuiteName))
        appSettings = AppSettings(defaults: appSettingsDefaults)
        let live = RemoteAccessCoordinator.makeServerServices(appSettings: appSettings)
        sessionAccess = RecordingRemoteSessionAccess(store: .shared)
        runtimeStatus = RecordingRemoteRuntimeStatus(runtime: .shared)
        settingsMutator = RecordingRemoteSettingsMutator(appSettings: appSettings)
        eventRecorder = RecordingRemoteEventRecorder()
        let identity = RemoteIdentityTestStore.make(label: "RemoteServerIntegrationTests")
        identityStore = identity.store
        identityDirectory = identity.directory
        server = RemoteAccessServer(services: RemoteAccessServerServices(
            sessionQueries: sessionAccess,
            sessionMutations: sessionAccess,
            runtimeStatus: runtimeStatus,
            settings: settingsMutator,
            eventLog: eventRecorder,
            mirrors: live.mirrors,
            notifications: live.notifications,
            archiveSync: live.archiveSync,
            snoozeCenter: live.snoozeCenter,
            attachments: live.attachments,
            extensions: live.extensions,
            mobileDiagnosticsCaptures: live.mobileDiagnosticsCaptures,
            usageDashboard: live.usageDashboard,
            usageLimit: live.usageLimit,
            usageCapacity: {
                RemoteUsageCapacityDTO(epoch: "A3C526A1-C6F2-49EE-A254-7542BB28E4D7", revision: 7,
                    accounts: [.init(runtimeID: "codex", runtimeName: "Codex", accountID: "personal",
                        accountName: "Personal", observedAt: 1_780_000_000, state: .current,
                        windows: [.init(id: "weekly", name: "Week", fraction: 0.42)])])
            }
        ), identityProvider: identity.store)
        server.authorizer = authority
        sessionCommands = RecordingRemoteSessionCommands()
        server.sessionCommands = sessionCommands
        server.receiveClientDiagnostics = { _, _, _ in true }
        let usageSummary = RemoteUsageLimitSeriesSummaryDTO(
            id: "codex|personal|weekly",
            runtimeName: "Codex",
            accountName: "Personal",
            windowLabel: "Weekly",
            currentFraction: 0.42,
            resetsAt: 200,
            bankedResetCount: 2,
            nextBankedResetExpiresAt: 300
        )
        server.usageDashboardLoader = { offset, count in
            let page = offset == 0 && count > 0 ? [usageSummary] : []
            return RemoteUsageDashboardDTO(
                isBuilding: false,
                builtAt: 100,
                pricingCatalogVersion: "test",
                ranges: [],
                coverage: [],
                limitSeries: page,
                nextLimitCursor: nil,
                omittedLimitSeriesCount: 0,
                preparedAt: 101
            )
        }
        server.usageLimitLoader = { seriesID, days in
            guard seriesID == usageSummary.id, days == 30 else { return nil }
            return RemoteUsageLimitDTO(
                series: usageSummary,
                days: days,
                start: 0,
                end: 101,
                observed: [.init(at: 100, fraction: 0.42, segment: 0)],
                resets: [],
                recordedResetCount: 0,
                restoredPaceFraction: 0,
                projection: nil,
                preparedAt: 101
            )
        }

        // A port the kernel just handed out and gave back, rather than the shipped default: the
        // listener's port is sticky now, so a test that took the real one would fight the app
        // the developer is running.
        let ready = expectation(description: "listening")
        server.start(configuration: RemoteListenerConfiguration(preferredPort: FreeLocalPort.take())) {
            outcome in
            self.port = outcome.port
            ready.fulfill()
        }
        await fulfillment(of: [ready], timeout: 5)
        XCTAssertNotNil(port, "the server should bind a loopback port")
    }

    func testFocusedInputControlAllowsOnlyControllerAndOwnerCanAlwaysReclaim() {
        let owner = RemoteCollaborationParticipantDTO.ownerID
        let anna = "member-anna"
        let eligible = Set([owner, anna])
        let initial = RemoteInputControlRecord.initial(default: .collaborative)
        XCTAssertTrue(RemoteInputControlPolicy.canWrite(initial, participantID: owner))
        XCTAssertTrue(RemoteInputControlPolicy.canWrite(initial, participantID: anna))

        let focused = RemoteInputControlPolicy.applying(
            .focused,
            to: initial,
            actorID: owner,
            actorCanManage: true,
            targetID: anna,
            eligibleParticipantIDs: eligible
        )!
        XCTAssertEqual(focused.status, .applied)
        XCTAssertEqual(focused.record.mode, .focused)
        XCTAssertFalse(RemoteInputControlPolicy.canWrite(focused.record, participantID: owner))
        XCTAssertTrue(RemoteInputControlPolicy.canWrite(focused.record, participantID: anna))
        XCTAssertTrue(RemoteInputControlPolicy.isFocusedController(
            focused.record,
            participantID: anna
        ))
        XCTAssertFalse(
            RemoteInputControlPolicy.isFocusedController(focused.record, participantID: owner),
            "another participant reconnecting must not cancel Anna's disconnect grace"
        )

        let reclaimed = RemoteInputControlPolicy.applying(
            .reclaim,
            to: focused.record,
            actorID: owner,
            actorCanManage: true,
            targetID: nil,
            eligibleParticipantIDs: eligible
        )!
        XCTAssertEqual(reclaimed.record.controllerID, owner)
        XCTAssertTrue(RemoteInputControlPolicy.canWrite(reclaimed.record, participantID: owner))
        XCTAssertFalse(RemoteInputControlPolicy.canWrite(reclaimed.record, participantID: anna))
    }

    func testFocusedControllerCanHandOffButWatcherCannotStealControl() {
        let owner = RemoteCollaborationParticipantDTO.ownerID
        let anna = "member-anna"
        let priya = "member-priya"
        let eligible = Set([owner, anna, priya])
        let focused = RemoteInputControlRecord(mode: .focused, controllerID: anna, revision: 8)

        let stolen = RemoteInputControlPolicy.applying(
            .handoff,
            to: focused,
            actorID: priya,
            actorCanManage: false,
            targetID: priya,
            eligibleParticipantIDs: eligible
        )!
        XCTAssertEqual(stolen.status, .forbidden)
        XCTAssertEqual(stolen.record, focused)

        let handedOff = RemoteInputControlPolicy.applying(
            .handoff,
            to: focused,
            actorID: anna,
            actorCanManage: false,
            targetID: priya,
            eligibleParticipantIDs: eligible
        )!
        XCTAssertEqual(handedOff.status, .applied)
        XCTAssertEqual(handedOff.record.controllerID, priya)
        XCTAssertEqual(handedOff.record.revision, 9)

        let requested = RemoteInputControlPolicy.applying(
            .request,
            to: handedOff.record,
            actorID: anna,
            actorCanManage: false,
            targetID: nil,
            eligibleParticipantIDs: eligible
        )!
        XCTAssertEqual(requested.status, .delivered)
        XCTAssertEqual(requested.record, handedOff.record)

        let selfRequest = RemoteInputControlPolicy.applying(
            .request,
            to: handedOff.record,
            actorID: priya,
            actorCanManage: false,
            targetID: nil,
            eligibleParticipantIDs: eligible
        )!
        XCTAssertEqual(selfRequest.status, .rejected)
        XCTAssertEqual(selfRequest.record, handedOff.record)
    }

    func testFocusedControlCannotHandOffToSomebodyWhoIsAlreadyOffline() {
        let participants = [
            RemoteCollaborationParticipantDTO(
                id: "owner",
                displayName: "Owner",
                role: .owner,
                isOnline: true
            ),
            RemoteCollaborationParticipantDTO(
                id: "anna",
                displayName: "Anna",
                role: .member,
                isOnline: false
            ),
        ]
        let eligible = RemoteSessionMirrorRegistry.eligibleInputControlParticipantIDs(participants)
        XCTAssertEqual(eligible, ["owner"])

        let focused = RemoteInputControlRecord(
            mode: .focused,
            controllerID: "owner",
            revision: 3
        )
        let result = RemoteInputControlPolicy.applying(
            .handoff,
            to: focused,
            actorID: "owner",
            actorCanManage: true,
            targetID: "anna",
            eligibleParticipantIDs: eligible
        )
        XCTAssertEqual(result?.status, .unavailable)
        XCTAssertEqual(result?.record, focused)
    }

    func testInputControlIdentityBelongsToAPersonAcrossTheirDevices() {
        let ownerPhone = RemoteAuthorization(
            shareID: "owner-phone",
            capability: .interact,
            scope: .allSessions,
            principal: .ownerDevice
        )
        let ownerBrowser = RemoteAuthorization(
            shareID: "owner-browser",
            capability: .interact,
            scope: .allSessions,
            principal: .ownerDevice
        )
        let member = RemoteMember(id: "member-anna", displayName: "Anna", deviceID: "phone")
        let anna = RemoteAuthorization(
            shareID: "accepted-share",
            capability: .interact,
            scope: .session(SessionID()),
            principal: .guest,
            member: member
        )

        XCTAssertEqual(ownerPhone.collaborationParticipantID, "owner")
        XCTAssertEqual(ownerBrowser.collaborationParticipantID, "owner")
        XCTAssertEqual(anna.collaborationParticipantID, "member-anna")
    }

    func testHostedServiceRequiresConfigurationAndSignInBeforeStarting() throws {
        let unconfigured = RemoteHostedServiceController(
            store: HostedServiceStore(record: nil),
            endpoint: nil,
            hostID: "host-test",
            hostName: "Test Mac"
        )
        unconfigured.start(targetPort: 9_876)
        XCTAssertEqual(unconfigured.state, .notConfigured)
        XCTAssertFalse(unconfigured.canIssueDeviceCredentials)

        let endpoint = try PeerControlPlaneServiceEndpoint(
            XCTUnwrap(URL(string: "https://remote.example.test"))
        )
        let signedOut = RemoteHostedServiceController(
            store: HostedServiceStore(record: nil),
            endpoint: endpoint,
            hostID: "host-test",
            hostName: "Test Mac"
        )
        signedOut.start(targetPort: 9_876)
        XCTAssertEqual(signedOut.state, .signInRequired)
        XCTAssertFalse(signedOut.canIssueDeviceCredentials)
    }

    func testHostedServiceRestoresOnlyCredentialsForThisHostAndEndpoint() throws {
        let endpoint = try PeerControlPlaneServiceEndpoint(
            XCTUnwrap(URL(string: "https://remote.example.test"))
        )
        let validRecord = try hostedServiceRecord(
            endpoint: endpoint.baseURL,
            hostID: "host-test"
        )
        let restored = RemoteHostedServiceController(
            store: HostedServiceStore(record: validRecord),
            endpoint: endpoint,
            hostID: "host-test",
            hostName: "Test Mac"
        )
        XCTAssertTrue(restored.canIssueDeviceCredentials)

        let wrongHost = RemoteHostedServiceController(
            store: HostedServiceStore(record: validRecord),
            endpoint: endpoint,
            hostID: "different-host",
            hostName: "Test Mac"
        )
        wrongHost.start(targetPort: 9_876)
        XCTAssertEqual(wrongHost.state, .unavailable("credentials"))
        XCTAssertFalse(wrongHost.canIssueDeviceCredentials)

        let differentEndpoint = try PeerControlPlaneServiceEndpoint(
            XCTUnwrap(URL(string: "https://different.example.test"))
        )
        let wrongService = RemoteHostedServiceController(
            store: HostedServiceStore(record: validRecord),
            endpoint: differentEndpoint,
            hostID: "host-test",
            hostName: "Test Mac"
        )
        wrongService.start(targetPort: 9_876)
        XCTAssertEqual(wrongService.state, .unavailable("credentials"))
        XCTAssertFalse(wrongService.canIssueDeviceCredentials)
    }

    func testHostedServiceRejectsTamperedPendingRevocationState() throws {
        let endpoint = try PeerControlPlaneServiceEndpoint(
            XCTUnwrap(URL(string: "https://remote.example.test"))
        )
        var tampered = try hostedServiceRecord(
            endpoint: endpoint.baseURL,
            hostID: "host-test"
        )
        tampered.pendingRevokedDeviceIDs = ["device-1", "device-1"]
        let controller = RemoteHostedServiceController(
            store: HostedServiceStore(record: tampered),
            endpoint: endpoint,
            hostID: "host-test",
            hostName: "Test Mac"
        )

        controller.start(targetPort: 9_876)

        XCTAssertEqual(controller.state, .unavailable("credentials"))
        XCTAssertFalse(controller.canIssueDeviceCredentials)
    }

    func testLiveAuthorityKeepsEveryAcceptedMemberCurrentAndRevokesExactlyOneCredential() {
        let sessionID = SessionID()
        let anna = RemoteAuthorization(
            shareID: "shared-chat",
            capability: .interact,
            scope: .session(sessionID),
            member: RemoteMember(id: "anna", displayName: "Anna", deviceID: "anna-phone")
        )
        let priya = RemoteAuthorization(
            shareID: "shared-chat",
            capability: .interact,
            scope: .session(sessionID),
            member: RemoteMember(id: "priya", displayName: "Priya", deviceID: "priya-phone")
        )

        let store = RemoteAuthorityStore()
        store.set(anna, forToken: "anna-token")
        store.set(priya, forToken: "priya-token")
        XCTAssertTrue(store.isCurrent(anna))
        XCTAssertTrue(store.isCurrent(priya))

        store.set(nil, forToken: "anna-token")
        XCTAssertFalse(store.isCurrent(anna))
        XCTAssertTrue(store.isCurrent(priya))
    }

    func testConversationProjectionKeepsDraftCapabilityButGatesSendForWatcher() {
        let authorization = RemoteAuthorization(
            shareID: "anna-share",
            capability: .interact,
            scope: .session(SessionID()),
            principal: .guest,
            member: RemoteMember(id: "anna", displayName: "Anna", deviceID: "phone")
        )
        let snapshot = RemoteConversationSnapshotDTO(
            rows: [],
            streamingText: "",
            canSend: true,
            composerCapabilities: [RemoteComposerCapabilityDTO(
                id: "status",
                name: "status",
                displayName: "Status",
                description: "Show status",
                argumentHint: "",
                kind: .command,
                trigger: .slash,
                presentation: .command,
                isEnabled: true
            )],
            permission: nil,
            revision: 2
        )
        let watcher = RemoteConversationWirePolicy.authorized(
            snapshot,
            for: authorization,
            canWrite: false
        )
        XCTAssertFalse(watcher.canSend)
        XCTAssertEqual(watcher.composerCapabilities, snapshot.composerCapabilities)
    }

    override func tearDown() {
        server.stop()
        server = nil
        RemoteIdentityTestStore.erase(identityDirectory)
        identityDirectory = nil
        identityStore = nil
        authority = nil
        settingsMutator = nil
        appSettings = nil
        appSettingsDefaults.removePersistentDomain(forName: appSettingsSuiteName)
        appSettingsDefaults = nil
        appSettingsSuiteName = nil
        super.tearDown()
    }

    private final class HostedServiceStore: RemoteHostedServicePersisting {
        private var record: RemoteHostedServiceRecord?

        init(record: RemoteHostedServiceRecord?) {
            self.record = record
        }

        func load() throws -> RemoteHostedServiceRecord? { record }
        func save(_ record: RemoteHostedServiceRecord) throws { self.record = record }
        func delete() throws { record = nil }
    }

    private func hostedServiceRecord(
        endpoint: URL,
        hostID: String
    ) throws -> RemoteHostedServiceRecord {
        let future = Date().addingTimeInterval(30 * 24 * 60 * 60)
        return RemoteHostedServiceRecord(
            version: 1,
            endpoint: endpoint,
            session: PeerControlPlaneSession(
                accountID: "account-test",
                accessToken: try PeerControlPlaneBearer("access-token"),
                accessTokenExpiresAt: future,
                refreshToken: try PeerControlPlaneBearer("refresh-token"),
                refreshTokenExpiresAt: future
            ),
            hostCredential: PeerHostServiceCredential(
                hostID: hostID,
                credential: try PeerControlPlaneBearer("host-token"),
                expiresAt: future
            ),
            pendingRevokedDeviceIDs: []
        )
    }

    // MARK: - Probing

    // The header names below — and every `headers:` dictionary the tests pass through these two
    // helpers — are spelled `X-Threading-…` in title case on purpose. **Do not rewire them onto
    // `RemoteHeader`.**
    //
    // A shipped iPhone in the field sends title case; the current client sends the lowercase
    // spelling `RemoteHeader` defines. Both are in the wild, and HTTP header names are
    // case-insensitive, so the host has to keep accepting either. These literals are the only
    // coverage proving it still accepts the casing from a client we do not control — derive them
    // from the enum and that regression test silently becomes a tautology.
    //
    // The enum-derived half of this lives in `RemoteRouteRoundTripTests`, which asserts both
    // casings reach the same host decision. Keep the two halves apart.

    private struct Probe { let status: Int; let headers: [AnyHashable: Any]; let body: Data }

    @discardableResult
    private func get(_ path: String, bearer: String? = nil, headers: [String: String] = [:]) -> Probe? {
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port!)\(path)")!)
        if let bearer { request.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization") }
        request.setValue("test-device", forHTTPHeaderField: "X-Threading-Device")
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }

        var probe: Probe?
        let done = expectation(description: "GET \(path)")
        URLSession.shared.dataTask(with: request) { data, response, _ in
            if let http = response as? HTTPURLResponse {
                probe = Probe(status: http.statusCode, headers: http.allHeaderFields, body: data ?? Data())
            }
            done.fulfill()
        }.resume()
        wait(for: [done], timeout: 5)
        return probe
    }

    @discardableResult
    private func post(
        _ path: String,
        bearer: String,
        body: Data,
        headers: [String: String] = [:]
    ) -> Probe? {
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port!)\(path)")!)
        request.httpMethod = "POST"
        request.httpBody = body
        request.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization")
        request.setValue("test-device", forHTTPHeaderField: "X-Threading-Device")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }

        var probe: Probe?
        let done = expectation(description: "POST \(path)")
        URLSession.shared.dataTask(with: request) { data, response, _ in
            if let http = response as? HTTPURLResponse {
                probe = Probe(status: http.statusCode, headers: http.allHeaderFields, body: data ?? Data())
            }
            done.fulfill()
        }.resume()
        wait(for: [done], timeout: 5)
        return probe
    }

    // MARK: - Tests

    func testServesTheClientPageWithHardeningHeaders() throws {
        let probe = try XCTUnwrap(get("/"))
        XCTAssertEqual(probe.status, 200)
        XCTAssertEqual(probe.headers["X-Frame-Options"] as? String, "DENY")
        XCTAssertEqual(probe.headers["X-Content-Type-Options"] as? String, "nosniff")
        XCTAssertEqual(probe.headers["Cache-Control"] as? String, "no-store")
        XCTAssertNotNil(probe.headers["Content-Security-Policy"], "the page must carry a CSP")
        XCTAssertTrue(String(decoding: probe.body, as: UTF8.self).contains("Threading Remote"))
    }

    func testServesTheClientScript() throws {
        let probe = try XCTUnwrap(get("/app.js"))
        XCTAssertEqual(probe.status, 200)
        XCTAssertEqual(probe.headers["X-Frame-Options"] as? String, "DENY")

        let script = String(decoding: probe.body, as: UTF8.self)
        let stash = try XCTUnwrap(script.range(of: "sessionStorage.setItem(tokenStorageKey, fragmentToken)"))
        let scrub = try XCTUnwrap(script.range(
            of: "history.replaceState(null, document.title, location.pathname + location.search)"
        ))
        let firstRequest = try XCTUnwrap(script.range(of: "fetch(\"/api/me\""))
        XCTAssertLessThan(stash.lowerBound, scrub.lowerBound)
        XCTAssertLessThan(scrub.lowerBound, firstRequest.lowerBound)
        XCTAssertTrue(script.contains("try {\n    deviceID = localStorage.getItem(deviceKey)"))
    }

    /// The browser client shipped without either half of this, so it rendered the Mac's grid at
    /// a fixed 13px into whatever box it had: on a narrower window the session simply ran off
    /// the frame and behind a scrollbar. `term.resize(msg.cols, msg.rows)` was the *only* sizing
    /// call in the file, and it takes the host's numbers.
    func testTheClientScriptFitsTheHostsGridToItsOwnFrame() throws {
        let script = String(decoding: try XCTUnwrap(get("/app.js")).body, as: UTF8.self)

        XCTAssertTrue(
            script.contains("type: \"viewport\""),
            "an interactive client asks the Mac to reflow to the grid it can actually show — "
                + "the lease the phone already takes, named `viewport` in RemoteAccessServer"
        )
        XCTAssertTrue(
            script.contains("type: \"viewportRelease\""),
            "and gives it back, so the Mac's own grid returns when nobody is holding it"
        )
        XCTAssertTrue(
            script.contains("term.options.fontSize = size"),
            "a view-only client cannot hold a lease — the server refuses one — so it shrinks "
                + "its own type until the host's grid fits instead"
        )
        XCTAssertTrue(
            script.contains("window.addEventListener(\"resize\", scheduleFit)"),
            "resizing the browser has to re-fit; only resizing the Mac did before"
        )
    }

    /// Two clients watching one session share one PTY, and the Mac broadcasts every grid it
    /// applies to all of them. Following whichever asked last therefore had no fixed point: the
    /// client that could not show the new grid answered by re-asking for its own, and the agent
    /// was reflowed and repainted a few times a second until one of them closed. The
    /// intersection is the grid every client can show whole, and does not depend on arrival
    /// order — so a second viewer joining costs one resize, not an endless argument.
    func testASharedTerminalSettlesOnTheGridEveryClientCanShow() {
        let phone = (cols: 46, rows: 35)
        let tablet = (cols: 80, rows: 33)

        let settled = RemoteSessionMirrorRegistry.resolvedViewport(of: [phone, tablet])
        XCTAssertEqual(settled?.cols, 46)
        XCTAssertEqual(settled?.rows, 33)

        XCTAssertEqual(
            RemoteSessionMirrorRegistry.resolvedViewport(of: [tablet, phone])?.cols,
            settled?.cols,
            "arrival order must not change the answer, or the two clients trade the grid forever"
        )
        XCTAssertEqual(
            RemoteSessionMirrorRegistry.resolvedViewport(of: [tablet, phone])?.rows,
            settled?.rows
        )

        XCTAssertEqual(
            RemoteSessionMirrorRegistry.resolvedViewport(of: [phone])?.rows,
            35,
            "one client alone still gets exactly what it asked for"
        )
        XCTAssertNil(
            RemoteSessionMirrorRegistry.resolvedViewport(of: []),
            "and the Mac's own frame decides again once nobody holds a lease"
        )
    }

    /// The sharing pane draws from two sources that both know about the same person: the live
    /// socket they are on, and the share store that let them in. Listing them from each would put
    /// one name in two sections and read as two people, so somebody watching appears once — in
    /// the live group, where there is more to say about them.
    func testSomebodyWatchingIsListedOnceRatherThanInBothGroups() {
        let socket = NSObject()
        let anna = RemoteSessionMirrorRegistry.Follower(
            id: ObjectIdentifier(socket),
            memberName: "Anna",
            memberID: "member-anna",
            deviceName: "iPhone",
            deviceLabel: "device-abc",
            isOwnerDevice: false,
            capability: .interact,
            canApprovePermissions: false,
            surface: .terminal,
            viewport: (cols: 46, rows: 35),
            watchingSince: Date(),
            isTyping: false
        )
        func member(_ id: String, _ name: String) -> RemoteAccessCoordinator.SessionAccess.Member {
            .init(
                id: id,
                displayName: name,
                deviceID: "device",
                capability: .view,
                canApprovePermissions: false,
                joinedAt: Date(),
                lastSeenAt: nil
            )
        }
        let access = RemoteAccessCoordinator.SessionAccess(
            members: [member("member-anna", "Anna"), member("member-jonas", "Jonas")],
            links: []
        )

        let sections = SessionSharingViewController.sections(
            followers: [anna],
            access: access
        )

        XCTAssertEqual(sections.watching.map(\.memberName), ["Anna"])
        XCTAssertEqual(
            sections.away.map(\.displayName),
            ["Jonas"],
            "Anna holds a membership and a socket; only the socket describes what she is doing"
        )
        _ = socket
    }

    func testSharingPaneRendersOwnerMemberAndUnusedLinkAtNarrowWidthAndRoutesActions()
        throws
    {
        func descendants(in root: NSView) -> [NSView] {
            root.subviews.flatMap { [$0] + descendants(in: $0) }
        }
        func button(titled title: String, in row: SessionSharingRowView) -> ThemedButton? {
            descendants(in: row).compactMap { $0 as? ThemedButton }.first { $0.title == title }
        }

        let previousEnabled = AppSettings.shared.remoteAccessEnabled
        let previousTheme = AppThemeLibrary.current
        defer {
            AppSettings.shared.remoteAccessEnabled = previousEnabled
            AppThemePalette.set(previousTheme)
            NotificationCenter.default.post(AppThemeDidChange(themeID: previousTheme.id))
        }
        AppSettings.shared.remoteAccessEnabled = true

        let ownerSocket = NSObject()
        let guestSocket = NSObject()
        let followers = [
            RemoteSessionMirrorRegistry.Follower(
                id: ObjectIdentifier(ownerSocket),
                memberName: nil,
                memberID: nil,
                deviceName: "David’s iPhone",
                deviceLabel: "device-owner",
                isOwnerDevice: true,
                capability: .interact,
                canApprovePermissions: true,
                surface: .conversation,
                viewport: nil,
                watchingSince: Date(timeIntervalSinceNow: -180),
                isTyping: false
            ),
            RemoteSessionMirrorRegistry.Follower(
                id: ObjectIdentifier(guestSocket),
                memberName: "Anna",
                memberID: "member-anna",
                deviceName: "Chrome on Mac",
                deviceLabel: "device-guest",
                isOwnerDevice: false,
                capability: .interact,
                canApprovePermissions: false,
                surface: .terminal,
                viewport: (cols: 46, rows: 35),
                watchingSince: Date(timeIntervalSinceNow: -90),
                isTyping: true
            ),
        ]
        let access = RemoteAccessCoordinator.SessionAccess(
            members: [
                .init(
                    id: "member-anna",
                    displayName: "Anna",
                    deviceID: "guest-device",
                    capability: .interact,
                    canApprovePermissions: false,
                    joinedAt: Date(timeIntervalSinceNow: -3_600),
                    lastSeenAt: Date(timeIntervalSinceNow: -600)
                ),
                .init(
                    id: "member-jonas",
                    displayName: "Jonas",
                    deviceID: "away-device",
                    capability: .view,
                    canApprovePermissions: false,
                    joinedAt: Date(timeIntervalSinceNow: -7_200),
                    lastSeenAt: nil
                ),
            ],
            links: [.init(
                id: "unused-link",
                capability: .view,
                canApprovePermissions: false,
                createdAt: Date(timeIntervalSinceNow: -300),
                expiresAt: Date(timeIntervalSinceNow: 3_600),
                url: URL(string: "https://share.example/invite")
            )]
        )

        let controller = SessionSharingViewController(sessionID: SessionID())
        var copied: String?
        var revokedMember: String?
        var revokedLink: String?
        controller.onCopyInvitation = { copied = $0 }
        controller.confirmRevocation = { _ in true }
        controller.onRevokeMember = { revokedMember = $0 }
        controller.onRevokeLink = { revokedLink = $0 }
        _ = controller.view
        controller.view.frame = NSRect(x: 0, y: 0, width: 280, height: 560)

        // Attaching the controller starts its live refresh timer and immediately reads the real
        // sharing stores. Install the fixture after that refresh; otherwise the attach rebuilds
        // the rows and this test retains controls that are no longer in the window.
        let window = NSWindow(
            contentRect: controller.view.frame,
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentViewController = controller
        controller.apply(
            followers: followers,
            access: access,
            inputControl: RemoteInputControlStateDTO(
                mode: .focused,
                controllerID: "member-anna",
                controllerDisplayName: "Anna",
                currentParticipantID: "owner",
                canWrite: false,
                canManage: true,
                canHandOff: true,
                participants: [
                    .init(id: "owner", displayName: "David", role: .owner, isOnline: true),
                    .init(
                        id: "member-anna",
                        displayName: "Anna",
                        role: .member,
                        isOnline: true
                    ),
                    .init(
                        id: "member-jonas",
                        displayName: "Jonas",
                        role: .member,
                        isOnline: false
                    ),
                ],
                revision: 4
            )
        )
        controller.view.layoutSubtreeIfNeeded()

        let mode = try XCTUnwrap(
            descendants(in: controller.view).compactMap { $0 as? ThemedSegmentedControl }.first
        )
        XCTAssertEqual(mode.selectedIndex, 1)
        let inputController = try XCTUnwrap(
            descendants(in: controller.view).compactMap { $0 as? ThemedPopUp }.first {
                $0.accessibilityIdentifier() == "sharing.input-controller"
            }
        )
        XCTAssertEqual(inputController.selectedItem?.title, "Anna")
        XCTAssertGreaterThan(
            mode.frame.width,
            240,
            "input mode should fill the narrow pane instead of retaining the old fixed width"
        )
        XCTAssertGreaterThan(
            inputController.frame.width,
            140,
            "controller names need the remaining row width without conflicting constraints"
        )

        let rows = descendants(in: controller.view).compactMap {
            $0 as? SessionSharingRowView
        }
        XCTAssertEqual(rows.count, 4, "live member must not be repeated in With access")
        let labels = rows.compactMap { $0.accessibilityLabel() }
        XCTAssertTrue(labels.contains { $0.contains("David’s iPhone") })
        XCTAssertTrue(labels.contains { $0.contains("Anna") && $0.contains("typing") })
        XCTAssertTrue(labels.contains { $0.contains("Jonas") })
        XCTAssertTrue(labels.contains { $0.contains("View only") })

        let jonas = try XCTUnwrap(rows.first { $0.accessibilityLabel()?.contains("Jonas") == true })
        let invitation = try XCTUnwrap(rows.first { button(titled: "Copy", in: $0) != nil })
        let invitationDetail = try XCTUnwrap(
            descendants(in: invitation).compactMap { $0 as? NSTextField }.first {
                $0.stringValue.localizedCaseInsensitiveContains("expires")
            }
        )
        XCTAssertEqual(invitationDetail.lineBreakMode, .byWordWrapping)
        XCTAssertEqual(invitationDetail.maximumNumberOfLines, 2)
        try XCTUnwrap(button(titled: "Revoke", in: jonas)).performClick()
        try XCTUnwrap(button(titled: "Copy", in: invitation)).performClick()
        try XCTUnwrap(button(titled: "Revoke", in: invitation)).performClick()
        XCTAssertEqual(revokedMember, "member-jonas")
        XCTAssertEqual(copied, "https://share.example/invite")
        XCTAssertEqual(revokedLink, "unused-link")

        let copy = try XCTUnwrap(button(titled: "Copy", in: invitation))
        XCTAssertTrue(copy.isBordered, "the primary invitation action needs a padded surface")
        XCTAssertFalse(copy.isProminent)
        XCTAssertTrue(window.makeFirstResponder(copy), "row actions must remain keyboard focusable")

        var renders = Set<Data>()
        for theme in [AppTheme.system, AppThemeStyles.cyberpunk] {
            AppThemePalette.set(theme)
            NotificationCenter.default.post(AppThemeDidChange(themeID: theme.id))
            controller.view.layoutSubtreeIfNeeded()
            let rep = try XCTUnwrap(
                controller.view.bitmapImageRepForCachingDisplay(in: controller.view.bounds)
            )
            controller.view.cacheDisplay(in: controller.view.bounds, to: rep)
            let png = try XCTUnwrap(rep.representation(using: .png, properties: [:]))
            renders.insert(png)
            if theme.id == AppThemeStyles.cyberpunk.id {
                let directory = ProcessInfo.processInfo.environment["THREADING_RENDER_OUT"].flatMap { override in
                    override.isEmpty ? nil : URL(fileURLWithPath: override, isDirectory: true)
                } ?? FileManager.default.temporaryDirectory.appendingPathComponent(
                    "ThreadingRenders",
                    isDirectory: true
                )
                try FileManager.default.createDirectory(
                    at: directory,
                    withIntermediateDirectories: true
                )
                try png.write(
                    to: directory.appendingPathComponent("session-sharing-focused.png")
                )
            }
        }
        XCTAssertEqual(renders.count, 2, "sharing rows ignored the authored theme")
        XCTAssertEqual(ThemeBoundaryAudit.violations(in: controller.view), [])
        window.close()
        _ = [ownerSocket, guestSocket]
    }

    /// A device's own label is shown beside a Revoke button, so it arrives from the network held
    /// to the same rules a member's display name is: bounded, printable, whitespace-collapsed.
    /// It is never an identity — the device id is what authorization binds to — and this is what
    /// keeps a chosen string from becoming a row that lies about who is watching.
    func testADeviceLabelIsBoundedAndSanitizedLikeAnyOtherNameFromTheNetwork() {
        XCTAssertEqual(RemoteInboundPolicy.normalizedDeviceName("  iPhone   15  "), "iPhone 15")
        // Control characters are dropped outright rather than turned into a space — a newline
        // is one, so a two-line label arrives as one word rather than as a row that wraps.
        XCTAssertEqual(
            RemoteInboundPolicy.normalizedDeviceName("Safari\u{0}on\nmacOS"),
            "SafarionmacOS"
        )
        XCTAssertEqual(
            RemoteInboundPolicy.normalizedDeviceName("Safari\u{2028}on macOS"),
            "Safari on macOS",
            "a separator that is not a control character still collapses to one space"
        )
        XCTAssertNil(RemoteInboundPolicy.normalizedDeviceName("   "))
        XCTAssertNil(RemoteInboundPolicy.normalizedDeviceName(nil))
        XCTAssertNil(
            RemoteInboundPolicy.normalizedDeviceName(String(repeating: "a", count: 4_096)),
            "an unbounded label would be a row that pushes its own Revoke button off screen"
        )
    }

    /// Both clients say what they are, so the sharing pane's rows are readable rather than a
    /// column of UUID fragments. The field is additive: a client that predates it omits it and
    /// the Mac falls back to the pseudonym, which is why this needs no protocol bump.
    func testBothClientsIntroduceThemselvesByName() throws {
        let script = String(decoding: try XCTUnwrap(get("/app.js")).body, as: UTF8.self)
        XCTAssertTrue(
            script.contains("deviceName: deviceName"),
            "the browser names itself on the auth frame, for the Mac's sharing pane"
        )
        XCTAssertTrue(
            script.contains("navigator.userAgent"),
            "and derives that name rather than asking, because it is a label and not an identity"
        )
        XCTAssertNil(
            RemoteClientMessage(type: "auth", token: "t", device: "d").deviceName,
            "a client that says nothing stays valid — the field is optional on the wire"
        )
    }

    func testBrowserShowsTheLiveRosterAndKeepsDraftsUntilTheMacAcknowledgesThem() throws {
        let script = String(decoding: try XCTUnwrap(get("/app.js")).body, as: UTF8.self)
        let page = String(decoding: try XCTUnwrap(get("/")).body, as: UTF8.self)

        XCTAssertTrue(page.contains("id=\"presence\""))
        XCTAssertTrue(page.contains("id=\"composerStatus\""))
        XCTAssertTrue(script.contains("case \"presence\""))
        XCTAssertTrue(script.contains("case \"submitResult\""))
        XCTAssertTrue(script.contains("pendingPrompt = {"))
        XCTAssertTrue(script.contains("messageType: \"submit\""))
        XCTAssertTrue(
            script.contains("savePendingSubmission({"),
            "an acknowledged submission must survive a reconnect with the same request id"
        )
        XCTAssertTrue(
            script.contains("if (els.prompt.value.trim() === submitted.text)"),
            "an acknowledgement may clear only the exact draft that was submitted"
        )
        XCTAssertFalse(
            script.contains("socket.send(JSON.stringify({ type: \"submit\", text: text }));\n    els.prompt.value = \"\";"),
            "the acknowledged path must not erase a draft before the Mac accepts it"
        )
    }

    func testBrowserContinuityIsScopedByHostShareAndSession() throws {
        let script = String(decoding: try XCTUnwrap(get("/app.js")).body, as: UTF8.self)

        XCTAssertTrue(script.contains("threading.sessionContinuity.v1"))
        XCTAssertTrue(script.contains("hostID + \":\" + shareID"))
        XCTAssertTrue(script.contains("continuitySessionKey(sessionID)"))
        XCTAssertTrue(script.contains("saveConversationDraft()"))
        XCTAssertTrue(script.contains("conversationViewportProgress"))
        XCTAssertTrue(script.contains("terminalViewportProgress"))
        XCTAssertTrue(script.contains("continuityArchive.lastRoute"))
        XCTAssertTrue(
            script.contains("!archive.states[key].conversationDraft"),
            "position history may be pruned, but unsent words must never be evicted"
        )
    }

    func testBrowserAttentionControlIsOutsideAgentAndPTYSubmission() throws {
        let script = String(decoding: try XCTUnwrap(get("/app.js")).body, as: UTF8.self)
        let page = String(decoding: try XCTUnwrap(get("/")).body, as: UTF8.self)

        XCTAssertTrue(page.contains("id=\"attentionButton\""))
        XCTAssertTrue(page.contains("id=\"attentionDialog\""))
        XCTAssertTrue(page.contains("human-only notification"))
        XCTAssertTrue(script.contains("case \"collaborationParticipants\""))
        XCTAssertTrue(script.contains("case \"attention\""))
        XCTAssertTrue(script.contains("case \"attentionResult\""))
        XCTAssertTrue(script.contains("type: \"attentionRequest\""))
        XCTAssertTrue(script.contains("recipientID: selected.value"))

        let requestStart = try XCTUnwrap(script.range(of: "els.attentionForm.addEventListener"))
        let cleanupStart = try XCTUnwrap(
            script.range(of: "// --- Cleanup", range: requestStart.upperBound..<script.endIndex)
        )
        let requestPath = script[requestStart.lowerBound..<cleanupStart.lowerBound]
        XCTAssertFalse(requestPath.contains("type: \"submit\""))
        XCTAssertFalse(requestPath.contains("type: \"input\""))
        XCTAssertFalse(requestPath.contains("type: \"terminalSubmit\""))
    }

    func testBrowserFocusedControlPreservesDraftAndDoesNotMasqueradeAsPTYInput() throws {
        let script = String(decoding: try XCTUnwrap(get("/app.js")).body, as: UTF8.self)
        let page = String(decoding: try XCTUnwrap(get("/")).body, as: UTF8.self)

        XCTAssertTrue(page.contains("id=\"inputControl\""))
        XCTAssertTrue(script.contains("case \"inputControl\""))
        XCTAssertTrue(script.contains("type: \"inputControl\""))
        XCTAssertTrue(script.contains("inputControlState.canWrite"))
        XCTAssertTrue(
            script.contains("els.prompt.disabled = !editable"),
            "focused watching must disable send, not the draft editor"
        )

        let controlStart = try XCTUnwrap(script.range(of: "function sendInputControl"))
        let renderStart = try XCTUnwrap(
            script.range(of: "function renderInputControl", range: controlStart.upperBound..<script.endIndex)
        )
        let controlPath = script[controlStart.lowerBound..<renderStart.lowerBound]
        XCTAssertFalse(controlPath.contains("type: \"submit\""))
        XCTAssertFalse(controlPath.contains("type: \"input\""))
        XCTAssertFalse(controlPath.contains("type: \"terminalSubmit\""))
    }

    /// The client clamps to the same range the server validates against, so a request from a
    /// very small or very large window is answered rather than refused as `invalidViewport`.
    func testTheClientAsksInsideTheRangeTheServerAccepts() throws {
        let script = String(decoding: try XCTUnwrap(get("/app.js")).body, as: UTF8.self)

        XCTAssertTrue(script.contains("minCols: 20"))
        XCTAssertTrue(script.contains("maxCols: 240"))
        XCTAssertTrue(script.contains("minRows: 4"))
        XCTAssertTrue(script.contains("maxRows: 160"))
    }

    func testTheClientOffersExplicitTimeBoundedSanitizedDiagnosticSharing() throws {
        let script = String(decoding: try XCTUnwrap(get("/app.js")).body, as: UTF8.self)

        XCTAssertTrue(script.contains("Share diagnostics for 30 min"))
        XCTAssertTrue(script.contains("fetch(\"/api/diagnostics\""))
        XCTAssertTrue(script.contains("sharingMS: 30 * 60 * 1000"))
        XCTAssertTrue(script.contains("source: \"browserClient\""))
        XCTAssertFalse(script.contains("console.log ="))
        XCTAssertFalse(script.contains("console.error ="))
    }

    func testUnknownPathIs404() throws {
        XCTAssertEqual(try XCTUnwrap(get("/does-not-exist")).status, 404)
    }

    /// The whole reason remote access is a separate server: none of the MCP surface is routed
    /// here, so a tunnel that reaches this port cannot reach permission brokering.
    func testMCPAndHookPathsAreUnreachable() throws {
        XCTAssertEqual(try XCTUnwrap(get("/mcp/anything")).status, 404)
        XCTAssertEqual(try XCTUnwrap(get("/permission/anything")).status, 404)
        XCTAssertEqual(try XCTUnwrap(get("/lifecycle/anything")).status, 404)
    }

    func testApiRequiresAValidBearerToken() throws {
        XCTAssertEqual(try XCTUnwrap(get("/api/me")).status, 401)
        XCTAssertEqual(try XCTUnwrap(get("/api/me", bearer: "wrong")).status, 401)
    }

    /// `/api/me` names the catalogue edition it describes, answers a client that already holds
    /// that edition with `304` and no body, and compresses a body of any size for a client that
    /// can inflate it — which `URLSession` says it can by default. `no-store` stays on all of it.
    func testMeIsConditionalOnItsCatalogueEditionAndCompressedForClientsThatInflate() throws {
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(
            "remote-me-revision-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporary) }
        let project = try XCTUnwrap(ProjectStore.shared.addProject(folderURL: temporary))
        for index in 0..<12 {
            XCTAssertNotNil(ProjectStore.shared.addSession(
                to: project.id,
                kind: .claude,
                title: "A conversation with a long enough title to matter \(index)"
            ))
        }

        let first = try XCTUnwrap(get("/api/me", bearer: "goodtoken"))
        XCTAssertEqual(first.status, 200)
        let entityTag = try XCTUnwrap(header("ETag", in: first))
        let me = try JSONDecoder().decode(RemoteMeDTO.self, from: first.body)
        XCTAssertEqual(me.sessions.count, 12)
        XCTAssertEqual(me.revision?.entityTag, entityTag)
        XCTAssertEqual(header("Vary", in: first), "Accept-Encoding")
        XCTAssertEqual(header("Content-Encoding", in: first), "gzip")
        XCTAssertEqual(header("Cache-Control", in: first), "no-store")

        let unchanged = try XCTUnwrap(get(
            "/api/me",
            bearer: "goodtoken",
            headers: ["If-None-Match": entityTag]
        ))
        XCTAssertEqual(unchanged.status, 304)
        XCTAssertTrue(unchanged.body.isEmpty)
        XCTAssertEqual(header("ETag", in: unchanged), entityTag)

        let foreign = try XCTUnwrap(get(
            "/api/me",
            bearer: "goodtoken",
            headers: ["If-None-Match": "\"someone-else:1\""]
        ))
        XCTAssertEqual(foreign.status, 200)
        XCTAssertEqual(header("ETag", in: foreign), entityTag, "the edition has not moved")

        XCTAssertNotNil(ProjectStore.shared.addSession(to: project.id, kind: .claude, title: "New"))
        let moved = try XCTUnwrap(get(
            "/api/me",
            bearer: "goodtoken",
            headers: ["If-None-Match": entityTag]
        ))
        XCTAssertEqual(moved.status, 200, "a changed catalogue is served in full")
        XCTAssertNotEqual(header("ETag", in: moved), entityTag)
        XCTAssertEqual(
            try JSONDecoder().decode(RemoteMeDTO.self, from: moved.body).sessions.count,
            13
        )
    }

    /// A phone still holding the current edition is answered without the main thread. The
    /// probe blocks main outright — no run loop spins while it waits — so a `304` that still
    /// hopped to main for a projection it then discarded could not arrive inside the deadline.
    /// That hop was 450–600 ms of every ordinary conditional refresh in the 2026-09-17 journal.
    func testAnUnchangedCatalogueIsAnsweredWithoutTheMainThread() throws {
        let first = try XCTUnwrap(get("/api/me", bearer: "goodtoken"))
        XCTAssertEqual(first.status, 200)
        let entityTag = try XCTUnwrap(header("ETag", in: first))

        let unchanged = try XCTUnwrap(getBlockingMain(
            "/api/me",
            bearer: "goodtoken",
            headers: ["If-None-Match": entityTag]
        ), "a conditional request waited on the main thread")
        XCTAssertEqual(unchanged.status, 304)
        XCTAssertTrue(unchanged.body.isEmpty)
        XCTAssertEqual(header("ETag", in: unchanged), entityTag)
    }

    /// `get`, but waiting on a semaphore so the main thread does nothing until it answers.
    private func getBlockingMain(
        _ path: String,
        bearer: String,
        headers: [String: String]
    ) -> Probe? {
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port!)\(path)")!)
        request.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization")
        request.setValue("test-device", forHTTPHeaderField: "X-Threading-Device")
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }

        let answered = DispatchSemaphore(value: 0)
        // The semaphore orders the write before the read.
        final class Box: @unchecked Sendable { var probe: Probe? }
        let box = Box()
        URLSession.shared.dataTask(with: request) { data, response, _ in
            if let http = response as? HTTPURLResponse {
                let probe = Probe(
                    status: http.statusCode,
                    headers: http.allHeaderFields,
                    body: data ?? Data()
                )
                box.probe = probe
            }
            answered.signal()
        }.resume()
        guard answered.wait(timeout: .now() + 3) == .success else { return nil }
        return box.probe
    }

    /// Header lookup that tolerates whichever casing Foundation surfaces the field under.
    private func header(_ name: String, in probe: Probe) -> String? {
        for (key, value) in probe.headers {
            if (key as? String)?.caseInsensitiveCompare(name) == .orderedSame {
                return value as? String
            }
        }
        return nil
    }

    func testCreateAndResumeRouteThroughInjectedApplicationCommands() throws {
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(
            "remote-session-commands-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporary) }
        let project = try XCTUnwrap(ProjectStore.shared.addProject(folderURL: temporary))
        let dormant = try XCTUnwrap(ProjectStore.shared.addSession(
            to: project.id,
            kind: .codex,
            usesNativeUI: false,
            title: "Dormant remote session"
        ))

        let createdID = SessionID()
        sessionCommands.createdSessionID = createdID
        let create = try JSONEncoder().encode(RemoteCreateSessionRequestDTO(
            projectID: project.id.uuidString,
            agentKind: AgentKind.codex.rawValue,
            surface: .terminal,
            prompt: "Inspect the dependency boundary"
        ))

        let createProbe = try XCTUnwrap(post(
            "/api/session",
            bearer: "goodtoken",
            body: create
        ))
        XCTAssertEqual(createProbe.status, 201)
        let legacyCreation = try JSONDecoder().decode(
            RemoteCreateSessionResponseDTO.self,
            from: createProbe.body
        )
        XCTAssertEqual(
            legacyCreation.sessionID,
            createdID.uuidString
        )
        XCTAssertNotNil(legacyCreation.me, "an older request still receives its full catalogue")
        XCTAssertNil(legacyCreation.session)
        XCTAssertEqual(sessionCommands.launches.count, 1)
        let launch = try XCTUnwrap(sessionCommands.launches.first)
        XCTAssertEqual(launch.projectID, project.id)
        XCTAssertEqual(launch.kind, .codex)
        XCTAssertEqual(launch.accountHandle, .standard)
        XCTAssertFalse(launch.usesNativeUI)
        XCTAssertEqual(launch.prompt, "Inspect the dependency boundary")

        sessionCommands.createdSessionID = dormant.id
        let compactCreate = try JSONEncoder().encode(RemoteCreateSessionRequestDTO(
            projectID: project.id.uuidString,
            agentKind: AgentKind.codex.rawValue,
            surface: .terminal,
            compactResponse: true,
            prompt: "Open one changed row"
        ))
        let compactProbe = try XCTUnwrap(post(
            "/api/session",
            bearer: "goodtoken",
            body: compactCreate
        ))
        XCTAssertEqual(compactProbe.status, 201)
        let compactCreation = try JSONDecoder().decode(
            RemoteCreateSessionResponseDTO.self,
            from: compactProbe.body
        )
        XCTAssertEqual(compactCreation.sessionID, dormant.id.uuidString)
        XCTAssertEqual(compactCreation.session?.id, dormant.id.uuidString)
        XCTAssertEqual(compactCreation.startup, .starting)
        XCTAssertNil(compactCreation.me, "the current path must not rebuild the complete catalogue")

        let resumeProbe = try XCTUnwrap(post(
            "/api/session/\(dormant.id.uuidString)/resume",
            bearer: "goodtoken",
            body: Data()
        ))
        XCTAssertEqual(resumeProbe.status, 202)
        XCTAssertEqual(sessionCommands.resumedSessionIDs, [dormant.id])
        XCTAssertTrue(sessionAccess.queriedProjectIDs.contains(project.id))
        XCTAssertTrue(sessionAccess.queriedSessionIDs.contains(dormant.id))
        XCTAssertTrue(runtimeStatus.runningSessionIDs.contains(dormant.id))
    }

    /// The first prompt has no host session yet. Its files therefore travel under the phone's
    /// draft UUID, then the create request exchanges that temporary scope for application
    /// attachment custody. A mismatched scope must refuse the whole opening and leave the staged
    /// bytes available for the rightful request instead of launching words without their file.
    func testCreateClaimsDraftScopedAttachmentsAtomically() throws {
        let me = try JSONDecoder().decode(
            RemoteMeDTO.self,
            from: try XCTUnwrap(get("/api/me", bearer: "goodtoken")).body
        )
        XCTAssertTrue(
            me.features?.contains(
                RemoteRESTFeature.sessionDraftAttachmentUploads.rawValue
            ) == true
        )

        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(
            "remote-draft-attachment-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporary) }
        let project = try XCTUnwrap(ProjectStore.shared.addProject(folderURL: temporary))
        let draftID = SessionID()
        let png = try XCTUnwrap(Data(base64Encoded:
            "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg=="
        ))
        let uploadBody = try JSONEncoder().encode(RemoteAttachmentUploadRequestDTO(
            name: "draft-photo.png",
            mediaType: "public.png",
            totalBytes: png.count,
            chunkIndex: 0,
            chunkCount: 1,
            chunk: png.base64EncodedString()
        ))
        let upload = try XCTUnwrap(post(
            "/api/session/\(draftID.uuidString)/attachment-upload",
            bearer: "goodtoken",
            body: uploadBody
        ))
        XCTAssertEqual(upload.status, 200)
        let uploadID = try JSONDecoder().decode(
            RemoteAttachmentUploadResponseDTO.self,
            from: upload.body
        ).uploadID

        func create(scopeID: SessionID) throws -> Probe {
            let body = try JSONEncoder().encode(RemoteCreateSessionRequestDTO(
                projectID: project.id.uuidString,
                agentKind: AgentKind.codex.rawValue,
                surface: .conversation,
                openingAttachmentScopeID: scopeID.uuidString,
                openingAttachmentUploadIDs: [uploadID],
                prompt: "Describe the attached image"
            ))
            return try XCTUnwrap(post("/api/session", bearer: "goodtoken", body: body))
        }

        let mismatched = try create(scopeID: SessionID())
        XCTAssertEqual(mismatched.status, 400)
        XCTAssertEqual(
            try JSONDecoder().decode(RemoteErrorDTO.self, from: mismatched.body).code,
            RemoteRESTErrorCode.invalidOpeningAttachments.rawValue
        )
        XCTAssertTrue(sessionCommands.launches.isEmpty)

        sessionCommands.createdSessionID = SessionID()
        let accepted = try create(scopeID: draftID)
        XCTAssertEqual(accepted.status, 201)
        let launch = try XCTUnwrap(sessionCommands.launches.last)
        XCTAssertEqual(launch.prompt, "Describe the attached image")
        XCTAssertEqual(launch.openingAttachmentPaths.count, 1)
        XCTAssertEqual(sessionCommands.openingAttachmentPayloads.last, [png])
    }

    func testReportCreateHandsReadablePromptAndClaimedScreenshotToApplicationAtomically() throws {
        let me = try JSONDecoder().decode(
            RemoteMeDTO.self,
            from: try XCTUnwrap(get("/api/me", bearer: "goodtoken")).body
        )
        XCTAssertTrue(
            me.features?.contains(RemoteRESTFeature.reportSessionOpening.rawValue) == true
        )

        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(
            "remote-report-opening-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporary) }
        let project = try XCTUnwrap(ProjectStore.shared.addProject(folderURL: temporary))
        sessionCommands.createdSessionID = SessionID()

        let jpeg = Data([0xff, 0xd8, 0xff, 0x10, 0x20, 0x30])
        let reportPrompt = "Investigate report without embedding image bytes"
        let body = try JSONEncoder().encode(RemoteCreateSessionRequestDTO(
            projectID: project.id.uuidString,
            agentKind: AgentKind.codex.rawValue,
            surface: .terminal,
            reportOpening: RemoteReportSessionOpeningDTO(
                prompt: reportPrompt,
                screenshot: RemoteReportScreenshotDTO(
                    jpegBase64: jpeg.base64EncodedString()
                )
            ),
            prompt: ""
        ))

        let response = try XCTUnwrap(post("/api/session", bearer: "goodtoken", body: body))

        XCTAssertEqual(response.status, 201)
        let launch = try XCTUnwrap(sessionCommands.launches.last)
        XCTAssertEqual(launch.prompt, reportPrompt)
        XCTAssertEqual(launch.openingAttachmentPaths.count, 1)
        XCTAssertEqual(sessionCommands.openingAttachmentPayloads.last, [jpeg])
        XCTAssertFalse(launch.prompt.contains(jpeg.base64EncodedString()))
    }

    func testMalformedOrAmbiguousReportOpeningStartsNoSession() throws {
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(
            "remote-report-refusal-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporary) }
        let project = try XCTUnwrap(ProjectStore.shared.addProject(folderURL: temporary))
        sessionCommands.createdSessionID = SessionID()

        func create(prompt: String, screenshot: RemoteReportScreenshotDTO?) throws -> Probe {
            let body = try JSONEncoder().encode(RemoteCreateSessionRequestDTO(
                projectID: project.id.uuidString,
                agentKind: AgentKind.codex.rawValue,
                surface: .terminal,
                reportOpening: RemoteReportSessionOpeningDTO(
                    prompt: "Read the attached report",
                    screenshot: screenshot
                ),
                prompt: prompt
            ))
            return try XCTUnwrap(post("/api/session", bearer: "goodtoken", body: body))
        }

        let ambiguous = try create(
            prompt: "A second competing prompt",
            screenshot: nil
        )
        XCTAssertEqual(ambiguous.status, 400)
        XCTAssertEqual(
            try JSONDecoder().decode(RemoteErrorDTO.self, from: ambiguous.body).code,
            RemoteRESTErrorCode.invalidReportOpening.rawValue
        )

        let malformed = try create(
            prompt: "",
            screenshot: RemoteReportScreenshotDTO(jpegBase64: "not-base64")
        )
        XCTAssertEqual(malformed.status, 400)
        XCTAssertEqual(
            try JSONDecoder().decode(RemoteErrorDTO.self, from: malformed.body).code,
            RemoteRESTErrorCode.invalidReportOpening.rawValue
        )

        let mixedOpening = try JSONEncoder().encode(RemoteCreateSessionRequestDTO(
            projectID: project.id.uuidString,
            agentKind: AgentKind.codex.rawValue,
            surface: .terminal,
            reportOpening: RemoteReportSessionOpeningDTO(prompt: "Read the report"),
            openingAttachmentScopeID: SessionID().uuidString,
            openingAttachmentUploadIDs: ["draft-upload"],
            prompt: ""
        ))
        let mixed = try XCTUnwrap(post(
            "/api/session",
            bearer: "goodtoken",
            body: mixedOpening
        ))
        XCTAssertEqual(mixed.status, 400)
        XCTAssertEqual(
            try JSONDecoder().decode(RemoteErrorDTO.self, from: mixed.body).code,
            RemoteRESTErrorCode.invalidOpeningAttachments.rawValue
        )
        XCTAssertTrue(sessionCommands.launches.isEmpty)
    }

    /// A phone may start a manager: the request names the role, the launch carries it to the
    /// coordinator that confers the grant, and a role the vocabulary does not know is refused
    /// rather than started as a chat that would not find out until it failed to reach its
    /// siblings. No role is a chat, which is what every older phone asks for.
    func testAManagerIsStartedByRoleAndAnUnknownRoleIsRefused() throws {
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(
            "remote-manager-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporary) }
        let project = try XCTUnwrap(ProjectStore.shared.addProject(folderURL: temporary))
        sessionCommands.createdSessionID = SessionID()

        func create(role: RemoteSessionRole?) throws -> Int {
            let body = try JSONEncoder().encode(RemoteCreateSessionRequestDTO(
                projectID: project.id.uuidString,
                agentKind: AgentKind.codex.rawValue,
                surface: .terminal,
                role: role,
                prompt: "Coordinate the release"
            ))
            return try XCTUnwrap(post("/api/session", bearer: "goodtoken", body: body)).status
        }

        XCTAssertEqual(try create(role: RemoteSessionRole.manager), 201)
        XCTAssertEqual(try XCTUnwrap(sessionCommands.launches.last).role, .manager)

        XCTAssertEqual(try create(role: nil), 201)
        XCTAssertEqual(try XCTUnwrap(sessionCommands.launches.last).role, .chat)

        XCTAssertEqual(try create(role: RemoteSessionRole.chat), 201)
        XCTAssertEqual(try XCTUnwrap(sessionCommands.launches.last).role, .chat)

        XCTAssertEqual(sessionCommands.launches.count, 3)
        let unknownRole = Data(
            #"{"projectID":"\#(project.id.uuidString)","agentKind":"codex","surface":"terminal","role":"overlord","prompt":"Coordinate the release"}"#.utf8
        )
        let refusal = try XCTUnwrap(post(
            "/api/session",
            bearer: "goodtoken",
            body: unknownRole
        ))
        XCTAssertEqual(refusal.status, 422)
        XCTAssertEqual(
            try JSONDecoder().decode(RemoteErrorDTO.self, from: refusal.body).code,
            RemoteRESTErrorCode.unknownRole.rawValue
        )
        XCTAssertEqual(sessionCommands.launches.count, 3, "an unknown role starts nothing")
    }

    func testCreateSessionNamesTheWithdrawnModelThatRefusedLaunch() throws {
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(
            "remote-unknown-model-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporary) }
        let project = try XCTUnwrap(ProjectStore.shared.addProject(folderURL: temporary))
        let body = try JSONEncoder().encode(RemoteCreateSessionRequestDTO(
            projectID: project.id.uuidString,
            agentKind: AgentKind.codex.rawValue,
            model: "withdrawn-model",
            surface: .terminal,
            prompt: "Explain the refusal"
        ))

        let response = try XCTUnwrap(post("/api/session", bearer: "goodtoken", body: body))
        XCTAssertEqual(response.status, 422)
        XCTAssertEqual(
            try JSONDecoder().decode(RemoteErrorDTO.self, from: response.body),
            RemoteErrorDTO(code: .unknownModel)
        )
        XCTAssertTrue(sessionCommands.launches.isEmpty)
    }

    /// A phone may ask for the isolated worktree the Mac offered it, and nothing else.
    ///
    /// The offer itself is made in the catalogue, where the owner's setting is read; this is the
    /// door it comes back through, and it trusts the request no more than any other. The
    /// refusals matter more than the acceptance: a workspace that could not be delivered would
    /// otherwise be discovered as a failed provision after the session record existed.
    func testAnIsolatedWorkspaceIsAcceptedOnlyWhereItCouldBeDelivered() throws {
        let plain = FileManager.default.temporaryDirectory.appendingPathComponent(
            "remote-workspace-plain-\(UUID().uuidString)",
            isDirectory: true
        )
        let repository = FileManager.default.temporaryDirectory.appendingPathComponent(
            "remote-workspace-repo-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: plain, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: repository, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: plain)
            try? FileManager.default.removeItem(at: repository)
        }
        _ = try GitProcess.run(["init", "--quiet"], in: repository)

        let plainProject = try XCTUnwrap(ProjectStore.shared.addProject(folderURL: plain))
        let gitProject = try XCTUnwrap(ProjectStore.shared.addProject(folderURL: repository))
        sessionCommands.createdSessionID = SessionID()

        func create(
            in projectID: ProjectID,
            workspace: RemoteManagedWorkspacePlanDTO?
        ) throws -> Int {
            let body = try JSONEncoder().encode(RemoteCreateSessionRequestDTO(
                projectID: projectID.uuidString,
                agentKind: AgentKind.codex.rawValue,
                surface: .terminal,
                managedWorkspace: workspace,
                prompt: "Look at the report"
            ))
            return try XCTUnwrap(post("/api/session", bearer: "goodtoken", body: body)).status
        }

        // Nothing to branch from: the report is still worth more than the workspace, but that
        // decision belongs to the catalogue, which never offers one here. A request anyway is a
        // client asking for something this Mac cannot do.
        XCTAssertEqual(
            try create(
                in: plainProject.id,
                workspace: RemoteManagedWorkspacePlanDTO(delivery: .mergeAndCleanUp)
            ),
            422,
            "a worktree was accepted for a folder with no Git checkout"
        )

        XCTAssertEqual(
            try create(in: gitProject.id, workspace: RemoteManagedWorkspacePlanDTO(
                delivery: .unknown("rebaseOntoMain")
            )),
            422,
            "an unrecognised delivery was accepted rather than refused"
        )

        // Publishing is a decision made while looking at the repository. A phone in somebody's
        // pocket does not open change requests.
        XCTAssertEqual(
            try create(in: gitProject.id, workspace: RemoteManagedWorkspacePlanDTO(
                delivery: .mergeAndCleanUp,
                publication: .draft
            )),
            422,
            "a phone was allowed to publish a change request"
        )

        XCTAssertTrue(
            sessionCommands.launches.isEmpty,
            "a refused workspace still reached the application"
        )

        // The plain request keeps working exactly as it did before the field existed.
        XCTAssertEqual(try create(in: gitProject.id, workspace: nil), 201)
        XCTAssertNil(
            try XCTUnwrap(sessionCommands.launches.last).managedWorkspacePlan,
            "a session nobody asked to isolate was given a worktree"
        )

        try XCTSkipUnless(
            ManagedWorkspaceEligibility.supportsFinishHandshake(kind: .codex, usesNativeUI: false),
            "this build cannot hand a terminal session the session tools"
        )
        XCTAssertEqual(
            try create(in: gitProject.id, workspace: RemoteManagedWorkspacePlanDTO(
                delivery: .keepForReview
            )),
            201
        )
        XCTAssertEqual(
            try XCTUnwrap(sessionCommands.launches.last).managedWorkspacePlan?.delivery,
            .keepForReview,
            "the delivery the phone asked for did not survive the door"
        )
    }

    func testProjectVisibilityIsOwnerOnlyAndKeepsChatsInTheCatalogue() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let project = try XCTUnwrap(ProjectStore.shared.addProject(folderURL: folder))
        let session = try XCTUnwrap(ProjectStore.shared.addSession(to: project.id, kind: .claude))
        authority.set(RemoteAuthorization(shareID: "guest", capability: .interact,
            scope: .session(session.id)), forToken: "visibility-guest")
        authority.set(RemoteAuthorization(shareID: "viewer", capability: .view,
            scope: .allSessions), forToken: "visibility-viewer")
        let hidden = try JSONEncoder().encode(RemoteSetProjectHiddenRequestDTO(
            projectID: project.id.uuidString, isHidden: true))
        for token in ["visibility-guest", "visibility-viewer"] {
            XCTAssertEqual(try XCTUnwrap(post("/api/project/visibility", bearer: token, body: hidden)).status, 403)
        }
        XCTAssertFalse(try XCTUnwrap(ProjectStore.shared.project(withID: project.id)).isHidden)
        for value in [true, true, false] {
            let body = try JSONEncoder().encode(RemoteSetProjectHiddenRequestDTO(
                projectID: project.id.uuidString, isHidden: value))
            let response = try XCTUnwrap(post("/api/project/visibility", bearer: "goodtoken", body: body))
            XCTAssertEqual(response.status, 200)
            let catalogue = try JSONDecoder().decode(RemoteMeDTO.self, from: response.body)
            XCTAssertEqual(catalogue.newSessionCatalog?.projects.first { $0.id == project.id.uuidString }?.isHidden, value)
            XCTAssertTrue(catalogue.sessions.contains { $0.id == session.id.uuidString })
            XCTAssertEqual(ProjectStore.shared.project(withID: project.id)?.isHidden, value)
        }
        let missing = try JSONEncoder().encode(RemoteSetProjectHiddenRequestDTO(
            projectID: UUID().uuidString, isHidden: true))
        XCTAssertEqual(try XCTUnwrap(post("/api/project/visibility", bearer: "goodtoken", body: missing)).status, 404)
        XCTAssertEqual(try XCTUnwrap(post("/api/project/visibility", bearer: "goodtoken", body: Data("{}".utf8))).status, 400)
    }

    func testSessionRefreshesRouteThroughInjectedApplicationCommands() throws {
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(
            "remote-session-refresh-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporary) }
        let project = try XCTUnwrap(ProjectStore.shared.addProject(folderURL: temporary))
        let session = try XCTUnwrap(ProjectStore.shared.addSession(
            to: project.id,
            kind: .claude,
            usesNativeUI: false,
            title: "Remote refresh"
        ))

        let pin = try JSONEncoder().encode(RemoteSetSessionPinnedRequestDTO(isPinned: true))
        XCTAssertEqual(
            try XCTUnwrap(post(
                "/api/session/\(session.id.uuidString)/pinned",
                bearer: "goodtoken",
                body: pin
            )).status,
            200
        )
        XCTAssertEqual(sessionCommands.sessionRefreshes.count, 1)
        XCTAssertEqual(sessionCommands.sessionRefreshes.first?.sessionID, session.id)
        XCTAssertEqual(sessionCommands.sessionRefreshes.first?.archived, false)
        XCTAssertEqual(sessionAccess.pinnedMutations.last?.sessionID, session.id)
        XCTAssertEqual(sessionAccess.pinnedMutations.last?.isPinned, true)

        let surface = try JSONEncoder().encode(
            RemoteSetSessionSurfaceRequestDTO(surface: .conversation)
        )
        XCTAssertEqual(
            try XCTUnwrap(post(
                "/api/session/\(session.id.uuidString)/surface",
                bearer: "goodtoken",
                body: surface
            )).status,
            200
        )
        XCTAssertEqual(sessionCommands.surfaceRefreshes, [session.id])
        XCTAssertEqual(sessionAccess.surfaceMutations.last?.sessionID, session.id)
        XCTAssertEqual(sessionAccess.surfaceMutations.last?.usesNativeUI, true)
        XCTAssertTrue(try XCTUnwrap(ProjectStore.shared.session(withID: session.id)).usesNativeUI)
    }

    func testStorageExhaustionCrossesTheRESTBoundaryAsItsOwnRefusal() throws {
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(
            "remote-storage-refusal-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporary) }
        let project = try XCTUnwrap(ProjectStore.shared.addProject(folderURL: temporary))
        let session = try XCTUnwrap(ProjectStore.shared.addSession(
            to: project.id,
            kind: .claude,
            usesNativeUI: false,
            title: "Storage refusal"
        ))
        sessionAccess.persistenceBlockReasonOverride = .storageExhausted
        sessionAccess.pinnedMutationResultOverride = .persistenceRefused

        let response = try XCTUnwrap(post(
            "/api/session/\(session.id.uuidString)/pinned",
            bearer: "goodtoken",
            body: try JSONEncoder().encode(
                RemoteSetSessionPinnedRequestDTO(isPinned: true)
            )
        ))

        XCTAssertEqual(response.status, 503)
        XCTAssertEqual(
            try JSONDecoder().decode(RemoteErrorDTO.self, from: response.body),
            RemoteErrorDTO(code: .storageExhausted)
        )
    }

    func testOwnerCanMoveAChatAccountAndSetItsLimitRecovery() throws {
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(
            "remote-session-controls-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporary) }
        let project = try XCTUnwrap(ProjectStore.shared.addProject(folderURL: temporary))
        let session = try XCTUnwrap(ProjectStore.shared.addSession(
            to: project.id,
            kind: .codex,
            usesNativeUI: true,
            title: "Remote controls"
        ))

        let account = try JSONEncoder().encode(
            RemoteMoveSessionAccountRequestDTO(accountID: "work")
        )
        XCTAssertEqual(
            try XCTUnwrap(post(
                "/api/session/\(session.id.uuidString)/account",
                bearer: "goodtoken",
                body: account
            )).status,
            200
        )
        XCTAssertEqual(sessionCommands.accountMoves.last?.sessionID, session.id)
        XCTAssertEqual(sessionCommands.accountMoves.last?.accountHandle.name, "work")

        let originalPolicy = LimitRecoverySettings.policy
        LimitRecoverySettings.policy = .flagOnly
        defer { LimitRecoverySettings.policy = originalPolicy }
        let recovery = try JSONEncoder().encode(
            RemoteSetSessionLimitRecoveryRequestDTO(policy: .waitForReset)
        )
        let recoveryProbe = try XCTUnwrap(post(
            "/api/session/\(session.id.uuidString)/limit-recovery",
            bearer: "goodtoken",
            body: recovery
        ))
        XCTAssertEqual(recoveryProbe.status, 200)
        XCTAssertEqual(sessionAccess.limitRecoveryMutations.last?.sessionID, session.id)
        XCTAssertEqual(sessionAccess.limitRecoveryMutations.last?.policy, .waitForReset)

        let ownerMe = try JSONDecoder().decode(RemoteMeDTO.self, from: recoveryProbe.body)
        let ownerSummary = try XCTUnwrap(ownerMe.sessions.first { $0.id == session.id.uuidString })
        XCTAssertEqual(ownerSummary.accountID, session.accountHandle.name)
        XCTAssertEqual(
            ownerSummary.limitRecovery,
            .waitForReset
        )

        let inheritedRecovery = try JSONEncoder().encode(
            RemoteSetSessionLimitRecoveryRequestDTO(policy: .flagOnly)
        )
        XCTAssertEqual(
            try XCTUnwrap(post(
                "/api/session/\(session.id.uuidString)/limit-recovery",
                bearer: "goodtoken",
                body: inheritedRecovery
            )).status,
            200
        )
        XCTAssertNil(
            sessionAccess.limitRecoveryMutations.last?.policy,
            "matching the inherited answer must keep the chat following its broader setting"
        )

        authority.set(RemoteAuthorization(
            shareID: "settings-guest",
            capability: .interact,
            scope: .session(session.id),
            principal: .guest
        ), forToken: "settingsguest")
        let guestMe = try JSONDecoder().decode(
            RemoteMeDTO.self,
            from: try XCTUnwrap(get("/api/me", bearer: "settingsguest")).body
        )
        let guestSummary = try XCTUnwrap(guestMe.sessions.first)
        XCTAssertNil(guestSummary.accountID)
        XCTAssertNil(guestSummary.limitRecovery)
    }

    /// The continuation route is the account move's sibling, and the differences are the point:
    /// it answers with the chat it created rather than only the snapshot, it names a runtime as
    /// well as a login, and its eligibility is asked before the choice is offered rather than
    /// carried on every session row.
    func testOwnerCanContinueAChatOnAnotherProvider() throws {
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(
            "remote-session-continuation-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporary) }
        let project = try XCTUnwrap(ProjectStore.shared.addProject(folderURL: temporary))
        let session = try XCTUnwrap(ProjectStore.shared.addSession(
            to: project.id,
            kind: .codex,
            usesNativeUI: true,
            title: "Continue me"
        ))

        // A chat that has recorded nothing offers nowhere to continue, which is the whole
        // answer a client needs: it draws no control rather than one the Mac would refuse.
        let ownerMe = try JSONDecoder().decode(
            RemoteMeDTO.self,
            from: try XCTUnwrap(get("/api/me", bearer: "goodtoken")).body
        )
        XCTAssertEqual(
            ownerMe.features?.contains(RemoteRESTFeature.sessionContinuation.rawValue),
            true,
            "a phone offers the control only where the Mac says the route exists"
        )

        let options = try XCTUnwrap(get(
            "/api/session/\(session.id.uuidString)/continuation",
            bearer: "goodtoken"
        ))
        XCTAssertEqual(options.status, 200)
        XCTAssertEqual(
            try JSONDecoder().decode(
                RemoteSessionContinuationOptionsDTO.self,
                from: options.body
            ).destinations,
            []
        )

        let created = SessionID()
        sessionCommands.continuationResult = .success(created)
        let accepted = try XCTUnwrap(post(
            "/api/session/\(session.id.uuidString)/continuation",
            bearer: "goodtoken",
            body: try JSONEncoder().encode(
                RemoteContinueSessionRequestDTO(agentID: "claude", accountID: "work")
            )
        ))
        XCTAssertEqual(accepted.status, 200)
        let response = try JSONDecoder().decode(
            RemoteContinueSessionResponseDTO.self,
            from: accepted.body
        )
        XCTAssertEqual(response.sessionID, created.uuidString)
        XCTAssertEqual(sessionCommands.continuations.last?.sessionID, session.id)
        XCTAssertEqual(sessionCommands.continuations.last?.destination.kind, .claude)
        XCTAssertEqual(
            sessionCommands.continuations.last?.destination.accountHandle?.name,
            "work"
        )

        // The Mac's own bounded reason crosses the wire as a detail, so the phone words the
        // cause instead of showing an alert sentence written for a Mac.
        sessionCommands.continuationResult = .failure(.continuationRefused(.nothingRecorded))
        let refused = try XCTUnwrap(post(
            "/api/session/\(session.id.uuidString)/continuation",
            bearer: "goodtoken",
            body: try JSONEncoder().encode(
                RemoteContinueSessionRequestDTO(agentID: "claude")
            )
        ))
        XCTAssertEqual(refused.status, 409)
        XCTAssertEqual(
            try JSONDecoder().decode(RemoteErrorDTO.self, from: refused.body),
            RemoteErrorDTO(code: .continuationRefused, detail: "nothingRecorded")
        )

        sessionCommands.continuationResult = .failure(.destinationNotFound)
        XCTAssertEqual(
            try XCTUnwrap(post(
                "/api/session/\(session.id.uuidString)/continuation",
                bearer: "goodtoken",
                body: try JSONEncoder().encode(
                    RemoteContinueSessionRequestDTO(agentID: "claude", accountID: "gone")
                )
            )).status,
            422,
            "a login this Mac never offered is refused by the command that owns that list"
        )
    }

    /// The continuation catalogue is owner-only for the same reason the account catalogue is:
    /// it names the user's logins.
    func testGuestsCannotReadOrRequestAContinuation() throws {
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(
            "remote-session-continuation-guest-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporary) }
        let project = try XCTUnwrap(ProjectStore.shared.addProject(folderURL: temporary))
        let session = try XCTUnwrap(ProjectStore.shared.addSession(
            to: project.id,
            kind: .codex,
            usesNativeUI: true
        ))
        authority.set(RemoteAuthorization(
            shareID: "continuation-guest",
            capability: .interact,
            scope: .session(session.id),
            principal: .guest
        ), forToken: "continuationguest")

        let guestMe = try JSONDecoder().decode(
            RemoteMeDTO.self,
            from: try XCTUnwrap(get("/api/me", bearer: "continuationguest")).body
        )
        XCTAssertFalse(
            guestMe.features?.contains(RemoteRESTFeature.sessionContinuation.rawValue) ?? false,
            "a guest is never told the route exists, let alone allowed through it"
        )
        XCTAssertEqual(
            try XCTUnwrap(get(
                "/api/session/\(session.id.uuidString)/continuation",
                bearer: "continuationguest"
            )).status,
            403
        )
        XCTAssertEqual(
            try XCTUnwrap(post(
                "/api/session/\(session.id.uuidString)/continuation",
                bearer: "continuationguest",
                body: try JSONEncoder().encode(
                    RemoteContinueSessionRequestDTO(agentID: "claude")
                )
            )).status,
            403
        )
        XCTAssertTrue(sessionCommands.continuations.isEmpty)
    }

    func testSessionSettingsRoutesRejectMalformedOrUnsupportedChoices() throws {
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(
            "remote-session-control-validation-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporary) }
        let project = try XCTUnwrap(ProjectStore.shared.addProject(folderURL: temporary))
        let session = try XCTUnwrap(ProjectStore.shared.addSession(
            to: project.id,
            kind: .codex,
            usesNativeUI: true
        ))

        XCTAssertEqual(
            try XCTUnwrap(post(
                "/api/session/\(session.id.uuidString)/account",
                bearer: "goodtoken",
                body: Data(#"{"accountID":"../credentials"}"#.utf8)
            )).status,
            400
        )
        let futureRecovery = try JSONEncoder().encode(
            RemoteSetSessionLimitRecoveryRequestDTO(
                policy: .unknown(action: "futureAction", accountID: nil)
            )
        )
        XCTAssertEqual(
            try XCTUnwrap(post(
                "/api/session/\(session.id.uuidString)/limit-recovery",
                bearer: "goodtoken",
                body: futureRecovery
            )).status,
            400
        )
        XCTAssertEqual(
            try XCTUnwrap(post(
                "/api/session/\(session.id.uuidString)/continuation",
                bearer: "goodtoken",
                body: Data(#"{"agentID":"claude","accountID":"../credentials"}"#.utf8)
            )).status,
            400
        )
        XCTAssertEqual(
            try XCTUnwrap(post(
                "/api/session/\(session.id.uuidString)/continuation",
                bearer: "goodtoken",
                body: Data(#"{"agentID":"gemini"}"#.utf8)
            )).status,
            422,
            "a token naming no runtime this Mac has is refused at the boundary"
        )
        XCTAssertTrue(sessionCommands.accountMoves.isEmpty)
        XCTAssertTrue(sessionCommands.continuations.isEmpty)
        XCTAssertTrue(sessionAccess.limitRecoveryMutations.isEmpty)
    }

    func testDormantResumeFailsClosedWithoutApplicationCommands() throws {
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(
            "remote-session-no-commands-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporary) }
        let project = try XCTUnwrap(ProjectStore.shared.addProject(folderURL: temporary))
        let session = try XCTUnwrap(ProjectStore.shared.addSession(
            to: project.id,
            kind: .codex,
            usesNativeUI: false,
            title: "No application capability"
        ))
        server.sessionCommands = nil

        XCTAssertEqual(
            try XCTUnwrap(post(
                "/api/session/\(session.id.uuidString)/resume",
                bearer: "goodtoken",
                body: Data()
            )).status,
            503
        )
    }

    /// A fresh socket to a chat whose agent is not running is told so in words before the close.
    /// It used to get the 4004 close alone, which the phone read as a network drop and redialled
    /// every eight seconds: 474 attempts at one exited chat on 2026-09-19.
    func testAFreshSocketToAStoppedChatIsToldItIsDormantBeforeTheClose() throws {
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(
            "remote-session-dormant-socket-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporary) }
        let project = try XCTUnwrap(ProjectStore.shared.addProject(folderURL: temporary))
        let session = try XCTUnwrap(ProjectStore.shared.addSession(
            to: project.id,
            kind: .claude,
            usesNativeUI: false,
            title: "Stopped chat"
        ))
        let link = try XCTUnwrap(RemoteConnectionLink(
            baseURL: URL(string: "http://127.0.0.1:\(port!)")!,
            token: "goodtoken"
        ))
        let socketURL = try XCTUnwrap(link.webSocketURL(sessionID: session.id.uuidString))

        let task = URLSession.shared.webSocketTask(with: socketURL)
        task.resume()
        let auth = RemoteClientMessage(
            type: "auth",
            token: "goodtoken",
            device: "test-device",
            protocolVersion: RemoteProtocol.current,
            protocolMinimum: RemoteProtocol.minimumSupported
        )
        let authText = String(decoding: try JSONEncoder().encode(auth), as: UTF8.self)
        task.send(.string(authText)) { _ in }

        // The expectation orders the last append before the read.
        final class Frames: @unchecked Sendable { var texts: [String] = [] }
        let received = Frames()
        let closed = expectation(description: "the host closes the socket")
        @Sendable func receive() {
            task.receive { result in
                switch result {
                case .success(.string(let text)):
                    received.texts.append(text)
                    receive()
                case .success:
                    receive()
                case .failure:
                    closed.fulfill()
                }
            }
        }
        receive()
        wait(for: [closed], timeout: 5)
        let frames = received.texts

        XCTAssertEqual(task.closeCode.rawValue, 4004)
        let ended = try XCTUnwrap(frames.compactMap {
            try? JSONDecoder().decode(RemoteEndedDTO.self, from: Data($0.utf8))
        }.first { $0.type == "ended" }, "the refusal must say why before it closes")
        XCTAssertEqual(ended.reason, "sessionDormant")
    }

    func testStorageBlockedResumeReturnsItsCauseAndLeavesCatalogueReachable() throws {
        let project = try XCTUnwrap(ProjectStore.shared.addProject(
            folderURL: FileManager.default.temporaryDirectory
        ))
        let session = try XCTUnwrap(ProjectStore.shared.addSession(
            to: project.id, kind: .claude, usesNativeUI: false, title: "Blocked resume"
        ))
        sessionAccess.persistenceBlockReasonOverride = .storageExhausted
        for _ in 0..<3 {
            let response = try XCTUnwrap(post(
                "/api/session/\(session.id.uuidString)/resume",
                bearer: "goodtoken", body: Data()
            ))
            XCTAssertEqual(response.status, 503)
            XCTAssertEqual(
                try JSONDecoder().decode(RemoteErrorDTO.self, from: response.body),
                RemoteErrorDTO(code: .storageExhausted)
            )
        }
        XCTAssertTrue(sessionCommands.resumedSessionIDs.isEmpty)
        XCTAssertEqual(try XCTUnwrap(get("/api/me", bearer: "goodtoken")).status, 200)
    }

    func testStorageFailureDiscoveredDuringResumeIsNotAcceptedAsStarting() throws {
        let project = try XCTUnwrap(ProjectStore.shared.addProject(
            folderURL: FileManager.default.temporaryDirectory
        ))
        let session = try XCTUnwrap(ProjectStore.shared.addSession(
            to: project.id, kind: .claude, usesNativeUI: false, title: "Failed resume"
        ))
        sessionCommands.onResume = { [weak sessionAccess] in
            sessionAccess?.persistenceBlockReasonOverride = .storageExhausted
        }
        let response = try XCTUnwrap(post(
            "/api/session/\(session.id.uuidString)/resume",
            bearer: "goodtoken", body: Data()
        ))
        XCTAssertEqual(response.status, 503)
        XCTAssertEqual(
            try JSONDecoder().decode(RemoteErrorDTO.self, from: response.body),
            RemoteErrorDTO(code: .storageExhausted)
        )
        XCTAssertEqual(sessionCommands.resumedSessionIDs, [session.id])
    }

    func testStandaloneTerminalCatalogAndResumeHonorTypedCapabilityScope() throws {
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(
            "remote-project-terminal-\(UUID().uuidString)",
            isDirectory: true
        )
        let otherDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "remote-project-terminal-other-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: otherDirectory,
            withIntermediateDirectories: true
        )
        let project = try XCTUnwrap(ProjectStore.shared.addProject(folderURL: temporary))
        let otherProject = try XCTUnwrap(ProjectStore.shared.addProject(folderURL: otherDirectory))
        let terminal = try XCTUnwrap(ProjectStore.shared.addTerminal(to: project.id))
        ProjectStore.shared.updateTerminalLocation(otherDirectory.path, for: terminal.id)
        defer {
            ProjectTerminalRuntime.shared.discard(terminalID: terminal.id)
            _ = ProjectStore.shared.removeTerminal(id: terminal.id)
            _ = ProjectStore.shared.removeProject(id: project.id)
            _ = ProjectStore.shared.removeProject(id: otherProject.id)
            try? FileManager.default.removeItem(at: temporary)
            try? FileManager.default.removeItem(at: otherDirectory)
        }

        let ownerMe = try JSONDecoder().decode(
            RemoteMeDTO.self,
            from: try XCTUnwrap(get("/api/me", bearer: "goodtoken")).body
        )
        XCTAssertEqual(ownerMe.terminals?.filter { $0.id == terminal.id.uuidString }.count, 1)
        XCTAssertFalse(ownerMe.sessions.contains { $0.id == terminal.id.uuidString })
        let summary = try XCTUnwrap(ownerMe.terminals?.first { $0.id == terminal.id.uuidString })
        XCTAssertEqual(summary.projectName, project.name)
        XCTAssertEqual(summary.state, .dormant)
        XCTAssertFalse(summary.isAvailable)

        authority.set(RemoteAuthorization(
            shareID: "terminal-view",
            capability: .view,
            scope: .projectTerminal(terminal.id),
            principal: .guest
        ), forToken: "terminalview")
        let guestMe = try JSONDecoder().decode(
            RemoteMeDTO.self,
            from: try XCTUnwrap(get("/api/me", bearer: "terminalview")).body
        )
        XCTAssertEqual(guestMe.share.scope, .terminal)
        XCTAssertTrue(guestMe.sessions.isEmpty)
        XCTAssertEqual(guestMe.terminals?.map(\.id), [terminal.id.uuidString])
        XCTAssertEqual(
            try XCTUnwrap(post(
                "/api/terminal/\(terminal.id.uuidString)/resume",
                bearer: "terminalview",
                body: Data()
            )).status,
            403,
            "view-only terminal links cannot start a shell"
        )

        authority.set(RemoteAuthorization(
            shareID: "terminal-control",
            capability: .interact,
            scope: .projectTerminal(terminal.id),
            principal: .guest
        ), forToken: "terminalcontrol")
        XCTAssertEqual(
            try XCTUnwrap(post(
                "/api/terminal/\(terminal.id.uuidString)/resume",
                bearer: "terminalcontrol",
                body: Data()
            )).status,
            202
        )
        XCTAssertEqual(sessionCommands.resumedTerminalIDs, [terminal.id])
        XCTAssertEqual(
            try XCTUnwrap(post(
                "/api/terminal/\(TerminalID().uuidString)/resume",
                bearer: "terminalcontrol",
                body: Data()
            )).status,
            404,
            "one terminal capability must not discover or control another terminal"
        )

        // Minting a link is an owner action, and the two ways of asking for an impossible one
        // are told apart here exactly as they are for a chat: an unreadable body is the
        // client's mistake, an unknown role is a request the host understood and refused.
        XCTAssertEqual(
            try XCTUnwrap(post(
                "/api/terminal/\(terminal.id.uuidString)/share",
                bearer: "terminalcontrol",
                body: try JSONEncoder().encode(
                    RemoteCreateShareRequestDTO(capability: .view)
                )
            )).status,
            403,
            "a terminal capability cannot create another share"
        )
        XCTAssertEqual(
            try XCTUnwrap(post(
                "/api/terminal/\(terminal.id.uuidString)/share",
                bearer: "goodtoken",
                body: Data()
            )).status,
            400
        )
        XCTAssertEqual(
            try XCTUnwrap(post(
                "/api/terminal/\(terminal.id.uuidString)/share",
                bearer: "goodtoken",
                body: Data(#"{"capability":"administrator"}"#.utf8)
            )).status,
            400
        )
    }

    @MainActor
    func testThemeBridgeSendsEveryResolvedChromeRoleAndFullANSIPalette() {
        let chrome = RemoteThemeBridge.appTheme()
        XCTAssertEqual(
            Set(chrome.colors.keys),
            Set(AppThemeRole.allCases.map(\.wireName))
        )
        XCTAssertTrue(chrome.colors.values.allSatisfy { $0.hasPrefix("#") })
        XCTAssertTrue([RemoteThemeMode.light, .dark].contains(chrome.mode))
        XCTAssertNotNil(chrome.material.textScale)

        let terminal = RemoteThemeBridge.terminalTheme(for: SessionID())
        XCTAssertEqual(terminal.ansi.count, 16)
        XCTAssertTrue(terminal.ansi.allSatisfy { $0.hasPrefix("#") })
        XCTAssertTrue(terminal.foreground.hasPrefix("#"))
        XCTAssertTrue(terminal.background.hasPrefix("#"))

        let catalog = RemoteThemeBridge.catalog()
        XCTAssertFalse(catalog.appThemes.isEmpty)
        XCTAssertFalse(catalog.terminalThemes.isEmpty)
        XCTAssertTrue(catalog.terminalThemes.allSatisfy { $0.ansi.count == 16 })
    }

    @MainActor
    func testInteractiveOwnerReceivesThemeChoicesButViewOnlyShareCannotChangeThem() throws {
        let meProbe = try XCTUnwrap(get("/api/me", bearer: "goodtoken"))
        let me = try JSONDecoder().decode(RemoteMeDTO.self, from: meProbe.body)
        XCTAssertFalse(try XCTUnwrap(me.themeCatalog).appThemes.isEmpty)
        let launchCatalog = try XCTUnwrap(me.newSessionCatalog)
        XCTAssertTrue(launchCatalog.agents.allSatisfy { !($0.accounts ?? []).isEmpty })

        let responseText = String(decoding: meProbe.body, as: UTF8.self)
        for kind in AgentKind.allCases {
            for account in AgentAccountDiscovery.accounts(for: kind) {
                XCTAssertFalse(responseText.contains(account.configPath))
            }
        }

        authority.set(
            RemoteAuthorization(shareID: "view", capability: .view, scope: .allSessions),
            forToken: "viewtoken"
        )
        let body = try JSONEncoder().encode(RemoteSetAppThemeRequestDTO(themeID: "system"))
        XCTAssertEqual(
            try XCTUnwrap(post("/api/theme", bearer: "viewtoken", body: body)).status,
            403
        )
        XCTAssertTrue(settingsMutator.appThemeIDs.isEmpty)
        XCTAssertEqual(
            try XCTUnwrap(post("/api/theme", bearer: "goodtoken", body: body)).status,
            200
        )
        XCTAssertEqual(settingsMutator.appThemeIDs, [AppThemeID("system")])
        XCTAssertTrue(eventRecorder.messages.contains("App theme changed remotely"))
        let create = try JSONEncoder().encode(RemoteCreateSessionRequestDTO(
            projectID: UUID().uuidString,
            agentKind: "codex",
            surface: .conversation,
            prompt: "Do work"
        ))
        XCTAssertEqual(
            try XCTUnwrap(post("/api/session", bearer: "viewtoken", body: create)).status,
            403
        )
    }

    /// Exercises the native iOS mutation shape against the shipping Mac settings mutator.
    /// Recording the requested id alone is not enough: that fake would pass without proving that
    /// the host actually installed or returned a phone's second selection.
    @MainActor
    func testIOSCanApplyTwoSuccessiveAppThemesToTheMac() throws {
        let previousTheme = AppThemeLibrary.current
        defer { AppThemeLibrary.apply(previousTheme) }
        AppThemeLibrary.apply(.system)
        settingsMutator.appliesAppThemesToHost = true

        let firstTheme = AppThemeStyles.threading
        let secondTheme = AppTheme.system
        let clientHeaders = [
            "X-Threading-Client": "Threading-iOS",
            "X-Threading-Protocol": String(RemoteProtocol.current),
            "X-Threading-Protocol-Min": String(RemoteProtocol.minimumSupported),
        ]
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]

        func select(_ theme: AppTheme, requestID: String) throws -> RemoteMeDTO {
            var headers = clientHeaders
            headers["X-Threading-Request-ID"] = requestID
            let response = try XCTUnwrap(post(
                "/api/theme",
                bearer: "goodtoken",
                body: try encoder.encode(
                    RemoteSetAppThemeRequestDTO(themeID: theme.id.rawValue)
                ),
                headers: headers
            ))
            XCTAssertEqual(response.status, 200)
            XCTAssertEqual(
                response.headers["X-Threading-Request-ID"] as? String,
                requestID
            )
            return try JSONDecoder().decode(RemoteMeDTO.self, from: response.body)
        }

        let first = try select(firstTheme, requestID: "ios-theme-request-1")
        XCTAssertEqual(AppThemeLibrary.current.id, firstTheme.id)
        XCTAssertEqual(first.theme?.id, firstTheme.id.rawValue)

        let second = try select(secondTheme, requestID: "ios-theme-request-2")
        XCTAssertEqual(AppThemeLibrary.current.id, secondTheme.id)
        XCTAssertEqual(second.theme?.id, secondTheme.id.rawValue)
        XCTAssertEqual(
            settingsMutator.appThemeIDs,
            [firstTheme.id, secondTheme.id],
            "a new iOS request id must perform the second selection, not replay the first"
        )
        XCTAssertEqual(
            eventRecorder.messages.filter { $0 == "App theme changed remotely" }.count,
            2
        )
    }

    func testAppSettingMutationProjectsDescriptorPolicyAndFailsClosed() throws {
        let focused = Data(#"{"value":"focusedOwner"}"#.utf8)
        authority.set(
            RemoteAuthorization(shareID: "view", capability: .view, scope: .allSessions),
            forToken: "viewtoken"
        )

        XCTAssertEqual(
            try XCTUnwrap(post(
                "/api/settings/remoteInputControlDefault",
                bearer: "viewtoken",
                body: focused
            )).status,
            403
        )
        XCTAssertTrue(settingsMutator.appSettingMutations.isEmpty)

        XCTAssertEqual(
            try XCTUnwrap(post(
                "/api/settings/remoteInputControlDefault",
                bearer: "goodtoken",
                body: focused
            )).status,
            200
        )
        XCTAssertEqual(appSettings.remoteInputControlDefault, .focusedOwner)

        XCTAssertEqual(
            try XCTUnwrap(post(
                "/api/settings/remoteAccessEnabled",
                bearer: "goodtoken",
                body: Data(#"{"value":true}"#.utf8)
            )).status,
            403,
            "transport lifecycle changes must stay behind coordinator sequencing"
        )
        XCTAssertFalse(appSettings.remoteAccessEnabled)

        XCTAssertEqual(
            try XCTUnwrap(post(
                "/api/settings/githubAppClientID",
                bearer: "goodtoken",
                body: Data(#"{"value":"client"}"#.utf8)
            )).status,
            403
        )
        XCTAssertEqual(appSettings.githubAppClientID, "")

        XCTAssertEqual(
            try XCTUnwrap(post(
                "/api/settings/remoteInputControlDefualt",
                bearer: "goodtoken",
                body: focused
            )).status,
            404
        )
        XCTAssertEqual(
            try XCTUnwrap(post(
                "/api/settings/remoteInputControlDefault",
                bearer: "goodtoken",
                body: Data(#"{"value":true}"#.utf8)
            )).status,
            422
        )
        XCTAssertEqual(
            try XCTUnwrap(post(
                "/api/settings/remoteInputControlDefault",
                bearer: "goodtoken",
                body: Data(#"{"value":"invented"}"#.utf8)
            )).status,
            422
        )
        XCTAssertTrue(eventRecorder.messages.contains("App setting changed remotely"))
        // The journal row names which setting moved and who moved it. Both are typed fields, so
        // this is the route filing them rather than a dictionary literal agreeing with itself.
        XCTAssertEqual(
            eventRecorder.detail(for: "App setting changed remotely")?[.setting],
            "remoteInputControlDefault"
        )
        XCTAssertNotNil(eventRecorder.detail(for: "App setting changed remotely")?[.device])
    }

    func testUsageIsAdvertisedAndReadableOnlyToWholeHostOwner() throws {
        let meProbe = try XCTUnwrap(get("/api/me", bearer: "goodtoken"))
        let me = try JSONDecoder().decode(RemoteMeDTO.self, from: meProbe.body)
        // Membership, not the whole list. This test is about who may be told that usage exists,
        // and pinning the exact array made it fail the moment an unrelated feature was added that
        // every principal legitimately gets — saying "usage leaked" when nothing about usage had
        // changed. What must hold is that the owner is told, and below, that a guest is not.
        XCTAssertEqual(
            me.features?.contains(RemoteRESTFeature.usageDashboard.rawValue),
            true,
            "The whole-host owner is the one principal that may be told the dashboard exists"
        )
        XCTAssertEqual(me.features?.contains(RemoteRESTFeature.usageCapacity.rawValue), true)
        let capacityProbe = try XCTUnwrap(get("/api/usage/capacity", bearer: "goodtoken"))
        XCTAssertEqual(capacityProbe.status, 200)
        let capacity = try RemoteUsageCapacityDTO.decode(capacityProbe.body)
        XCTAssertEqual(capacity.accounts.first?.observedAt, 1_780_000_000)
        XCTAssertEqual(capacity.revision, 7)

        let overviewProbe = try XCTUnwrap(get("/api/usage?limit=1", bearer: "goodtoken"))
        XCTAssertEqual(overviewProbe.status, 200)
        let overview = try JSONDecoder().decode(
            RemoteUsageDashboardDTO.self,
            from: overviewProbe.body
        )
        XCTAssertEqual(overview.limitSeries.map(\.id), ["codex|personal|weekly"])
        XCTAssertLessThanOrEqual(
            overviewProbe.body.count,
            RemoteUsageBridge.maximumOverviewResponseBytes
        )

        let detailProbe = try XCTUnwrap(get(
            "/api/usage/limit?series=codex%7Cpersonal%7Cweekly&days=30",
            bearer: "goodtoken"
        ))
        XCTAssertEqual(detailProbe.status, 200)
        let detail = try JSONDecoder().decode(RemoteUsageLimitDTO.self, from: detailProbe.body)
        XCTAssertEqual(detail.series.bankedResetCount, 2)
        XCTAssertLessThanOrEqual(
            detailProbe.body.count,
            RemoteUsageBridge.maximumLimitResponseBytes
        )

        let sessionID = SessionID()
        authority.set(
            RemoteAuthorization(
                shareID: "view-guest",
                capability: .view,
                scope: .session(sessionID),
                principal: .guest
            ),
            forToken: "viewguesttoken"
        )
        authority.set(
            RemoteAuthorization(
                shareID: "interact-guest",
                capability: .interact,
                scope: .session(sessionID),
                principal: .guest
            ),
            forToken: "interactguesttoken"
        )
        for token in ["viewguesttoken", "interactguesttoken"] {
            XCTAssertEqual(try XCTUnwrap(get("/api/usage/capacity", bearer: token)).status, 403)
            XCTAssertEqual(try XCTUnwrap(get("/api/usage", bearer: token)).status, 403)
            let guestMe = try JSONDecoder().decode(
                RemoteMeDTO.self,
                from: try XCTUnwrap(get("/api/me", bearer: token)).body
            )
            XCTAssertFalse(
                guestMe.features?.contains(RemoteRESTFeature.usageDashboard.rawValue) ?? false,
                "A guest share must never be told the usage dashboard exists"
            )
            XCTAssertFalse(guestMe.features?.contains(RemoteRESTFeature.usageCapacity.rawValue) ?? false)
        }
        XCTAssertEqual(try XCTUnwrap(get("/api/usage", bearer: "revoked")).status, 401)
        XCTAssertEqual(try XCTUnwrap(get("/api/usage/capacity", bearer: "revoked")).status, 401)
    }

    func testBankedUsageResetRequiresManagingOwnerAndReplaysOneMutation() throws {
        let offer = RemoteBankedUsageResetOfferDTO(
            seriesID: "codex|personal|weekly",
            accountName: "Personal",
            availableCount: 2,
            offerFingerprint: String(repeating: "a", count: 64),
            selectedCreditTitle: "Reset credit",
            selectedCreditExpiresAt: 300,
            letsProviderChooseCredit: false,
            eligibleWindowLabels: ["Weekly"],
            owedContinuationCount: 1
        )
        server.usageResetOfferLoader = { seriesID in
            seriesID == offer.seriesID ? offer : nil
        }
        var consumeCount = 0
        server.usageResetConsumer = { request, idempotencyKey in
            consumeCount += 1
            XCTAssertEqual(request.seriesID, offer.seriesID)
            XCTAssertEqual(idempotencyKey, "reset-request-one")
            return RemoteBankedUsageResetResponseDTO(
                outcome: .reset,
                remainingCreditCount: 1,
                releasedContinuationCount: 1,
                hasVerifiedHeadroom: true,
                continuationReleaseFailed: false
            )
        }

        let prepared = try XCTUnwrap(get(
            "/api/usage/reset?series=codex%7Cpersonal%7Cweekly",
            bearer: "goodtoken"
        ))
        XCTAssertEqual(prepared.status, 200)
        XCTAssertEqual(
            try JSONDecoder().decode(RemoteBankedUsageResetOfferDTO.self, from: prepared.body),
            offer
        )

        authority.set(
            RemoteAuthorization(
                shareID: "view-owner",
                capability: .view,
                scope: .allSessions,
                principal: .ownerDevice
            ),
            forToken: "viewownertoken"
        )
        XCTAssertEqual(try XCTUnwrap(get(
            "/api/usage/reset?series=codex%7Cpersonal%7Cweekly",
            bearer: "viewownertoken"
        )).status, 403)

        let request = RemoteBankedUsageResetRequestDTO(
            seriesID: offer.seriesID,
            availableCount: offer.availableCount,
            offerFingerprint: offer.offerFingerprint,
            letsProviderChooseCredit: false
        )
        let body = try JSONEncoder().encode(request)
        let headers = ["X-Threading-Request-ID": "reset-request-one"]
        let first = try XCTUnwrap(post(
            "/api/usage/reset",
            bearer: "goodtoken",
            body: body,
            headers: headers
        ))
        let replay = try XCTUnwrap(post(
            "/api/usage/reset",
            bearer: "goodtoken",
            body: body,
            headers: headers
        ))

        XCTAssertEqual(first.status, 200)
        XCTAssertEqual(replay.status, 200)
        XCTAssertEqual(first.body, replay.body)
        XCTAssertEqual(consumeCount, 1)
    }

    func testUniversalSearchIsAdvertisedAndRoutedOnlyForWholeHostOwners() throws {
        server.universalSearchLoader = { request, deviceID in
            XCTAssertEqual(deviceID, "test-device")
            return RemoteSearchResponseDTO(
                generation: request.generation,
                groups: [RemoteSearchGroupResultDTO(
                    group: .destinations,
                    hits: [RemoteSearchHitDTO(
                        id: "result-1",
                        token: "opaque-token",
                        group: .destinations,
                        kind: .project,
                        title: "Threading",
                        snippet: nil,
                        provenance: RemoteSearchProvenanceDTO(projectName: "Threading")
                    )],
                    coverage: [RemoteSearchCoverageDTO(kind: .complete)],
                    isCapped: false
                )],
                isComplete: true
            )
        }
        server.universalSearchResolver = { token, deviceID in
            XCTAssertEqual(token, "opaque-token")
            XCTAssertEqual(deviceID, "test-device")
            return RemoteSearchResolutionDTO(kind: .project, projectName: "Threading")
        }

        let ownerMe = try JSONDecoder().decode(
            RemoteMeDTO.self,
            from: try XCTUnwrap(get("/api/me", bearer: "goodtoken")).body
        )
        XCTAssertTrue(
            ownerMe.features?.contains(RemoteRESTFeature.universalSearch.rawValue) ?? false
        )

        let request = RemoteSearchRequestDTO(query: "thread", generation: 17)
        let search = try XCTUnwrap(post(
            RemoteRouter.searchPath,
            bearer: "goodtoken",
            body: try JSONEncoder().encode(request)
        ))
        XCTAssertEqual(search.status, 200)
        let response = try JSONDecoder().decode(RemoteSearchResponseDTO.self, from: search.body)
        XCTAssertEqual(response.generation, 17)
        XCTAssertEqual(response.groups.first?.hits.first?.token, "opaque-token")
        XCTAssertLessThanOrEqual(search.body.count, RemoteAccessDefaults.maximumSearchResponseBytes)

        let resolution = try XCTUnwrap(post(
            RemoteRouter.searchResolvePath,
            bearer: "goodtoken",
            body: try JSONEncoder().encode(RemoteSearchResolveRequestDTO(token: "opaque-token"))
        ))
        XCTAssertEqual(resolution.status, 200)
        XCTAssertEqual(
            try JSONDecoder().decode(RemoteSearchResolutionDTO.self, from: resolution.body),
            RemoteSearchResolutionDTO(kind: .project, projectName: "Threading")
        )

        let guestSessionID = SessionID()
        authority.set(
            RemoteAuthorization(
                shareID: "search-guest",
                capability: .interact,
                scope: .session(guestSessionID),
                principal: .guest
            ),
            forToken: "searchguesttoken"
        )
        let guestMe = try JSONDecoder().decode(
            RemoteMeDTO.self,
            from: try XCTUnwrap(get("/api/me", bearer: "searchguesttoken")).body
        )
        XCTAssertFalse(
            guestMe.features?.contains(RemoteRESTFeature.universalSearch.rawValue) ?? false
        )
        XCTAssertEqual(
            try XCTUnwrap(post(
                RemoteRouter.searchPath,
                bearer: "searchguesttoken",
                body: try JSONEncoder().encode(request)
            )).status,
            404,
            "a guest must not even learn that the whole-host search route exists"
        )
        XCTAssertEqual(
            try XCTUnwrap(post(
                RemoteRouter.searchResolvePath,
                bearer: "searchguesttoken",
                body: try JSONEncoder().encode(RemoteSearchResolveRequestDTO(
                    token: "opaque-token"
                ))
            )).status,
            404
        )
    }

    func testUniversalSearchRechecksRevocationBeforeReturningData() throws {
        server.universalSearchLoader = { request, _ in
            self.authority.set(nil, forToken: "goodtoken")
            return RemoteSearchResponseDTO(
                generation: request.generation,
                groups: [],
                isComplete: true
            )
        }
        defer {
            authority.set(
                RemoteAuthorization(
                    shareID: "test",
                    capability: .interact,
                    scope: .allSessions
                ),
                forToken: "goodtoken"
            )
        }

        let response = try XCTUnwrap(post(
            RemoteRouter.searchPath,
            bearer: "goodtoken",
            body: try JSONEncoder().encode(RemoteSearchRequestDTO(
                query: "secret",
                generation: 1
            ))
        ))
        XCTAssertEqual(response.status, 401)

        authority.set(
            RemoteAuthorization(
                shareID: "test",
                capability: .interact,
                scope: .allSessions
            ),
            forToken: "goodtoken"
        )
        server.universalSearchResolver = { token, _ in
            XCTAssertEqual(token, "opaque-token")
            self.authority.set(nil, forToken: "goodtoken")
            return RemoteSearchResolutionDTO(kind: .project, projectName: "Threading")
        }
        let resolution = try XCTUnwrap(post(
            RemoteRouter.searchResolvePath,
            bearer: "goodtoken",
            body: try JSONEncoder().encode(RemoteSearchResolveRequestDTO(
                token: "opaque-token"
            ))
        ))
        XCTAssertEqual(resolution.status, 401)
    }

    func testGuestShareCannotManageSessionLifecycle() throws {
        let sessionID = SessionID()
        authority.set(
            RemoteAuthorization(
                shareID: "guest",
                capability: .interact,
                scope: .session(sessionID)
            ),
            forToken: "guesttoken"
        )
        let pin = try JSONEncoder().encode(RemoteSetSessionPinnedRequestDTO(isPinned: true))
        XCTAssertEqual(
            try XCTUnwrap(post(
                "/api/session/\(sessionID.uuidString)/pinned",
                bearer: "guesttoken",
                body: pin
            )).status,
            403
        )
        let surface = try JSONEncoder().encode(
            RemoteSetSessionSurfaceRequestDTO(surface: .conversation)
        )
        XCTAssertEqual(
            try XCTUnwrap(post(
                "/api/session/\(sessionID.uuidString)/surface",
                bearer: "guesttoken",
                body: surface
            )).status,
            403
        )
        XCTAssertEqual(
            try XCTUnwrap(post(
                "/api/session/\(sessionID.uuidString)/account",
                bearer: "guesttoken",
                body: try JSONEncoder().encode(
                    RemoteMoveSessionAccountRequestDTO(accountID: "work")
                )
            )).status,
            403
        )
        XCTAssertEqual(
            try XCTUnwrap(post(
                "/api/session/\(sessionID.uuidString)/limit-recovery",
                bearer: "guesttoken",
                body: try JSONEncoder().encode(
                    RemoteSetSessionLimitRecoveryRequestDTO(policy: .waitForReset)
                )
            )).status,
            403
        )
        let snooze = try JSONEncoder().encode(
            RemoteSetSessionSnoozeRequestDTO(snoozedUntil: Date().timeIntervalSince1970 + 3_600)
        )
        XCTAssertEqual(
            try XCTUnwrap(post(
                "/api/session/\(sessionID.uuidString)/snoozed",
                bearer: "guesttoken",
                body: snooze
            )).status,
            403
        )
        let share = try JSONEncoder().encode(
            RemoteCreateShareRequestDTO(capability: .view)
        )
        XCTAssertEqual(
            try XCTUnwrap(post(
                "/api/session/\(sessionID.uuidString)/share",
                bearer: "guesttoken",
                body: share
            )).status,
            403
        )
        XCTAssertEqual(
            try XCTUnwrap(post(
                "/api/session/\(sessionID.uuidString)/unshare",
                bearer: "guesttoken",
                body: try JSONEncoder().encode(RemoteRevokeSharesRequestDTO())
            )).status,
            403
        )
        XCTAssertEqual(
            try XCTUnwrap(get(
                "/api/session/\(sessionID.uuidString)/git-review/unstaged",
                bearer: "guesttoken"
            )).status,
            403,
            "sharing one conversation must not expose its whole checkout"
        )
        XCTAssertEqual(
            try XCTUnwrap(get(
                "/api/session/\(sessionID.uuidString)/repository-files",
                bearer: "guesttoken"
            )).status,
            403
        )
        XCTAssertEqual(
            try XCTUnwrap(get(
                "/api/session/\(sessionID.uuidString)/attachments",
                bearer: "guesttoken"
            )).status,
            403
        )
        XCTAssertEqual(
            try XCTUnwrap(get(
                "/api/session/\(sessionID.uuidString)/attachment?id=attachment-1",
                bearer: "guesttoken"
            )).status,
            403
        )
        XCTAssertEqual(
            try XCTUnwrap(get(
                "/api/session/\(sessionID.uuidString)/attachment-thumbnail?id=attachment-1",
                bearer: "guesttoken"
            )).status,
            403,
            "a thumbnail is gated exactly like the attachment it shrinks"
        )
        XCTAssertEqual(
            try XCTUnwrap(get(
                "/api/session/\(sessionID.uuidString)/workspace",
                bearer: "guesttoken"
            )).status,
            403,
            "sharing one conversation must not expose browser metadata"
        )
        XCTAssertEqual(
            try XCTUnwrap(get(
                "/api/session/\(sessionID.uuidString)/browser-preview?tab=\(UUID().uuidString)",
                bearer: "guesttoken"
            )).status,
            403,
            "sharing one conversation must not expose browser pixels"
        )
        let panelPath = "/api/session/\(sessionID.uuidString)/extension-panel?extension=codes.threading.progress&panel=build-status"
        XCTAssertEqual(
            try XCTUnwrap(get(panelPath, bearer: "guesttoken")).status,
            403,
            "sharing one conversation must not expose extension panel state"
        )
        XCTAssertEqual(
            try XCTUnwrap(get(
                "/api/session/\(sessionID.uuidString)/extension-panel-resource?extension=codes.threading.progress&panel=build-status&path=Images%2Fstatus.png",
                bearer: "guesttoken"
            )).status,
            403,
            "sharing one conversation must not expose extension package resources"
        )
        XCTAssertEqual(
            try XCTUnwrap(post(
                panelPath,
                bearer: "guesttoken",
                body: Data(#"{"processGeneration":"generation-1","actionID":"refresh"}"#.utf8)
            )).status,
            403,
            "sharing one conversation must not invoke extension actions"
        )
    }

    func testGuestPermissionApprovalIsAnIndependentChatRight() {
        let sessionID = SessionID()
        let terminalID = TerminalID(sessionID.rawValue)
        let guest = RemoteAuthorization(
            shareID: "guest",
            capability: .interact,
            scope: .session(sessionID),
            principal: .guest
        )
        let trustedGuest = RemoteAuthorization(
            shareID: "trusted-guest",
            capability: .interact,
            scope: .session(sessionID),
            principal: .guest,
            canApprovePermissions: true
        )
        let owner = RemoteAuthorization(
            shareID: "owner",
            capability: .interact,
            scope: .allSessions,
            principal: .ownerDevice
        )
        let terminalGuest = RemoteAuthorization(
            shareID: "terminal-guest",
            capability: .interact,
            scope: .projectTerminal(terminalID),
            principal: .guest,
            canApprovePermissions: true
        )

        XCTAssertTrue(guest.scope.covers(sessionID))
        XCTAssertFalse(guest.canApprovePermissions)
        XCTAssertFalse(guest.canManageHost)
        XCTAssertFalse(guest.canReadHostUsage)
        XCTAssertTrue(trustedGuest.canApprovePermissions)
        XCTAssertFalse(trustedGuest.canManageHost)
        XCTAssertFalse(trustedGuest.canReadHostUsage)
        XCTAssertTrue(owner.canApprovePermissions)
        XCTAssertTrue(owner.canManageHost)
        XCTAssertTrue(owner.canReadHostUsage)
        XCTAssertTrue(terminalGuest.scope.covers(terminalID))
        XCTAssertFalse(
            terminalGuest.scope.covers(sessionID),
            "equal UUID bytes must not collapse terminal and chat authority"
        )
        XCTAssertFalse(terminalGuest.canManageHost)
        XCTAssertFalse(terminalGuest.canReadHostUsage)
        XCTAssertFalse(
            terminalGuest.canApprovePermissions,
            "terminal capabilities never inherit an AI permission surface"
        )
    }

    func testGuestPermissionProjectionIsVisibleButNotActionable() {
        let guest = RemoteAuthorization(
            shareID: "guest",
            capability: .interact,
            scope: .session(SessionID()),
            principal: .guest
        )
        let original = RemoteConversationSnapshotDTO(
            rows: [],
            canSend: true,
            permission: RemotePermissionRequestDTO(
                id: "permission-1",
                toolName: "Edit",
                summary: "Change a file"
            )
        )
        let projected = RemoteConversationWirePolicy.authorized(original, for: guest)

        XCTAssertTrue(projected.canSend, "collaboration and approval are separate rights")
        XCTAssertFalse(projected.permission?.canDecide ?? true)
        XCTAssertEqual(
            projected.permission?.unavailableReason,
            "You don’t have permission to approve requests in this chat."
        )
    }

    func testTrustedGuestPermissionProjectionIsActionable() {
        let sessionID = SessionID()
        let trustedGuest = RemoteAuthorization(
            shareID: "trusted",
            capability: .interact,
            scope: .session(sessionID),
            principal: .guest,
            member: RemoteMember(
                id: "member-1",
                displayName: "Kalle",
                deviceID: "kalles-phone"
            ),
            canApprovePermissions: true
        )
        let projected = RemoteConversationWirePolicy.authorized(
            RemoteConversationSnapshotDTO(
                rows: [],
                canSend: true,
                permission: RemotePermissionRequestDTO(
                    id: "permission-1",
                    toolName: "Edit",
                    summary: "Change a file"
                )
            ),
            for: trustedGuest
        )

        XCTAssertTrue(projected.permission?.canDecide ?? false)
        XCTAssertNil(projected.permission?.unavailableReason)
        XCTAssertFalse(trustedGuest.canManageHost)
    }

    func testDeviceBoundMembershipRejectsAnotherDevice() throws {
        authority.set(
            RemoteAuthorization(
                shareID: "member",
                capability: .interact,
                scope: .session(SessionID()),
                principal: .guest,
                member: RemoteMember(
                    id: "member",
                    displayName: "Kalle",
                    deviceID: "kalles-phone"
                )
            ),
            forToken: "boundtoken"
        )
        XCTAssertEqual(
            try XCTUnwrap(get("/api/me", bearer: "boundtoken")).status,
            401
        )
    }

    func testViewOnlyProjectionCannotSendWithoutAPermissionCard() {
        let viewer = RemoteAuthorization(
            shareID: "viewer",
            capability: .view,
            scope: .session(SessionID()),
            principal: .guest
        )
        let projected = RemoteConversationWirePolicy.authorized(
            RemoteConversationSnapshotDTO(
                rows: [],
                canSend: true,
                composerCapabilities: [RemoteComposerCapabilityDTO(
                    id: "codex.skill:release",
                    name: "release",
                    displayName: "Release",
                    description: "Private project release workflow",
                    argumentHint: "",
                    kind: .skill,
                    trigger: .dollar,
                    presentation: .turn
                )]
            ),
            for: viewer
        )

        XCTAssertFalse(projected.canSend)
        XCTAssertTrue(
            projected.composerCapabilities.isEmpty,
            "A view-only share does not need project capability metadata"
        )
        XCTAssertNil(projected.permission)
    }

    func testExpiredCapabilityIsRejected() throws {
        authority.set(
            RemoteAuthorization(
                shareID: "expired",
                capability: .view,
                scope: .session(SessionID()),
                principal: .guest,
                expiresAt: Date(timeIntervalSinceNow: -1)
            ),
            forToken: "expiredtoken"
        )
        XCTAssertEqual(
            try XCTUnwrap(get("/api/me", bearer: "expiredtoken")).status,
            401
        )
    }

    func testNotificationRegistrationIsAuthenticatedAndValidatesDeviceToken() throws {
        authority.set(
            RemoteAuthorization(
                shareID: "notification-test",
                capability: .interact,
                scope: .allSessions,
                boundDeviceID: "test-device"
            ),
            forToken: "notificationtoken"
        )
        let valid = try JSONEncoder().encode(RemoteNotificationRegistrationDTO(
            deviceToken: String(repeating: "ab", count: 32),
            environment: .sandbox,
            enabledKinds: [.permissionRequest, .agentMessage]
        ))
        let registered = try XCTUnwrap(post(
            RemoteRouter.notificationRegistrationPath,
            bearer: "notificationtoken",
            body: valid
        ))
        XCTAssertEqual(registered.status, 200)
        let response = try JSONDecoder().decode(
            RemoteNotificationRegistrationResponseDTO.self,
            from: registered.body
        )
        XCTAssertTrue([.live, .push].contains(response.delivery))

        let invalid = try JSONEncoder().encode(RemoteNotificationRegistrationDTO(
            deviceToken: "../../not-a-token",
            environment: .sandbox,
            enabledKinds: [.permissionRequest]
        ))
        XCTAssertEqual(
            try XCTUnwrap(post(
                RemoteRouter.notificationRegistrationPath,
                bearer: "notificationtoken",
                body: invalid
            )).status,
            422
        )
    }

    func testDiagnosticUploadIsOwnerOnlyTypedAndBounded() throws {
        let timestamp = ISO8601DateFormatter().string(from: Date())
        let record = RemoteDiagnosticRecord(
            timestamp: timestamp,
            source: .iOSClient,
            level: .error,
            event: .socketFailed,
            fields: ["code": "url.-1009"]
        )
        let valid = try JSONEncoder().encode(
            RemoteDiagnosticUploadRequestDTO(source: .iOSClient, records: [record])
        )
        var receivedSource: RemoteDiagnosticSource?
        var receivedDevice: String?
        server.receiveClientDiagnostics = { records, source, device in
            receivedSource = source
            receivedDevice = device
            return records == [record]
        }

        let accepted = try XCTUnwrap(post(
            RemoteRouter.diagnosticUploadPath,
            bearer: "goodtoken",
            body: valid,
            headers: ["X-Threading-Client": "Threading-iOS"]
        ))
        XCTAssertEqual(accepted.status, 200)
        XCTAssertEqual(
            try JSONDecoder().decode(
                RemoteDiagnosticUploadResponseDTO.self,
                from: accepted.body
            ).acceptedRecords,
            1
        )
        XCTAssertEqual(receivedSource, .iOSClient)
        XCTAssertEqual(receivedDevice, "test-device")

        XCTAssertEqual(
            try XCTUnwrap(post(
                RemoteRouter.diagnosticUploadPath,
                bearer: "goodtoken",
                body: valid,
                headers: ["X-Threading-Client": "Threading-Web"]
            )).status,
            400,
            "the shipping client header must agree with the record source"
        )

        XCTAssertEqual(
            try XCTUnwrap(post(
                RemoteRouter.diagnosticUploadPath,
                bearer: "goodtoken",
                body: valid
            )).status,
            400,
            "a source must be tied to a known shipping client"
        )

        authority.set(
            RemoteAuthorization(
                shareID: "guest",
                capability: .interact,
                scope: .session(SessionID())
            ),
            forToken: "guesttoken"
        )
        XCTAssertEqual(
            try XCTUnwrap(post(
                RemoteRouter.diagnosticUploadPath,
                bearer: "guesttoken",
                body: valid,
                headers: ["X-Threading-Client": "Threading-iOS"]
            )).status,
            403
        )

        let rawField = RemoteDiagnosticRecord(
            timestamp: timestamp,
            source: .iOSClient,
            level: .error,
            event: .socketFailed,
            fields: ["message": "terminal contents"]
        )
        XCTAssertEqual(
            try XCTUnwrap(post(
                RemoteRouter.diagnosticUploadPath,
                bearer: "goodtoken",
                body: try JSONEncoder().encode(
                    RemoteDiagnosticUploadRequestDTO(
                        source: .iOSClient,
                        records: [rawField]
                    )
                ),
                headers: ["X-Threading-Client": "Threading-iOS"]
            )).status,
            400
        )
    }

    func testMobileDiagnosticsCaptureRouteRequiresOptInOwnerIOSAndALiveRequest() throws {
        let captureStore = MobileDiagnosticsCaptureStore.shared
        let previousEnabled = captureStore.isEnabled
        captureStore.setEnabled(false)
        defer { captureStore.setEnabled(previousEnabled) }
        let now = Date()
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let timestamp = formatter.string(from: now)
        func makeBody(for requestID: String) throws -> Data {
            let capture = RemoteMobileDiagnosticsCaptureDTO(
                captureID: UUID().uuidString.lowercased(),
                requestID: requestID,
                capturedAt: timestamp,
                appVersion: "1.0",
                appBuild: "1",
                operatingSystem: "iOS Test",
                deviceModel: "iPhone-test",
                applicationState: .active,
                connectionState: .online,
                activeEndpointKind: .lan,
                pairedHostCount: 1,
                visibleSessionCount: 1,
                diagnostics: [RemoteDiagnosticRecord(
                    timestamp: timestamp,
                    source: .iOSClient,
                    level: .info,
                    event: .socketConnected,
                    fields: ["transport": "websocket"]
                )],
                screenshotJPEGBase64: nil,
                screenshotKind: nil
            )
            return try JSONEncoder().encode(
                RemoteMobileDiagnosticsCaptureUploadRequestDTO(capture: capture)
            )
        }

        let requestID = UUID().uuidString.lowercased()
        let body = try makeBody(for: requestID)
        let headers = [
            "X-Threading-Client": "Threading-iOS",
            "X-Threading-Request-ID": requestID,
        ]

        XCTAssertEqual(try XCTUnwrap(post(
            RemoteRouter.mobileDiagnosticsCaptureUploadPath,
            bearer: "goodtoken",
            body: body,
            headers: headers
        )).status, 403, "the shipping route stays inert until the Mac opt-in is on")

        captureStore.setEnabled(true)
        let enabledRequestID = UUID().uuidString.lowercased()
        XCTAssertEqual(try XCTUnwrap(post(
            RemoteRouter.mobileDiagnosticsCaptureUploadPath,
            bearer: "goodtoken",
            body: try makeBody(for: enabledRequestID),
            headers: [
                "X-Threading-Client": "Threading-iOS",
                "X-Threading-Request-ID": enabledRequestID,
            ]
        )).status, 409, "an opted-in owner still needs a live, single-use request")

        let webRequestID = UUID().uuidString.lowercased()
        XCTAssertEqual(try XCTUnwrap(post(
            RemoteRouter.mobileDiagnosticsCaptureUploadPath,
            bearer: "goodtoken",
            body: try makeBody(for: webRequestID),
            headers: [
                "X-Threading-Client": "Threading-Web",
                "X-Threading-Request-ID": webRequestID,
            ]
        )).status, 403, "only the native iOS client may use this diagnostics route")

        authority.set(
            RemoteAuthorization(
                shareID: "guest",
                capability: .interact,
                scope: .session(SessionID())
            ),
            forToken: "guesttoken"
        )
        let guestRequestID = UUID().uuidString.lowercased()
        XCTAssertEqual(try XCTUnwrap(post(
            RemoteRouter.mobileDiagnosticsCaptureUploadPath,
            bearer: "guesttoken",
            body: try makeBody(for: guestRequestID),
            headers: [
                "X-Threading-Client": "Threading-iOS",
                "X-Threading-Request-ID": guestRequestID,
            ]
        )).status, 403, "a session guest cannot upload host diagnostics custody")
    }

    func testHostedCredentialRouteAdmitsOnlyTheBoundGuestWithoutRetiringOwnerPairing() throws {
        let commands = HostedGuestCommandSpy()
        server.hostCommands = commands
        authority.set(RemoteAuthorization(shareID: "membership", capability: .view,
            scope: .session(SessionID()), principal: .guest,
            member: RemoteMember(id: "membership", displayName: "Guest", deviceID: "test-device")),
            forToken: "guest-transport-test")
        let body = try JSONEncoder().encode(RemoteHostedDeviceCredentialRequestDTO())
        let response = try XCTUnwrap(post(RemoteRouter.hostedDeviceCredentialPath,
            bearer: "guest-transport-test", body: body))
        XCTAssertEqual(response.status, 201)
        let credential = try JSONDecoder().decode(RemoteHostedDeviceCredentialDTO.self, from: response.body)
        XCTAssertEqual(credential.deviceID, "guest-membership")
        XCTAssertEqual(commands.accessToken, "guest-transport-test")
        XCTAssertEqual(commands.deviceID, "test-device")
        XCTAssertFalse(commands.completedOwnerBootstrap)
        XCTAssertEqual(try XCTUnwrap(post(RemoteRouter.hostedDeviceCredentialPath,
            bearer: "guest-transport-test", body: body,
            headers: ["X-Threading-Device": "another-device"])).status, 401)
        XCTAssertEqual(commands.issueCount, 1)
    }

    func testInvitationAcceptanceIsIdempotentForAnExistingBearer() throws {
        let request = try JSONEncoder().encode(
            RemoteAcceptInvitationRequestDTO(displayName: "Test iPhone")
        )
        let response = try XCTUnwrap(post(
            RemoteRouter.invitationAcceptancePath,
            bearer: "goodtoken",
            body: request
        ))
        XCTAssertEqual(response.status, 200)
        let accepted = try JSONDecoder().decode(
            RemoteAcceptInvitationResponseDTO.self,
            from: response.body
        )
        XCTAssertEqual(accepted.accessToken, "goodtoken")
        XCTAssertEqual(accepted.me.share.scope, .all)
    }

    func testOnlyTheNativeIOSClientRequestsDurableOwnerPairing() throws {
        let redeemer = InvitationPersistenceSpy()
        server.invitationRedeemer = redeemer
        let request = try JSONEncoder().encode(
            RemoteAcceptInvitationRequestDTO(displayName: "Test iPhone")
        )

        XCTAssertEqual(try XCTUnwrap(post(
            RemoteRouter.invitationAcceptancePath,
            bearer: "ios-bootstrap",
            body: request,
            headers: ["X-Threading-Client": "Threading-iOS"]
        )).status, 201)
        XCTAssertEqual(try XCTUnwrap(post(
            RemoteRouter.invitationAcceptancePath,
            bearer: "browser-bootstrap",
            body: request,
            headers: ["X-Threading-Client": "Threading-Web"]
        )).status, 201)

        XCTAssertEqual(redeemer.persistenceRequests, [true, false])
    }

    func testMutationRequestIDReplaysOneInvitationRedemption() throws {
        let redeemer = InvitationPersistenceSpy()
        server.invitationRedeemer = redeemer
        let body = try JSONEncoder().encode(
            RemoteAcceptInvitationRequestDTO(displayName: "Test iPhone")
        )
        let headers = [
            "X-Threading-Client": "Threading-iOS",
            "X-Threading-Request-ID": "request-1",
        ]

        let first = try XCTUnwrap(post(
            RemoteRouter.invitationAcceptancePath,
            bearer: "ios-bootstrap",
            body: body,
            headers: headers
        ))
        let replay = try XCTUnwrap(post(
            RemoteRouter.invitationAcceptancePath,
            bearer: "ios-bootstrap",
            body: body,
            headers: headers
        ))

        XCTAssertEqual(first.status, 201)
        XCTAssertEqual(replay.status, 201)
        XCTAssertEqual(replay.body, first.body)
        XCTAssertEqual(redeemer.persistenceRequests, [true])
        XCTAssertEqual(replay.headers["X-Threading-Request-ID"] as? String, "request-1")
    }

    func testMutationRequestIDReplaysEquivalentJSONSerialization() throws {
        let redeemer = InvitationPersistenceSpy()
        server.invitationRedeemer = redeemer
        let headers = [
            "X-Threading-Client": "Threading-iOS",
            "X-Threading-Request-ID": "request-1",
        ]
        let firstBody = Data(
            #"{"displayName":"Test iPhone","futureField":true}"#.utf8
        )
        let fallbackBody = Data(
            #"{ "futureField" : true, "displayName" : "Test iPhone" }"#.utf8
        )

        let first = try XCTUnwrap(post(
            RemoteRouter.invitationAcceptancePath,
            bearer: "ios-bootstrap",
            body: firstBody,
            headers: headers
        ))
        let replay = try XCTUnwrap(post(
            RemoteRouter.invitationAcceptancePath,
            bearer: "ios-bootstrap",
            body: fallbackBody,
            headers: headers
        ))

        XCTAssertEqual(first.status, 201)
        XCTAssertEqual(replay.status, 201)
        XCTAssertEqual(replay.body, first.body)
        XCTAssertEqual(
            redeemer.persistenceRequests,
            [true],
            "one semantic mutation must not run again when route failover re-encodes its JSON"
        )
    }

    func testMutationRequestIDRejectsADifferentBody() throws {
        let redeemer = InvitationPersistenceSpy()
        server.invitationRedeemer = redeemer
        let headers = [
            "X-Threading-Client": "Threading-iOS",
            "X-Threading-Request-ID": "request-1",
        ]
        XCTAssertEqual(try XCTUnwrap(post(
            RemoteRouter.invitationAcceptancePath,
            bearer: "ios-bootstrap",
            body: try JSONEncoder().encode(
                RemoteAcceptInvitationRequestDTO(displayName: "First Phone")
            ),
            headers: headers
        )).status, 201)
        XCTAssertEqual(try XCTUnwrap(post(
            RemoteRouter.invitationAcceptancePath,
            bearer: "ios-bootstrap",
            body: try JSONEncoder().encode(
                RemoteAcceptInvitationRequestDTO(displayName: "Different Phone")
            ),
            headers: headers
        )).status, 409)
        XCTAssertEqual(redeemer.persistenceRequests, [true])
    }

    func testBearerSchemeIsCaseInsensitive() {
        let raw = "GET /api/me HTTP/1.1\r\nAuthorization: bearer goodtoken\r\n\r\n"
        guard case .request(let request, _) = MCPConnection.parseRequest(
            from: Data(raw.utf8),
            maximumBodyBytes: RemoteAccessDefaults.maximumRequestBytes
        ) else {
            return XCTFail("expected a parsed request")
        }
        XCTAssertEqual(RemoteRouter.bearerToken(from: request), "goodtoken")
    }

    /// A paired client declaring a protocol older than the server supports is told to update,
    /// with a body naming which side must change.
    func testTooOldClientProtocolGets426() throws {
        let probe = try XCTUnwrap(get(
            "/api/me",
            bearer: "goodtoken",
            headers: ["X-Threading-Protocol": "0", "X-Threading-Protocol-Min": "0"]
        ))
        XCTAssertEqual(probe.status, 426)
        XCTAssertTrue(String(decoding: probe.body, as: UTF8.self).contains("protocolMismatch"))
    }

    /// Protocol negotiation must not be an unauthenticated event-log oracle. An outdated paired
    /// client still gets the precise 426 above; a public probe first has to prove it belongs here.
    func testProtocolMismatchRequiresAuthentication() throws {
        let probe = try XCTUnwrap(get(
            "/api/me",
            headers: ["X-Threading-Protocol": "0", "X-Threading-Protocol-Min": "0"]
        ))
        XCTAssertEqual(probe.status, 401)
        XCTAssertFalse(String(decoding: probe.body, as: UTF8.self).contains("protocolMismatch"))
    }

    /// A client that requires a protocol newer than the server is told the *host* must update.
    func testTooNewClientProtocolAsksHostToUpdate() throws {
        let probe = try XCTUnwrap(get(
            "/api/me",
            bearer: "goodtoken",
            headers: ["X-Threading-Protocol": "99", "X-Threading-Protocol-Min": "99"]
        ))
        XCTAssertEqual(probe.status, 426)
        XCTAssertTrue(String(decoding: probe.body, as: UTF8.self).contains("\"update\":\"host\""))
    }

    /// Drives the real HTTP→WebSocket upgrade over a raw socket: the connection state machine
    /// must answer a valid upgrade with `101` and the standard `Sec-WebSocket-Accept` value.
    func testWebSocketUpgradeHandshake() throws {
        let request = "GET /ws/session/\(UUID().uuidString) HTTP/1.1\r\n"
            + "Host: 127.0.0.1\r\n"
            + "Upgrade: websocket\r\n"
            + "Connection: Upgrade\r\n"
            + "Sec-WebSocket-Version: 13\r\n"
            + "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\n\r\n"
        let response = try socketExchange(request)
        XCTAssertTrue(response.hasPrefix("HTTP/1.1 101 Switching Protocols\r\n"), "got: \(response)")
        XCTAssertTrue(response.contains("Sec-WebSocket-Accept: s3pPLMBiTxaQ9kYGzzhZRbK+xOo=\r\n"))
    }

    func testThemeEventWebSocketUpgradeHandshake() throws {
        let request = "GET /ws/events HTTP/1.1\r\n"
            + "Host: 127.0.0.1\r\n"
            + "Upgrade: websocket\r\n"
            + "Connection: Upgrade\r\n"
            + "Sec-WebSocket-Version: 13\r\n"
            + "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\n\r\n"
        XCTAssertTrue(try socketExchange(request).hasPrefix("HTTP/1.1 101 Switching Protocols\r\n"))
    }

    /// The cap is concurrent. Closed tabs must release their admission slot, or a server that
    /// has seen 32 browser visits becomes permanently unavailable until Threading restarts.
    func testMoreThanConnectionLimitSequentialVisitsRemainAccepted() throws {
        for visit in 0..<(RemoteAccessDefaults.maximumConnections + 4) {
            let request = "GET /ws/session/\(UUID().uuidString) HTTP/1.1\r\n"
                + "Host: 127.0.0.1\r\n"
                + "Upgrade: websocket\r\n"
                + "Connection: Upgrade\r\n"
                + "Sec-WebSocket-Version: 13\r\n"
                + "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\n\r\n"
            XCTAssertTrue(
                try socketExchange(request).hasPrefix("HTTP/1.1 101"),
                "visit \(visit + 1) should not consume a permanent connection slot"
            )
        }
    }

    /// Shutdown snapshots its connection table before cancelling. Each cancel reports a close
    /// synchronously, so iterating the live Dictionary while those callbacks remove entries
    /// would otherwise mutate the collection mid-iteration.
    func testStopIsSafeWithAnOpenWebSocket() throws {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        try XCTSkipIf(fd < 0, "could not open a socket")
        defer { close(fd) }

        var timeout = timeval(tv_sec: 1, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))

        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        inet_pton(AF_INET, "127.0.0.1", &addr.sin_addr)
        let connected = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        try XCTSkipIf(connected != 0, "could not connect to the loopback server")

        let request = "GET /ws/session/\(UUID().uuidString) HTTP/1.1\r\n"
            + "Host: 127.0.0.1\r\n"
            + "Upgrade: websocket\r\n"
            + "Connection: Upgrade\r\n"
            + "Sec-WebSocket-Version: 13\r\n"
            + "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\n\r\n"
        let bytes = Array(request.utf8)
        _ = bytes.withUnsafeBytes { send(fd, $0.baseAddress, bytes.count, 0) }

        var response = [UInt8](repeating: 0, count: 1024)
        XCTAssertGreaterThan(recv(fd, &response, response.count, 0), 0)

        server.stop()
        XCTAssertNil(server.port)
    }

    func testResumeRouteAcceptsOnlyOneSessionIdentifier() {
        XCTAssertEqual(
            RemoteRouter.resumeSessionID(forPath: "/api/session/abc/resume"),
            "abc"
        )
        XCTAssertNil(RemoteRouter.resumeSessionID(forPath: "/api/session//resume"))
        XCTAssertNil(RemoteRouter.resumeSessionID(forPath: "/api/session/a/b/resume"))
        XCTAssertNil(RemoteRouter.resumeSessionID(forPath: "/api/session/abc"))

        XCTAssertEqual(
            RemoteRouter.resumeTerminalID(forPath: "/api/terminal/terminal-1/resume"),
            "terminal-1"
        )
        XCTAssertEqual(
            RemoteRouter.shareTerminalID(forPath: "/api/terminal/terminal-1/share"),
            "terminal-1"
        )
        XCTAssertEqual(
            RemoteRouter.unshareTerminalID(forPath: "/api/terminal/terminal-1/unshare"),
            "terminal-1"
        )
        XCTAssertEqual(
            RemoteRouter.webSocketTerminalID(forPath: "/ws/terminal/terminal-1"),
            "terminal-1"
        )
        XCTAssertNil(RemoteRouter.resumeTerminalID(forPath: "/api/terminal/a/b/resume"))
        XCTAssertNil(RemoteRouter.webSocketTerminalID(forPath: "/ws/terminal/a/b"))

        XCTAssertEqual(
            RemoteRouter.themeSessionID(forPath: "/api/session/abc/theme"),
            "abc"
        )
        XCTAssertNil(RemoteRouter.themeSessionID(forPath: "/api/session/a/b/theme"))
        XCTAssertEqual(
            RemoteRouter.surfaceSessionID(forPath: "/api/session/abc/surface"),
            "abc"
        )
        XCTAssertNil(RemoteRouter.surfaceSessionID(forPath: "/api/session/a/b/surface"))
        XCTAssertEqual(
            RemoteRouter.accountSessionID(forPath: "/api/session/abc/account"),
            "abc"
        )
        XCTAssertNil(RemoteRouter.accountSessionID(forPath: "/api/session/a/b/account"))
        XCTAssertEqual(
            RemoteRouter.limitRecoverySessionID(
                forPath: "/api/session/abc/limit-recovery"
            ),
            "abc"
        )
        XCTAssertNil(RemoteRouter.limitRecoverySessionID(
            forPath: "/api/session/a/b/limit-recovery"
        ))
        XCTAssertEqual(
            RemoteRouter.snoozedSessionID(forPath: "/api/session/abc/snoozed"),
            "abc"
        )
        XCTAssertNil(RemoteRouter.snoozedSessionID(forPath: "/api/session/a/b/snoozed"))
        XCTAssertEqual(
            RemoteRouter.shareSessionID(forPath: "/api/session/abc/share"),
            "abc"
        )
        XCTAssertNil(RemoteRouter.shareSessionID(forPath: "/api/session/a/b/share"))
        XCTAssertEqual(
            RemoteRouter.unshareSessionID(forPath: "/api/session/abc/unshare"),
            "abc"
        )
        XCTAssertNil(RemoteRouter.unshareSessionID(forPath: "/api/session/a/b/unshare"))
        XCTAssertEqual(RemoteRouter.notificationRegistrationPath, "/api/notifications")
        XCTAssertEqual(
            RemoteRouter.invitationAcceptancePath,
            "/api/invitations/accept"
        )

        XCTAssertEqual(
            RemoteRouter.gitReviewRoute(forPath: "/api/session/abc/git-review/lastTurn"),
            RemoteRouter.GitReviewRoute(sessionID: "abc", mode: .lastTurn)
        )
        XCTAssertEqual(
            RemoteRouter.gitReviewRoute(forPath: "/api/session/abc/git-review/uncommitted"),
            RemoteRouter.GitReviewRoute(sessionID: "abc", mode: .uncommitted)
        )
        XCTAssertNil(RemoteRouter.gitReviewRoute(
            forPath: "/api/session/abc/git-review/not-a-mode"
        ))
        XCTAssertNil(RemoteRouter.gitReviewRoute(
            forPath: "/api/session/a/b/git-review/staged"
        ))
        XCTAssertEqual(
            RemoteRouter.repositoryFilesSessionID(
                forPath: "/api/session/abc/repository-files"
            ),
            "abc"
        )
        XCTAssertEqual(
            RemoteRouter.attachmentsSessionID(
                forPath: "/api/session/abc/attachments"
            ),
            "abc"
        )
        XCTAssertEqual(
            RemoteRouter.attachmentSessionID(
                forPath: "/api/session/abc/attachment"
            ),
            "abc"
        )
        XCTAssertEqual(
            RemoteRouter.attachmentThumbnailSessionID(
                forPath: "/api/session/abc/attachment-thumbnail"
            ),
            "abc"
        )
        XCTAssertNil(
            RemoteRouter.attachmentSessionID(
                forPath: "/api/session/abc/attachment-thumbnail"
            ),
            "the thumbnail route is its own action, not a suffix of the attachment's"
        )
        XCTAssertEqual(
            RemoteRouter.workspaceSessionID(
                forPath: "/api/session/abc/workspace"
            ),
            "abc"
        )
        XCTAssertEqual(
            RemoteRouter.browserPreviewSessionID(
                forPath: "/api/session/abc/browser-preview"
            ),
            "abc"
        )
        XCTAssertEqual(
            RemoteRouter.extensionPanelSessionID(
                forPath: "/api/session/abc/extension-panel"
            ),
            "abc"
        )
        XCTAssertEqual(
            RemoteRouter.extensionPanelResourceSessionID(
                forPath: "/api/session/abc/extension-panel-resource"
            ),
            "abc"
        )
        XCTAssertNil(RemoteRouter.extensionPanelSessionID(
            forPath: "/api/session/a/b/extension-panel"
        ))
        XCTAssertEqual(
            RemoteRouter.queryValue(
                named: "path",
                in: "/api/session/abc/repository-file?path=Sources%2FThing.swift"
            ),
            "Sources/Thing.swift"
        )
    }

    func testAuthRateLimiterBoundsOneDeviceAndRecoversAfterTheWindow() {
        var limiter = RemoteAuthRateLimiter()
        let now: TimeInterval = 1_000
        for _ in 0..<RemoteAccessDefaults.failedAuthLimitPerDevice {
            XCTAssertFalse(limiter.shouldReject(device: "phone", now: now))
            limiter.recordFailure(device: "phone", now: now)
        }
        XCTAssertTrue(limiter.shouldReject(device: "phone", now: now))
        XCTAssertFalse(limiter.shouldReject(device: "other-phone", now: now))
        XCTAssertFalse(limiter.shouldReject(
            device: "phone",
            now: now + RemoteAccessDefaults.failedAuthWindow + 1
        ))
    }

    func testAuthRateLimiterAlsoHasAGlobalCeilingForRotatingDeviceIDs() {
        var limiter = RemoteAuthRateLimiter()
        let now: TimeInterval = 2_000
        for attempt in 0..<RemoteAccessDefaults.failedAuthLimitGlobal {
            XCTAssertFalse(limiter.shouldReject(device: "device-\(attempt)", now: now))
            limiter.recordFailure(device: "device-\(attempt)", now: now)
        }
        XCTAssertTrue(limiter.shouldReject(device: "fresh-device", now: now))
    }

    /// The public failure budget bounds bad credentials and their logging. It must never let an
    /// attacker turn 60 guesses into a one-minute outage for devices holding the real bearer.
    func testValidBearerBypassesExhaustedFailedAuthBudget() throws {
        for attempt in 0..<RemoteAccessDefaults.failedAuthLimitGlobal {
            let probe = try XCTUnwrap(get(
                "/api/me",
                bearer: "wrong-\(attempt)",
                headers: ["X-Threading-Device": "attacker-\(attempt)"]
            ))
            XCTAssertEqual(probe.status, 401)
        }

        XCTAssertEqual(
            try XCTUnwrap(get(
                "/api/me",
                bearer: "goodtoken",
                headers: ["X-Threading-Device": "paired-phone"]
            )).status,
            200
        )
        XCTAssertEqual(
            try XCTUnwrap(get(
                "/api/me",
                bearer: "still-wrong",
                headers: ["X-Threading-Device": "fresh-attacker"]
            )).status,
            429
        )
    }

    func testInboundPolicyBoundsCredentialsAndMainActorActions() {
        XCTAssertEqual(
            RemoteInboundPolicy.normalizedDeviceID(" phone-1 "),
            "phone-1"
        )
        XCTAssertNil(RemoteInboundPolicy.normalizedDeviceID("phone\nforged-log-line"))
        XCTAssertNil(RemoteInboundPolicy.normalizedDeviceID(
            String(repeating: "d", count: RemoteAccessDefaults.maximumDeviceIDBytes + 1)
        ))

        XCTAssertTrue(RemoteInboundPolicy.acceptsBearerToken("token"))
        XCTAssertFalse(RemoteInboundPolicy.acceptsBearerToken(
            String(repeating: "t", count: RemoteAccessDefaults.maximumBearerTokenBytes + 1)
        ))
        XCTAssertTrue(RemoteInboundPolicy.acceptsTerminalInput(
            String(repeating: "i", count: RemoteAccessDefaults.maximumTerminalInputBytes)
        ))
        XCTAssertFalse(RemoteInboundPolicy.acceptsTerminalInput(
            String(repeating: "i", count: RemoteAccessDefaults.maximumTerminalInputBytes + 1)
        ))
        XCTAssertTrue(RemoteInboundPolicy.acceptsTerminalInput("one complete line\r"))
        XCTAssertFalse(RemoteInboundPolicy.acceptsTerminalInput(
            String(repeating: "i", count: RemoteAccessDefaults.maximumTerminalInputBytes) + "\r"
        ), "the atomic terminal path includes Return in its bounded PTY write")
        XCTAssertFalse(RemoteInboundPolicy.acceptsPrompt(
            String(repeating: "p", count: RemoteAccessDefaults.maximumPromptBytes + 1)
        ))
        let context = RemoteConversationContextAttachmentDTO(
            id: UUID().uuidString,
            kind: .comment,
            source: .attachment,
            title: "layout.png",
            comment: "Reduce the padding."
        )
        XCTAssertTrue(RemoteInboundPolicy.acceptsContextAttachments([context]))
        XCTAssertFalse(RemoteInboundPolicy.acceptsContextAttachments(
            Array(repeating: context, count: ConversationContextPolicy.maximumAttachments + 1)
        ))
        let oversizedContext = RemoteConversationContextAttachmentDTO(
            id: UUID().uuidString,
            kind: .comment,
            source: .attachment,
            title: "layout.png",
            comment: String(
                repeating: "c",
                count: ConversationContextPolicy.maximumEnvelopeUTF8Bytes
            )
        )
        XCTAssertFalse(RemoteInboundPolicy.acceptsContextAttachments([oversizedContext]))
    }

    func testArchivedSessionsAreOutsideEveryRemoteEntryPoint() {
        var session = AgentSession(kind: .codex, title: "Review")
        XCTAssertTrue(RemoteSessionAccess.isVisible(session))

        session.isArchived = true
        XCTAssertFalse(RemoteSessionAccess.isVisible(session))
        XCTAssertFalse(RemoteSessionAccess.isVisible(nil))
    }

    func testConversationProjectionKeepsNewestContentBelowSocketHighWater() throws {
        let hostileText = String(repeating: "\u{0001}", count: 40_000)
        let rows = (0..<300).map {
            RemoteConversationRowDTO(
                id: String($0),
                kind: .assistant,
                text: hostileText
            )
        }
        let bounded = RemoteConversationWirePolicy.bounded(RemoteConversationSnapshotDTO(
            rows: rows,
            streamingText: hostileText,
            canSend: true
        ))
        let encoded = try JSONEncoder().encode(bounded)

        XCTAssertLessThan(encoded.count, RemoteAccessDefaults.outboundHighWaterBytes)
        XCTAssertEqual(bounded.rows.first?.kind, .notice)
        XCTAssertEqual(bounded.rows.last?.id, "299")
        XCTAssertLessThanOrEqual(
            bounded.streamingText.utf8.count,
            RemoteAccessDefaults.maximumRemoteStreamingBytes
        )
    }

    func testConversationInitialWindowAndOlderPageMeetWithoutSyntheticRows() {
        let rows = (0..<220).map {
            RemoteConversationRowDTO(id: String($0), kind: .assistant, text: "Row \($0)")
        }
        let complete = RemoteConversationSnapshotDTO(rows: rows, canSend: true)
        let initial = RemoteConversationWirePolicy.initial(complete, revision: 9)
        let page = RemoteConversationWirePolicy.page(
            complete,
            beforeRowID: initial.rows.first?.id,
            requestedLimit: 64
        )

        XCTAssertEqual(initial.revision, 9)
        XCTAssertTrue(initial.hasEarlier)
        XCTAssertEqual(initial.rows.first?.id, "60")
        XCTAssertEqual(initial.rows.last?.id, "219")
        XCTAssertFalse(initial.rows.contains(where: { $0.kind == .notice }))
        XCTAssertEqual(page.rows.first?.id, "0")
        XCTAssertEqual(page.rows.last?.id, "59")
        XCTAssertFalse(page.hasEarlier)
    }

    func testConversationDeltaNamesOnlyAppendedAndUpdatedRows() throws {
        let previous = RemoteConversationSnapshotDTO(
            rows: [
                .init(id: "0", kind: .user, text: "Test"),
                .init(id: "1", kind: .tool, toolName: "Bash", summary: "swift test"),
            ],
            streamingText: "Run",
            canSend: false
        )
        let current = RemoteConversationSnapshotDTO(
            rows: [
                previous.rows[0],
                .init(
                    id: "1",
                    kind: .tool,
                    toolName: "Bash",
                    summary: "swift test",
                    result: "Passed"
                ),
                .init(id: "2", kind: .assistant, text: "Done"),
            ],
            canSend: true
        )
        let delta = try XCTUnwrap(RemoteConversationWirePolicy.delta(
            from: previous,
            to: current,
            baseRevision: 3,
            revision: 4
        ))

        XCTAssertEqual(delta.updatedRows.map(\.id), ["1"])
        XCTAssertEqual(delta.appendedRows.map(\.id), ["2"])
        XCTAssertEqual(delta.baseRevision, 3)
        XCTAssertEqual(delta.revision, 4)
        XCTAssertTrue(delta.canSend)
    }

    func testConversationMetadataDeltaRequiresStableRowCountAndCarriesNoRows() throws {
        let rows = [RemoteConversationRowDTO(id: "0", kind: .assistant, text: "Settled")]
        let previous = RemoteConversationSnapshotDTO(
            rows: rows,
            streamingText: "A",
            canSend: false
        )
        let current = RemoteConversationSnapshotDTO(
            rows: rows,
            streamingText: "AB",
            canSend: false
        )
        let delta = try XCTUnwrap(RemoteConversationWirePolicy.deltaWithUnchangedRows(
            from: previous,
            to: current,
            baseRevision: 8,
            revision: 9
        ))

        XCTAssertTrue(delta.appendedRows.isEmpty)
        XCTAssertTrue(delta.updatedRows.isEmpty)
        XCTAssertEqual(delta.streamingText, "AB")
        XCTAssertNil(RemoteConversationWirePolicy.deltaWithUnchangedRows(
            from: previous,
            to: RemoteConversationSnapshotDTO(rows: rows + rows, canSend: false),
            baseRevision: 9,
            revision: 10
        ))
    }

    func testConversationRowProjectionTracksExactTimelineChanges() {
        var timeline = ConversationTimeline(sessionID: SessionID())
        var projection = RemoteConversationRowProjection()

        func apply(_ event: StreamEvent) {
            for change in timeline.apply(event) {
                projection.apply(change, timelineRows: timeline.rows)
            }
        }

        apply(.userMessage("Run the tests"))
        apply(.assistantMessage(blocks: [
            .toolUse(id: "call-1", tool: .bash, input: ["command": "swift test"])
        ]))
        let beforeResult = projection.rowsRevision
        apply(.toolResults([
            ToolResult(toolUseID: "call-1", text: "Passed", isError: false)
        ]))

        XCTAssertEqual(projection.rows.map(\.id), ["0", "1"])
        XCTAssertEqual(projection.rows[0].text, "Run the tests")
        XCTAssertEqual(projection.rows[1].result, "Passed")
        XCTAssertNotEqual(projection.rowsRevision, beforeResult)

        let beforeStreaming = projection.rowsRevision
        apply(.textDelta("Still working"))
        XCTAssertEqual(projection.rowsRevision, beforeStreaming)
        XCTAssertEqual(projection.rows.count, timeline.rows.count)
    }

    func testConversationCatalogIsDeltaEncodedAndBoundedWithoutPrivateSkillPaths() throws {
        let previous = RemoteConversationSnapshotDTO(rows: [], canSend: true)
        let capabilities = (0..<400).map { index in
            RemoteComposerCapabilityDTO(
                id: "codex.skill:\(index)",
                name: "skill-\(index)",
                displayName: "Skill \(index)",
                description: String(repeating: "d", count: 2_000),
                argumentHint: "[task]",
                aliases: ["alias-\(index)"],
                kind: .skill,
                trigger: .dollar,
                presentation: .turn
            )
        }
        let current = RemoteConversationSnapshotDTO(
            rows: [],
            canSend: true,
            composerCapabilities: capabilities
        )

        let delta = try XCTUnwrap(RemoteConversationWirePolicy.delta(
            from: previous,
            to: current,
            baseRevision: 1,
            revision: 2
        ))
        let catalog = try XCTUnwrap(delta.composerCapabilities)
        XCTAssertLessThanOrEqual(
            catalog.count,
            RemoteAccessDefaults.maximumRemoteComposerCapabilities
        )
        XCTAssertLessThanOrEqual(
            try JSONEncoder().encode(catalog).count,
            RemoteAccessDefaults.maximumRemoteComposerCapabilityBytes
        )
        let encoded = String(decoding: try JSONEncoder().encode(delta), as: UTF8.self)
        XCTAssertFalse(encoded.contains("/Users/"))
        XCTAssertNil(RemoteConversationWirePolicy.delta(
            from: current,
            to: current,
            baseRevision: 2,
            revision: 3
        )?.composerCapabilities)
    }

    /// Measures the complete catch-up pipeline without requiring a live provider: a large Mac
    /// timeline is projected into the bounded recent window, encoded, decoded into the mobile
    /// state model, paged to the beginning, advanced by one live write, and recovered after a
    /// revision gap. This is deliberately opt-in because the 20,000-row point is diagnostic,
    /// not part of the fast protocol suite.
    func testStressRemoteConversationCatchUpWhenEnabled() throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["THREADING_REMOTE_CONVERSATION_STRESS"] == "1",
            "Set THREADING_REMOTE_CONVERSATION_STRESS=1 to run the remote catch-up sweep."
        )

        let override = ProcessInfo.processInfo.environment[
            "THREADING_REMOTE_CONVERSATION_STRESS_ROWS"
        ].flatMap(Int.init).flatMap { $0 > 0 ? $0 : nil }
        for rowCount in override.map({ [$0] }) ?? [1_000, 5_000, 20_000] {
            try autoreleasepool {
                try runRemoteConversationCatchUpStress(rowCount: rowCount)
            }
        }
    }

    private func runRemoteConversationCatchUpStress(rowCount: Int) throws {
        let rows = (0..<rowCount).map { index in
            switch index % 12 {
            case 0:
                return RemoteConversationRowDTO(
                    id: String(index),
                    kind: .user,
                    text: "Remote prompt \(index): continue the cross-device performance run."
                )
            case 1, 5, 9:
                return RemoteConversationRowDTO(
                    id: String(index),
                    kind: .tool,
                    toolName: index.isMultiple(of: 2) ? "Read" : "Bash",
                    summary: "Sources/Remote/Fixture\(index).swift",
                    result: "Completed deterministic operation \(index)."
                )
            default:
                return RemoteConversationRowDTO(
                    id: String(index),
                    kind: .assistant,
                    text: """
                    ### Cross-device result \(index)

                    This deterministic Markdown row represents work written from another device. \
                    It exercises projection, serialization, pagination, and client reconciliation.

                    `let remoteRow = \(index)`
                    """
                )
            }
        }
        let complete = RemoteConversationSnapshotDTO(rows: rows, canSend: true)
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()

        let projectionStarted = DispatchTime.now().uptimeNanoseconds
        let initial = RemoteConversationWirePolicy.initial(complete, revision: 1)
        let projectionEnded = DispatchTime.now().uptimeNanoseconds
        let initialData = try encoder.encode(initial)
        let encodingEnded = DispatchTime.now().uptimeNanoseconds
        let decodedInitial = try decoder.decode(
            RemoteConversationSnapshotDTO.self,
            from: initialData
        )
        var client = RemoteConversationState()
        _ = client.apply(decodedInitial)
        let clientEnded = DispatchTime.now().uptimeNanoseconds

        XCTAssertEqual(client.rows.last?.id, String(rowCount - 1))
        XCTAssertLessThanOrEqual(
            client.rows.count,
            RemoteAccessDefaults.maximumRemoteConversationRows
        )
        XCTAssertEqual(client.hasEarlier, rowCount > client.rows.count)
        print(
            "THREADING_PERF remote-conversation-open "
                + "source_rows=\(rowCount) recent_rows=\(client.rows.count) "
                + "wire_bytes=\(initialData.count) "
                + "projection_ms=\(Self.milliseconds(projectionEnded - projectionStarted)) "
                + "encode_ms=\(Self.milliseconds(encodingEnded - projectionEnded)) "
                + "decode_apply_ms=\(Self.milliseconds(clientEnded - encodingEnded)) "
                + "elapsed_ms=\(Self.milliseconds(clientEnded - projectionStarted))"
        )

        var reconnectDurations: [UInt64] = []
        for revision in 2...21 {
            let started = DispatchTime.now().uptimeNanoseconds
            let projected = RemoteConversationWirePolicy.initial(complete, revision: revision)
            let data = try encoder.encode(projected)
            let decoded = try decoder.decode(RemoteConversationSnapshotDTO.self, from: data)
            _ = client.apply(decoded)
            reconnectDurations.append(DispatchTime.now().uptimeNanoseconds - started)
        }
        print(
            "THREADING_PERF remote-conversation-reconnect "
                + "source_rows=\(rowCount) repetitions=\(reconnectDurations.count) "
                + "p50_ms=\(Self.milliseconds(Self.percentile(reconnectDurations, 0.50))) "
                + "p95_ms=\(Self.milliseconds(Self.percentile(reconnectDurations, 0.95)))"
        )

        _ = client.apply(initial)
        let paginationStarted = DispatchTime.now().uptimeNanoseconds
        var pageDurations: [UInt64] = []
        var pageWireBytes = 0
        while client.hasEarlier {
            let pageStarted = DispatchTime.now().uptimeNanoseconds
            let page = RemoteConversationWirePolicy.page(
                complete,
                beforeRowID: client.rows.first?.id,
                requestedLimit: RemoteAccessDefaults.maximumRemoteConversationPageRows
            )
            let data = try encoder.encode(page)
            let decoded = try decoder.decode(RemoteConversationPageDTO.self, from: data)
            _ = client.prepend(decoded)
            pageWireBytes += data.count
            pageDurations.append(DispatchTime.now().uptimeNanoseconds - pageStarted)
        }
        let paginationEnded = DispatchTime.now().uptimeNanoseconds
        XCTAssertEqual(client.rows.count, rowCount)
        print(
            "THREADING_PERF remote-conversation-pagination "
                + "source_rows=\(rowCount) pages=\(pageDurations.count) "
                + "wire_bytes=\(pageWireBytes) "
                + "page_p50_ms=\(Self.milliseconds(Self.percentile(pageDurations, 0.50))) "
                + "page_p95_ms=\(Self.milliseconds(Self.percentile(pageDurations, 0.95))) "
                + "elapsed_ms=\(Self.milliseconds(paginationEnded - paginationStarted))"
        )

        let appended = RemoteConversationRowDTO(
            id: String(rowCount),
            kind: .assistant,
            text: "The remote writer appended one more result."
        )
        let advanced = RemoteConversationSnapshotDTO(rows: rows + [appended], canSend: true)
        let deltaStarted = DispatchTime.now().uptimeNanoseconds
        let delta = try XCTUnwrap(RemoteConversationWirePolicy.delta(
            from: complete,
            to: advanced,
            baseRevision: 1,
            revision: 2
        ))
        let deltaEnded = DispatchTime.now().uptimeNanoseconds
        let deltaData = try encoder.encode(delta)
        let decodedDelta = try decoder.decode(RemoteConversationDeltaDTO.self, from: deltaData)
        _ = client.apply(decodedDelta)
        let deltaApplied = DispatchTime.now().uptimeNanoseconds
        XCTAssertEqual(client.rows.last?.id, appended.id)
        print(
            "THREADING_PERF remote-conversation-live-update "
                + "source_rows=\(rowCount) wire_bytes=\(deltaData.count) "
                + "delta_ms=\(Self.milliseconds(deltaEnded - deltaStarted)) "
                + "encode_decode_apply_ms=\(Self.milliseconds(deltaApplied - deltaEnded)) "
                + "elapsed_ms=\(Self.milliseconds(deltaApplied - deltaStarted))"
        )

        let streamingUpdates = 250
        var legacyStreamingNanoseconds: UInt64 = 0
        var exactStreamingNanoseconds: UInt64 = 0
        var priorStreaming = complete
        for update in 0..<streamingUpdates {
            let next = RemoteConversationSnapshotDTO(
                rows: rows,
                streamingText: "Streaming token \(update)",
                canSend: false
            )
            let legacyStarted = DispatchTime.now().uptimeNanoseconds
            _ = RemoteConversationWirePolicy.delta(
                from: priorStreaming,
                to: next,
                baseRevision: update,
                revision: update + 1
            )
            legacyStreamingNanoseconds += DispatchTime.now().uptimeNanoseconds - legacyStarted

            let exactStarted = DispatchTime.now().uptimeNanoseconds
            let exact = try XCTUnwrap(RemoteConversationWirePolicy.deltaWithUnchangedRows(
                from: priorStreaming,
                to: next,
                baseRevision: update,
                revision: update + 1
            ))
            exactStreamingNanoseconds += DispatchTime.now().uptimeNanoseconds - exactStarted
            XCTAssertTrue(exact.appendedRows.isEmpty)
            XCTAssertTrue(exact.updatedRows.isEmpty)
            priorStreaming = next
        }
        print(
            "THREADING_PERF remote-conversation-streaming-burst "
                + "source_rows=\(rowCount) updates=\(streamingUpdates) "
                + "whole_row_compare_ms=\(Self.milliseconds(legacyStreamingNanoseconds)) "
                + "stable_row_generation_ms=\(Self.milliseconds(exactStreamingNanoseconds))"
        )

        let gap = RemoteConversationDeltaDTO(
            baseRevision: 99,
            revision: 100,
            streamingText: "missed update",
            canSend: false
        )
        let resyncStarted = DispatchTime.now().uptimeNanoseconds
        XCTAssertEqual(client.apply(gap), .requiresSnapshot)
        let resync = RemoteConversationWirePolicy.initial(advanced, revision: 100)
        let resyncData = try encoder.encode(resync)
        let decodedResync = try decoder.decode(
            RemoteConversationSnapshotDTO.self,
            from: resyncData
        )
        _ = client.apply(decodedResync)
        let resyncEnded = DispatchTime.now().uptimeNanoseconds
        XCTAssertEqual(client.revision, 100)
        XCTAssertEqual(client.rows.last?.id, appended.id)
        print(
            "THREADING_PERF remote-conversation-resync "
                + "source_rows=\(rowCount) recent_rows=\(client.rows.count) "
                + "wire_bytes=\(resyncData.count) "
                + "elapsed_ms=\(Self.milliseconds(resyncEnded - resyncStarted))"
        )
    }

    private static func milliseconds(_ nanoseconds: UInt64) -> String {
        String(format: "%.3f", Double(nanoseconds) / 1_000_000)
    }

    private static func percentile(_ values: [UInt64], _ fraction: Double) -> UInt64 {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        let index = Int((Double(sorted.count - 1) * fraction).rounded(.up))
        return sorted[min(max(index, 0), sorted.count - 1)]
    }

    func testAttachmentResponseIsHardenedAndClosesItsConnection() {
        let response = RemoteRouter.data(Data("image".utf8), contentType: "image/png")
        let serialized = String(decoding: response.serialized, as: UTF8.self)

        XCTAssertTrue(response.closesConnection)
        XCTAssertTrue(serialized.contains("Content-Type: image/png\r\n"))
        XCTAssertTrue(serialized.contains("Connection: close\r\n"))
        XCTAssertEqual(response.extraHeaders["Cache-Control"], "no-store")
        XCTAssertEqual(response.extraHeaders["X-Content-Type-Options"], "nosniff")
    }

    /// A thumbnail is small by construction, so its connection is kept for the ledger's next
    /// cell. Closing it after each of thirty pictures was the churn a phone reported as a lost
    /// network connection.
    func testAThumbnailResponseKeepsItsConnectionAndStaysHardened() {
        let response = RemoteRouter.data(
            Data("jpeg".utf8),
            contentType: "image/jpeg",
            closesConnection: false
        )
        let serialized = String(decoding: response.serialized, as: UTF8.self)

        XCTAssertFalse(response.closesConnection)
        XCTAssertTrue(serialized.contains("Connection: keep-alive\r\n"))
        XCTAssertEqual(response.extraHeaders["Cache-Control"], "no-store")
        XCTAssertEqual(response.extraHeaders["X-Content-Type-Options"], "nosniff")
    }

    func testRESTRefusalsAreMachineReadableAndHardened() throws {
        let precise = RemoteRouter.error(
            422,
            "Unknown Model",
            code: .unknownModel
        )
        XCTAssertEqual(precise.status, 422)
        XCTAssertEqual(precise.contentType, "application/json")
        XCTAssertEqual(
            try JSONDecoder().decode(RemoteErrorDTO.self, from: precise.body),
            RemoteErrorDTO(code: .unknownModel)
        )
        XCTAssertEqual(precise.extraHeaders["Cache-Control"], "no-store")

        let opaque = RemoteRouter.error(404, "Not Found")
        XCTAssertEqual(
            try JSONDecoder().decode(RemoteErrorDTO.self, from: opaque.body).code,
            RemoteRESTErrorCode.notFound.rawValue
        )
        XCTAssertEqual(
            try JSONDecoder().decode(
                RemoteErrorDTO.self,
                from: RemoteRouter.error(500, "Internal Server Error").body
            ).code,
            RemoteRESTErrorCode.serverFailure.rawValue
        )
        XCTAssertEqual(
            try JSONDecoder().decode(
                RemoteErrorDTO.self,
                from: RemoteRouter.error(503, "Service Unavailable").body
            ).code,
            RemoteRESTErrorCode.serviceUnavailable.rawValue
        )
    }

    func testAttachmentDetectorAcceptsVisualFilesInsideCheckoutOnly() throws {
        let temporary = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let root = temporary.appendingPathComponent("project", isDirectory: true)
        let current = root.appendingPathComponent("art", isDirectory: true)
        try FileManager.default.createDirectory(
            at: current,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: temporary) }

        let pdf = current.appendingPathComponent("final report.pdf")
        let image = root.appendingPathComponent("preview.png")
        let nestedImage = current.appendingPathComponent("diagram.webp")
        let source = root.appendingPathComponent("Ignored.swift")
        try Data("%PDF-test".utf8).write(to: pdf)
        try Data("png".utf8).write(to: image)
        try Data("webp".utf8).write(to: nestedImage)
        try Data("swift".utf8).write(to: source)

        let outside = temporary.appendingPathComponent("private.png")
        let escaped = root.appendingPathComponent("escaped.png")
        try Data("outside".utf8).write(to: outside)
        try FileManager.default.createSymbolicLink(
            at: escaped,
            withDestinationURL: outside
        )

        let text = """
        PDF: [report](art/final report.pdf)
        Image: `preview.png:12:4`
        Working-directory image: diagram.webp
        Ignore source: Ignored.swift
        Ignore missing: absent.jpg
        Ignore symlink escape: escaped.png
        Ignore outside: \(outside.path)
        """
        let found = AttachmentReferenceDetector.resolve(
            text: text,
            projectRoot: root,
            currentDirectory: current
        )

        XCTAssertEqual(
            Set(found.insideProject.map { $0.resolvingSymlinksInPath().path }),
            Set([pdf.path, image.path, nestedImage.path])
        )
        XCTAssertEqual(
            found.outsideProject.map { $0.resolvingSymlinksInPath().path },
            [outside.resolvingSymlinksInPath().path],
            "an outside path is sorted, not dropped — the store decides what that means"
        )
    }

    /// A deterministic PNG whose pixels do not compress, so the encoded file lands in the size
    /// band a real page raster occupies rather than a few hundred bytes of flat colour.
    private static func incompressiblePNG(side: Int) throws -> Data {
        let rep = try XCTUnwrap(NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: side,
            pixelsHigh: side,
            bitsPerSample: 8,
            samplesPerPixel: 3,
            hasAlpha: false,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ))
        let plane = try XCTUnwrap(rep.bitmapData)
        var state: UInt64 = 0x2545_F491_4F6C_DD1D
        for index in 0..<(rep.bytesPerRow * side) {
            state ^= state << 13
            state ^= state >> 7
            state ^= state << 17
            plane[index] = UInt8(truncatingIfNeeded: state)
        }
        return try XCTUnwrap(rep.representation(using: .png, properties: [:]))
    }

    /// The gallery asks the Mac two questions about one file, and the answers have to agree.
    ///
    /// The pair had only a refusal test: nothing anywhere proved that an attachment the ledger
    /// can draw a thumbnail of also comes back whole, which is exactly the asymmetry a report
    /// described — the thumbnail arrived and the preview never did.
    func testServesAnInCheckoutImageWholeAndAsAThumbnail() throws {
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(
            "remote-attachment-bytes-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporary) }

        let project = try XCTUnwrap(ProjectStore.shared.addProject(folderURL: temporary))
        let session = try XCTUnwrap(ProjectStore.shared.addSession(
            to: project.id,
            kind: .claude,
            title: "Attachment bytes"
        ))

        let nested = temporary.appendingPathComponent("tmp/pdfs", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        let file = nested.appendingPathComponent("reception-certificate-after-1.png")
        let png = try Self.incompressiblePNG(side: 210)
        try png.write(to: file)

        let attachment = try XCTUnwrap(SessionAttachmentStore.shared.record(
            url: file,
            sessionID: session.id,
            projectRoot: temporary
        ))
        XCTAssertEqual(attachment.kind, .image)

        let listing = try XCTUnwrap(get(
            "/api/session/\(session.id.uuidString)/attachments",
            bearer: "goodtoken"
        ))
        XCTAssertEqual(listing.status, 200)
        let listed = try JSONDecoder().decode(RemoteAttachmentsDTO.self, from: listing.body)
        XCTAssertEqual(listed.attachments.map(\.id), [attachment.id])
        XCTAssertEqual(listed.attachments.first?.byteCount, Int64(png.count))
        XCTAssertEqual(
            try XCTUnwrap(listed.attachments.first?.referencedAt).timeIntervalSince1970,
            attachment.referencedAt.timeIntervalSince1970,
            accuracy: 0.001
        )

        let thumbnail = try XCTUnwrap(get(
            "/api/session/\(session.id.uuidString)/attachment-thumbnail?id=\(attachment.id)",
            bearer: "goodtoken"
        ))
        XCTAssertEqual(thumbnail.status, 200, "the ledger's thumbnail is the half that worked")
        XCTAssertFalse(thumbnail.body.isEmpty)

        let whole = try XCTUnwrap(get(
            "/api/session/\(session.id.uuidString)/attachment?id=\(attachment.id)",
            bearer: "goodtoken"
        ))
        XCTAssertEqual(whole.status, 200)
        XCTAssertEqual(whole.headers["Content-Type"] as? String, "image/png")
        XCTAssertEqual(whole.body, png, "the preview must receive the file's exact bytes")
    }

    func testMovieByteRangesAreBoundedAndRejectMalformedRequests() {
        XCTAssertEqual(
            RemoteAttachmentByteRange.resolve("bytes=10-19", fileSize: 100),
            10 ..< 20
        )
        XCTAssertEqual(
            RemoteAttachmentByteRange.resolve("bytes=-10", fileSize: 100),
            90 ..< 100
        )
        XCTAssertEqual(
            RemoteAttachmentByteRange.resolve(
                "bytes=10-",
                fileSize: Int64(RemoteAttachmentVideo.maximumChunkBytes * 2)
            ),
            10 ..< Int64(10 + RemoteAttachmentVideo.maximumChunkBytes)
        )
        XCTAssertEqual(
            RemoteAttachmentByteRange.resolve("bytes=90-\(Int64.max)", fileSize: 100),
            90 ..< 100,
            "an untrusted inclusive upper bound must not overflow"
        )
        XCTAssertNil(RemoteAttachmentByteRange.resolve("bytes=100-", fileSize: 100))
        XCTAssertNil(RemoteAttachmentByteRange.resolve("bytes=20-10", fileSize: 100))
        XCTAssertNil(RemoteAttachmentByteRange.resolve("bytes=0-1,4-5", fileSize: 100))
        XCTAssertNil(RemoteAttachmentByteRange.resolve("items=0-1", fileSize: 100))
    }

    func testListsAndStreamsAMovieLargerThanTheWholeFileCeiling() throws {
        let me = try JSONDecoder().decode(
            RemoteMeDTO.self,
            from: try XCTUnwrap(get("/api/me", bearer: "goodtoken")).body
        )
        XCTAssertTrue(
            me.features?.contains(RemoteRESTFeature.attachmentVideoStreaming.rawValue) == true
        )

        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(
            "remote-attachment-video-range-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporary) }

        let project = try XCTUnwrap(ProjectStore.shared.addProject(folderURL: temporary))
        let session = try XCTUnwrap(ProjectStore.shared.addSession(
            to: project.id,
            kind: .claude,
            title: "Movie range"
        ))
        let file = temporary.appendingPathComponent("recording.mov")
        try MovieFixture.write(to: file)
        let handle = try FileHandle(forWritingTo: file)
        let byteCount = UInt64(RemoteAccessDefaults.maximumAttachmentBytes + 4_096)
        try handle.truncate(atOffset: byteCount)
        try handle.close()

        let attachment = try XCTUnwrap(SessionAttachmentStore.shared.record(
            url: file,
            sessionID: session.id,
            projectRoot: temporary
        ))
        XCTAssertEqual(attachment.kind, .video)

        let listing = try XCTUnwrap(get(
            "/api/session/\(session.id.uuidString)/attachments",
            bearer: "goodtoken"
        ))
        let listed = try JSONDecoder().decode(RemoteAttachmentsDTO.self, from: listing.body)
        XCTAssertEqual(listed.attachments.map(\.id), [attachment.id])
        XCTAssertEqual(listed.attachments.first?.byteCount, Int64(byteCount))

        let whole = try XCTUnwrap(get(
            "/api/session/\(session.id.uuidString)/attachment?id=\(attachment.id)",
            bearer: "goodtoken"
        ))
        XCTAssertEqual(whole.status, 416, "a large movie is never allocated as one response")

        let partial = try XCTUnwrap(get(
            "/api/session/\(session.id.uuidString)/attachment?id=\(attachment.id)",
            bearer: "goodtoken",
            headers: ["Range": "bytes=0-1023"]
        ))
        XCTAssertEqual(partial.status, 206)
        XCTAssertEqual(partial.body.count, 1_024)
        XCTAssertEqual(partial.headers["Accept-Ranges"] as? String, "bytes")
        XCTAssertEqual(
            partial.headers["Content-Range"] as? String,
            "bytes 0-1023/\(byteCount)"
        )
        XCTAssertEqual(partial.headers["Content-Type"] as? String, "video/quicktime")
    }

    func testAttachmentStoreDeduplicatesAndMovesLatestReferenceFirst() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let first = root.appendingPathComponent("first.png")
        let second = root.appendingPathComponent("second.pdf")
        try Data("one".utf8).write(to: first)
        try Data("%PDF-two".utf8).write(to: second)

        var instant = Date(timeIntervalSince1970: 10)
        let store = SessionAttachmentStore(now: { instant })
        let sessionID = SessionID()
        XCTAssertNotNil(store.record(url: first, sessionID: sessionID, projectRoot: root))
        instant = Date(timeIntervalSince1970: 20)
        XCTAssertNotNil(store.record(url: second, sessionID: sessionID, projectRoot: root))
        instant = Date(timeIntervalSince1970: 30)
        XCTAssertNotNil(store.record(url: first, sessionID: sessionID, projectRoot: root))

        let attachments = store.attachments(for: sessionID)
        XCTAssertEqual(attachments.map(\.relativePath), ["first.png", "second.pdf"])
        XCTAssertEqual(attachments.first?.referencedAt, instant)
    }

    /// Keeps the real HTTP/WebSocket server alive for the non-interactive iOS process-chaos
    /// driver. The app receives this loopback URL through the same narrow DEBUG-only door as the
    /// terminal wire lab, so no durable pairing, developer Keychain item, or production listener
    /// is touched. The shell driver owns process faults and proves recovery from the app's
    /// share-safe journal; this fixture owns only a bounded server lifetime.
    func testRemoteConnectivityProcessFixtureWhenEnabled() throws {
        let environment = ProcessInfo.processInfo.environment
        try XCTSkipUnless(
            environment["THREADING_REMOTE_CONNECTIVITY_FIXTURE"] == "1",
            "Run only from the iOS connectivity process-chaos driver."
        )
        let launchURL = URL(fileURLWithPath: try XCTUnwrap(
            environment["THREADING_REMOTE_CONNECTIVITY_LAUNCH_PATH"]
        ))
        let stopURL = URL(fileURLWithPath: try XCTUnwrap(
            environment["THREADING_REMOTE_CONNECTIVITY_STOP_PATH"]
        ))
        try? FileManager.default.removeItem(at: launchURL)
        try? FileManager.default.removeItem(at: stopURL)

        let launch = ["url": "http://127.0.0.1:\(port!)/#goodtoken"]
        try JSONSerialization.data(withJSONObject: launch, options: [.sortedKeys])
            .write(to: launchURL, options: .atomic)
        print("THREADING_REMOTE_CONNECTIVITY_READY \(launchURL.path)")

        defer {
            try? FileManager.default.removeItem(at: launchURL)
            try? FileManager.default.removeItem(at: stopURL)
        }
        let timeout = TimeInterval(
            environment["THREADING_REMOTE_CONNECTIVITY_TIMEOUT"] ?? ""
        ) ?? 300
        let deadline = Date(timeIntervalSinceNow: min(max(timeout, 30), 1_800))
        while !FileManager.default.fileExists(atPath: stopURL.path), Date() < deadline {
            RunLoop.main.run(until: min(deadline, Date(timeIntervalSinceNow: 0.05)))
        }
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: stopURL.path),
            "The connectivity process fixture timed out before its stop marker."
        )
    }

    /// Hosts two token-free, provider-shaped terminal workloads for the iOS simulator lab.
    /// Unlike the static mobile demos, these are child processes on real PTYs behind the
    /// shipping remote server. The driver supplies all file locations and stops the host with a
    /// marker, keeping the opt-in test isolated from a developer's running Threading process.
    func testInteractiveRemoteTerminalWireFixtureWhenEnabled() throws {
        let environment = ProcessInfo.processInfo.environment
        try XCTSkipUnless(
            environment["THREADING_REMOTE_TERMINAL_WIRE_FIXTURE"] == "1",
            "Run only from the iOS terminal wire driver."
        )
        let helperPath = try XCTUnwrap(
            environment["THREADING_REMOTE_TERMINAL_WIRE_HELPER"],
            "The driver must supply its built threading-scenario executable."
        )
        XCTAssertTrue(
            FileManager.default.isExecutableFile(atPath: helperPath),
            "The terminal wire helper is not executable at \(helperPath)."
        )
        let historyLines = Int(
            environment["THREADING_REMOTE_TERMINAL_WIRE_HISTORY_LINES"] ?? ""
        ) ?? 2_400
        XCTAssertTrue((1...10_000).contains(historyLines))
        let launchURL = URL(fileURLWithPath: try XCTUnwrap(
            environment["THREADING_REMOTE_TERMINAL_WIRE_LAUNCH_PATH"]
        ))
        let stopURL = URL(fileURLWithPath: try XCTUnwrap(
            environment["THREADING_REMOTE_TERMINAL_WIRE_STOP_PATH"]
        ))
        try? FileManager.default.removeItem(at: launchURL)
        try? FileManager.default.removeItem(at: stopURL)

        let temporary = FileManager.default.temporaryDirectory
            .appendingPathComponent("threading-terminal-wire-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        // `xcrun xctest` loads the app's test bundle without running AppDelegate, so the live
        // composition root has not installed its terminal capability. Install that same
        // adapter explicitly before creating the fixture controllers; otherwise `/api/me`
        // lists the sessions but the first WebSocket auth closes with 4004 because the mirror
        // cannot see their PTYs.
        RemoteSessionMirrorRegistry.shared.installTerminalApplication(
            LiveRemoteTerminalApplicationCapability(surfaces: AgentRuntime.shared)
        )
        let project = try XCTUnwrap(ProjectStore.shared.addProject(folderURL: temporary))
        let codex = try XCTUnwrap(ProjectStore.shared.addSession(
            to: project.id,
            kind: .codex,
            usesNativeUI: false,
            title: "Codex · terminal wire lab"
        ))
        let claude = try XCTUnwrap(ProjectStore.shared.addSession(
            to: project.id,
            kind: .claude,
            usesNativeUI: false,
            title: "Claude · terminal wire lab"
        ))
        let codexController = AgentRuntime.shared.makeController(for: codex)
        let claudeController = AgentRuntime.shared.makeController(for: claude)
        codexController.startRemoteTerminalFixture(plan: AgentLaunchPlan(
            executable: helperPath,
            arguments: ["terminal-fixture", "codex", "--history-lines", String(historyLines)],
            resumeState: .unavailable
        ))
        claudeController.startRemoteTerminalFixture(plan: AgentLaunchPlan(
            executable: helperPath,
            arguments: ["terminal-fixture", "claude", "--history-lines", String(historyLines)],
            resumeState: .unavailable
        ))
        XCTAssertTrue(codexController.isRunning)
        XCTAssertTrue(claudeController.isRunning)
        XCTAssertNotNil(RemoteSessionMirrorRegistry.shared.beginCapturing(sessionID: codex.id))
        XCTAssertNotNil(RemoteSessionMirrorRegistry.shared.beginCapturing(sessionID: claude.id))

        let origin = "http://127.0.0.1:\(port!)"
        let launch: [String: Any] = [
            "url": "\(origin)/#goodtoken",
            "codexSessionID": codex.id.uuidString,
            "claudeSessionID": claude.id.uuidString,
            "historyLines": historyLines,
        ]
        try JSONSerialization.data(withJSONObject: launch, options: [.sortedKeys])
            .write(to: launchURL, options: .atomic)
        print("THREADING_REMOTE_TERMINAL_WIRE_READY \(launchURL.path)")

        defer {
            try? FileManager.default.removeItem(at: launchURL)
            try? FileManager.default.removeItem(at: stopURL)
            AgentRuntime.shared.discard(sessionID: codex.id)
            AgentRuntime.shared.discard(sessionID: claude.id)
            _ = ProjectStore.shared.removeProject(id: project.id)
            try? FileManager.default.removeItem(at: temporary)
        }

        let timeout = TimeInterval(
            environment["THREADING_REMOTE_TERMINAL_WIRE_TIMEOUT"] ?? ""
        ) ?? 600
        let deadline = Date(timeIntervalSinceNow: min(max(timeout, 30), 3_600))
        while !FileManager.default.fileExists(atPath: stopURL.path),
              codexController.isRunning || claudeController.isRunning,
              Date() < deadline {
            RunLoop.main.run(until: min(deadline, Date(timeIntervalSinceNow: 0.05)))
        }
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: stopURL.path)
                || (!codexController.isRunning && !claudeController.isRunning),
            "The terminal wire lab timed out before its stop marker or both fixtures finished."
        )
    }

    /// Opt-in live host for the browser-driven release gate. Unlike a fixture page, this puts a
    /// real PTY behind the shipping HTTP/WebSocket server and keeps two independently
    /// authenticated clients connected until one atomically submits `finish-e2e`.
    func testInteractiveRemoteBrowserJourneyWhenEnabled() throws {
        let enableMarker = URL(
            fileURLWithPath: "/tmp/threading-remote-browser-e2e-enabled",
            isDirectory: true
        )
        let explicitlyEnabled = ProcessInfo.processInfo.environment[
            "THREADING_REMOTE_BROWSER_E2E"
        ] == "1" || FileManager.default.fileExists(atPath: enableMarker.path)
        try XCTSkipUnless(explicitlyEnabled, "Run only from the browser E2E driver.")
        try? FileManager.default.removeItem(at: enableMarker)

        let temporary = FileManager.default.temporaryDirectory
            .appendingPathComponent("threading-remote-browser-e2e", isDirectory: true)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        let project = try XCTUnwrap(ProjectStore.shared.addProject(folderURL: temporary))
        let session = try XCTUnwrap(ProjectStore.shared.addSession(
            to: project.id,
            kind: .codex,
            usesNativeUI: false,
            title: "Remote collaboration release gate"
        ))
        let controller = AgentRuntime.shared.makeController(for: session)
        controller.startRemoteBrowserE2EFixture()
        XCTAssertTrue(controller.isRunning)

        let redeemer = RemoteBrowserE2ERedeemer(
            authority: authority,
            sessionID: session.id
        )
        server.invitationRedeemer = redeemer
        let origin = "http://127.0.0.1:\(port!)"
        let launch = [
            "ownerURL": "\(origin)/#goodtoken",
            "guestURL": "\(origin)/#guestinvite",
            "sessionID": session.id.uuidString,
        ]
        let launchURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("threading-remote-browser-e2e.json")
        try JSONSerialization.data(withJSONObject: launch, options: [.sortedKeys])
            .write(to: launchURL, options: .atomic)
        print("THREADING_REMOTE_BROWSER_E2E_READY \(launchURL.path)")

        defer {
            try? FileManager.default.removeItem(at: launchURL)
            AgentRuntime.shared.discard(sessionID: session.id)
            ProjectStore.shared.removeProject(id: project.id)
            try? FileManager.default.removeItem(at: temporary)
            _ = redeemer
        }

        let deadline = Date(timeIntervalSinceNow: 180)
        while controller.isRunning, Date() < deadline {
            RunLoop.main.run(until: min(deadline, Date(timeIntervalSinceNow: 0.05)))
        }
        XCTAssertFalse(
            controller.isRunning,
            "The browser journey did not atomically submit its finish line before timing out."
        )
    }

    /// Opens a loopback TCP socket, writes `request`, and returns whatever comes back as a string.
    private func socketExchange(_ request: String) throws -> String {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        try XCTSkipIf(fd < 0, "could not open a socket")
        defer { close(fd) }

        var timeout = timeval(tv_sec: 1, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))

        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        inet_pton(AF_INET, "127.0.0.1", &addr.sin_addr)

        let connected = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        try XCTSkipIf(connected != 0, "could not connect to the loopback server")

        let bytes = Array(request.utf8)
        _ = bytes.withUnsafeBytes { send(fd, $0.baseAddress, bytes.count, 0) }

        var buffer = [UInt8](repeating: 0, count: 1024)
        let received = recv(fd, &buffer, buffer.count, 0)
        guard received > 0 else { return "" }
        return String(decoding: buffer[0..<received], as: UTF8.self)
    }
}

@MainActor
private final class RecordingRemoteSessionAccess: RemoteSessionQuerying, RemoteSessionMutating {
    struct PinnedMutation: Equatable {
        let sessionID: SessionID
        let isPinned: Bool
    }

    struct SurfaceMutation: Equatable {
        let sessionID: SessionID
        let usesNativeUI: Bool
    }

    struct LimitRecoveryMutation: Equatable {
        let sessionID: SessionID
        let policy: LimitRecoveryPolicy?
    }

    private let store: ProjectStore
    private(set) var queriedSessionIDs: [SessionID] = []
    private(set) var queriedTerminalIDs: [TerminalID] = []
    private(set) var queriedProjectIDs: [ProjectID] = []
    private(set) var pinnedMutations: [PinnedMutation] = []
    private(set) var surfaceMutations: [SurfaceMutation] = []
    private(set) var limitRecoveryMutations: [LimitRecoveryMutation] = []
    var persistenceBlockReasonOverride: ProjectStorePersistenceBlock?
    var pinnedMutationResultOverride: ProjectMutationResult?

    init(store: ProjectStore) {
        self.store = store
    }

    var persistenceBlockReason: ProjectStorePersistenceBlock? {
        persistenceBlockReasonOverride ?? store.persistenceBlockReason
    }

    func session(withID sessionID: SessionID) -> AgentSession? {
        queriedSessionIDs.append(sessionID)
        return store.session(withID: sessionID)
    }

    func terminal(withID terminalID: TerminalID) -> ProjectTerminal? {
        queriedTerminalIDs.append(terminalID)
        return store.terminal(withID: terminalID)
    }

    func project(withID projectID: ProjectID) -> Project? {
        queriedProjectIDs.append(projectID)
        return store.project(withID: projectID)
    }

    func project(forSessionID sessionID: SessionID) -> Project? {
        store.project(forSessionID: sessionID)
    }

    func renameSession(id sessionID: SessionID, to title: String?) -> ProjectMutationResult {
        store.renameSession(id: sessionID, to: title)
    }

    func setProjectHidden(_ hidden: Bool, projectID: ProjectID) -> ProjectMutationResult {
        store.setProjectHidden(hidden, projectID: projectID)
    }

    func setPinned(_ pinned: Bool, for sessionID: SessionID) -> ProjectMutationResult {
        pinnedMutations.append(PinnedMutation(sessionID: sessionID, isPinned: pinned))
        if let pinnedMutationResultOverride { return pinnedMutationResultOverride }
        return store.setPinned(pinned, for: sessionID)
    }

    func setUsesNativeUI(
        _ usesNativeUI: Bool,
        for sessionID: SessionID
    ) -> ProjectMutationResult {
        surfaceMutations.append(SurfaceMutation(
            sessionID: sessionID,
            usesNativeUI: usesNativeUI
        ))
        return store.setUsesNativeUI(usesNativeUI, for: sessionID)
    }

    func setLimitRecoveryPolicy(
        _ policy: LimitRecoveryPolicy?,
        forSessionID sessionID: SessionID
    ) -> ProjectMutationResult {
        limitRecoveryMutations.append(.init(sessionID: sessionID, policy: policy))
        return store.setLimitRecoveryPolicy(policy, forSessionID: sessionID)
    }
}

@MainActor
private final class RecordingRemoteRuntimeStatus: RemoteRuntimeStatus {
    private let runtime: AgentRuntime
    private(set) var runningSessionIDs: [SessionID] = []

    init(runtime: AgentRuntime) {
        self.runtime = runtime
    }

    func isRunning(sessionID: SessionID) -> Bool {
        runningSessionIDs.append(sessionID)
        return runtime.isRunning(sessionID: sessionID)
    }

    func discard(sessionID: SessionID, preservingViewport: Bool) {
        runtime.discard(sessionID: sessionID, preservingViewport: preservingViewport)
    }

    func resolveRemotePermission(
        sessionID: SessionID,
        id: String,
        decision: RemotePermissionDecision
    ) -> Bool {
        runtime.resolveRemotePermission(sessionID: sessionID, id: id, decision: decision)
    }
}

@MainActor
private final class RecordingRemoteSettingsMutator: RemoteSettingsMutating {
    struct AppSettingMutation: Equatable {
        let identity: String
        let value: AppSettingStoredValue
    }

    private let appSettings: AppSettings
    private(set) var appThemeIDs: [AppThemeID] = []
    private(set) var appSettingMutations: [AppSettingMutation] = []
    var appliesAppThemesToHost = false

    init(appSettings: AppSettings) {
        self.appSettings = appSettings
    }

    func applyAppSetting(
        identity: String,
        value: AppSettingStoredValue
    ) -> AppSettingRemoteMutationResult {
        appSettingMutations.append(.init(identity: identity, value: value))
        return appSettings.applyRemoteMutation(identity: identity, value: value)
    }

    func applyAppTheme(id: AppThemeID) -> RemoteAppThemeMutationResult {
        appThemeIDs.append(id)
        if appliesAppThemesToHost {
            return LiveRemoteSettingsMutator(appSettings: appSettings).applyAppTheme(id: id)
        }
        guard let theme = AppThemeLibrary.theme(withID: id) else { return .unknownTheme }
        return .applied(theme.id)
    }

    func setSessionTheme(
        id: TerminalThemeID?,
        for sessionID: SessionID
    ) -> ProjectMutationResult {
        if let id, ThemeAssignments.selectableTheme(withID: id) == nil {
            return .unsupportedValue
        }
        return .unchanged
    }
}

private final class RecordingRemoteEventRecorder: @unchecked Sendable, RemoteEventRecording {
    private let lock = NSLock()
    private var recordedMessages: [String] = []
    private var recordedDetails: [String: [RemoteEventField: String]] = [:]

    var messages: [String] {
        lock.withLock { recordedMessages }
    }

    /// The detail last recorded under one message, for asserting which fields a route filed.
    func detail(for message: String) -> [RemoteEventField: String]? {
        lock.withLock { recordedDetails[message] }
    }

    func recordRemoteEvent(
        _ message: String,
        _ detail: [RemoteEventField: String]
    ) {
        lock.withLock {
            recordedMessages.append(message)
            recordedDetails[message] = detail
        }
    }
}

@MainActor
private final class RecordingRemoteSessionCommands: RemoteSessionCommands {
    struct SessionRefresh {
        let sessionID: SessionID
        let archived: Bool
    }

    var createdSessionID: SessionID?
    var resumeResult = true
    var onResume: (() -> Void)?
    var accountMoveResult: Result<Void, RemoteSessionAccountMoveFailure> = .success(())
    private(set) var launches: [RemoteSessionLaunch] = []
    private(set) var openingAttachmentPayloads: [[Data?]] = []
    private(set) var resumedSessionIDs: [SessionID] = []
    private(set) var resumedTerminalIDs: [TerminalID] = []
    private(set) var accountMoves: [(sessionID: SessionID, accountHandle: AccountHandle)] = []
    var continuationResult: Result<SessionID, RemoteSessionContinuationFailure> = .success(SessionID())
    private(set) var continuations: [
        (sessionID: SessionID, destination: RemoteContinuationTarget)
    ] = []
    private(set) var sessionRefreshes: [SessionRefresh] = []
    private(set) var surfaceRefreshes: [SessionID] = []

    func resumeRemoteSession(_ sessionID: SessionID) -> Bool {
        resumedSessionIDs.append(sessionID)
        onResume?()
        return resumeResult
    }

    func resumeRemoteTerminal(_ terminalID: TerminalID) -> Bool {
        resumedTerminalIDs.append(terminalID)
        return resumeResult
    }

    func moveRemoteSession(
        _ sessionID: SessionID,
        to accountHandle: AccountHandle
    ) -> Result<Void, RemoteSessionAccountMoveFailure> {
        accountMoves.append((sessionID: sessionID, accountHandle: accountHandle))
        return accountMoveResult
    }

    func continueRemoteSession(
        _ sessionID: SessionID,
        with destination: RemoteContinuationTarget,
        completion: @escaping @MainActor @Sendable (
            Result<SessionID, RemoteSessionContinuationFailure>
        ) -> Void
    ) {
        continuations.append((sessionID: sessionID, destination: destination))
        completion(continuationResult)
    }

    func startRemoteSession(_ launch: RemoteSessionLaunch) -> SessionID? {
        launches.append(launch)
        openingAttachmentPayloads.append(launch.openingAttachmentPaths.map {
            try? Data(contentsOf: URL(fileURLWithPath: $0))
        })
        return createdSessionID
    }

    func refreshAfterRemoteSessionMutation(sessionID: SessionID, archived: Bool) {
        sessionRefreshes.append(SessionRefresh(sessionID: sessionID, archived: archived))
    }

    func refreshAfterRemoteSurfaceMutation(sessionID: SessionID) {
        surfaceRefreshes.append(sessionID)
    }
}

@MainActor
private final class RemoteBrowserE2ERedeemer: RemoteInvitationRedeeming {
    private let authority: RemoteAuthorityStore
    private let sessionID: SessionID

    init(authority: RemoteAuthorityStore, sessionID: SessionID) {
        self.authority = authority
        self.sessionID = sessionID
    }

    func redeemInvitation(
        token: String,
        deviceID: String,
        displayName: String,
        persistsOwnerDevice _: Bool
    ) -> RemoteInvitationRedemption? {
        guard token == "guestinvite" else { return nil }
        let member = RemoteMember(
            id: "browser-guest",
            displayName: displayName,
            deviceID: deviceID
        )
        let authorization = RemoteAuthorization(
            shareID: "browser-guest",
            capability: .interact,
            scope: .session(sessionID),
            principal: .guest,
            member: member
        )
        let accessToken = "accepted-guestinvite"
        authority.set(authorization, forToken: accessToken)
        return RemoteInvitationRedemption(
            accessToken: accessToken,
            authorization: authorization
        )
    }
}

@MainActor
private final class InvitationPersistenceSpy: RemoteInvitationRedeeming {
    private(set) var persistenceRequests: [Bool] = []

    func redeemInvitation(
        token: String,
        deviceID: String,
        displayName: String,
        persistsOwnerDevice: Bool
    ) -> RemoteInvitationRedemption? {
        persistenceRequests.append(persistsOwnerDevice)
        return RemoteInvitationRedemption(
            accessToken: "accepted-\(token)",
            authorization: RemoteAuthorization(
                shareID: "owner-\(token)",
                capability: .interact,
                scope: .allSessions,
                principal: .ownerDevice,
                boundDeviceID: deviceID
            )
        )
    }
}

// MARK: - Remote transport and durable-owner policy

@MainActor
final class RemoteAccessTransportPolicyTests: XCTestCase {

    func testSessionRemovalDeltaNamesOnlyTheCoveredDeletedSession() {
        let removedSessionID = SessionID()
        let otherSessionID = SessionID()
        let change = ProjectsDidChange(sidebarImpact: .sessionRemoved(
            projectID: ProjectID(),
            sessionID: removedSessionID
        ))
        let allSessions = RemoteAuthorization(
            shareID: "all",
            capability: .interact,
            scope: .allSessions
        )
        let exactSession = RemoteAuthorization(
            shareID: "exact",
            capability: .view,
            scope: .session(removedSessionID)
        )
        let otherSession = RemoteAuthorization(
            shareID: "other",
            capability: .view,
            scope: .session(otherSessionID)
        )

        XCTAssertEqual(
            RemoteSessionMirrorRegistry.sessionRemovalDelta(
                for: change,
                authorization: allSessions
            )?.removedSessionID,
            removedSessionID.uuidString
        )
        XCTAssertEqual(
            RemoteSessionMirrorRegistry.sessionRemovalDelta(
                for: change,
                authorization: exactSession
            )?.removedSessionID,
            removedSessionID.uuidString
        )
        XCTAssertNil(RemoteSessionMirrorRegistry.sessionRemovalDelta(
            for: change,
            authorization: otherSession
        ))
        XCTAssertNil(RemoteSessionMirrorRegistry.sessionRemovalDelta(
            for: ProjectsDidChange(sidebarImpact: .sessionRow(removedSessionID)),
            authorization: allSessions
        ))
    }

    func testSessionMutationDeltaDoesNotSignalAnOutOfScopeIdentity() {
        let changedSessionID = SessionID()
        let otherSessionID = SessionID()
        let exactSession = RemoteAuthorization(
            shareID: "exact",
            capability: .view,
            scope: .session(changedSessionID)
        )
        let otherSession = RemoteAuthorization(
            shareID: "other",
            capability: .view,
            scope: .session(otherSessionID)
        )

        XCTAssertEqual(
            RemoteSessionMirrorRegistry.sessionMutationDelta(
                sessionID: changedSessionID,
                visibleSummary: nil,
                authorization: exactSession
            )?.removedSessionID,
            changedSessionID.uuidString
        )
        XCTAssertNil(RemoteSessionMirrorRegistry.sessionMutationDelta(
            sessionID: changedSessionID,
            visibleSummary: nil,
            authorization: otherSession
        ))
    }

    func testPromptReplayCacheRejectsConflictsExpiresAndStaysBounded() {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        var cache = RemotePromptReplayCache(maximumEntries: 2, lifetime: 10)
        let first = RemotePromptReplayCache.Key(
            sessionID: "session-1",
            principalID: "device-1",
            requestID: "request-1"
        )
        let second = RemotePromptReplayCache.Key(
            sessionID: "session-1",
            principalID: "device-2",
            requestID: "request-2"
        )
        let third = RemotePromptReplayCache.Key(
            sessionID: "session-2",
            principalID: "device-3",
            requestID: "request-3"
        )
        let promptA = Data("prompt-a".utf8)
        let promptB = Data("prompt-b".utf8)

        XCTAssertEqual(cache.decision(for: first, fingerprint: promptA, now: start), .new)
        cache.store(.accepted, for: first, fingerprint: promptA, now: start)
        XCTAssertEqual(
            cache.decision(for: first, fingerprint: promptA, now: start),
            .replay(.accepted)
        )
        XCTAssertEqual(
            cache.decision(for: first, fingerprint: promptB, now: start),
            .conflict
        )

        cache.store(.busy, for: second, fingerprint: promptB, now: start)
        cache.store(.accepted, for: third, fingerprint: promptA, now: start)
        XCTAssertEqual(cache.count, 2)
        XCTAssertEqual(cache.decision(for: first, fingerprint: promptA, now: start), .new)

        XCTAssertEqual(
            cache.decision(
                for: second,
                fingerprint: promptB,
                now: start.addingTimeInterval(11)
            ),
            .new
        )
        XCTAssertEqual(cache.count, 0)
    }

    /// Re-storing a key that is already cached must not cost an unrelated entry its place.
    ///
    /// This is the *normal* path, not an edge: a prompt is stored once when it is accepted and
    /// again when its status settles, so every prompt stores its key twice. The eviction loop
    /// ran on `entries.count` after the key had been pulled out of `order` but before it was
    /// pulled out of `entries`, so the count still said "full" and the oldest *other* entry was
    /// dropped to make room for something already present.
    ///
    /// The cost is the exact guarantee this cache exists to provide: the evicted prompt's
    /// replay state is gone, so its retry reads as `.new` and the prompt is submitted a second
    /// time.
    func testUpdatingACachedPromptDoesNotEvictAnotherOne() {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        var cache = RemotePromptReplayCache(maximumEntries: 2, lifetime: 600)
        let mine = RemotePromptReplayCache.Key(
            sessionID: "session-1", principalID: "device-1", requestID: "request-1"
        )
        let theirs = RemotePromptReplayCache.Key(
            sessionID: "session-2", principalID: "device-2", requestID: "request-2"
        )
        let promptA = Data("prompt-a".utf8)
        let promptB = Data("prompt-b".utf8)

        cache.store(.accepted, for: mine, fingerprint: promptA, now: start)
        cache.store(.busy, for: theirs, fingerprint: promptB, now: start)
        XCTAssertEqual(cache.count, 2)

        // The second store for `mine` — the status settling, which every prompt does.
        cache.store(.accepted, for: mine, fingerprint: promptA, now: start)

        XCTAssertEqual(cache.count, 2, "updating an entry changed how many are held")
        XCTAssertEqual(
            cache.decision(for: theirs, fingerprint: promptB, now: start),
            .replay(.busy),
            "an unrelated prompt was evicted by an update, and would now be submitted twice"
        )
        XCTAssertEqual(
            cache.decision(for: mine, fingerprint: promptA, now: start),
            .replay(.accepted)
        )
    }

    /// A genuine insert past the cap still evicts, oldest first — the property the update path
    /// above must not be fixed at the expense of.
    func testAThirdPromptStillEvictsTheOldest() {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        var cache = RemotePromptReplayCache(maximumEntries: 2, lifetime: 600)
        let keys = (1...3).map {
            RemotePromptReplayCache.Key(
                sessionID: "session-\($0)", principalID: "device-\($0)", requestID: "request-\($0)"
            )
        }
        let fingerprint = Data("prompt".utf8)

        for key in keys { cache.store(.accepted, for: key, fingerprint: fingerprint, now: start) }

        XCTAssertEqual(cache.count, 2)
        XCTAssertEqual(cache.decision(for: keys[0], fingerprint: fingerprint, now: start), .new)
        XCTAssertEqual(
            cache.decision(for: keys[1], fingerprint: fingerprint, now: start), .replay(.accepted)
        )
        XCTAssertEqual(
            cache.decision(for: keys[2], fingerprint: fingerprint, now: start), .replay(.accepted)
        )
    }

    /// The attention policy keeps the same bounded map as the prompt cache, and had the same
    /// eviction defect. Here losing an entry costs the exactly-once guarantee on a *poke*: the
    /// evicted request replays as `.proceed` and the person is notified twice.
    func testUpdatingAStoredAttentionRequestDoesNotEvictAnother() {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        var policy = RemoteAttentionRequestPolicy(maximumEntries: 2, lifetime: 600, cooldown: 30)

        func request(_ index: Int) -> RemoteAttentionRequestPolicy.RequestKey {
            .init(sessionID: "session-\(index)", principalID: "member-\(index)", requestID: "request-\(index)")
        }
        func rate(_ index: Int) -> RemoteAttentionRequestPolicy.RateKey {
            .init(sessionID: "session-\(index)", principalID: "member-\(index)", recipientID: "anna")
        }
        let payload = Data("please review".utf8)

        policy.store(.delivered, requestKey: request(1), rateKey: rate(1), fingerprint: payload, now: start)
        policy.store(.unavailable, requestKey: request(2), rateKey: rate(2), fingerprint: payload, now: start)
        XCTAssertEqual(policy.count, 2)

        // The same request settling to a different status — the ordinary second store.
        policy.store(.rejected, requestKey: request(1), rateKey: rate(1), fingerprint: payload, now: start)

        XCTAssertEqual(policy.count, 2, "updating an entry changed how many are held")
        XCTAssertEqual(
            policy.decision(requestKey: request(2), rateKey: rate(2), fingerprint: payload, now: start),
            .replay(.unavailable),
            "an unrelated request was evicted by an update, and would poke its recipient twice"
        )
        XCTAssertEqual(
            policy.decision(requestKey: request(1), rateKey: rate(1), fingerprint: payload, now: start),
            .replay(.rejected)
        )
    }

    func testAttentionRequestsReplayExactlyOnceAndCollapseRepeatedPokes() {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        var policy = RemoteAttentionRequestPolicy(
            maximumEntries: 2,
            lifetime: 60,
            cooldown: 30
        )
        let first = RemoteAttentionRequestPolicy.RequestKey(
            sessionID: "session-1",
            principalID: "member-david:phone",
            requestID: "request-1"
        )
        let retry = RemoteAttentionRequestPolicy.RequestKey(
            sessionID: "session-1",
            principalID: "member-david:phone",
            requestID: "request-2"
        )
        let rate = RemoteAttentionRequestPolicy.RateKey(
            sessionID: "session-1",
            principalID: "member-david:phone",
            recipientID: "member-anna"
        )
        let firstPayload = Data("anna\0please review".utf8)
        let changedPayload = Data("anna\0different".utf8)

        XCTAssertEqual(
            policy.decision(
                requestKey: first,
                rateKey: rate,
                fingerprint: firstPayload,
                now: start
            ),
            .proceed
        )
        policy.store(
            .delivered,
            requestKey: first,
            rateKey: rate,
            fingerprint: firstPayload,
            now: start
        )
        XCTAssertEqual(
            policy.decision(
                requestKey: first,
                rateKey: rate,
                fingerprint: firstPayload,
                now: start.addingTimeInterval(1)
            ),
            .replay(.delivered),
            "a lost acknowledgement must not emit a second notification"
        )
        XCTAssertEqual(
            policy.decision(
                requestKey: first,
                rateKey: rate,
                fingerprint: changedPayload,
                now: start.addingTimeInterval(1)
            ),
            .conflict
        )
        XCTAssertEqual(
            policy.decision(
                requestKey: retry,
                rateKey: rate,
                fingerprint: firstPayload,
                now: start.addingTimeInterval(10)
            ),
            .rateLimited
        )
        XCTAssertEqual(
            policy.decision(
                requestKey: retry,
                rateKey: rate,
                fingerprint: firstPayload,
                now: start.addingTimeInterval(31)
            ),
            .proceed
        )
    }

    /// Serve's own origin, which is the browser convenience's address and no phone's: it is a
    /// publicly trusted `*.ts.net` certificate on Serve's dedicated port, and `/api/me` never
    /// carries it.
    func testTailscaleStatusBecomesAStableServeOrigin() throws {
        let status = Data("""
        {
          "BackendState": "Running",
          "Self": { "DNSName": "threading-mac.example.ts.net." }
        }
        """.utf8)

        XCTAssertEqual(
            TailscaleServeTransport.origin(fromStatusJSON: status),
            URL(string: "https://threading-mac.example.ts.net:8443/")
        )
        XCTAssertNil(TailscaleServeTransport.origin(fromStatusJSON: Data("""
        {
          "BackendState": "Stopped",
          "Self": { "DNSName": "threading-mac.example.ts.net." }
        }
        """.utf8)))
    }

    func testTailscaleReadinessNamesRecoveryInsteadOfCollapsingToUnavailable() {
        XCTAssertEqual(TailscaleServeTransport.readinessIssue(fromStatusJSON: Data("""
        { "BackendState": "NeedsLogin", "Self": { "DNSName": "" } }
        """.utf8)), .signedOut)
        XCTAssertEqual(TailscaleServeTransport.readinessIssue(fromStatusJSON: Data("""
        { "BackendState": "Stopped", "Self": { "DNSName": "mac.example.ts.net." } }
        """.utf8)), .stopped)
        XCTAssertEqual(TailscaleServeTransport.readinessIssue(fromStatusJSON: Data("{".utf8)),
                       .statusUnavailable)
    }

    func testTailscaleOwnsOnlyItsDedicatedServePort() {
        XCTAssertEqual(TailscaleServeTransport.statusArguments, [
            "status", "--json", "--peers=false",
        ])
        XCTAssertEqual(TailscaleServeTransport.serveArguments(localPort: 49152), [
            "serve", "--yes", "--bg", "--https=8443", "http://127.0.0.1:49152",
        ])
        XCTAssertEqual(TailscaleServeTransport.stopArguments, [
            "serve", "--https=8443", "off",
        ])
        XCTAssertFalse(TailscaleServeTransport.stopArguments.contains("reset"))
    }

    func testTailscaleRefusesToReplaceAnExistingServeHandler() {
        let empty = Data(#"{}"#.utf8)
        let occupied = Data(#"{"TCP":{"8443":{"HTTPS":true}}}"#.utf8)
        let unrelated = Data(#"{"TCP":{"443":{"HTTPS":true}}}"#.utf8)

        XCTAssertTrue(TailscaleServeTransport.isValidServeStatus(empty))
        XCTAssertFalse(TailscaleServeTransport.serveStatus(
            empty,
            containsHTTPSPort: 8443
        ))
        XCTAssertTrue(TailscaleServeTransport.serveStatus(
            occupied,
            containsHTTPSPort: 8443
        ))
        XCTAssertFalse(TailscaleServeTransport.serveStatus(
            unrelated,
            containsHTTPSPort: 8443
        ))
        XCTAssertEqual(TailscaleServeTransport.serveStatusArguments, [
            "serve", "status", "--json",
        ])
    }

    func testOwnerCredentialIsBoundToTheDeviceThatReceivedIt() {
        let authorization = RemoteAuthorization(
            shareID: "owner-device",
            capability: .interact,
            scope: .allSessions,
            principal: .ownerDevice,
            boundDeviceID: "device-one"
        )

        XCTAssertTrue(authorization.isBound(to: "device-one"))
        XCTAssertFalse(authorization.isBound(to: "device-two"))
        XCTAssertFalse(authorization.isBound(to: nil))
    }

    /// The doors ship as one switch per network, and a settings screen that offered a *mode*
    /// could not say what any of them cost. What survives of the mode is one migration.
    func testDoorSwitchesDefaultAndRoundTripWithoutEnablingAnotherDoor() throws {
        let suite = "RemoteDoorSwitches.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.register(defaults: AppSettingDefinitions.registeredDefaults)
        let settings = AppSettings(defaults: defaults)

        XCTAssertEqual(settings.remoteAccessDoors, [.lan])
        XCTAssertFalse(settings.remoteAccessTailscaleEnabled)
        XCTAssertFalse(settings.remoteAccessTailscaleServeEnabled)
        XCTAssertEqual(settings.remoteInputControlDefault, .collaborative)

        settings.remoteAccessTailscaleEnabled = true
        settings.remoteInputControlDefault = .focusedOwner
        XCTAssertTrue(AppSettings(defaults: defaults).remoteAccessTailscaleEnabled)
        XCTAssertEqual(AppSettings(defaults: defaults).remoteInputControlDefault, .focusedOwner)

        // Switching the only door off has to stay off. An empty array used to be written as an
        // absent key, which handed the read back to the registered default.
        settings.remoteAccessDoors = []
        XCTAssertEqual(AppSettings(defaults: defaults).remoteAccessDoors, [])

        // An unknown door fails closed rather than being guessed at.
        defaults.set(["lan", "moon"], forKey: "remoteAccessDoors")
        XCTAssertEqual(AppSettings(defaults: defaults).remoteAccessDoors, [.lan])
    }

    /// The one thing the retired mode still does.
    func testAStoredConnectionModeMigratesToTheDoorSwitchesExactlyOnce() throws {
        func settings(mode: String?) throws -> (AppSettings, UserDefaults, String) {
            let suite = "RemoteDoorMigration.\(UUID().uuidString)"
            let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
            defaults.register(defaults: AppSettingDefinitions.registeredDefaults)
            if let mode { defaults.set(mode, forKey: "remoteAccessConnectionMode") }
            return (AppSettings(defaults: defaults), defaults, suite)
        }

        // Both tailnet modes meant "this Mac answers on my tailnet".
        for mode in ["tailscale", "tailscaleAndRelay"] {
            let (migrated, defaults, suite) = try settings(mode: mode)
            defer { defaults.removePersistentDomain(forName: suite) }
            XCTAssertTrue(
                migrated.remoteAccessTailscaleEnabled,
                "\(mode) did not carry over to the tailnet door"
            )
            XCTAssertEqual(migrated.remoteAccessDoors, [.lan])
        }

        // Relay carries nothing: it stopped being an owner pairing route, so somebody who was
        // on it lands on the door that replaced it rather than on nothing at all.
        let (relay, relayDefaults, relaySuite) = try settings(mode: "relay")
        defer { relayDefaults.removePersistentDomain(forName: relaySuite) }
        XCTAssertFalse(relay.remoteAccessTailscaleEnabled)
        XCTAssertEqual(relay.remoteAccessDoors, [.lan])

        // A fresh install has no mode to read and is not changed by the migration either.
        let (fresh, freshDefaults, freshSuite) = try settings(mode: nil)
        defer { freshDefaults.removePersistentDomain(forName: freshSuite) }
        XCTAssertFalse(fresh.remoteAccessTailscaleEnabled)

        // An unreadable mode carries nothing rather than being guessed at.
        let (unknown, unknownDefaults, unknownSuite) = try settings(mode: "moon")
        defer { unknownDefaults.removePersistentDomain(forName: unknownSuite) }
        XCTAssertFalse(unknown.remoteAccessTailscaleEnabled)

        // And it runs once: switching the door off again survives the next launch.
        let (once, onceDefaults, onceSuite) = try settings(mode: "tailscale")
        defer { onceDefaults.removePersistentDomain(forName: onceSuite) }
        XCTAssertTrue(once.remoteAccessTailscaleEnabled)
        XCTAssertTrue(onceDefaults.bool(forKey: "didMigrateRemoteAccessDoors"))
        once.remoteAccessTailscaleEnabled = false
        XCTAssertFalse(AppSettings(defaults: onceDefaults).remoteAccessTailscaleEnabled)
    }

    /// Having read the retired keys, the migration takes them away. They are not settings any
    /// more, so leaving them on disk would leave three values nothing in the app can explain.
    func testTheMigrationDeletesTheRetiredModeKeysItRead() throws {
        let suite = "RemoteDoorMigrationCleanup.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.register(defaults: AppSettingDefinitions.registeredDefaults)
        defaults.set("tailscaleAndRelay", forKey: "remoteAccessConnectionMode")
        defaults.set(true, forKey: "remoteAccessAllowsOwnerRelayFallback")
        defaults.set(true, forKey: "remoteAccessKeepsRelayReady")

        XCTAssertTrue(AppSettings(defaults: defaults).remoteAccessTailscaleEnabled)

        for key in [
            "remoteAccessConnectionMode",
            "remoteAccessAllowsOwnerRelayFallback",
            "remoteAccessKeepsRelayReady",
        ] {
            XCTAssertNil(defaults.object(forKey: key), "\(key) survived the migration")
        }
    }
}

@MainActor
final class RemoteOwnerDeviceRegistryTests: XCTestCase {

    private let tokenA = String(repeating: "a", count: 43)
    private let tokenB = String(repeating: "b", count: 43)

    func testPairedOwnerCredentialSurvivesRegistryRecreationAndCanBeRevoked() throws {
        let store = InMemoryRemoteOwnerDeviceStore()
        let first = RemoteOwnerDeviceRegistry(store: store)
        let pairedAt = Date(timeIntervalSince1970: 1_700_000_000)
        let record = try XCTUnwrap(first.pair(
            deviceID: "phone-1",
            displayName: "David’s iPhone",
            token: tokenA,
            now: pairedAt
        ))

        let afterRestart = RemoteOwnerDeviceRegistry(store: store)
        XCTAssertEqual(afterRestart.devices, [record])
        XCTAssertEqual(afterRestart.devices.first?.authorization.boundDeviceID, "phone-1")

        XCTAssertEqual(afterRestart.revoke(id: record.id), record)
        XCTAssertTrue(RemoteOwnerDeviceRegistry(store: store).devices.isEmpty)
    }

    func testPairingTheSameDeviceRotatesItsBearerWithoutDuplicatingTheDevice() throws {
        let store = InMemoryRemoteOwnerDeviceStore()
        let registry = RemoteOwnerDeviceRegistry(store: store)
        let first = try XCTUnwrap(registry.pair(
            deviceID: "phone-1",
            displayName: "Phone",
            token: tokenA
        ))
        let rotated = try XCTUnwrap(registry.pair(
            deviceID: "phone-1",
            displayName: "Renamed Phone",
            token: tokenB
        ))

        XCTAssertEqual(rotated.id, first.id)
        XCTAssertEqual(rotated.token, tokenB)
        XCTAssertEqual(rotated.displayName, "Renamed Phone")
        XCTAssertEqual(registry.devices.count, 1)
        XCTAssertEqual(RemoteOwnerDeviceRegistry(store: store).devices, [rotated])
    }

    func testUnreadablePersistenceFailsClosedWithoutOverwritingIt() {
        let store = FailingOwnerDeviceStore(failsLoad: true)
        let registry = RemoteOwnerDeviceRegistry(store: store)

        XCTAssertNotNil(registry.persistenceError)
        XCTAssertNil(registry.pair(
            deviceID: "phone-1",
            displayName: "Phone",
            token: tokenA
        ))
        XCTAssertEqual(store.saveCount, 0)
    }

    func testFailedRevokeKeepsTheLiveCredential() throws {
        let initial = RemoteOwnerDeviceRecord(
            id: "owner-1",
            token: tokenA,
            deviceID: "phone-1",
            displayName: "Phone",
            pairedAt: Date(timeIntervalSince1970: 1_700_000_000),
            lastSeenAt: nil
        )
        let store = FailingOwnerDeviceStore(devices: [initial], failsSave: true)
        let registry = RemoteOwnerDeviceRegistry(store: store)

        XCTAssertNil(registry.revoke(id: initial.id))
        XCTAssertEqual(registry.devices, [initial])
        XCTAssertNotNil(registry.persistenceError)
    }

    func testFullResetCanDeleteEvenAnUnreadableCredentialItem() throws {
        let store = FailingOwnerDeviceStore(failsLoad: true)
        let registry = RemoteOwnerDeviceRegistry(store: store)
        XCTAssertNotNil(registry.persistenceError)

        try registry.deleteAllForAppReset()

        XCTAssertEqual(store.deleteCount, 1)
        XCTAssertTrue(registry.devices.isEmpty)
        XCTAssertNil(registry.persistenceError)
    }
}

@MainActor
final class RemoteGuestSharePersistenceTests: HostedStoreTestCase {

    private let invitationToken = String(repeating: "c", count: 43)
    private var appSettingsSuites: [(String, UserDefaults)] = []
    private var transportDoubles: [any RemoteAccessTransport] = []

    override func tearDown() {
        for (name, defaults) in appSettingsSuites {
            defaults.removePersistentDomain(forName: name)
        }
        appSettingsSuites.removeAll()
        transportDoubles.removeAll()
        super.tearDown()
    }

    private func isolatedRemoteAppSettings() -> AppSettings {
        let name = "RemoteGuestSharePersistenceTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        appSettingsSuites.append((name, defaults))
        return AppSettings(defaults: defaults)
    }

    /// Never the shipping transport. A coordinator built with the defaults owns a
    /// `TailscaleServeTransport` pointed at the real CLI, and the test bundle is hosted inside
    /// the app, so a coordinator that started it here would publish this developer's Mac.
    private func makeCoordinator(
        guestShareStore: RemoteGuestSharePersisting
    ) -> RemoteAccessCoordinator {
        let tailnet = RecordingTailnetTransport()
        transportDoubles.append(tailnet)
        return RemoteAccessCoordinator(
            ownerDeviceStore: InMemoryRemoteOwnerDeviceStore(),
            appSettings: isolatedRemoteAppSettings(),
            guestShareStore: guestShareStore,
            tailnetTransport: tailnet
        )
    }

    func testAcceptedGuestMembershipAndUnusedInvitationSurviveCoordinatorRecreation() throws {
        let sessionID = SessionID()
        let store = InMemoryRemoteGuestShareStore(shares: [RemoteGuestShareRecord(
            id: "share-one",
            sessionID: sessionID.uuidString,
            invitationToken: invitationToken,
            capability: .interact,
            canApprovePermissions: false,
            createdAt: Date(),
            expiresAt: Date(timeIntervalSinceNow: 3_600),
            members: []
        )])
        let first = makeCoordinator(guestShareStore: store)
        XCTAssertEqual(first.access(for: sessionID).links.count, 1)

        let redemption = try XCTUnwrap(first.redeemInvitation(
            token: invitationToken,
            deviceID: "anna-phone",
            displayName: "Anna",
            persistsOwnerDevice: false
        ))
        XCTAssertEqual(redemption.authorization.member?.displayName, "Anna")
        XCTAssertTrue(first.access(for: sessionID).links.isEmpty)
        XCTAssertEqual(first.access(for: sessionID).members.map(\.displayName), ["Anna"])

        let afterRestart = makeCoordinator(guestShareStore: store)
        XCTAssertTrue(afterRestart.access(for: sessionID).links.isEmpty)
        XCTAssertEqual(afterRestart.access(for: sessionID).members.map(\.displayName), ["Anna"])
    }

    func testGuestAcceptanceRetriesOnlyOnItsDeviceAndCannotSurviveRevocation() throws {
        let sessionID = SessionID()
        let url = URL(string: "https://dev.remote.threading.codes/join#fixture")!
        let store = InMemoryRemoteGuestShareStore(shares: [RemoteGuestShareRecord(
            id: "guest-retry", sessionID: sessionID.uuidString, invitationToken: invitationToken,
            hostedInvitationURL: url, capability: .interact, canApprovePermissions: false,
            createdAt: Date(), expiresAt: Date(timeIntervalSinceNow: 3600), members: [])])
        let coordinator = makeCoordinator(guestShareStore: store)
        XCTAssertEqual(coordinator.access(for: sessionID).links.first?.url, url)
        let accepted = try XCTUnwrap(coordinator.redeemInvitation(token: invitationToken,
            deviceID: "guest-phone", displayName: "Guest", persistsOwnerDevice: false))
        let retried = try XCTUnwrap(coordinator.redeemInvitation(token: invitationToken,
            deviceID: "guest-phone", displayName: "Guest", persistsOwnerDevice: false))
        XCTAssertEqual(accepted.accessToken, retried.accessToken)
        XCTAssertEqual(accepted.authorization.scope, .session(sessionID))
        XCTAssertFalse(accepted.authorization.canManageHost)
        XCTAssertFalse(accepted.authorization.canApprovePermissions)
        XCTAssertNil(coordinator.redeemInvitation(token: invitationToken,
            deviceID: "other-phone", displayName: "Other", persistsOwnerDevice: false))
        coordinator.revokeSessionShares(sessionID)
        XCTAssertNil(coordinator.redeemInvitation(token: invitationToken,
            deviceID: "guest-phone", displayName: "Guest", persistsOwnerDevice: false))
    }

    func testUnreadableGuestPersistenceFailsClosedWithoutConsumingAnInvitation() {
        let store = FailingGuestShareStore()
        let coordinator = makeCoordinator(guestShareStore: store)

        XCTAssertNotNil(coordinator.guestSharePersistenceError)
        XCTAssertNil(coordinator.redeemInvitation(
            token: invitationToken,
            deviceID: "anna-phone",
            displayName: "Anna",
            persistsOwnerDevice: false
        ))
        XCTAssertEqual(store.saveCount, 0)
    }

    func testStandaloneTerminalMembershipRestoresWithExactScopeAndNoAIApproval() throws {
        let terminalID = TerminalID()
        let store = InMemoryRemoteGuestShareStore(shares: [RemoteGuestShareRecord(
            id: "terminal-share",
            targetKind: .projectTerminal,
            sessionID: terminalID.uuidString,
            invitationToken: invitationToken,
            capability: .interact,
            canApprovePermissions: true,
            createdAt: Date(),
            expiresAt: Date(timeIntervalSinceNow: 3_600),
            members: []
        )])
        let first = makeCoordinator(guestShareStore: store)
        XCTAssertTrue(first.hasTerminalShares(terminalID))

        let redemption = try XCTUnwrap(first.redeemInvitation(
            token: invitationToken,
            deviceID: "anna-phone",
            displayName: "Anna",
            persistsOwnerDevice: false
        ))
        XCTAssertEqual(redemption.authorization.scope, .projectTerminal(terminalID))
        XCTAssertFalse(redemption.authorization.canApprovePermissions)
        XCTAssertFalse(redemption.authorization.canManageHost)

        let afterRestart = makeCoordinator(guestShareStore: store)
        XCTAssertTrue(afterRestart.hasTerminalShares(terminalID))
        XCTAssertEqual(store.shares.first?.targetKind, .projectTerminal)
        XCTAssertFalse(store.shares.first?.canApprovePermissions ?? true)
    }
}

private final class FailingGuestShareStore: RemoteGuestSharePersisting {
    enum Failure: Error { case expected }
    private(set) var saveCount = 0

    func load() throws -> [RemoteGuestShareRecord] { throw Failure.expected }
    func save(_: [RemoteGuestShareRecord]) throws {
        saveCount += 1
        throw Failure.expected
    }
    func deleteAll() throws {}
}

private final class FailingOwnerDeviceStore: RemoteOwnerDevicePersisting {
    enum Failure: Error { case expected }

    var devices: [RemoteOwnerDeviceRecord]
    let failsLoad: Bool
    let failsSave: Bool
    private(set) var saveCount = 0
    private(set) var deleteCount = 0

    init(
        devices: [RemoteOwnerDeviceRecord] = [],
        failsLoad: Bool = false,
        failsSave: Bool = false
    ) {
        self.devices = devices
        self.failsLoad = failsLoad
        self.failsSave = failsSave
    }

    func load() throws -> [RemoteOwnerDeviceRecord] {
        if failsLoad { throw Failure.expected }
        return devices
    }

    func save(_ devices: [RemoteOwnerDeviceRecord]) throws {
        saveCount += 1
        if failsSave { throw Failure.expected }
        self.devices = devices
    }

    func deleteAll() throws {
        deleteCount += 1
        devices = []
    }
}

final class RemoteAPNSConfigurationTests: XCTestCase {
    func testEnvironmentLoadsABoundedRegularPrivateKey() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "RemoteAPNSConfiguration.\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let keyURL = directory.appendingPathComponent("AuthKey.p8")
        let pem = P256.Signing.PrivateKey().pemRepresentation
        try pem.write(to: keyURL, atomically: true, encoding: .utf8)

        XCTAssertNotNil(RemoteAPNSPushSender.fromEnvironment(environment(keyURL)))
    }

    func testEnvironmentRefusesAnOversizedPrivateKeyBeforeParsing() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "RemoteAPNSConfigurationOversized.\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let keyURL = directory.appendingPathComponent("AuthKey.p8")
        try Data(repeating: 0x41, count: 64 * 1_024 + 1).write(to: keyURL)

        XCTAssertNil(RemoteAPNSPushSender.fromEnvironment(environment(keyURL)))
    }

    private func environment(_ keyURL: URL) -> [String: String] {
        [
            "THREADING_APNS_KEY_ID": "key-id",
            "THREADING_APNS_TEAM_ID": "team-id",
            "THREADING_APNS_PRIVATE_KEY_PATH": keyURL.path,
            "THREADING_APNS_TOPIC": "codes.threading.mobile",
        ]
    }
}

@MainActor
private final class HostedGuestCommandSpy: RemoteHostCommanding {
    var accessToken: String?
    var deviceID: String?
    var issueCount = 0
    var completedOwnerBootstrap = false

    func issueHostedDeviceCredential(accessToken: String, deviceID: String) async throws
        -> RemoteHostedDeviceCredentialDTO {
        self.accessToken = accessToken
        self.deviceID = deviceID
        issueCount += 1
        return RemoteHostedDeviceCredentialDTO(serviceURL: "https://dev.remote.threading.codes",
            hostID: "host", deviceID: "guest-membership", credential: "test-credential",
            expiresAt: Date().addingTimeInterval(3600).timeIntervalSince1970 * 1000)
    }
    func completeHostedPairingBootstrap() { completedOwnerBootstrap = true }
    func createSessionShare(for sessionID: SessionID, capability: RemoteCapability,
        canApprovePermissions: Bool) -> Result<RemoteCreatedShare, RemoteSharePreparationError> {
        .failure(.remoteAccessUnavailable)
    }
    func revokeSessionShares(_ sessionID: SessionID) {}
    func createTerminalShare(for terminalID: TerminalID, capability: RemoteCapability)
        -> Result<RemoteCreatedShare, RemoteSharePreparationError> { .failure(.remoteAccessUnavailable) }
    func revokeTerminalShares(_ terminalID: TerminalID) {}
}
