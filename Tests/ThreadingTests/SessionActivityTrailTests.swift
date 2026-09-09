import XCTest
@testable import Threading

/// The record a state change leaves behind.
///
/// Written after a mark appeared on a session's row mid-conversation and nothing anywhere could
/// say which of the three routes into `needsAttention` had put it there. The state was derivable
/// and the *cause* was not, so these assert the cause: what the log line carries is exactly what
/// `lastCause` carries, and a rule with a test is a rule a refactor keeps.
@MainActor
final class SessionActivityTrailTests: XCTestCase {

    // MARK: - The Three Ways Into The Unread Mark

    func testExplicitAskRemainsABlockerWithoutAnObservedTurnStart() {
        let tracker = SessionActivityTracker()
        tracker.markRunning()
        tracker.noteUnattendedLaunch()
        tracker.noteBlockingAskOpened(id: "real-question")
        XCTAssertFalse(tracker.runtimeSnapshot.hasOpenTurn)
        XCTAssertEqual(tracker.runtimeSnapshot.blocker, .awaitingUser)
        tracker.isVisible = true
        XCTAssertEqual(tracker.runtimeSnapshot.blocker, .awaitingUser)
        tracker.noteBlockingAskClosed(id: "real-question")
        XCTAssertEqual(tracker.runtimeSnapshot.blocker, .none)
    }

    /// A turn ending off screen. The ordinary one: the agent finished, nobody watched.
    func testATurnThatEndsOffScreenNamesTheTurnAsTheCause() {
        let tracker = SessionActivityTracker()
        tracker.isVisible = false
        tracker.noteTurnStarted()
        tracker.noteTurnFinished()

        XCTAssertEqual(tracker.activity, .needsAttention)
        XCTAssertEqual(tracker.lastCause, .turnFinished)
    }

    /// The same edge with the session on screen settles somewhere else entirely, under the same
    /// cause. This pair is the reason the cause is recorded rather than inferred from the state:
    /// one input, two outcomes, and only the facts beside it tell them apart.
    func testTheSameTurnEndingOnScreenKeepsTheCauseAndDropsTheMark() {
        let tracker = SessionActivityTracker()
        tracker.isVisible = true
        tracker.noteTurnStarted()
        tracker.noteTurnFinished()

        XCTAssertEqual(tracker.activity, .idle)
        XCTAssertEqual(tracker.lastCause, .turnFinished)
    }

    /// The runtime's own idle-prompt notice — Claude's `Notification` hook. The one route that
    /// flags a session the user is looking straight at, which is what makes it the confusing
    /// one to receive and the one worth naming in the log.
    func testTheRuntimesOwnNoticeNamesItselfEvenOnAVisibleSession() {
        let tracker = SessionActivityTracker()
        tracker.isVisible = true
        tracker.noteTurnStarted()
        tracker.noteTurnFinished()
        XCTAssertEqual(tracker.activity, .idle, "the fixture did not reach a finished turn")

        tracker.noteAwaitingUser()

        XCTAssertEqual(tracker.activity, .needsAttention)
        XCTAssertEqual(tracker.lastCause, .awaitingUserReported)
    }

    /// A bell rung off screen, the third route. Distinguishable in the trail from both of the
    /// above, which it is not distinguishable from on the row.
    func testABellNamesItself() {
        let tracker = SessionActivityTracker()
        tracker.isVisible = false
        tracker.recordBell()

        XCTAssertEqual(tracker.activity, .needsAttention)
        XCTAssertEqual(tracker.lastCause, .bell)
    }

    // MARK: - Turn Endings Are Told Apart

    /// `Stop`, a rollout's interrupt and a transcript refusal settle identically and arrive from
    /// three different places. Collapsing them under one cause would leave the log saying a turn
    /// ended without saying who said so — which for the two fallbacks is the whole question,
    /// since they exist to cover a hook that did not fire.
    func testEachWayATurnCanEndCarriesItsOwnCause() {
        let interrupted = SessionActivityTracker()
        interrupted.noteTurnStarted(turnID: "turn-1")
        XCTAssertTrue(interrupted.noteTurnInterrupted(turnID: "turn-1"))
        XCTAssertEqual(interrupted.lastCause, .turnInterrupted)

        let refused = SessionActivityTracker()
        refused.noteTurnStarted(turnID: "turn-2")
        XCTAssertTrue(refused.noteTurnRefused(turn: refused.turnGeneration))
        XCTAssertEqual(refused.lastCause, .turnRefused)
    }

