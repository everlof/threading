import XCTest
import ThreadingRemoteKit
@testable import ThreadingMobile

final class RemoteNotificationPresentationPolicyTests: XCTestCase {
    @MainActor
    func testResponsePreviewConsentIsDeviceLocalAndDefaultsOff() throws {
        let firstSuite = "RemoteNotificationPresentationPolicyTests.first.\(UUID().uuidString)"
        let secondSuite = "RemoteNotificationPresentationPolicyTests.second.\(UUID().uuidString)"
        let firstDefaults = try XCTUnwrap(UserDefaults(suiteName: firstSuite))
        let secondDefaults = try XCTUnwrap(UserDefaults(suiteName: secondSuite))
        defer {
            firstDefaults.removePersistentDomain(forName: firstSuite)
            secondDefaults.removePersistentDomain(forName: secondSuite)
        }

        let first = RemoteNotificationManager(defaults: firstDefaults)
        let second = RemoteNotificationManager(defaults: secondDefaults)
        XCTAssertFalse(first.includesResponsePreviews)
        XCTAssertFalse(second.includesResponsePreviews)

        first.includesResponsePreviews = true
        XCTAssertTrue(RemoteNotificationManager(defaults: firstDefaults).includesResponsePreviews)
        XCTAssertFalse(second.includesResponsePreviews)
    }

    func testOnlyAnExplicitlyRequestedAgentUpdatePresentsInForeground() {
        for kind in RemoteNotificationKind.allCases {
            XCTAssertEqual(
                RemoteNotificationPresentationPolicy.presentsInForeground(kind),
                kind == .agentMessage,
                "Unexpected foreground presentation policy for \(kind.rawValue)"
            )
        }
    }

    func testRetractionDecoderAcceptsLiveAndSilentPushForms() throws {
        let retraction = RemoteNotificationRetractionDTO(
            hostID: "host-1",
            sessionID: UUID().uuidString,
            eventID: "event-1",
            kind: .turnCompleted
        )
        let data = try JSONEncoder().encode(retraction)
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )

