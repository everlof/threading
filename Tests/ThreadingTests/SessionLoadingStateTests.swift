import XCTest
@testable import Threading

/// The row spinner's bookkeeping, and the identifier a chat is known by outside the app.
///
/// Both exist because of one bug: a session selected in the sidebar span forever. The spinner
/// had two independent owners writing one boolean, so the selection's raise had no lowering of
/// its own — it was cleared only as a side effect of a *git* load finishing for whichever
/// session happened to be on screen. These pin the two rules that fix it.
final class SessionLoadingStateTests: XCTestCase {

    private let alpha = SessionID()
    private let beta = SessionID()
    private let epoch = Date(timeIntervalSinceReferenceDate: 0)

    // MARK: - Reasons

    func testARowSpinsUntilEveryReasonThatRaisedItIsLowered() {
        var state = SessionLoadingState()

        state.set(true, reason: .presentation, for: alpha)
        state.set(true, reason: .gitStatus, for: alpha)
        XCTAssertTrue(state.isLoading(alpha))

        state.set(false, reason: .presentation, for: alpha)
        XCTAssertTrue(state.isLoading(alpha), "the git read still holds the spinner")

        state.set(false, reason: .gitStatus, for: alpha)
        XCTAssertFalse(state.isLoading(alpha))
    }

    /// The bug in one assertion: whoever raises a reason can lower it, whatever else has
    /// happened in between. The old boolean could be cleared by a different owner entirely.
    func testLoweringOneReasonDoesNotDependOnWhoElseRaisedOne() {
        var state = SessionLoadingState()

        state.set(true, reason: .gitReview, for: alpha)
        state.set(false, reason: .gitStatus, for: alpha)

        XCTAssertTrue(state.isLoading(alpha), "an unrelated reason cleared a spinner it never raised")
        XCTAssertEqual(state.reasons(for: alpha), [.gitReview])
    }

    /// Only one session is presented at a time, so a row abandoned mid-presentation stops
    /// spinning — nothing else was ever going to say so.
    func testANewPresentationEndsTheOneItInterrupts() {
        var state = SessionLoadingState()

        state.set(true, reason: .presentation, for: alpha)
        let affected = state.set(true, reason: .presentation, for: beta)

        XCTAssertFalse(state.isLoading(alpha))
        XCTAssertTrue(state.isLoading(beta))
        XCTAssertEqual(affected, [alpha, beta], "both rows changed and both must be refreshed")
    }

    /// A pane's own reason belongs to that session and is not one of the presentation's, so an
    /// interrupted presentation must not take a live git read down with it.
    func testANewPresentationLeavesAnotherSessionsPaneReasonAlone() {
        var state = SessionLoadingState()

        state.set(true, reason: .gitReview, for: alpha)
        state.set(true, reason: .presentation, for: beta)

        XCTAssertTrue(state.isLoading(alpha))
        XCTAssertEqual(state.reasons(for: alpha), [.gitReview])
    }

    // MARK: - Refresh Reporting

    /// Rows are refreshed from what this reports, so it reports a change to the *spinner*,
    /// not to the set — a second reason on a row that already spins redraws nothing.
    func testOnlyAVisibleChangeIsReported() {
        var state = SessionLoadingState()

        XCTAssertEqual(state.set(true, reason: .presentation, for: alpha), [alpha])
        XCTAssertEqual(state.set(true, reason: .gitStatus, for: alpha), [])
        XCTAssertEqual(state.set(false, reason: .gitStatus, for: alpha), [])
        XCTAssertEqual(state.set(false, reason: .presentation, for: alpha), [alpha])
    }

    func testLoweringAReasonNobodyRaisedChangesNothing() {
        var state = SessionLoadingState()

        XCTAssertEqual(state.set(false, reason: .presentation, for: alpha), [])
        XCTAssertFalse(state.isLoading(alpha))
    }

    // MARK: - Expiry