    /// A refused turn that never settles never records a cause either: the fallbacks are
    /// guarded, and a trail claiming a turn ended where the guard refused would be worse than no
    /// trail at all.
    func testARefusedFallbackThatChangesNothingRecordsNothing() {
        let tracker = SessionActivityTracker()
        tracker.noteTurnStarted(turnID: "turn-1")
        let causeAfterStart = tracker.lastCause

        XCTAssertFalse(tracker.noteTurnInterrupted(turnID: "a-different-turn"))

        XCTAssertEqual(tracker.lastCause, causeAfterStart, "a refused fallback rewrote the trail")
    }

    // MARK: - What The Line Is Told Apart By

    /// Looking at a flagged session lowers the mark, and says so as itself rather than as
    /// whatever raised it. The row going quiet is a state change like any other and the reason
    /// it went quiet is a fact about the user, not about the agent.
    func testLookingAtAFlaggedSessionNamesTheGlance() {
        let tracker = SessionActivityTracker()
        tracker.isVisible = false
        tracker.noteTurnStarted()
        tracker.noteTurnFinished()
        XCTAssertEqual(tracker.activity, .needsAttention)

        tracker.isVisible = true

        XCTAssertEqual(tracker.activity, .idle)
        XCTAssertEqual(tracker.lastCause, .seen)
    }

    /// Only the causes an agent reports are worth a line when the state does not move; the
    /// inferred ones fire on every burst of output from every session with no hooks, and a trail
    /// they were in would be unreadable at exactly the moment it is needed.
    func testOnlyReportedCausesCountAsWorthALineWhenNothingMoves() {
        for cause in [SessionActivityCause.turnStarted, .turnFinished, .turnInterrupted,
                      .awaitingUserReported, .blockingAskOpened, .blockingAskClosed] {
            XCTAssertTrue(cause.isReported, "\(cause.rawValue) is the agent speaking")
        }

        for cause in [SessionActivityCause.output, .quiet, .seen, .userInput, .bell, .turnRefused,
                      .limitParked, .limitCleared, .dormant, .running] {
            XCTAssertFalse(cause.isReported, "\(cause.rawValue) is Threading inferring")
        }
    }

    /// Every state and every park names itself in the log, and names itself *stably*: these
    /// strings are read months later beside lines written by an older build, so they are pinned
    /// here rather than derived from the case names.
    func testEveryStateAndParkHasAStableLogName() {
        XCTAssertEqual(SessionActivity.dormant.logName, "dormant")
        XCTAssertEqual(SessionActivity.idle.logName, "idle")
        XCTAssertEqual(SessionActivity.working.logName, "working")
        XCTAssertEqual(SessionActivity.awaitingUser.logName, "awaitingUser")
        XCTAssertEqual(SessionActivity.needsAttention.logName, "needsAttention")
        XCTAssertEqual(SessionActivity.limitReached.logName, "limitReached")

        XCTAssertEqual(SessionActivityTracker.LimitPark.none.logName, "none")
        XCTAssertEqual(SessionActivityTracker.LimitPark.flagged.logName, "flagged")
        XCTAssertEqual(SessionActivityTracker.LimitPark.recovering.logName, "recovering")
    }

    /// The trail is useless without an identity: a window holds dozens of these and they all
    /// report the same six states. The owner sets it; a fixture legitimately has none, and the
    /// line says `unowned` rather than dropping the entry.
    func testATrackerCarriesTheSessionItSpeaksFor() {
        let tracker = SessionActivityTracker()
        XCTAssertNil(tracker.sessionID, "a fixture should not have to invent a session")

        let id = SessionID()
        tracker.sessionID = id
        XCTAssertEqual(tracker.sessionID, id)
    }
}
