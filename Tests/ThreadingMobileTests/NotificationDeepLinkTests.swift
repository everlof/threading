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
        destination: RemoteNotificationDestinationDTO
    ) -> RemoteNotificationEventDTO {
        RemoteNotificationEventDTO(
            id: "event-1",
            kind: .agentMessage,
            hostID: "host-1",
            sessionID: "session-1",
            title: "Done",
            body: "Inspect the step",
            destination: destination,
            createdAt: 123
        )
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
