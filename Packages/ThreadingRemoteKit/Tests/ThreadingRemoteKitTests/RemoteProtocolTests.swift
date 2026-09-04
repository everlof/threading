import XCTest
import ThreadingExtensionKit
@testable import ThreadingRemoteKit

final class RemoteProtocolTests: XCTestCase {

    func testRESTRefusalCarriesStableCodeAndOptionalMachineDetail() throws {
        let refusal = RemoteErrorDTO(
            code: RemoteRESTErrorCode.unknownModel,
            detail: "catalogChanged"
        )
        let data = try JSONEncoder().encode(refusal)

        XCTAssertEqual(try JSONDecoder().decode(RemoteErrorDTO.self, from: data), refusal)
        XCTAssertEqual(refusal.type, "error")
        XCTAssertEqual(refusal.code, "unknownModel")
        XCTAssertEqual(RemoteRESTErrorCode(rawValue: refusal.code), .unknownModel)
    }

    func testStorageExhaustionHasAStableRESTCode() {
        XCTAssertEqual(RemoteRESTErrorCode.storageExhausted.rawValue, "storageExhausted")
    }

    func testHostedPairingLinkRoundTripsWithoutPuttingSecretsInTheRequestURL() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let link = try XCTUnwrap(HostedPairingLink(
            serviceURL: URL(string: "https://remote.threading.codes")!,
            hostID: "host-123",
            deviceID: "hosted-pairing",
            rendezvousCredential: "th_device_secret",
            bootstrapToken: "PAIRINGSECRET",
            expiresAt: now.addingTimeInterval(300),
            now: now
        ))

