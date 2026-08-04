import XCTest
@testable import ThreadingRemoteKit

final class RemoteProtocolTests: XCTestCase {

    func testNotificationPayloadAndRegistrationRoundTrip() throws {
        let event = RemoteNotificationEventDTO(
            id: "event-1",
            kind: .permissionRequest,
            hostID: "mac-1",
            sessionID: "session-1",
            title: "Needs permission",
            body: "Review the edit",
            createdAt: 123
        )
        XCTAssertEqual(
            try JSONDecoder().decode(
                RemoteNotificationEventDTO.self,
                from: JSONEncoder().encode(event)
            ),
            event
        )

        let registration = RemoteNotificationRegistrationDTO(
            deviceToken: "abcd",
            environment: "sandbox",
            enabledKinds: [.sharedSession, .permissionRequest]
        )
        XCTAssertEqual(
            try JSONDecoder().decode(
                RemoteNotificationRegistrationDTO.self,
                from: JSONEncoder().encode(registration)
            ),
            registration
        )
    }

    func testOlderSharePayloadDefaultsPermissionApprovalToFalse() throws {
        let data = Data(
            #"{"label":"guest","scope":"session","capability":"interact","expiresAt":null}"#
                .utf8
        )
        let share = try JSONDecoder().decode(RemoteMeDTO.Share.self, from: data)
        XCTAssertFalse(share.canApprovePermissions)
        XCTAssertNil(share.memberID)
        XCTAssertNil(share.displayName)
    }

    func testInvitationMembershipAndPresenceRoundTrip() throws {
        let request = RemoteCreateShareRequestDTO(
            capability: "interact",
            canApprovePermissions: true
        )
        XCTAssertEqual(
            try JSONDecoder().decode(
                RemoteCreateShareRequestDTO.self,
                from: JSONEncoder().encode(request)
            ),
            request
        )

        let acceptance = RemoteAcceptInvitationResponseDTO(
            accessToken: "membership",
            me: RemoteMeDTO(
                serverProtocol: RemoteProtocolInfo(),
                share: .init(
                    label: "member-1",
                    scope: "session",
                    capability: "interact",
                    canApprovePermissions: true,
                    expiresAt: nil,
                    memberID: "member-1",
                    displayName: "Kalle"
                ),
                sessions: []
            )
        )
        XCTAssertEqual(
            try JSONDecoder().decode(
                RemoteAcceptInvitationResponseDTO.self,
                from: JSONEncoder().encode(acceptance)
            ),
            acceptance
        )

        let presence = RemotePresenceDTO(
            memberID: "member-1",
            displayName: "Kalle",
            state: "typing",
            updatedAt: 123
        )
        XCTAssertEqual(
            try JSONDecoder().decode(
                RemotePresenceDTO.self,
                from: JSONEncoder().encode(presence)
            ),
            presence
        )
    }

    func testAMatchingPeerIsCompatible() {
        XCTAssertEqual(
            RemoteProtocolCompatibility.evaluate(
                peerVersion: RemoteProtocol.current,
                peerMinimumSupported: RemoteProtocol.minimumSupported
            ),
            .compatible
        )
    }

    func testAPeerBelowOurMinimumIsTooOld() {
        // A peer whose newest version is older than the oldest we accept.
        XCTAssertEqual(
            RemoteProtocolCompatibility.evaluate(
                peerVersion: RemoteProtocol.minimumSupported - 1,
                peerMinimumSupported: RemoteProtocol.minimumSupported - 1
            ),
            .peerTooOld
        )
    }

    func testWeAreTooOldWhenThePeerRequiresNewer() {
        // A peer that only speaks versions newer than ours.
        XCTAssertEqual(
            RemoteProtocolCompatibility.evaluate(
                peerVersion: RemoteProtocol.current + 5,
                peerMinimumSupported: RemoteProtocol.current + 1
            ),
            .selfTooOld
        )
    }

    func testANewerButBackwardCompatiblePeerStillTalks() {
        // Peer is newer, but still supports our version.
        XCTAssertEqual(
            RemoteProtocolCompatibility.evaluate(
                peerVersion: RemoteProtocol.current + 3,
                peerMinimumSupported: RemoteProtocol.current
            ),
            .compatible
        )
    }

