import XCTest
import ThreadingRemoteKit
@testable import ThreadingMobile

final class NotificationDeepLinkTests: XCTestCase {
    func testAPNsNestedEventDecodesTheExactExtensionPanelDestination() throws {
        let expected = event(destination: .extensionPanel(
            extensionIdentifier: "codes.threading.progress",
            panelID: "build-status"
        ))
        let payload: [AnyHashable: Any] = [
            "aps": ["alert": ["title": "Done", "body": "Inspect the step"]],
            "event": try jsonObject(for: expected),
        ]

        let decoded = try XCTUnwrap(RemoteNotificationPayloadDecoder.event(from: payload))

        XCTAssertEqual(decoded, expected)
        XCTAssertEqual(
            SessionWorkspaceRoute.notificationDestination(decoded.destination),
            .extensionPanel(
                extensionIdentifier: "codes.threading.progress",
                panelID: "build-status"
            )
        )
    }

    func testLiveEventPayloadDecodesWithoutAnAPNsEnvelope() throws {
        let expected = event(destination: .attachment(id: "attachment-42"))

        let decoded = try XCTUnwrap(RemoteNotificationPayloadDecoder.event(
            from: try hashableKeys(jsonObject(for: expected))
        ))

        XCTAssertEqual(decoded, expected)
        XCTAssertEqual(
            SessionWorkspaceRoute.notificationDestination(decoded.destination),
            .attachment(id: "attachment-42")
        )
    }

    func testDestinationResolverPreservesExactBrowserTab() {
        XCTAssertEqual(
            SessionWorkspaceRoute.notificationDestination(.browserTab(id: "browser-7")),
            .browser(tabID: "browser-7")
        )
    }

    func testSessionDestinationStaysInTheConversation() {
        XCTAssertNil(SessionWorkspaceRoute.notificationDestination(.session))
        XCTAssertNil(SessionWorkspaceRoute.notificationDestination(nil))
    }

    func testMalformedDestinationsNeverDegradeIntoABroaderWorkspaceRoute() {
        let malformed: [RemoteNotificationDestinationDTO] = [
            .init(kind: .attachment),
            .init(kind: .attachment, attachmentID: ""),
            .init(kind: .browserTab),
            .init(kind: .extensionPanel, extensionIdentifier: "codes.threading.progress"),
            .init(
                kind: .attachment,
                attachmentID: "attachment-42",
                browserTabID: "browser-7"
            ),
        ]

        for destination in malformed {
            XCTAssertNil(
                SessionWorkspaceRoute.notificationDestination(destination),
                "malformed destination must not be partially interpreted: \(destination)"
            )
        }
    }

    func testMalformedPushPayloadIsRejected() {
        XCTAssertNil(RemoteNotificationPayloadDecoder.event(from: [
            "event": ["type": "notification", "destination": ["kind": "extensionPanel"]]
        ]))
        XCTAssertNil(RemoteNotificationPayloadDecoder.event(from: [
            "event": Data([0x00, 0x01])
        ]))
    }

    @MainActor
    func testConnectingSceneNotificationSuppressesSavedRouteRestoration() async throws {
        let (model, continuity, defaults, suite) = try makeDemoModel()
        defer { defaults.removePersistentDomain(forName: suite) }
        let response = try XCTUnwrap(model.me)
        let previous = try XCTUnwrap(response.sessions.first)
        let target = try XCTUnwrap(response.sessions.dropFirst().first)
        let hostID = try XCTUnwrap(model.activeHostID)
        continuity.setLastRoute(hostID: hostID, sessionID: previous.id)

        XCTAssertTrue(model.openSessionFromNotification(
            event(id: "cold-tap", hostID: hostID, sessionID: target.id),
            origin: .connectingScene
        ))

        // The root's refresh can finish while the notification transaction is waiting on the
        // same catalogue. Saved continuity must not put its chat on the stack in that window.
        model.restoreRouteIfPossible(hostID: hostID, response: response)
        XCTAssertTrue(model.navigationPath.isEmpty)

        await waitForPath([.session(target.id)], in: model)
        XCTAssertEqual(model.navigationPath, [.session(target.id)])
    }

    @MainActor
    func testDuplicateLifecycleDeliveryCoalescesIntoTheConnectingSceneRoute() async throws {
        let (model, _, defaults, suite) = try makeDemoModel()
        defer { defaults.removePersistentDomain(forName: suite) }
        let sessions = try XCTUnwrap(model.me?.sessions)
        let previous = try XCTUnwrap(sessions.first)
        let target = try XCTUnwrap(sessions.dropFirst().first)
        let hostID = try XCTUnwrap(model.activeHostID)
        model.navigationPath = [.session(previous.id)]
        let notification = event(
            id: "one-tap-two-callbacks",
            hostID: hostID,
            sessionID: target.id,
            destination: .attachment(id: "attachment-42")
        )

        XCTAssertTrue(model.openSessionFromNotification(
            notification,
            origin: .notificationCenter
        ))
        XCTAssertFalse(model.openSessionFromNotification(
            notification,
            origin: .connectingScene
        ))

        await waitForPath([.session(target.id)], in: model)
        XCTAssertEqual(model.navigationPath, [.session(target.id)])
        XCTAssertEqual(
            model.notificationOpenRequest,
            RemoteNotificationOpenRequest(
                eventID: notification.id,
                sessionID: target.id,
                destination: notification.destination
            )
        )
        XCTAssertFalse(model.openSessionFromNotification(
            notification,
            origin: .notificationCenter
        ))
        await Task.yield()
        XCTAssertEqual(model.navigationPath, [.session(target.id)])
    }