        XCTAssertTrue(link.scannablePayload.hasPrefix("THREADING://PAIR#"))
        XCTAssertFalse(link.scannablePayload.contains("th_device_secret"))
        XCTAssertFalse(link.scannablePayload.contains("PAIRINGSECRET"))
        XCTAssertEqual(
            HostedPairingLink(string: link.scannablePayload, now: now),
            link
        )
    }

    func testHostedPairingLinkRejectsExpiredAndInsecurePayloads() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        XCTAssertNil(HostedPairingLink(
            serviceURL: URL(string: "http://remote.example.com")!,
            hostID: "host-123",
            deviceID: "hosted-pairing",
            rendezvousCredential: "credential",
            bootstrapToken: "bootstrap",
            expiresAt: now.addingTimeInterval(300),
            now: now
        ))
        XCTAssertNil(HostedPairingLink(
            serviceURL: URL(string: "https://remote.threading.codes")!,
            hostID: "host-123",
            deviceID: "hosted-pairing",
            rendezvousCredential: "credential",
            bootstrapToken: "bootstrap",
            expiresAt: now,
            now: now
        ))
        XCTAssertNil(HostedPairingLink(string: "THREADING://PAIR#not-base64", now: now))
    }

    func testNotificationPayloadAndRegistrationRoundTrip() throws {
        let event = RemoteNotificationEventDTO(
            id: "event-1",
            kind: .permissionRequest,
            hostID: "mac-1",
            sessionID: "session-1",
            title: "Needs permission",
            body: "Review the edit",
            destination: .attachment(id: "attachment-1"),
            createdAt: 123,
            turnGeneration: 7
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
            environment: .sandbox,
            enabledKinds: [
                .sharedSession, .permissionRequest, .agentQuestion, .turnCompleted,
                .attentionRequest,
            ],
            soundEnabledKinds: [.permissionRequest, .agentQuestion],
            capabilities: [.turnCompletionPreview, .notificationRetraction],
            includesResponsePreviews: true
        )
        XCTAssertEqual(
            try JSONDecoder().decode(
                RemoteNotificationRegistrationDTO.self,
                from: JSONEncoder().encode(registration)
            ),
            registration
        )

        let legacy = try JSONDecoder().decode(
            RemoteNotificationRegistrationDTO.self,
            from: Data(#"{"deviceToken":"abcd","environment":"sandbox","enabledKinds":["permissionRequest"]}"#.utf8)
        )
        XCTAssertNil(legacy.soundEnabledKinds)
        XCTAssertNil(legacy.capabilities)
        XCTAssertNil(legacy.includesResponsePreviews)

        let retraction = RemoteNotificationRetractionDTO(
            hostID: "mac-1",
            sessionID: "session-1",
            eventID: "event-1",
            kind: .turnCompleted
        )
        XCTAssertEqual(
            try JSONDecoder().decode(
                RemoteNotificationRetractionDTO.self,
                from: JSONEncoder().encode(retraction)
            ),
            retraction
        )
    }

    func testNotificationKindsKeepTheirWireVocabulary() {
        XCTAssertEqual(
            RemoteNotificationKind.allCases.map(\.rawValue),
            [
                "sharedSession", "permissionRequest", "agentQuestion", "turnCompleted",
                "agentMessage", "attentionRequest",
            ]
        )
    }

    func testHumanAttentionProtocolStaysSeparateFromPromptAndTerminalInput() throws {
        let participants = RemoteCollaborationParticipantsDTO(participants: [
            .init(id: "member-anna", displayName: "Anna", role: .member, isOnline: false),
            .init(
                id: RemoteCollaborationParticipantDTO.ownerID,
                displayName: "David’s Mac",
                role: .owner,
                isOnline: true
            ),
        ])
        XCTAssertEqual(
            try JSONDecoder().decode(
                RemoteCollaborationParticipantsDTO.self,
                from: JSONEncoder().encode(participants)
            ),
            participants
        )

        let request = RemoteClientMessage(
            type: "attentionRequest",
            text: "Could you check the domain wording?",
            recipientID: "member-anna",
            requestID: "attention-request-1"
        )
        XCTAssertNil(request.data, "attention is never raw terminal input")
        XCTAssertEqual(
            try JSONDecoder().decode(
                RemoteClientMessage.self,
                from: JSONEncoder().encode(request)
            ),
            request
        )

        let event = RemoteAttentionEventDTO(
            id: "attention-1",
            requestID: "attention-request-1",
            senderID: "owner:phone",
            senderDisplayName: "David",
            recipientID: "member-anna",
            recipientDisplayName: "Anna",
            note: "Could you check the domain wording?",
            createdAt: 123
        )
        XCTAssertEqual(
            try JSONDecoder().decode(
                RemoteAttentionEventDTO.self,
                from: JSONEncoder().encode(event)
            ),
            event
        )

        let result = RemoteAttentionRequestResultDTO(
            requestID: "attention-request-1",
            status: .delivered
        )
        XCTAssertEqual(
            try JSONDecoder().decode(
                RemoteAttentionRequestResultDTO.self,
                from: JSONEncoder().encode(result)
            ),
            result
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
            capability: .interact,
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
                    scope: .session,
                    capability: .interact,
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
            presenceID: "socket-1",
            memberID: "member-1",
            displayName: "Kalle",
            deviceName: "Kalle’s iPhone",
            surface: .conversation,
            state: .typing,
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

    /// The pin that makes a version bump a decision rather than a side effect: raising
    /// `minimumSupported` cuts off every installed iOS build that App Review has not yet let
    /// update. Move these expected values only through the checklist in
    /// `docs/architecture/releasing.md` ("Releasing beside the iOS companion"), in a commit
    /// that is about nothing else.
    func testProtocolVersionsChangeOnlyThroughTheReleasingChecklist() {
        XCTAssertEqual(RemoteProtocol.current, 1)
        XCTAssertEqual(RemoteProtocol.minimumSupported, 1)
        XCTAssertLessThanOrEqual(
            RemoteProtocol.minimumSupported,
            RemoteProtocol.current,
            "a build that cannot speak to itself is no protocol at all"
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
            mode: .dark,
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
            share: .init(label: "l", scope: .all, capability: .interact, expiresAt: nil),
            sessions: [RemoteSessionSummaryDTO(
                id: "s", title: "t", agentKind: "claude", surface: .terminal,
                state: .idle, projectName: "p", isAvailable: false, lastActiveAt: 123,
                isPinned: true,
                terminalTheme: terminalTheme,
                terminalThemeAssignmentID: "ocean",
                inheritedTerminalThemeName: "Default",
                inheritedTerminalTheme: terminalTheme,
                accountID: "default",
                limitRecovery: .resumeOnBestAccount
            )],
            terminals: [RemoteProjectTerminalSummaryDTO(
                id: "terminal-1",
                title: "Server",
                projectName: "Threading",
                state: .working,
                isAvailable: true,
                createdAt: 124,
                isShared: true,
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
        XCTAssertNil(summary.archivedAt)
        XCTAssertFalse(summary.isShared)
        XCTAssertNil(summary.snoozedAt)
        XCTAssertNil(summary.snoozedUntil)
        XCTAssertNil(summary.wokeReason)
        XCTAssertNil(summary.wokeAt)
        XCTAssertNil(summary.accountID)
        XCTAssertNil(summary.limitRecovery)
        XCTAssertFalse(summary.isSnoozed())
    }

    func testSessionArchiveTimestampRoundTrips() throws {
        let summary = RemoteSessionSummaryDTO(
            id: "archived",
            title: "Filed session",
            agentKind: "codex",
            surface: .conversation,
            state: .idle,
            projectName: "Project",
            isArchived: true,
            archivedAt: 2_000_000_000
        )

        let roundTrip = try JSONDecoder().decode(
            RemoteSessionSummaryDTO.self,
            from: JSONEncoder().encode(summary)
        )
        XCTAssertEqual(roundTrip, summary)
    }

    func testLimitRecoveryPolicyRecognizesOnlyStructurallyValidChoices() throws {
        XCTAssertTrue(RemoteLimitRecoveryPolicyDTO.flagOnly.isKnown)
        XCTAssertTrue(RemoteLimitRecoveryPolicyDTO.resumeVia(accountID: "work").isKnown)
        XCTAssertFalse(try JSONDecoder().decode(
            RemoteLimitRecoveryPolicyDTO.self,
            from: Data(#"{"action":"resumeVia"}"#.utf8)
        ).isKnown)
        XCTAssertFalse(try JSONDecoder().decode(
            RemoteLimitRecoveryPolicyDTO.self,
            from: Data(#"{"action":"futureAction"}"#.utf8)
        ).isKnown)
    }

    func testSessionSnoozeFieldsRoundTripAndDeriveFromTheDeadline() throws {
        let start = 2_000_000_000.0
        let deadline = start + 3_600
        let summary = RemoteSessionSummaryDTO(
            id: "s",
            title: "Session",
            agentKind: "codex",
            surface: .conversation,
            state: .working,
            projectName: "Project",
            snoozedAt: start,
            snoozedUntil: deadline,
            wokeReason: nil,
            wokeAt: nil
        )
        let roundTrip = try JSONDecoder().decode(
            RemoteSessionSummaryDTO.self,
            from: JSONEncoder().encode(summary)
        )

        XCTAssertEqual(roundTrip, summary)
        XCTAssertTrue(roundTrip.isSnoozed(at: Date(timeIntervalSince1970: start + 1)))
        XCTAssertFalse(roundTrip.isSnoozed(at: Date(timeIntervalSince1970: deadline)))
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
        XCTAssertNil(hello.features)

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
        XCTAssertNil(me.features)
        XCTAssertNil(me.terminals)
    }

    func testUsageDTOsRoundTripWithoutCollapsingBankedResetInventory() throws {
        let unknown = RemoteUsageLimitSeriesSummaryDTO(
            id: "codex|personal|weekly",
            runtimeName: "Codex",
            accountName: "Personal",
            windowLabel: "Weekly",
            currentFraction: 0.42,
            resetsAt: 200,
            windowDuration: 604_800,
            bankedResetCount: nil,
            nextBankedResetExpiresAt: nil
        )
        let empty = RemoteUsageLimitSeriesSummaryDTO(
            id: "codex|work|weekly",
            runtimeName: "Codex",
            accountName: "Work",
            windowLabel: "Weekly",
            currentFraction: 0.73,
            resetsAt: 300,
            bankedResetCount: 0,
            nextBankedResetExpiresAt: nil
        )
        let dashboard = RemoteUsageDashboardDTO(
            isBuilding: false,
            builtAt: 123,
            pricingCatalogVersion: "test",
            ranges: [],
            coverage: [],
            limitSeries: [unknown, empty],
            nextLimitCursor: "2",
            omittedLimitSeriesCount: 3,
            preparedAt: 124
        )

        let decoded = try JSONDecoder().decode(
            RemoteUsageDashboardDTO.self,
            from: JSONEncoder().encode(dashboard)
        )
        XCTAssertEqual(decoded, dashboard)
        XCTAssertNil(decoded.limitSeries[0].bankedResetCount)
        XCTAssertEqual(decoded.limitSeries[0].windowDuration, 604_800)
        XCTAssertEqual(decoded.limitSeries[1].bankedResetCount, 0)

        let legacyJSON = """
            {
              "id": "legacy",
              "runtimeName": "Codex",
              "accountName": "Personal",
              "windowLabel": "Weekly",
              "currentFraction": 0.42,
              "resetsAt": 200
            }
            """
        let legacy = try JSONDecoder().decode(
            RemoteUsageLimitSeriesSummaryDTO.self,
            from: Data(legacyJSON.utf8)
        )
        XCTAssertNil(legacy.windowDuration)

        let me = RemoteMeDTO(
            serverProtocol: RemoteProtocolInfo(),
            share: .init(label: "owner", scope: .all, capability: .view, expiresAt: nil),
            sessions: [],
            features: [RemoteRESTFeature.usageDashboard.rawValue]
        )
        XCTAssertEqual(
            try JSONDecoder().decode(RemoteMeDTO.self, from: JSONEncoder().encode(me)),
            me
        )
    }

    func testLiveThemeUpdateRoundTrips() throws {
        let update = RemoteThemeUpdateDTO(
            theme: .init(
                id: "swiss",
                name: "Swiss",
                mode: .light,
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

        let delta = RemoteSessionsChangedDTO(
            session: RemoteSessionSummaryDTO(
                id: "session-1",
                title: "Changed",
                agentKind: "codex",
                surface: .conversation,
                state: .working,
                projectName: "Threading"
            )
        )
        XCTAssertEqual(
            try JSONDecoder().decode(
                RemoteSessionsChangedDTO.self,
                from: JSONEncoder().encode(delta)
            ),
            delta
        )

        let terminalDelta = RemoteSessionsChangedDTO(
            terminal: RemoteProjectTerminalSummaryDTO(
                id: "terminal-1",
                title: "Server",
                projectName: "Threading",
                state: .idle,
                isAvailable: true
            )
        )
        XCTAssertEqual(
            try JSONDecoder().decode(
                RemoteSessionsChangedDTO.self,
                from: JSONEncoder().encode(terminalDelta)
            ),
            terminalDelta
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

    func testPromptSubmissionAcknowledgementRoundTrips() throws {
        let submit = RemoteClientMessage(
            type: "submit",
            text: "Review the current diff",
            requestID: "prompt-request-1"
        )
        XCTAssertEqual(
            try JSONDecoder().decode(
                RemoteClientMessage.self,
                from: JSONEncoder().encode(submit)
            ),
            submit
        )

        let terminalSubmit = RemoteClientMessage(
            type: "terminalSubmit",
            text: "Run the focused tests",
            requestID: "terminal-request-1"
        )
        XCTAssertEqual(
            try JSONDecoder().decode(
                RemoteClientMessage.self,
                from: JSONEncoder().encode(terminalSubmit)
            ),
            terminalSubmit
        )

        let result = RemotePromptSubmissionResultDTO(
            requestID: "prompt-request-1",
            status: .accepted
        )
        XCTAssertEqual(
            try JSONDecoder().decode(
                RemotePromptSubmissionResultDTO.self,
                from: JSONEncoder().encode(result)
            ),
            result
        )

        let inputProbe = RemoteTerminalInputProbeResultDTO(
            requestID: "input-probe-1",
            accepted: true
        )
        XCTAssertEqual(
            try JSONDecoder().decode(
                RemoteTerminalInputProbeResultDTO.self,
                from: JSONEncoder().encode(inputProbe)
            ),
            inputProbe
        )
        XCTAssertTrue(
            RemoteWebSocketFeature.allCases.contains(.terminalInputLatencyProbe)
        )

        let hello = RemoteHelloDTO(
            surface: .conversation,
            capability: .interact,
            cols: 0,
            rows: 0,
            title: "Review",
            features: RemoteWebSocketFeature.allCases.map(\.rawValue)
        )
        XCTAssertEqual(
            try JSONDecoder().decode(
                RemoteHelloDTO.self,
                from: JSONEncoder().encode(hello)
            ),
            hello
        )
        XCTAssertTrue(hello.features?.contains("atomicTerminalSubmission") == true)
    }

    func testConversationContextAttachmentsRoundTripAndRemainAdditive() throws {
        let attachment = RemoteConversationContextAttachmentDTO(
            id: "a9143d6f-b539-468d-8cd7-b244cfc50e26",
            kind: .comment,
            source: .attachment,
            title: "layout.png",
            excerpt: "Image attachment",
            comment: "The spacing above the toolbar feels too large.",
            locator: "attachments/layout.png"
        )
        let row = RemoteConversationRowDTO(
            id: "7",
            kind: .user,
            text: "Please address the comment above.",
            contextAttachments: [attachment]
        )
        XCTAssertEqual(
            try JSONDecoder().decode(
                RemoteConversationRowDTO.self,
                from: JSONEncoder().encode(row)
            ),
            row
        )

        let submit = RemoteClientMessage(
            type: "submit",
            text: "",
            requestID: "context-request-1",
            contextAttachments: [attachment]
        )
        XCTAssertEqual(
            try JSONDecoder().decode(
                RemoteClientMessage.self,
                from: JSONEncoder().encode(submit)
            ),
            submit
        )

        let legacyRow = try JSONDecoder().decode(
            RemoteConversationRowDTO.self,
            from: Data(#"{"id":"legacy","kind":"user","text":"Hello","isError":false}"#.utf8)
        )
        XCTAssertNil(legacyRow.contextAttachments)
        XCTAssertTrue(
            RemoteWebSocketFeature.allCases.contains(.conversationContextAttachments)
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
            fastMode: true,
            permissionMode: "acceptEdits",
            surface: .conversation,
            role: RemoteSessionRole.manager,
            openingAttachmentScopeID: "11111111-1111-1111-1111-111111111111",
            openingAttachmentUploadIDs: ["upload-image", "upload-document"],
            compactResponse: true,
            prompt: "Review remote access"
        )
        XCTAssertEqual(
            try JSONDecoder().decode(
                RemoteCreateSessionRequestDTO.self,
                from: JSONEncoder().encode(creation)
            ),
            creation
        )
        XCTAssertEqual(creation.role, .manager)
        XCTAssertEqual(
            creation.openingAttachmentScopeID,
            "11111111-1111-1111-1111-111111111111"
        )
        XCTAssertEqual(
            creation.openingAttachmentUploadIDs,
            ["upload-image", "upload-document"]
        )
        XCTAssertEqual(creation.compactResponse, true)

        let olderCreation = try JSONDecoder().decode(
            RemoteCreateSessionRequestDTO.self,
            from: Data(
                #"{"projectID":"project","agentKind":"codex","surface":"terminal","prompt":"Review"}"#.utf8
            )
        )
        XCTAssertNil(olderCreation.fastMode)
        XCTAssertNil(olderCreation.permissionMode)
        XCTAssertNil(olderCreation.role, "an older phone's request is a chat")
        XCTAssertNil(olderCreation.openingAttachmentScopeID)
        XCTAssertNil(olderCreation.openingAttachmentUploadIDs)
        XCTAssertNil(olderCreation.compactResponse)

        let summary = RemoteSessionSummaryDTO(
            id: "session",
            title: "Remote review",
            agentKind: "codex",
            surface: .conversation,
            state: .dormant,
            projectName: "Threading",
            isAvailable: false
        )
        let compactResponse = RemoteCreateSessionResponseDTO(
            sessionID: summary.id,
            session: summary,
            startup: .starting
        )
        XCTAssertEqual(
            try JSONDecoder().decode(
                RemoteCreateSessionResponseDTO.self,
                from: JSONEncoder().encode(compactResponse)
            ),
            compactResponse
        )
        XCTAssertNil(compactResponse.me)

        let legacyResponse = RemoteCreateSessionResponseDTO(
            sessionID: summary.id,
            me: RemoteMeDTO(
                serverProtocol: RemoteProtocolInfo(),
                share: .init(
                    label: "owner",
                    scope: .all,
                    capability: .interact,
                    expiresAt: nil
                ),
                sessions: [summary]
            )
        )
        let decodedLegacyResponse = try JSONDecoder().decode(
            RemoteCreateSessionResponseDTO.self,
            from: JSONEncoder().encode(legacyResponse)
        )
        XCTAssertEqual(decodedLegacyResponse.me?.sessions, [summary])
        XCTAssertNil(decodedLegacyResponse.session)
        XCTAssertNil(decodedLegacyResponse.startup)

        // An older Mac's catalogue says nothing about managers, which a phone reads as "no".
        let olderCatalog = try JSONDecoder().decode(
            RemoteNewSessionCatalogDTO.self,
            from: Data(#"{"projects":[],"agents":[]}"#.utf8)
        )
        XCTAssertNil(olderCatalog.supportsManagerRole)
        let catalog = RemoteNewSessionCatalogDTO(projects: [], agents: [], supportsManagerRole: true)
        XCTAssertEqual(
            try JSONDecoder().decode(
                RemoteNewSessionCatalogDTO.self,
                from: JSONEncoder().encode(catalog)
            ).supportsManagerRole,
            true
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
        let snoozed = RemoteSetSessionSnoozeRequestDTO(snoozedUntil: 2_000_003_600)
        XCTAssertEqual(
            try JSONDecoder().decode(
                RemoteSetSessionSnoozeRequestDTO.self,
                from: JSONEncoder().encode(snoozed)
            ),
            snoozed
        )
        let surface = RemoteSetSessionSurfaceRequestDTO(surface: .conversation)
        XCTAssertEqual(
            try JSONDecoder().decode(
                RemoteSetSessionSurfaceRequestDTO.self,
                from: JSONEncoder().encode(surface)
            ),
            surface
        )
        let account = RemoteMoveSessionAccountRequestDTO(accountID: "work")
        XCTAssertEqual(
            try JSONDecoder().decode(
                RemoteMoveSessionAccountRequestDTO.self,
                from: JSONEncoder().encode(account)
            ),
            account
        )
        let recovery = RemoteSetSessionLimitRecoveryRequestDTO(
            policy: .resumeVia(accountID: "work")
        )
        XCTAssertEqual(
            try JSONDecoder().decode(
                RemoteSetSessionLimitRecoveryRequestDTO.self,
                from: JSONEncoder().encode(recovery)
            ),
            recovery
        )
    }

    func testConversationSnapshotRoundTrips() throws {
        let snapshot = RemoteConversationSnapshotDTO(
            rows: [
                .init(id: "0", kind: .user, text: "Fix the failing test"),
                .init(
                    id: "1",
                    kind: .tool,
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
                    .init(id: "0", kind: .removal, text: "let old = true"),
                    .init(id: "1", kind: .addition, text: "let fixed = true"),
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

    func testAuthFrameCarriesAReplayBudgetAndOlderClientsStillOmitIt() throws {
        let auth = RemoteClientMessage(
            type: "auth",
            token: "t",
            device: "d",
            deviceName: "iPhone",
            replayBudget: 128 * 1024,
            protocolVersion: 1,
            protocolMinimum: 1
        )
        let encoded = try JSONEncoder().encode(auth)

        XCTAssertEqual(
            try JSONDecoder().decode(RemoteClientMessage.self, from: encoded).replayBudget,
            128 * 1024
        )

        let olderFrame = #"{"type":"auth","token":"t","device":"d","protocolVersion":1}"#
        let older = try JSONDecoder().decode(
            RemoteClientMessage.self,
            from: Data(olderFrame.utf8)
        )
        XCTAssertNil(older.replayBudget)
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
                    change: .modified,
                    hunks: [
                        RemoteGitHunkDTO(
                            header: "@@ -1,2 +1,2 @@",
                            lines: [
                                RemoteGitDiffLineDTO(
                                    kind: .removal,
                                    text: "let old = true",
                                    oldNumber: 1,
                                    newNumber: nil
                                ),
                                RemoteGitDiffLineDTO(
                                    kind: .addition,
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
        XCTAssertEqual(
            RemoteGitReviewMode.allCases,
            [.uncommitted, .unstaged, .staged, .lastTurn, .branch]
        )
    }

    func testConnectionLinkSeparatesFragmentBearerFromRequests() throws {
        let link = try XCTUnwrap(RemoteConnectionLink(
            string: "https://quiet-river.trycloudflare.com/#private-token"
        ))

        XCTAssertEqual(link.baseURL.absoluteString, "https://quiet-river.trycloudflare.com/")
        XCTAssertEqual(link.token, "private-token")
        XCTAssertEqual(link.meURL.absoluteString, "https://quiet-river.trycloudflare.com/api/me")
        XCTAssertEqual(
            link.usageURL.absoluteString,
            "https://quiet-river.trycloudflare.com/api/usage"
        )
        XCTAssertEqual(
            link.usageURL(cursor: "48", limit: 24).absoluteString,
            "https://quiet-river.trycloudflare.com/api/usage?cursor=48&limit=24"
        )
        XCTAssertEqual(
            link.usageLimitURL(seriesID: "codex|personal|weekly", days: 30).absoluteString,
            "https://quiet-river.trycloudflare.com/api/usage/limit?series=codex%7Cpersonal%7Cweekly&days=30"
        )
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
            link.resumeTerminalURL(terminalID: "terminal-1").absoluteString,
            "https://quiet-river.trycloudflare.com/api/terminal/terminal-1/resume"
        )
        XCTAssertEqual(
            link.terminalShareURL(terminalID: "terminal-1").absoluteString,
            "https://quiet-river.trycloudflare.com/api/terminal/terminal-1/share"
        )
        XCTAssertEqual(
            link.terminalUnshareURL(terminalID: "terminal-1").absoluteString,
            "https://quiet-river.trycloudflare.com/api/terminal/terminal-1/unshare"
        )
        XCTAssertEqual(
            link.terminalWebSocketURL(terminalID: "terminal-1")?.absoluteString,
            "wss://quiet-river.trycloudflare.com/ws/terminal/terminal-1"
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
            link.snoozedSessionURL(sessionID: "abc").absoluteString,
            "https://quiet-river.trycloudflare.com/api/session/abc/snoozed"
        )
        XCTAssertEqual(
            link.sessionSurfaceURL(sessionID: "abc").absoluteString,
            "https://quiet-river.trycloudflare.com/api/session/abc/surface"
        )
        XCTAssertEqual(
            link.sessionAccountURL(sessionID: "abc").absoluteString,
            "https://quiet-river.trycloudflare.com/api/session/abc/account"
        )
        XCTAssertEqual(
            link.sessionLimitRecoveryURL(sessionID: "abc").absoluteString,
            "https://quiet-river.trycloudflare.com/api/session/abc/limit-recovery"
        )
        XCTAssertEqual(
            link.gitReviewURL(sessionID: "abc", mode: .lastTurn).absoluteString,
            "https://quiet-river.trycloudflare.com/api/session/abc/git-review/lastTurn"
        )
        XCTAssertEqual(
            link.gitReviewURL(sessionID: "abc", mode: .uncommitted).absoluteString,
            "https://quiet-river.trycloudflare.com/api/session/abc/git-review/uncommitted"
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
            link.attachmentURL(sessionID: "abc", id: "attachment-1")?
                .absoluteString,
            "https://quiet-river.trycloudflare.com/api/session/abc/attachment?id=attachment-1"
        )
        XCTAssertEqual(
            link.attachmentThumbnailURL(sessionID: "abc", id: "attachment-1")?
                .absoluteString,
            "https://quiet-river.trycloudflare.com/api/session/abc/attachment-thumbnail?id=attachment-1"
        )
        XCTAssertEqual(
            link.workspaceURL(sessionID: "abc").absoluteString,
            "https://quiet-river.trycloudflare.com/api/session/abc/workspace"
        )
        XCTAssertEqual(
            link.browserPreviewURL(sessionID: "abc", tabID: "tab-1")?.absoluteString,
            "https://quiet-river.trycloudflare.com/api/session/abc/browser-preview?tab=tab-1"
        )
        XCTAssertEqual(
            link.extensionPanelURL(
                sessionID: "abc",
                extensionIdentifier: "codes.threading.progress",
                panelID: "build-status"
            )?.absoluteString,
            "https://quiet-river.trycloudflare.com/api/session/abc/extension-panel?extension=codes.threading.progress&panel=build-status"
        )
        XCTAssertEqual(
            link.extensionPanelResourceURL(
                sessionID: "abc",
                extensionIdentifier: "codes.threading.progress",
                panelID: "build-status",
                path: "Images/status.png"
            )?.absoluteString,
            "https://quiet-river.trycloudflare.com/api/session/abc/extension-panel-resource?extension=codes.threading.progress&panel=build-status&path=Images/status.png"
        )
    }

    func testExtensionPanelPayloadsPreserveSemanticUIAndProcessGeneration() throws {
        let panel = ExtensionPanel(
            id: "build-status",
            title: "Build status",
            root: .stack(axis: .vertical, spacing: .small, children: [
                .text("Two of three steps complete", role: .heading),
                .button(id: "refresh", title: "Refresh", role: .primary, isEnabled: true),
            ]),
            loadActionID: "load"
        )
        let payload = RemoteExtensionPanelDTO(
            extensionIdentifier: "codes.threading.progress",
            extensionName: "Progress",
            processGeneration: "generation-1",
            panel: panel
        )
        XCTAssertEqual(
            try JSONDecoder().decode(
                RemoteExtensionPanelDTO.self,
                from: JSONEncoder().encode(payload)
            ),
            payload
        )

        let request = RemoteExtensionPanelActionRequestDTO(
            processGeneration: "generation-1",
            actionID: "refresh",
            value: .string("step-2")
        )
        XCTAssertEqual(
            try JSONDecoder().decode(
                RemoteExtensionPanelActionRequestDTO.self,
                from: JSONEncoder().encode(request)
            ),
            request
        )

        let response = RemoteExtensionPanelActionResponseDTO(
            processGeneration: "generation-2",
            panel: panel,
            error: "Refresh failed"
        )
        XCTAssertEqual(
            try JSONDecoder().decode(
                RemoteExtensionPanelActionResponseDTO.self,
                from: JSONEncoder().encode(response)
            ),
            response
        )
    }

    func testAttachmentPayloadRoundTrips() throws {
        let payload = RemoteAttachmentsDTO(attachments: [
            RemoteAttachmentDTO(
                path: "art/final report.pdf",
                name: "final report.pdf",
                kind: .pdf,
                byteCount: 4_096,
                modifiedAt: Date(timeIntervalSince1970: 123),
                id: "attachment-1"
            ),
            RemoteAttachmentDTO(
                path: "images/result.png",
                name: "result.png",
                kind: .image,
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
        XCTAssertNil(RemoteConnectionLink(string: "https:/#token"))
        XCTAssertNil(RemoteConnectionLink(string: "https:///#token"))
        XCTAssertNil(RemoteConnectionLink(string: "https://example.com/"))
        XCTAssertNil(RemoteConnectionLink(string: "https://user@example.com/#token"))
        XCTAssertNil(RemoteConnectionLink(string: "https://example.com/?token=visible#token"))
    }

    /// Synthesized `Codable` bypasses a failable initializer. A persisted or imported link could
    /// therefore carry an FTP origin or empty bearer into the non-optional URL accessors even
    /// though no ordinary caller could construct that state.
    func testConnectionLinkDecodeRevalidatesItsConstructionInvariant() throws {
        let decoder = JSONDecoder()
        for json in [
            #"{"baseURL":"ftp:\/\/example.com\/","token":"bearer"}"#,
            #"{"baseURL":"https:\/\/example.com\/","token":"  \n "}"#,
            #"{"baseURL":"https:\/\/user@example.com\/","token":"bearer"}"#,
        ] {
            XCTAssertThrowsError(
                try decoder.decode(RemoteConnectionLink.self, from: Data(json.utf8)),
                "decoded an invalid link: \(json)"
            )
        }
    }

    func testConnectionLinkCodableRoundTripKeepsOnlyValidatedSourceFields() throws {
        let link = try XCTUnwrap(RemoteConnectionLink(
            baseURL: try XCTUnwrap(URL(string: "HTTPS://EXAMPLE.COM/path?discarded=true#old")),
            token: "  MixedCase-Bearer  "
        ))

        XCTAssertEqual(link.baseURL.absoluteString, "https://example.com/")
        XCTAssertEqual(link.token, "MixedCase-Bearer")
        XCTAssertEqual(link.shareURL.absoluteString, "https://example.com/#MixedCase-Bearer")

        let encoded = try JSONEncoder().encode(link)
        XCTAssertEqual(try JSONDecoder().decode(RemoteConnectionLink.self, from: encoded), link)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        XCTAssertEqual(Set(object.keys), ["baseURL", "token"])
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

    func testLogicalHostEndpointsRoundTripAndOlderHostsStillDecode() throws {
        let privateURL = try XCTUnwrap(URL(string: "https://mac.example.ts.net:8443/"))
        let relayURL = try XCTUnwrap(URL(string: "https://threading.example.com/"))
        let host = RemoteHostDTO(
            id: "mac-1",
            name: "Studio Mac",
            endpoints: [
                .init(kind: .tailscale, baseURL: privateURL, isStable: true),
                .init(kind: .relay, baseURL: relayURL, isStable: true),
            ],
            connectionPolicy: .preferPrivate
        )
        XCTAssertEqual(
            try JSONDecoder().decode(RemoteHostDTO.self, from: JSONEncoder().encode(host)),
            host
        )

        let older = try JSONDecoder().decode(
            RemoteHostDTO.self,
            from: Data(#"{"id":"mac-1","name":"Studio Mac","platform":"macOS"}"#.utf8)
        )
        XCTAssertNil(older.endpoints)
        XCTAssertNil(older.connectionPolicy)
    }

    func testEndpointSelectionPrefersPrivateAndMigratesToAStableRelay() throws {
        let privateEndpoint = RemoteHostEndpointDTO(
            kind: .tailscale,
            baseURL: try XCTUnwrap(URL(string: "https://mac.example.ts.net:8443/")),
            isStable: true
        )
        let quickRelay = RemoteHostEndpointDTO(
            kind: .relay,
            baseURL: try XCTUnwrap(URL(string: "https://quick.trycloudflare.com/")),
            isStable: false
        )
        let stableRelay = RemoteHostEndpointDTO(
            kind: .relay,
            baseURL: try XCTUnwrap(URL(string: "https://threading.example.com/")),
            isStable: true
        )

        XCTAssertEqual(
            RemoteHostEndpointSelection.ordered(
                [quickRelay, stableRelay, privateEndpoint],
                policy: .preferPrivate,
                currentBaseURL: quickRelay.baseURL
            ),
            [privateEndpoint, stableRelay, quickRelay]
        )
        XCTAssertEqual(
            RemoteHostEndpointSelection.ordered(
                [quickRelay, stableRelay, privateEndpoint],
                policy: .relayOnly,
                currentBaseURL: quickRelay.baseURL
            ),
            [stableRelay, quickRelay]
        )
    }

    func testEndpointPolicyFailsClosedForUnknownValuesAndUnsafeURLs() throws {
        let decoded = try JSONDecoder().decode(
            RemoteHostConnectionPolicy.self,
            from: Data(#""future-policy""#.utf8)
        )
        XCTAssertEqual(decoded, .privateOnly)

        let unsafe = RemoteHostEndpointDTO(
            kind: .tailscale,
            baseURL: try XCTUnwrap(URL(string: "http://mac.example.ts.net:8443/")),
            isStable: true
        )
        let relay = RemoteHostEndpointDTO(
            kind: .relay,
            baseURL: try XCTUnwrap(URL(string: "https://relay.example.com/")),
            isStable: true
        )
        XCTAssertTrue(RemoteHostEndpointSelection.ordered(
            [unsafe, relay],
            policy: .privateOnly
        ).isEmpty)
    }

    func testFocusedInputControlProtocolIsTypedAndSeparateFromAgentInput() throws {
        let participants = [
            RemoteCollaborationParticipantDTO(
                id: "owner",
                displayName: "David",
                role: .owner,
                isOnline: true
            ),
            RemoteCollaborationParticipantDTO(
                id: "member-anna",
                displayName: "Anna",
                role: .member,
                isOnline: true
            ),
        ]
        let state = RemoteInputControlStateDTO(
            mode: .focused,
            controllerID: "member-anna",
            controllerDisplayName: "Anna",
            currentParticipantID: "owner",
            canWrite: false,
            canManage: true,
            canHandOff: true,
            participants: participants,
            revision: 4
        )
        XCTAssertEqual(
            try JSONDecoder().decode(
                RemoteInputControlStateDTO.self,
                from: JSONEncoder().encode(state)
            ),
            state
        )

        let handoff = RemoteClientMessage(
            type: "inputControl",
            state: "handoff",
            recipientID: "member-anna",
            requestID: "control-1"
        )
        let encoded = try JSONEncoder().encode(handoff)
        let decoded = try JSONDecoder().decode(RemoteClientMessage.self, from: encoded)
        XCTAssertEqual(decoded.type, "inputControl")
        XCTAssertEqual(decoded.state, "handoff")
        XCTAssertEqual(decoded.recipientID, "member-anna")
        XCTAssertNil(decoded.text)
        XCTAssertNil(decoded.data)

        let event = RemoteInputControlEventDTO(
            action: .requested,
            actorID: "member-anna",
            actorDisplayName: "Anna",
            targetID: "owner",
            targetDisplayName: "David"
        )
        XCTAssertEqual(
            try JSONDecoder().decode(
                RemoteInputControlEventDTO.self,
                from: JSONEncoder().encode(event)
            ),
            event
        )
        XCTAssertTrue(RemoteWebSocketFeature.allCases.contains(.focusedInputControl))
    }

    func testTerminalAttachmentInsertionCarriesStagedUploadIDs() throws {
        let insertion = RemoteClientMessage(
            type: "terminalAttachmentInsert",
            text: "",
            requestID: "insert-files-1",
            attachmentUploadIDs: ["upload-image", "upload-document"]
        )

        XCTAssertEqual(
            try JSONDecoder().decode(
                RemoteClientMessage.self,
                from: JSONEncoder().encode(insertion)
            ),
            insertion
        )
        XCTAssertTrue(
            RemoteWebSocketFeature.allCases.contains(.terminalAttachmentInsertion)
        )
    }

    func testTerminalHydrationBoundaryKeepsItsViewportRequestIdentity() throws {
        let ready = RemoteTerminalReadyDTO(requestID: "viewport-generation-1")
        let decoded = try JSONDecoder().decode(
            RemoteTerminalReadyDTO.self,
            from: JSONEncoder().encode(ready)
        )

        XCTAssertEqual(decoded, ready)
        XCTAssertEqual(decoded.type, "terminalReady")
        XCTAssertTrue(
            RemoteWebSocketFeature.allCases.contains(.terminalHydrationBoundary)
        )
    }

    func testSessionConnectionParkingIsNegotiatedAndAcknowledged() throws {
        let parked = RemoteSessionParkedDTO()
        let decoded = try JSONDecoder().decode(
            RemoteSessionParkedDTO.self,
            from: JSONEncoder().encode(parked)
        )

        XCTAssertEqual(decoded, parked)
        XCTAssertEqual(decoded.type, "sessionParked")
        XCTAssertTrue(
            RemoteWebSocketFeature.allCases.contains(.sessionConnectionParking)
        )
    }

    func testRunPlanSummaryClearAndPagedChecklistRoundTrip() throws {
        let summary = RemoteRunPlanUpdateDTO(
            revision: 7,
            plan: .init(
                activeTitle: "Implement status strip",
                current: 2,
                completed: 1,
                active: 1,
                total: 3
            )
        )
        XCTAssertEqual(
            try JSONDecoder().decode(
                RemoteRunPlanUpdateDTO.self,
                from: JSONEncoder().encode(summary)
            ),
            summary
        )

        let page = RemoteRunPlanPageDTO(
            revision: 7,
            offset: 0,
            total: 3,
            steps: [
                .init(id: "step-0", providerID: "provider-1", title: "Inspect", status: .completed),
                .init(id: "step-1", providerID: "provider-2", title: "Implement", status: .inProgress),
            ]
        )
        XCTAssertEqual(
            try JSONDecoder().decode(
                RemoteRunPlanPageDTO.self,
                from: JSONEncoder().encode(page)
            ),
            page
        )

        let request = RemoteClientMessage(type: "runPlanPage", offset: 64, revision: 7)
        XCTAssertEqual(
            try JSONDecoder().decode(
                RemoteClientMessage.self,
                from: JSONEncoder().encode(request)
            ),
            request
        )

        let clear = RemoteRunPlanUpdateDTO(revision: 8, plan: nil)
        XCTAssertNil(
            try JSONDecoder().decode(
                RemoteRunPlanUpdateDTO.self,
                from: JSONEncoder().encode(clear)
            ).plan
        )
        XCTAssertTrue(RemoteWebSocketFeature.allCases.contains(.runPlanProgress))
    }
}

// MARK: - Account usage windows

/// The phone rings each window of a login for the chat's own model. The catalogue therefore
/// carries the windows, each scoped one with the model ids it meters, and a chat carries the
/// model it chose; and a Mac predating both leaves them absent rather than empty, so a phone can
/// tell "no windows" from "no answer".
final class RemoteAccountUsageWireTests: XCTestCase {

    func testAnAccountCarriesItsWindowsAndAChatItsModelAcrossTheWire() throws {
        let account = RemoteAccountChoiceDTO(
            id: "default",
            name: "David",
            usageSummary: "5h 43% · 7d Fable 89%",
            usageFraction: 0.89,
            usageWindows: [
                .init(id: "5h", name: "5h", fraction: 0.43, resetsAt: 1_700_000_000, windowDuration: 18_000),
                .init(
                    id: "Fable",
                    name: "7d Fable",
                    fraction: 0.89,
                    windowDuration: 604_800,
                    metersModelIDs: ["claude-fable-5", "claude-fable-5[1m]"]
                ),
            ],
            models: [],
            defaultModelID: "claude-fable-5"
        )
        let decoded = try JSONDecoder().decode(
            RemoteAccountChoiceDTO.self,
            from: JSONEncoder().encode(account)
        )
        XCTAssertEqual(decoded, account)

        let chat = RemoteSessionSummaryDTO(
            id: "s",
            title: "Rings",
            agentKind: "claude",
            surface: .conversation,
            state: .idle,
            projectName: "Threading",
            model: "claude-fable-5"
        )
        let decodedChat = try JSONDecoder().decode(
            RemoteSessionSummaryDTO.self,
            from: JSONEncoder().encode(chat)
        )
        XCTAssertEqual(decodedChat.model, "claude-fable-5")
        XCTAssertEqual(decodedChat, chat)
    }

    func testAnOlderHostLeavesTheWindowsAndTheModelAbsentNotEmpty() throws {
        let account = try JSONDecoder().decode(
            RemoteAccountChoiceDTO.self,
            from: Data(#"{"id":"default","name":"David","usageFraction":0.73,"models":[]}"#.utf8)
        )
        XCTAssertNil(account.usageWindows)
        XCTAssertEqual(account.usageFraction, 0.73)

        let chat = try JSONDecoder().decode(
            RemoteSessionSummaryDTO.self,
            from: Data(#"""
            {"id":"s","title":"Rings","agentKind":"claude","surface":"terminal","state":"idle","projectName":"Threading"}
            """#.utf8)
        )
        XCTAssertNil(chat.model)
    }
}