    func testWireTypesRoundTripThroughJSON() throws {
        let terminalTheme = RemoteTerminalThemeDTO(
            id: "ocean",
            name: "Ocean",
            foreground: "#C0C5CE",
            background: "#2B303B",
            cursor: "#C0C5CE",
            selection: "#4F5B66",
            ansi: (0..<16).map { String(format: "#%02X%02X%02X", $0, $0, $0) }
        )
        let theme = RemoteThemeDTO(
            id: "cyberpunk",
            name: "Cyberpunk",
            mode: "dark",
            colors: ["ground": "#07070B", "accent": "#00FF88"],
            material: .init(
                panelRadius: 3,
                controlRadius: 2,
                borderWidth: 1,
                glow: .init(color: "#00FF88", radius: 10, opacity: 0.28),
                textScale: 0.8
            )
        )
        let me = RemoteMeDTO(
            serverProtocol: RemoteProtocolInfo(),
            share: .init(label: "l", scope: "all", capability: "interact", expiresAt: nil),
            sessions: [RemoteSessionSummaryDTO(
                id: "s", title: "t", agentKind: "claude", surface: "terminal",
                state: "idle", projectName: "p", isAvailable: false, lastActiveAt: 123,
                isPinned: true,
                terminalTheme: terminalTheme,
                terminalThemeAssignmentID: "ocean",
                inheritedTerminalThemeName: "Default",
                inheritedTerminalTheme: terminalTheme
            )],
            host: RemoteHostDTO(id: "mac", name: "Developer Mac"),
            theme: theme,
            themeCatalog: .init(appThemes: [theme], terminalThemes: [terminalTheme]),
            archivedSessions: [],
            newSessionCatalog: .init(
                projects: [
                    .init(id: "p", name: "Project", branch: "main", checkoutLabel: "Project")
                ],
                agents: [
                    .init(
                        id: "codex",
                        name: "Codex",
                        accounts: [
                            .init(
                                id: "default",
                                name: "Personal",
                                usageSummary: "5h 43% · 7d 73%",
                                usageFraction: 0.73,
                                models: [
                                    .init(
                                        id: "sol",
                                        name: "Sol",
                                        reasoning: [.init(id: "high", name: "High")],
                                        defaultReasoningID: "high"
                                    )
                                ],
                                defaultModelID: "sol"
                            )
                        ],
                        models: [
                            .init(
                                id: "sol",
                                name: "Sol",
                                reasoning: [.init(id: "high", name: "High")],
                                defaultReasoningID: "high"
                            )
                        ],
                        defaultModelID: "sol",
                        supportsConversation: true
                    )
                ]
            )
        )
        let data = try JSONEncoder().encode(me)
        XCTAssertEqual(try JSONDecoder().decode(RemoteMeDTO.self, from: data), me)
    }

    func testOlderSessionSummaryDefaultsToAvailable() throws {
        let json = """
            {
              "id": "s",
              "title": "Session",
              "agentKind": "codex",
              "surface": "terminal",
              "state": "idle",
              "projectName": "Project"
            }
            """
        let summary = try JSONDecoder().decode(
            RemoteSessionSummaryDTO.self,
            from: Data(json.utf8)
        )
        XCTAssertTrue(summary.isAvailable)
        XCTAssertNil(summary.lastActiveAt)
        XCTAssertNil(summary.terminalTheme)
        XCTAssertNil(summary.terminalThemeAssignmentID)
        XCTAssertNil(summary.inheritedTerminalTheme)
        XCTAssertFalse(summary.isPinned)
        XCTAssertFalse(summary.isArchived)
        XCTAssertFalse(summary.isShared)
    }

    func testOlderHelloAndMePayloadsDecodeWithoutThemes() throws {
        let helloJSON = """
            {
              "type": "hello",
              "surface": "terminal",
              "capability": "view",
              "cols": 80,
              "rows": 24,
              "title": "Session"
            }
            """
        let hello = try JSONDecoder().decode(RemoteHelloDTO.self, from: Data(helloJSON.utf8))
        XCTAssertNil(hello.theme)
        XCTAssertNil(hello.terminalTheme)

        let meJSON = """
            {
              "serverProtocol": {"version": 1, "minimumSupported": 1},
              "share": {"label": "l", "scope": "all", "capability": "view"},
              "sessions": []
            }
            """
        let me = try JSONDecoder().decode(RemoteMeDTO.self, from: Data(meJSON.utf8))
        XCTAssertNil(me.theme)
        XCTAssertNil(me.themeCatalog)
        XCTAssertNil(me.archivedSessions)
        XCTAssertNil(me.newSessionCatalog)
    }

