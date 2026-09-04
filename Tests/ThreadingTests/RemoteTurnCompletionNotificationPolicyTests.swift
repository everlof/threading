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

    func testRecentlyActiveMacDefersOnlyItsOwnersRoutineCompletion() {
        let now: TimeInterval = 1_000
        let ownerDecision = RemoteTurnCompletionDeviceActivityPolicy.deliveryDecision(
            actor: .owner,
            applicationIsActive: true,
            lastInteractionUptime: now - 30,
            nowUptime: now
        )
        guard case .deferUntilMacInactive(let deadline) = ownerDecision else {
            return XCTFail("the recently active owner Mac should defer routine completion")
        }
        XCTAssertEqual(deadline, now + 90, accuracy: 0.000_001)
        XCTAssertEqual(RemoteTurnCompletionDeviceActivityPolicy.deliveryDecision(
            actor: .member(id: "anna", name: "Anna"),
            applicationIsActive: true,
            lastInteractionUptime: now - 30,
            nowUptime: now
        ), .deliverNow, "the owner's Mac cannot silence another participant")
    }

    func testInactiveOrUntouchedMacDoesNotDeferCompletion() {
        let now: TimeInterval = 1_000
        XCTAssertEqual(RemoteTurnCompletionDeviceActivityPolicy.deliveryDecision(
            actor: .owner,
            applicationIsActive: false,
            lastInteractionUptime: now - 1,
            nowUptime: now
        ), .deliverNow)
        XCTAssertEqual(RemoteTurnCompletionDeviceActivityPolicy.deliveryDecision(
            actor: .owner,
            applicationIsActive: true,
            lastInteractionUptime: nil,
            nowUptime: now
        ), .deliverNow)
    }

    func testMacBecomesInactiveAtTheFixedTwoMinuteBoundary() {
        let now: TimeInterval = 1_000
        let justBeforeBoundary = RemoteTurnCompletionDeviceActivityPolicy.deliveryDecision(
            actor: .owner,
            applicationIsActive: true,
            lastInteractionUptime: now
                - RemoteTurnCompletionDeviceActivityPolicy.recentMacInteractionSeconds
                + 0.001,
            nowUptime: now
        )
        guard case .deferUntilMacInactive(let deadline) = justBeforeBoundary else {
            return XCTFail("the Mac should remain active immediately before the boundary")
        }
        XCTAssertEqual(deadline, now + 0.001, accuracy: 0.000_001)
        XCTAssertEqual(RemoteTurnCompletionDeviceActivityPolicy.deliveryDecision(
            actor: .owner,
            applicationIsActive: true,
            lastInteractionUptime: now
                - RemoteTurnCompletionDeviceActivityPolicy.recentMacInteractionSeconds,
            nowUptime: now
        ), .deliverNow)
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