        XCTAssertEqual(
            RemoteNotificationPayloadDecoder.retraction(from: object),
            retraction
        )
        XCTAssertEqual(
            RemoteNotificationPayloadDecoder.retraction(from: ["retraction": object]),
            retraction
        )
    }

    func testResponseRetractionsDecodeAndTombstoneOnlyTheExactRequest() throws {
        for kind in [RemoteNotificationKind.agentQuestion, .permissionRequest] {
            let retraction = RemoteNotificationRetractionDTO(
                hostID: "host", sessionID: "session", eventID: "event", kind: kind
            )
            let data = try JSONEncoder().encode(retraction)
            let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [AnyHashable: Any])
            XCTAssertEqual(RemoteNotificationPayloadDecoder.retraction(from: ["retraction": object]), retraction)
            var tombstones = RemoteNotificationRetractionTombstones()
            tombstones.insert(retraction)
            let event = RemoteNotificationEventDTO(
                id: "event", kind: kind, hostID: "host", sessionID: "session", title: "Chat", body: "Respond"
            )
            XCTAssertTrue(tombstones.contains(event))
            XCTAssertTrue(RemoteNotificationRemovalPolicy.matches(event, retraction: retraction))
            XCTAssertFalse(RemoteNotificationRemovalPolicy.matches(event, retraction: .init(
                hostID: "host", sessionID: "session", eventID: "new-request", kind: kind
            )))
        }
    }

    func testRetractionDecoderRejectsWrongTypeAndNonRetractableKind() {
        let base: [String: Any] = [
            "type": "notificationRetraction",
            "hostID": "host-1",
            "sessionID": "session-1",
            "eventID": "event-1",
            "kind": "turnCompleted",
        ]
        XCTAssertNil(RemoteNotificationPayloadDecoder.retraction(from: [
            "retraction": base.merging(["type": "notification"]) { _, new in new },
        ]))
        XCTAssertNil(RemoteNotificationPayloadDecoder.retraction(from: [
            "retraction": base.merging(["kind": "agentMessage"]) { _, new in new },
        ]))
    }

    func testEventDecoderRejectsInvalidDiscriminatorAndDestination() throws {
        let event = RemoteNotificationEventDTO(
            kind: .turnCompleted,
            hostID: "host-1",
            sessionID: UUID().uuidString,
            title: "Chat",
            body: "Finished its turn."
        )
        let data = try JSONEncoder().encode(event)
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )

        object["type"] = "notificationRetraction"
        XCTAssertNil(RemoteNotificationPayloadDecoder.event(from: object))

        object["type"] = "notification"
        object["destination"] = [
            "kind": "attachment",
            "attachmentID": "valid-id",
            "browserTabID": "must-not-also-be-present",
        ]
        XCTAssertNil(RemoteNotificationPayloadDecoder.event(from: object))
    }

    func testPayloadValidationRejectsUnboundedOrUnsafeRoutingValues() {
        XCTAssertFalse(RemoteNotificationPayloadValidation.accepts(
            RemoteNotificationEventDTO(
                kind: .turnCompleted,
                hostID: "host/escape",
                sessionID: "session-1",
                title: "Chat",
                body: "Finished its turn."
            )
        ))
        XCTAssertFalse(RemoteNotificationPayloadValidation.accepts(
            RemoteNotificationEventDTO(
                kind: .turnCompleted,
                hostID: "host-1",
                sessionID: "session-1",
                title: String(repeating: "x", count: 161),
                body: "Finished its turn."
            )
        ))
        XCTAssertFalse(RemoteNotificationPayloadValidation.accepts(
            RemoteNotificationEventDTO(
                kind: .turnCompleted,
                hostID: "host-1",
                sessionID: "session-1",
                title: "Chat",
                body: "unsafe\nbody"
            )
        ))
    }

    func testRetractionRemovalMatchesEveryOpaqueIdentifierAndTypedKind() {
        let event = RemoteNotificationEventDTO(
            id: "event-1",
            kind: .turnCompleted,
            hostID: "host-1",
            sessionID: "session-1",
            title: "Chat",
            body: "Finished its turn."
        )
        XCTAssertTrue(RemoteNotificationRemovalPolicy.matches(
            event,
            retraction: .init(
                hostID: "host-1",
                sessionID: "session-1",
                eventID: "event-1",
                kind: .turnCompleted
            )
        ))
        XCTAssertFalse(RemoteNotificationRemovalPolicy.matches(
            event,
            retraction: .init(
                hostID: "other-host",
                sessionID: "session-1",
                eventID: "event-1",
                kind: .turnCompleted
            )
        ))
        for retraction in [
            RemoteNotificationRetractionDTO(
                hostID: "host-1", sessionID: "other-session",
                eventID: "event-1", kind: .turnCompleted
            ),
            RemoteNotificationRetractionDTO(
                hostID: "host-1", sessionID: "session-1",
                eventID: "other-event", kind: .turnCompleted
            ),
            RemoteNotificationRetractionDTO(
                hostID: "host-1", sessionID: "session-1",
                eventID: "event-1", kind: .agentMessage
            ),
        ] {
            XCTAssertFalse(RemoteNotificationRemovalPolicy.matches(
                event,
                retraction: retraction
            ))
        }
    }

    func testApplicationActivationPreservesUnansweredRequestsAndExplicitMessages() {
        for kind in RemoteNotificationKind.allCases {
            let event = RemoteNotificationEventDTO(
                id: "event-1",
                kind: kind,
                hostID: "host-1",
                sessionID: "session-1",
                title: "Chat",
                body: "Body"
            )
            XCTAssertEqual(
                RemoteNotificationRemovalPolicy.matchesApplicationActivation(event),
                kind == .turnCompleted,
                "Unexpected activation clearing policy for \(kind.rawValue)"
            )
        }
    }

    func testOpeningAChatClearsOnlyThatChatsStateAlerts() {
        for kind in RemoteNotificationKind.allCases {
            let event = RemoteNotificationEventDTO(
                id: "event", kind: kind, hostID: "host", sessionID: "session", title: "Chat", body: "Body"
            )
            XCTAssertEqual(RemoteNotificationRemovalPolicy.matchesSession(
                event, hostID: "host", sessionID: "session"
            ), [.turnCompleted, .agentQuestion, .permissionRequest].contains(kind))
            XCTAssertFalse(RemoteNotificationRemovalPolicy.matchesSession(
                event, hostID: "host", sessionID: "another-chat"
            ))
            XCTAssertFalse(RemoteNotificationRemovalPolicy.matchesSession(
                event, hostID: "another-host", sessionID: "session"
            ))
        }
    }

    func testRetractionTombstoneSuppressesLateEventAndExpires() {
        let event = RemoteNotificationEventDTO(
            id: "event-1",
            kind: .turnCompleted,
            hostID: "host-1",
            sessionID: "session-1",
            title: "Chat",
            body: "Finished its turn."
        )
        let retraction = RemoteNotificationRetractionDTO(
            hostID: event.hostID,
            sessionID: event.sessionID,
            eventID: event.id,
            kind: event.kind
        )
        let now = Date(timeIntervalSince1970: 1_000)
        var tombstones = RemoteNotificationRetractionTombstones()

        tombstones.insert(retraction, now: now)

        XCTAssertTrue(tombstones.contains(event, now: now))
        XCTAssertFalse(tombstones.contains(
            event,
            now: now.addingTimeInterval(RemoteNotificationRetractionTombstones.lifetime + 1)
        ))
    }

    func testRetractionTombstonesStayBounded() {
        var tombstones = RemoteNotificationRetractionTombstones()
        let now = Date(timeIntervalSince1970: 1_000)
        for index in 0...RemoteNotificationRetractionTombstones.maximumEntries {
            tombstones.insert(
                RemoteNotificationRetractionDTO(
                    hostID: "host-1",
                    sessionID: "session-1",
                    eventID: "event-\(index)",
                    kind: .turnCompleted
                ),
                now: now.addingTimeInterval(Double(index))
            )
        }

        XCTAssertEqual(
            tombstones.count,
            RemoteNotificationRetractionTombstones.maximumEntries
        )
    }
}