    func testLiveThemeUpdateRoundTrips() throws {
        let update = RemoteThemeUpdateDTO(
            theme: .init(
                id: "swiss",
                name: "Swiss",
                mode: "light",
                colors: ["ground": "#FFFFFF", "label": "#111111"],
                material: .init(
                    panelRadius: 0,
                    controlRadius: 0,
                    borderWidth: 1,
                    glow: .init(
                        color: "#111111",
                        radius: 0,
                        opacity: 0.7,
                        offsetX: 4,
                        offsetY: -4
                    )
                )
            ),
            terminalTheme: .init(
                id: "swiss-terminal",
                name: "Swiss",
                foreground: "#111111",
                background: "#FFFFFF",
                cursor: "#D6180B",
                selection: "#FAD5D1",
                ansi: Array(repeating: "#111111", count: 16)
            )
        )
        let data = try JSONEncoder().encode(update)
        XCTAssertEqual(try JSONDecoder().decode(RemoteThemeUpdateDTO.self, from: data), update)

        let appUpdate = RemoteAppThemeUpdateDTO(theme: update.theme)
        let appData = try JSONEncoder().encode(appUpdate)
        XCTAssertEqual(
            try JSONDecoder().decode(RemoteAppThemeUpdateDTO.self, from: appData),
            appUpdate
        )

        let changed = RemoteSessionsChangedDTO()
        XCTAssertEqual(
            try JSONDecoder().decode(
                RemoteSessionsChangedDTO.self,
                from: JSONEncoder().encode(changed)
            ),
            changed
        )
    }

    func testViewportMessagesRoundTrip() throws {
        let viewport = RemoteClientMessage(type: "viewport", cols: 44, rows: 29)
        XCTAssertEqual(
            try JSONDecoder().decode(
                RemoteClientMessage.self,
                from: JSONEncoder().encode(viewport)
            ),
            viewport
        )

        let release = RemoteClientMessage(type: "viewportRelease")
        XCTAssertEqual(
            try JSONDecoder().decode(
                RemoteClientMessage.self,
                from: JSONEncoder().encode(release)
            ),
            release
        )
    }

    func testOlderThemeShadowDecodesWithoutOffsets() throws {
        let data = try XCTUnwrap("""
            {
              "id": "old-theme",
              "name": "Old Theme",
              "mode": "dark",
              "colors": {"ground": "#000000"},
              "material": {
                "panelRadius": 8,
                "controlRadius": 6,
                "borderWidth": 1,
                "glow": {"color": "#FF00FF", "radius": 8, "opacity": 0.2}
              }
            }
            """.data(using: .utf8))

        let theme = try JSONDecoder().decode(RemoteThemeDTO.self, from: data)
        XCTAssertNil(theme.material.glow?.offsetX)
        XCTAssertNil(theme.material.glow?.offsetY)
        XCTAssertNil(theme.material.textScale, "an older sender has no authored text scale")
    }

    func testThemeSelectionRequestsRoundTrip() throws {
        let app = RemoteSetAppThemeRequestDTO(themeID: "swiss")
        XCTAssertEqual(
            try JSONDecoder().decode(
                RemoteSetAppThemeRequestDTO.self,
                from: JSONEncoder().encode(app)
            ),
            app
        )

        for selection in [
            RemoteSetTerminalThemeRequestDTO(themeID: "ocean"),
            RemoteSetTerminalThemeRequestDTO(themeID: nil),
        ] {
            XCTAssertEqual(
                try JSONDecoder().decode(
                    RemoteSetTerminalThemeRequestDTO.self,
                    from: JSONEncoder().encode(selection)
                ),
                selection
            )
        }
    }

    func testSessionLifecycleRequestsRoundTrip() throws {
        let creation = RemoteCreateSessionRequestDTO(
            projectID: "project",
            agentKind: "codex",
            accountHandle: "codex-work",
            model: "sol",
            reasoningEffort: "high",
            surface: "conversation",
            prompt: "Review remote access"
        )
        XCTAssertEqual(
            try JSONDecoder().decode(
                RemoteCreateSessionRequestDTO.self,
                from: JSONEncoder().encode(creation)
            ),
            creation
        )

        let rename = RemoteRenameSessionRequestDTO(title: "Remote review")
        XCTAssertEqual(
            try JSONDecoder().decode(
                RemoteRenameSessionRequestDTO.self,
                from: JSONEncoder().encode(rename)
            ),
            rename
        )
        let pinned = RemoteSetSessionPinnedRequestDTO(isPinned: true)
        XCTAssertEqual(
            try JSONDecoder().decode(
                RemoteSetSessionPinnedRequestDTO.self,
                from: JSONEncoder().encode(pinned)
            ),
            pinned
        )
        let archived = RemoteSetSessionArchivedRequestDTO(isArchived: true)
        XCTAssertEqual(
            try JSONDecoder().decode(
                RemoteSetSessionArchivedRequestDTO.self,
                from: JSONEncoder().encode(archived)
            ),
            archived
        )
        let surface = RemoteSetSessionSurfaceRequestDTO(surface: "conversation")
        XCTAssertEqual(
            try JSONDecoder().decode(
                RemoteSetSessionSurfaceRequestDTO.self,
                from: JSONEncoder().encode(surface)
            ),
            surface
        )
    }