    @MainActor
    func testExistingSceneNotificationIsOneForwardPush() async throws {
        let (model, _, defaults, suite) = try makeDemoModel()
        defer { defaults.removePersistentDomain(forName: suite) }
        let sessions = try XCTUnwrap(model.me?.sessions)
        let previous = try XCTUnwrap(sessions.first)
        let target = try XCTUnwrap(sessions.dropFirst().first)
        let hostID = try XCTUnwrap(model.activeHostID)
        model.navigationPath = [.session(previous.id)]

        XCTAssertTrue(model.openSessionFromNotification(
            event(id: "warm-tap", hostID: hostID, sessionID: target.id),
            origin: .notificationCenter
        ))

        let expected: [MobileNavigationRoute] = [
            .session(previous.id),
            .session(target.id),
        ]
        await waitForPath(expected, in: model)
        XCTAssertEqual(model.navigationPath, expected)
    }

    func testLegacyPairedHostRecordDecodesWithoutHostedRoute() throws {
        let link = try XCTUnwrap(RemoteConnectionLink(
            string: "https://mac.example.test/#capability"
        ))
        let legacy = PairedRemoteHost(
            id: "host-1",
            hostID: "host-1",
            shareID: "my-devices",
            scope: "all",
            name: "Mac",
            link: link,
            lastConnectedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(legacy)) as? [String: Any]
        )
        object["hostedServiceURL"] = nil
        object["hostedCredential"] = nil

        let decoded = try JSONDecoder().decode(
            PairedRemoteHost.self,
            from: JSONSerialization.data(withJSONObject: object)
        )

        XCTAssertEqual(decoded.id, legacy.id)
        XCTAssertEqual(decoded.link, legacy.link)
        XCTAssertNil(decoded.hostedServiceURL)
        XCTAssertNil(decoded.hostedCredential)
    }

    @MainActor
    func testOversizedContinuityDraftCannotReplacePublishedOrDurableState() throws {
        let suite = "MobileContinuityCandidate.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = MobileSessionContinuityStore(defaults: defaults)
        store.setDraft("keep me", surface: .conversation, hostID: "host", sessionID: "session")

        store.setDraft(
            String(repeating: "x", count: 256 * 1_024 + 1),
            surface: .conversation,
            hostID: "host",
            sessionID: "session"
        )

        XCTAssertEqual(
            store.draft(surface: .conversation, hostID: "host", sessionID: "session"),
            "keep me"
        )
        XCTAssertEqual(
            MobileSessionContinuityStore(defaults: defaults).draft(
                surface: .conversation,
                hostID: "host",
                sessionID: "session"
            ),
            "keep me"
        )
        XCTAssertNotNil(store.recoveryMessage)
    }

    @MainActor
    func testOversizedKeyboardActionCannotReplacePublishedOrDurableLayout() throws {
        let suite = "MobileKeyboardCandidate.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = MobileTerminalKeyboardStore(defaults: defaults)
        let valid = RemoteTerminalKeyboardLayout(keys: [
            .init(action: .snippet(text: "echo ready", submits: true))
        ])
        store.setLayout(valid, forAgentKind: "codex")
        let oversized = RemoteTerminalKeyboardLayout(keys: [
            .init(action: .sequence(String(repeating: "x", count: 64 * 1_024 + 1)))
        ])

        store.setLayout(oversized, forAgentKind: "codex")

        XCTAssertEqual(store.layout(forAgentKind: "codex"), valid)
        XCTAssertEqual(
            MobileTerminalKeyboardStore(defaults: defaults).layout(forAgentKind: "codex"),
            valid
        )
        XCTAssertNotNil(store.recoveryMessage)
    }

    private func event(
        id: String = "event-1",
        hostID: String = "host-1",
        sessionID: String = "session-1",
        destination: RemoteNotificationDestinationDTO = .session
    ) -> RemoteNotificationEventDTO {
        RemoteNotificationEventDTO(
            id: id,
            kind: .agentMessage,
            hostID: hostID,
            sessionID: sessionID,
            title: "Done",
            body: "Inspect the step",
            destination: destination,
            createdAt: 123
        )
    }

    @MainActor
    private func makeDemoModel() throws -> (
        RemoteAppModel,
        MobileSessionContinuityStore,
        UserDefaults,
        String
    ) {
        let suite = "NotificationDeepLinkTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let continuity = MobileSessionContinuityStore(defaults: defaults)
        let model = RemoteAppModel(continuity: continuity)
        model.startDemo()
        return (model, continuity, defaults, suite)
    }

    @MainActor
    private func waitForPath(
        _ expected: [MobileNavigationRoute],
        in model: RemoteAppModel
    ) async {
        for _ in 0..<20 {
            if model.navigationPath == expected { return }
            await Task.yield()
        }
    }

    private func jsonObject(
        for event: RemoteNotificationEventDTO
    ) throws -> [String: Any] {
        let data = try JSONEncoder().encode(event)
        return try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
    }

    private func hashableKeys(
        _ object: [String: Any]
    ) -> [AnyHashable: Any] {
        Dictionary(uniqueKeysWithValues: object.map { (AnyHashable($0.key), $0.value) })
    }
}
