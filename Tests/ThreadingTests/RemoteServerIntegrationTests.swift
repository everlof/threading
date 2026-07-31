import XCTest
@testable import Threading

/// Boots the real `RemoteAccessServer` on a loopback port and probes it over an actual socket.
/// This is where the isolation invariant is pinned: the tunnel-facing server must not route any
/// MCP, permission or lifecycle path — those belong to a different server the tunnel never
/// reaches — and an unauthenticated API call must be refused.
@MainActor
final class RemoteServerIntegrationTests: XCTestCase {

    private var server: RemoteAccessServer!
    private var authority: RemoteAuthorityStore!
    private var port: UInt16!

    override func setUp() {
        super.setUp()
        authority = RemoteAuthorityStore()
        authority.set(
            RemoteAuthorization(shareID: "test", capability: .interact, scope: .allSessions),
            forToken: "goodtoken"
        )
        server = RemoteAccessServer()
        server.authorizer = authority
        server.receiveClientDiagnostics = { _, _, _ in true }

        let ready = expectation(description: "listening")
        server.start { resolved in
            self.port = resolved
            ready.fulfill()
        }
        wait(for: [ready], timeout: 5)
        XCTAssertNotNil(port, "the server should bind a loopback port")
    }

    override func tearDown() {
        server.stop()
        server = nil
        authority = nil
        super.tearDown()
    }

    // MARK: - Probing

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