    func testConversationSnapshotRoundTrips() throws {
        let snapshot = RemoteConversationSnapshotDTO(
            rows: [
                .init(id: "0", kind: "user", text: "Fix the failing test"),
                .init(
                    id: "1",
                    kind: "tool",
                    toolName: "Bash",
                    summary: "swift test",
                    result: "All tests passed"
                ),
            ],
            streamingText: "Finishing up…",
            canSend: false,
            permission: .init(
                id: "permission-1",
                toolName: "Edit",
                summary: "Sources/App.swift",
                filePath: "Sources/App.swift",
                diff: [
                    .init(id: "0", kind: "removal", text: "let old = true"),
                    .init(id: "1", kind: "addition", text: "let fixed = true"),
                ]
            )
        )
        let data = try JSONEncoder().encode(snapshot)
        XCTAssertEqual(
            try JSONDecoder().decode(RemoteConversationSnapshotDTO.self, from: data),
            snapshot
        )
    }

    func testPermissionRequestDefaultsToDecidableForOlderFrames() throws {
        let json = """
            {
              "type": "permission",
              "id": "permission-1",
              "toolName": "Bash",
              "summary": "swift test",
              "diff": []
            }
            """
        let request = try JSONDecoder().decode(
            RemotePermissionRequestDTO.self,
            from: Data(json.utf8)
        )

        XCTAssertTrue(request.canDecide)
        XCTAssertNil(request.unavailableReason)
    }

    func testClientMessageDecodesAnAuthFrameWithProtocol() throws {
        let json = #"{"type":"auth","token":"t","device":"d","protocolVersion":1,"protocolMinimum":1}"#
        let message = try JSONDecoder().decode(RemoteClientMessage.self, from: Data(json.utf8))
        XCTAssertEqual(message.type, "auth")
        XCTAssertEqual(message.protocolVersion, 1)
        XCTAssertEqual(message.token, "t")
    }

    func testClientMessageDecodesAPermissionDecision() throws {
        let json = #"{"type":"permission","id":"permission-1","decision":"allow"}"#
        let message = try JSONDecoder().decode(RemoteClientMessage.self, from: Data(json.utf8))
        XCTAssertEqual(message.type, "permission")
        XCTAssertEqual(message.id, "permission-1")
        XCTAssertEqual(message.decision, "allow")
    }

    func testLiveTerminalMetadataMessagesRoundTrip() throws {
        let resizeData = try JSONEncoder().encode(RemoteResizeDTO(cols: 120, rows: 42))
        let titleData = try JSONEncoder().encode(RemoteTitleDTO(title: "Running tests"))

        XCTAssertEqual(
            try JSONDecoder().decode(RemoteResizeDTO.self, from: resizeData),
            RemoteResizeDTO(cols: 120, rows: 42)
        )
        XCTAssertEqual(
            try JSONDecoder().decode(RemoteTitleDTO.self, from: titleData),
            RemoteTitleDTO(title: "Running tests")
        )
    }

    func testGitReviewPayloadRoundTrips() throws {
        let snapshot = RemoteGitReviewSnapshotDTO(
            mode: .lastTurn,
            files: [
                RemoteGitFileDiffDTO(
                    path: "Sources/App.swift",
                    change: "modified",
                    hunks: [
                        RemoteGitHunkDTO(
                            header: "@@ -1,2 +1,2 @@",
                            lines: [
                                RemoteGitDiffLineDTO(
                                    kind: "removal",
                                    text: "let old = true",
                                    oldNumber: 1,
                                    newNumber: nil
                                ),
                                RemoteGitDiffLineDTO(
                                    kind: "addition",
                                    text: "let new = true",
                                    oldNumber: nil,
                                    newNumber: 1
                                ),
                            ]
                        )
                    ],
                    added: 1,
                    removed: 1
                )
            ]
        )

        let data = try JSONEncoder().encode(snapshot)
        let decoded = try JSONDecoder().decode(RemoteGitReviewSnapshotDTO.self, from: data)
        XCTAssertEqual(decoded, snapshot)
        XCTAssertEqual(decoded.added, 1)
        XCTAssertEqual(decoded.removed, 1)
    }

