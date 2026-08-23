import XCTest

@testable import ThreadingRemoteKit

final class RemoteVocabularyTests: XCTestCase {
    func testTerminalActivityUsesItsWireSpellingAndPreservesANewerState() throws {
        XCTAssertEqual(
            String(decoding: try JSONEncoder().encode(RemoteTerminalActivity.working), as: UTF8.self),
            #""working""#
        )

        let future = try JSONDecoder().decode(
            RemoteTerminalActivity.self,
            from: Data(#""multiplexing""#.utf8)
        )
        XCTAssertEqual(future, .unknown("multiplexing"))
        XCTAssertEqual(
            String(decoding: try JSONEncoder().encode(future), as: UTF8.self),
            #""multiplexing""#
        )
    }

    func testHostVocabularyPreservesFutureValues() throws {
        XCTAssertEqual(
            try roundTrip(RemoteThemeMode.unknown("sepia")),
            .unknown("sepia")
        )
        XCTAssertEqual(
            try roundTrip(RemoteManagedWorkspaceDelivery.unknown("archive")),
            .unknown("archive")
        )
        XCTAssertEqual(
            try roundTrip(RemoteAdvertisedCapability.unknown("comment")),
            .unknown("comment")
        )
        XCTAssertEqual(
            try roundTrip(RemoteNotificationDelivery.unknown("relay")),
            .unknown("relay")
        )
        XCTAssertEqual(
            try roundTrip(RemoteUsageCoverageState.unknown("sampling")),
            .unknown("sampling")
        )
        XCTAssertEqual(
            try roundTrip(RemoteHostEndpointKind.unknown("satellite")),
            .unknown("satellite")
        )
        XCTAssertEqual(
            try roundTrip(RemoteHostEndpointIdentity.unknown("hardwareBound")),
            .unknown("hardwareBound")
        )
        XCTAssertEqual(
            try roundTrip(RemoteMobileApplicationState.unknown("suspended")),
            .unknown("suspended")
        )
        XCTAssertEqual(
            try roundTrip(RemoteMobileConnectionState.unknown("recovering")),
            .unknown("recovering")
        )
        XCTAssertEqual(
            try roundTrip(RemoteMobileDiagnosticsScreenshotKind.unknown("automatic")),
            .unknown("automatic")
        )
    }

    func testClientCommandVocabularyRejectsUnknownValues() {
        XCTAssertThrowsError(try JSONDecoder().decode(
            RemoteCapability.self,
            from: Data(#""admin""#.utf8)
        ))
        XCTAssertThrowsError(try JSONDecoder().decode(
            RemoteNotificationEnvironment.self,
            from: Data(#""development""#.utf8)
        ))
        XCTAssertThrowsError(try JSONDecoder().decode(
            PublicIssueReportTrigger.self,
            from: Data(#""automatic""#.utf8)
        ))
        XCTAssertThrowsError(try JSONDecoder().decode(
            RemoteSessionRouteAction.self,
            from: Data(#""delete""#.utf8)
        ))
        XCTAssertEqual(RemoteSessionRouteAction.gitReview.rawValue, "git-review")
        XCTAssertEqual(RemoteTerminalRouteAction.resume.rawValue, "resume")
    }

    func testContentVocabularyPreservesFutureHostValues() throws {
        XCTAssertEqual(
            try roundTrip(RemoteDiffLineKind.unknown("annotation")),
            .unknown("annotation")
        )
        XCTAssertEqual(
            try roundTrip(RemoteGitFileChange.unknown("copied")),
            .unknown("copied")
        )
        XCTAssertEqual(
            try roundTrip(RemoteAttachmentKind.unknown("spreadsheet")),
            .unknown("spreadsheet")
        )
        XCTAssertEqual(
            try roundTrip(RemoteAttachmentOrigin.unknown("extension")),
            .unknown("extension")
        )
        XCTAssertEqual(
            try roundTrip(RemoteComposerCapabilityKind.unknown("workflow")),
            .unknown("workflow")
        )
        XCTAssertEqual(
            try roundTrip(RemoteComposerCapabilityTrigger.unknown("at")),
            .unknown("at")
        )
        XCTAssertEqual(
            try roundTrip(RemoteComposerCapabilityPresentation.unknown("panel")),
            .unknown("panel")
        )
        XCTAssertEqual(
            try roundTrip(RemoteConversationContextKind.unknown("selection")),
            .unknown("selection")
        )
        XCTAssertEqual(
            try roundTrip(RemoteConversationContextSource.unknown("browser")),
            .unknown("browser")
        )
        XCTAssertEqual(
            try roundTrip(RemoteConversationRowKind.unknown("checkpoint")),
            .unknown("checkpoint")
        )
    }

    func testCollaborationVocabularyKeepsHostProjectionOpenAndClientCommandsClosed() throws {
        XCTAssertEqual(
            try roundTrip(RemotePresenceState.unknown("recording")),
            .unknown("recording")
        )
        XCTAssertEqual(
            try roundTrip(RemoteCollaborationRole.unknown("moderator")),
            .unknown("moderator")
        )
        XCTAssertEqual(
            try roundTrip(RemoteInputControlEventAction.unknown("queued")),
            .unknown("queued")
        )
        XCTAssertNil(RemotePresenceUpdate(rawValue: "viewing"))
        XCTAssertNil(RemoteInputControlAction(rawValue: "steal"))
        XCTAssertNil(RemotePermissionDecision(rawValue: "always"))
    }

    func testSessionRolePreservesUnknownValuesForServerValidation() throws {
        let future = try JSONDecoder().decode(
            RemoteSessionRole.self,
            from: Data(#""overlord""#.utf8)
        )

        XCTAssertEqual(future, .unknown("overlord"))
        XCTAssertEqual(
            String(decoding: try JSONEncoder().encode(future), as: UTF8.self),
            #""overlord""#
        )
    }

    func testLimitRecoveryIsAnAssociatedEnumWithoutChangingItsObjectWireShape() throws {
        let pinned = RemoteLimitRecoveryPolicyDTO.resumeVia(accountID: "work")
        XCTAssertEqual(
            try JSONSerialization.jsonObject(with: JSONEncoder().encode(pinned)) as? [String: String],
            ["action": "resumeVia", "accountID": "work"]
        )
        XCTAssertEqual(try roundTrip(pinned), pinned)

        let future = try JSONDecoder().decode(
            RemoteLimitRecoveryPolicyDTO.self,
            from: Data(#"{"action":"handoff","accountID":"team"}"#.utf8)
        )
        XCTAssertEqual(future, .unknown(action: "handoff", accountID: "team"))
        XCTAssertEqual(try roundTrip(future), future)
    }

    private func roundTrip<Value: Codable>(_ value: Value) throws -> Value {
        try JSONDecoder().decode(Value.self, from: JSONEncoder().encode(value))
    }
}
