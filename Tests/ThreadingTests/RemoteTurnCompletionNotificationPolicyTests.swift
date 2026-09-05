import XCTest
@testable import Threading

final class RemoteTurnCompletionNotificationPolicyTests: XCTestCase {
    func testDeclaredTurnFinishesReadOrUnread() {
        for old in [SessionActivity.working, .awaitingUser] {
            for new in [SessionActivity.idle, .needsAttention] {
                XCTAssertTrue(RemoteTurnCompletionNotificationPolicy.shouldNotify(
                    transition(from: old, to: new)
                ))
            }
        }
    }

    func testShellQuietEdgeNeverClaimsCompletion() {
        XCTAssertFalse(RemoteTurnCompletionNotificationPolicy.shouldNotify(
            transition(from: .working, to: .idle, reportsOwnTurns: false)
        ))
    }

    func testForegroundTurnEndingIntoBackgroundWorkIsNotCompletion() {
        XCTAssertFalse(RemoteTurnCompletionNotificationPolicy.shouldNotify(
            SessionRuntimeTransition(
                previous: .test(activity: .working),
                current: .test(activity: .readyWithBackgroundWork)
            )
        ))
    }

    func testContinuationCompletesOnlyAfterItsResultTurnFinishes() {
        let waiting = SessionRuntimeSnapshot.test(activity: .readyWithBackgroundWork)
        let resultTurn = SessionRuntimeSnapshot.test(activity: .working, continuation: .standing)
        XCTAssertFalse(RemoteTurnCompletionNotificationPolicy.shouldNotify(
            SessionRuntimeTransition(previous: waiting, current: resultTurn)
        ))
        XCTAssertTrue(RemoteTurnCompletionNotificationPolicy.shouldNotify(
            SessionRuntimeTransition(
                previous: resultTurn,
                current: .test(activity: .needsAttention)
            )
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
                transition(from: .working, to: new)
            ))
        }
        XCTAssertFalse(RemoteTurnCompletionNotificationPolicy.shouldNotify(
            transition(from: .idle, to: .needsAttention)
        ))
    }

    private func transition(
        from old: SessionActivity,
        to new: SessionActivity,
        reportsOwnTurns: Bool = true
    ) -> SessionRuntimeTransition {
        SessionRuntimeTransition(
            previous: .test(activity: old, reportsOwnTurns: reportsOwnTurns),
            current: .test(activity: new, reportsOwnTurns: reportsOwnTurns)
        )
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