    func testConnectionLinkSeparatesFragmentBearerFromRequests() throws {
        let link = try XCTUnwrap(RemoteConnectionLink(
            string: "https://quiet-river.trycloudflare.com/#private-token"
        ))

        XCTAssertEqual(link.baseURL.absoluteString, "https://quiet-river.trycloudflare.com/")
        XCTAssertEqual(link.token, "private-token")
        XCTAssertEqual(link.meURL.absoluteString, "https://quiet-river.trycloudflare.com/api/me")
        XCTAssertEqual(
            link.appThemeURL.absoluteString,
            "https://quiet-river.trycloudflare.com/api/theme"
        )
        XCTAssertEqual(
            link.createSessionURL.absoluteString,
            "https://quiet-river.trycloudflare.com/api/session"
        )
        XCTAssertEqual(
            link.eventsWebSocketURL?.absoluteString,
            "wss://quiet-river.trycloudflare.com/ws/events"
        )
        XCTAssertEqual(
            link.webSocketURL(sessionID: "abc")?.absoluteString,
            "wss://quiet-river.trycloudflare.com/ws/session/abc"
        )
        XCTAssertEqual(
            link.resumeURL(sessionID: "abc").absoluteString,
            "https://quiet-river.trycloudflare.com/api/session/abc/resume"
        )
        XCTAssertEqual(
            link.sessionThemeURL(sessionID: "abc").absoluteString,
            "https://quiet-river.trycloudflare.com/api/session/abc/theme"
        )
        XCTAssertEqual(
            link.renameSessionURL(sessionID: "abc").absoluteString,
            "https://quiet-river.trycloudflare.com/api/session/abc/rename"
        )
        XCTAssertEqual(
            link.pinnedSessionURL(sessionID: "abc").absoluteString,
            "https://quiet-river.trycloudflare.com/api/session/abc/pinned"
        )
        XCTAssertEqual(
            link.archivedSessionURL(sessionID: "abc").absoluteString,
            "https://quiet-river.trycloudflare.com/api/session/abc/archived"
        )
        XCTAssertEqual(
            link.sessionSurfaceURL(sessionID: "abc").absoluteString,
            "https://quiet-river.trycloudflare.com/api/session/abc/surface"
        )
        XCTAssertEqual(
            link.gitReviewURL(sessionID: "abc", mode: .lastTurn).absoluteString,
            "https://quiet-river.trycloudflare.com/api/session/abc/git-review/lastTurn"
        )
        XCTAssertEqual(
            link.repositoryFilesURL(sessionID: "abc").absoluteString,
            "https://quiet-river.trycloudflare.com/api/session/abc/repository-files"
        )
        XCTAssertEqual(
            link.repositoryFileURL(sessionID: "abc", path: "Sources/App.swift")?
                .absoluteString,
            "https://quiet-river.trycloudflare.com/api/session/abc/repository-file?path=Sources/App.swift"
        )
        XCTAssertEqual(
            link.attachmentsURL(sessionID: "abc").absoluteString,
            "https://quiet-river.trycloudflare.com/api/session/abc/attachments"
        )
        XCTAssertEqual(
            link.attachmentURL(sessionID: "abc", path: "art/final report.pdf")?
                .absoluteString,
            "https://quiet-river.trycloudflare.com/api/session/abc/attachment?path=art/final%20report.pdf"
        )
        XCTAssertEqual(
            link.workspaceURL(sessionID: "abc").absoluteString,
            "https://quiet-river.trycloudflare.com/api/session/abc/workspace"
        )
        XCTAssertEqual(
            link.browserPreviewURL(sessionID: "abc", tabID: "tab-1")?.absoluteString,
            "https://quiet-river.trycloudflare.com/api/session/abc/browser-preview?tab=tab-1"
        )
    }

    func testAttachmentPayloadRoundTrips() throws {
        let payload = RemoteAttachmentsDTO(attachments: [
            RemoteAttachmentDTO(
                path: "art/final report.pdf",
                name: "final report.pdf",
                kind: "pdf",
                byteCount: 4_096,
                modifiedAt: Date(timeIntervalSince1970: 123)
            ),
            RemoteAttachmentDTO(
                path: "images/result.png",
                name: "result.png",
                kind: "image",
                byteCount: 512
            ),
        ])

        XCTAssertEqual(
            try JSONDecoder().decode(
                RemoteAttachmentsDTO.self,
                from: JSONEncoder().encode(payload)
            ),
            payload
        )
    }

