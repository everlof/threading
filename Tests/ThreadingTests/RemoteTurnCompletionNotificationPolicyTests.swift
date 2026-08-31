import XCTest
@testable import Threading

final class RemoteTurnCompletionNotificationPolicyTests: XCTestCase {
    func testDeclaredTurnFinishesReadOrUnread() {
        for old in [SessionActivity.working, .awaitingUser] {
            for new in [SessionActivity.idle, .needsAttention] {
                XCTAssertTrue(RemoteTurnCompletionNotificationPolicy.shouldNotify(
                    from: old,
                    to: new,
                    reportsOwnTurns: true
                ))
            }
        }
    }

    func testShellQuietEdgeNeverClaimsCompletion() {
        XCTAssertFalse(RemoteTurnCompletionNotificationPolicy.shouldNotify(
            from: .working,
            to: .idle,
            reportsOwnTurns: false
        ))
    }

    func testQuestionRefusalAndTeardownAreNotCompletions() {
        for new in [
            SessionActivity.working,
            .awaitingUser,
            .limitReached,
            .dormant,
        ] {
            XCTAssertFalse(RemoteTurnCompletionNotificationPolicy.shouldNotify(
                from: .working,
                to: new,
                reportsOwnTurns: true
            ))
        }
        XCTAssertFalse(RemoteTurnCompletionNotificationPolicy.shouldNotify(
            from: .idle,
            to: .needsAttention,
            reportsOwnTurns: true
        ))
    }

    func testCompletionTargetsOnlyTheParticipantWhoStartedTheTurn() {
        let owner = RemoteAuthorization(
            shareID: "owner",
            capability: .interact,
            scope: .allSessions,
            boundDeviceID: "owner-phone"
        )
        let anna = guestAuthorization(id: "anna")
        let ben = guestAuthorization(id: "ben")

        XCTAssertTrue(RemoteTurnCompletionRecipientPolicy.matches(.owner, authorization: owner))
        XCTAssertFalse(RemoteTurnCompletionRecipientPolicy.matches(.owner, authorization: anna))
        XCTAssertTrue(RemoteTurnCompletionRecipientPolicy.matches(
            .member(id: "anna", name: "Anna"),
            authorization: anna
        ))
        XCTAssertFalse(RemoteTurnCompletionRecipientPolicy.matches(
            .member(id: "anna", name: "Anna"),
            authorization: owner
        ))
        XCTAssertFalse(RemoteTurnCompletionRecipientPolicy.matches(
            .member(id: "anna", name: "Anna"),
            authorization: ben
        ))
    }

    private func guestAuthorization(id: String) -> RemoteAuthorization {
        let sessionID = SessionID()
        return RemoteAuthorization(
            shareID: "share-\(id)",
            capability: .interact,
            scope: .session(sessionID),
            principal: .guest,
            member: RemoteMember(id: id, displayName: id.capitalized, deviceID: "phone-\(id)")
        )
    }
}
