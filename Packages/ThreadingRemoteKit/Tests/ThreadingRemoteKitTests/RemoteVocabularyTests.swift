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
    }

    func testClientCommandVocabularyRejectsUnknownValues() {
        XCTAssertThrowsError(try JSONDecoder().decode(
            RemoteCapability.self,
            from: Data(#""admin""#.utf8)
        ))
        XCTAssertThrowsError(try JSONDecoder().decode(
            RemoteSessionRole.self,
            from: Data(#""overlord""#.utf8)
        ))
        XCTAssertThrowsError(try JSONDecoder().decode(
            RemoteNotificationEnvironment.self,
            from: Data(#""development""#.utf8)
        ))
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