    func testWorkspacePayloadAndInvalidationsRoundTrip() throws {
        let workspace = RemoteWorkspaceDTO(
            browserTabs: [
                RemoteBrowserTabDTO(
                    id: "tab-1",
                    title: "Threading",
                    displayURL: "https://example.com/docs",
                    isActive: true,
                    isPrivate: false,
                    canPreview: true
                ),
                RemoteBrowserTabDTO(
                    id: "tab-2",
                    title: "",
                    displayURL: nil,
                    isActive: false,
                    isPrivate: true,
                    canPreview: false
                ),
            ],
            latestActivityID: "activity-1"
        )
        XCTAssertEqual(
            try JSONDecoder().decode(
                RemoteWorkspaceDTO.self,
                from: JSONEncoder().encode(workspace)
            ),
            workspace
        )

        let announced = RemoteWorkspaceChangedDTO(
            kind: .browser,
            activityID: "activity-1",
            occurredAt: 123
        )
        XCTAssertEqual(
            try JSONDecoder().decode(
                RemoteWorkspaceChangedDTO.self,
                from: JSONEncoder().encode(announced)
            ),
            announced
        )

        let invalidation = RemoteWorkspaceChangedDTO(
            kind: .browser,
            occurredAt: 124
        )
        XCTAssertNil(invalidation.activityID)
    }

    func testConnectionLinkRejectsUnsafeOrAmbiguousShapes() {
        XCTAssertNil(RemoteConnectionLink(string: "ftp://example.com/#token"))
        XCTAssertNil(RemoteConnectionLink(string: "https://example.com/"))
        XCTAssertNil(RemoteConnectionLink(string: "https://user@example.com/#token"))
        XCTAssertNil(RemoteConnectionLink(string: "https://example.com/?token=visible#token"))
    }

    /// The pairing code writes the origin in upper case to reach QR's alphanumeric mode. That
    /// is only free if it is normalised back here — otherwise every API URL for the rest of the
    /// session carries an uppercase host into `Host:` and SNI.
    func testConnectionLinkLowercasesSchemeAndHost() throws {
        let link = try XCTUnwrap(RemoteConnectionLink(
            string: "HTTPS://QUIET-RIVER.TRYCLOUDFLARE.COM/#MZXW6YTBOI7EU3TFOQQGE43FMN"
        ))

        XCTAssertEqual(link.baseURL.absoluteString, "https://quiet-river.trycloudflare.com/")
        XCTAssertEqual(
            link.meURL.absoluteString,
            "https://quiet-river.trycloudflare.com/api/me"
        )
        // The token is a bearer, not a hostname: its case is data and must survive untouched.
        XCTAssertEqual(link.token, "MZXW6YTBOI7EU3TFOQQGE43FMN")
    }

    func testScannablePayloadUppercasesOnlyTheOriginAndSurvivesARoundTrip() throws {
        let link = try XCTUnwrap(RemoteConnectionLink(
            string: "https://quiet-river.trycloudflare.com/#MZXW6YTBOI7EU3TFOQQGE43FMN"
        ))

        XCTAssertEqual(
            link.scannablePayload,
            "HTTPS://QUIET-RIVER.TRYCLOUDFLARE.COM/#MZXW6YTBOI7EU3TFOQQGE43FMN"
        )

        let scanned = try XCTUnwrap(RemoteConnectionLink(string: link.scannablePayload))
        XCTAssertEqual(scanned, link, "scanning the code did not yield the link it was made from")
    }

    /// A base64url token is mixed case, so upper-casing the origin cannot help it — but the
    /// payload still has to be the same credential, and the token still has to come back byte
    /// for byte.
    func testScannablePayloadLeavesAMixedCaseTokenAlone() throws {
        let token = "kJ8vQ2mXp4TnR7bL0aYc-Zf5WdEsHuG1iOoN3jVrKtM"
        let link = try XCTUnwrap(
            RemoteConnectionLink(string: "https://quiet-river.trycloudflare.com/#\(token)")
        )

        XCTAssertTrue(link.scannablePayload.hasSuffix("#\(token)"))
        XCTAssertEqual(RemoteConnectionLink(string: link.scannablePayload)?.token, token)
    }
}