    /// The failsafe under the reasons: a raise whose lower gets dropped — a completion dying
    /// with its owner — used to spin its row for the rest of the app's life. Now it expires,
    /// and the sweep is told whose raise it took, because an expiry is a raiser that leaked.
    func testARaiseNobodyLowersExpires() {
        var state = SessionLoadingState()
        state.set(true, reason: .gitStatus, for: alpha, at: epoch)

        let expired = state.lowerExpired(raisedBefore: epoch.addingTimeInterval(1))

        XCTAssertEqual(expired.count, 1)
        XCTAssertEqual(expired.first?.sessionID, alpha)
        XCTAssertEqual(expired.first?.reason, .gitStatus)
        XCTAssertFalse(state.isLoading(alpha))
    }

    /// Re-raising is the owner saying the load is still real, so the clock starts over — a
    /// session re-selected while its checkout re-reads must not lose the new load's spinner
    /// to the old load's age.
    func testARenewedRaiseIsYoungAgain() {
        var state = SessionLoadingState()
        state.set(true, reason: .gitStatus, for: alpha, at: epoch)
        state.set(true, reason: .gitStatus, for: alpha, at: epoch.addingTimeInterval(20))

        let expired = state.lowerExpired(raisedBefore: epoch.addingTimeInterval(10))

        XCTAssertTrue(expired.isEmpty)
        XCTAssertTrue(state.isLoading(alpha))
    }

    /// Each raise carries its own age: the sweep takes only the leaked one, and a fresh
    /// reason keeps the row spinning exactly as one lowered by its owner would.
    func testExpiryTakesOnlyTheOldRaise() {
        var state = SessionLoadingState()
        state.set(true, reason: .presentation, for: alpha, at: epoch)
        state.set(true, reason: .gitReview, for: alpha, at: epoch.addingTimeInterval(20))

        let expired = state.lowerExpired(raisedBefore: epoch.addingTimeInterval(10))

        XCTAssertEqual(expired.count, 1)
        XCTAssertEqual(expired.first?.reason, .presentation)
        XCTAssertTrue(state.isLoading(alpha), "the fresh review read still holds the spinner")
        XCTAssertEqual(state.reasons(for: alpha), [.gitReview])
    }

    /// What decides whether the sweep needs to be scheduled at all.
    func testEmptinessFollowsTheLastSpinner() {
        var state = SessionLoadingState()
        XCTAssertTrue(state.isEmpty)

        state.set(true, reason: .gitStatus, for: alpha, at: epoch)
        XCTAssertFalse(state.isEmpty)

        state.lowerExpired(raisedBefore: epoch.addingTimeInterval(1))
        XCTAssertTrue(state.isEmpty)
    }

    // MARK: - Identifiers

    /// The identifier that names a conversation outside Threading is the agent's own where
    /// there is one — what "Copy Agent Session ID" puts on the pasteboard.
    func testTheExternalIdentifierIsTheAgentsOwnWhereThereIsOne() {
        var session = AgentSession(kind: .codex, title: "Rollout")
        session.resumeState = .resumable(TranscriptID("019852cf-codex-rollout"))

        XCTAssertEqual(session.externalIdentifier, "019852cf-codex-rollout")
    }

    /// Before an agent names a conversation, Threading's own id is still what the settings file,
    /// the MCP route and the journal are keyed by — which is what someone reading a log needs.
    func testTheExternalIdentifierFallsBackToThreadingsOwn() {
        let session = AgentSession(kind: .claude, title: "Fresh")

        XCTAssertEqual(session.resumeState, .awaitingIdentifier)
        XCTAssertEqual(session.externalIdentifier, session.threadingIdentifier)
    }

    /// Threading's own identifier, in the lowercased spelling every app-side surface uses —
    /// what "Copy Threading ID" puts on the pasteboard. It exists from birth and does not
    /// move when the agent later names the conversation.
    func testTheThreadingIdentifierIsTheLowercasedSessionID() {
        var session = AgentSession(kind: .codex, title: "Rollout")

        XCTAssertEqual(session.threadingIdentifier, session.id.uuidString.lowercased())

        let before = session.threadingIdentifier
        session.resumeState = .resumable(TranscriptID("019852cf-codex-rollout"))
        XCTAssertEqual(session.threadingIdentifier, before)
    }
}