    @MainActor
    func testThemeBridgeSendsEveryResolvedChromeRoleAndFullANSIPalette() {
        let chrome = RemoteThemeBridge.appTheme()
        XCTAssertEqual(
            Set(chrome.colors.keys),
            Set(AppThemeRole.allCases.map(\.wireName))
        )
        XCTAssertTrue(chrome.colors.values.allSatisfy { $0.hasPrefix("#") })
        XCTAssertTrue(["light", "dark"].contains(chrome.mode))

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
        let create = try JSONEncoder().encode(RemoteCreateSessionRequestDTO(
            projectID: UUID().uuidString,
            agentKind: "codex",
            surface: "conversation",
            prompt: "Do work"
        ))
        XCTAssertEqual(
            try XCTUnwrap(post("/api/session", bearer: "viewtoken", body: create)).status,
            403
        )
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
            RemoteSetSessionSurfaceRequestDTO(surface: "conversation")
        )
        XCTAssertEqual(
            try XCTUnwrap(post(
                "/api/session/\(sessionID.uuidString)/surface",
                bearer: "guesttoken",
                body: surface
            )).status,
            403
        )
        let share = try JSONEncoder().encode(
            RemoteCreateShareRequestDTO(capability: RemoteCapability.view.rawValue)
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
                "/api/session/\(sessionID.uuidString)/attachment?path=preview.png",
                bearer: "guesttoken"
            )).status,
            403
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
    }

    func testGuestPermissionApprovalIsAnIndependentChatRight() {
        let sessionID = SessionID()
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

        XCTAssertTrue(guest.scope.covers(sessionID))
        XCTAssertFalse(guest.canApprovePermissions)
        XCTAssertFalse(guest.canManageHost)
        XCTAssertTrue(trustedGuest.canApprovePermissions)
        XCTAssertFalse(trustedGuest.canManageHost)
        XCTAssertTrue(owner.canApprovePermissions)
        XCTAssertTrue(owner.canManageHost)
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
            RemoteConversationSnapshotDTO(rows: [], canSend: true),
            for: viewer
        )

        XCTAssertFalse(projected.canSend)
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
        let valid = try JSONEncoder().encode(RemoteNotificationRegistrationDTO(
            deviceToken: String(repeating: "ab", count: 32),
            environment: "sandbox",
            enabledKinds: [.permissionRequest, .agentMessage]
        ))
        let registered = try XCTUnwrap(post(
            RemoteRouter.notificationRegistrationPath,
            bearer: "goodtoken",
            body: valid
        ))
        XCTAssertEqual(registered.status, 200)
        let response = try JSONDecoder().decode(
            RemoteNotificationRegistrationResponseDTO.self,
            from: registered.body
        )
        XCTAssertTrue(["live", "push"].contains(response.delivery))

        let invalid = try JSONEncoder().encode(RemoteNotificationRegistrationDTO(
            deviceToken: "../../not-a-token",
            environment: "sandbox",
            enabledKinds: [.permissionRequest]
        ))
        XCTAssertEqual(
            try XCTUnwrap(post(
                RemoteRouter.notificationRegistrationPath,
                bearer: "goodtoken",
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
        XCTAssertEqual(accepted.me.share.scope, "all")
    }

    func testBearerSchemeIsCaseInsensitive() {
        let raw = "GET /api/me HTTP/1.1\r\nAuthorization: bearer goodtoken\r\n\r\n"
        guard case .request(let request, _) = MCPConnection.parseRequest(from: Data(raw.utf8)) else {
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

    func testQuickTunnelURLCanBeRecoveredAcrossLogChunks() throws {
        let log = """
            INF Requesting new quick Tunnel on trycloudflare.com...
            INF +-----------------------------------------------------------+
            INF |  https://quiet-river-42.trycloudflare.com                 |
            """
        XCTAssertEqual(
            RemoteTunnel.publicURL(in: log)?.absoluteString,
            "https://quiet-river-42.trycloudflare.com"
        )
        XCTAssertNil(RemoteTunnel.publicURL(in: "INF tunnel is still starting"))
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
        XCTAssertFalse(RemoteInboundPolicy.acceptsPrompt(
            String(repeating: "p", count: RemoteAccessDefaults.maximumPromptBytes + 1)
        ))
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
                kind: "assistant",
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
        XCTAssertEqual(bounded.rows.first?.kind, "notice")
        XCTAssertEqual(bounded.rows.last?.id, "299")
        XCTAssertLessThanOrEqual(
            bounded.streamingText.utf8.count,
            RemoteAccessDefaults.maximumRemoteStreamingBytes
        )
    }

    func testConversationInitialWindowAndOlderPageMeetWithoutSyntheticRows() {
        let rows = (0..<220).map {
            RemoteConversationRowDTO(id: String($0), kind: "assistant", text: "Row \($0)")
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
        XCTAssertFalse(initial.rows.contains(where: { $0.kind == "notice" }))
        XCTAssertEqual(page.rows.first?.id, "0")
        XCTAssertEqual(page.rows.last?.id, "59")
        XCTAssertFalse(page.hasEarlier)
    }

    func testConversationDeltaNamesOnlyAppendedAndUpdatedRows() throws {
        let previous = RemoteConversationSnapshotDTO(
            rows: [
                .init(id: "0", kind: "user", text: "Test"),
                .init(id: "1", kind: "tool", toolName: "Bash", summary: "swift test"),
            ],
            streamingText: "Run",
            canSend: false
        )
        let current = RemoteConversationSnapshotDTO(
            rows: [
                previous.rows[0],
                .init(
                    id: "1",
                    kind: "tool",
                    toolName: "Bash",
                    summary: "swift test",
                    result: "Passed"
                ),
                .init(id: "2", kind: "assistant", text: "Done"),
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

    func testAttachmentResponseIsHardenedAndClosesItsConnection() {
        let response = RemoteRouter.data(Data("image".utf8), contentType: "image/png")
        let serialized = String(decoding: response.serialized, as: UTF8.self)

        XCTAssertTrue(response.closesConnection)
        XCTAssertTrue(serialized.contains("Content-Type: image/png\r\n"))
        XCTAssertTrue(serialized.contains("Connection: close\r\n"))
        XCTAssertEqual(response.extraHeaders["Cache-Control"], "no-store")
        XCTAssertEqual(response.extraHeaders["X-Content-Type-Options"], "nosniff")
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
            Set(found.map { $0.resolvingSymlinksInPath().path }),
            Set([pdf.path, image.path, nestedImage.path])
        )
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
