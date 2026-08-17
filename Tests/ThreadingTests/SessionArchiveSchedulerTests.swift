import AppKit
import XCTest
@testable import Threading

/// The wait between an agent asking to be archived and the archive happening.
///
/// The wait is the whole component. Archiving stops the agent, so an archive that landed while
/// the tool call was still open would kill the agent inside its own tool call — the user would
/// lose the answer they asked for on the way to the thing they asked for. Everything here is
/// therefore about *when*: that the request survives the rest of the turn, that it is spent on
/// the end of the turn that made it and not on some later one, and that it can be taken back.
///
/// Driven through a private `NotificationCenter` with both of the scheduler's lookups injected,
/// so no live agent, no store and none of the running app's own event traffic is involved.
@MainActor
final class SessionArchiveSchedulerTests: XCTestCase {

    // MARK: - Fixture

    private var center: NotificationCenter!
    private var session: AgentSession!
    private var activity: SessionActivity = .working
    private var due: [SessionArchiveRequestDidBecomeDue] = []
    private var observations: AppEventObservations!

    override func setUp() {
        super.setUp()
        center = NotificationCenter()
        session = AgentSession(kind: .claude, title: "Refactor the parser")
        activity = .working
        due = []
        observations = AppEventObservations(center: center)
        observations.observe(SessionArchiveRequestDidBecomeDue.self) { [weak self] event in
            self?.due.append(event)
        }
    }

    override func tearDown() {
        observations = nil
        center = nil
        super.tearDown()
    }

    private func scheduler(settle: TimeInterval = 0.02) -> SessionArchiveScheduler {
        let scheduler = SessionArchiveScheduler(
            center: center,
            activity: { [weak self] _ in self?.activity ?? .dormant },
            session: { [weak self] id in
                guard let self, id == self.session.id else { return nil }
                return self.session
            }
        )
        scheduler.settleDelay = settle
        return scheduler
    }

    /// The one signal the scheduler listens to, as the container posts it.
    private func reportActivity(_ new: SessionActivity, of sessionID: SessionID? = nil) {
        activity = new
        center.post(SessionActivityDidChange(sessionID: sessionID ?? session.id))
    }

    private func settle(_ interval: TimeInterval = 0.2) {
        let settled = expectation(description: "the run loop advanced")
        DispatchQueue.main.asyncAfter(deadline: .now() + interval) { settled.fulfill() }
        wait(for: [settled], timeout: interval + 5)
    }

    // MARK: - Waiting for the turn

    /// The heart of it: the request is made mid-turn, and nothing happens while the agent is
    /// still answering. An archive that landed here would stop the agent inside the very tool
    /// call that asked for it.
    func testARequestMadeMidTurnWaitsForTheTurnToEnd() {
        let scheduler = scheduler()
        XCTAssertEqual(
            scheduler.request(sessionID: session.id, reason: "committed the parser fix"),
            .scheduled
        )

        reportActivity(.working)
        settle()
        XCTAssertTrue(due.isEmpty, "the archive landed while the agent was still working")
        XCTAssertTrue(scheduler.isPending(sessionID: session.id))

        reportActivity(.idle)
        settle()

        XCTAssertEqual(due.map(\.sessionID), [session.id])
        XCTAssertEqual(due.first?.reason, "committed the parser fix")
        XCTAssertFalse(
            scheduler.isPending(sessionID: session.id),
            "a request that has been spent is still armed"
        )
    }

    func testManagerAttributionSurvivesTheSettleBoundary() {
        let scheduler = scheduler()
        let managerID = SessionID()
        XCTAssertEqual(
            scheduler.request(
                sessionID: session.id,
                reason: "review complete",
                requestedByManagerID: managerID
            ),
            .scheduled
        )

        reportActivity(.idle)
        settle()

        XCTAssertEqual(due.first?.sessionID, session.id)
        XCTAssertEqual(due.first?.requestedByManagerID, managerID)
        XCTAssertEqual(due.first?.reason, "review complete")
    }

    /// A manager may target only a child with no turn in flight. That means the child has already
    /// crossed the activity edge the ordinary self-archive waits for, and may never emit another
    /// one. The request must begin its settle from the current state rather than remain pending
    /// until an unrelated future turn.
    func testManagerRequestForAnAlreadySettledChildNeedsNoFutureActivityEvent() {
        activity = .idle
        let scheduler = scheduler()
        let managerID = SessionID()

        XCTAssertEqual(
            scheduler.request(
                sessionID: session.id,
                reason: "review complete",
                requestedByManagerID: managerID
            ),
            .scheduled
        )

        settle()

        XCTAssertEqual(due.map(\.sessionID), [session.id])
        XCTAssertEqual(due.first?.requestedByManagerID, managerID)
        XCTAssertFalse(scheduler.isPending(sessionID: session.id))
    }

    /// The manager shortcut must not change self-archive semantics. Even if the activity snapshot
    /// is briefly quiet while the tool call is open, the session filing itself still waits for a
    /// later report from its own turn boundary.
    func testSelfArchiveDoesNotTrustAnAlreadyIdleSnapshotInsideItsOwnTurn() {
        activity = .idle
        let scheduler = scheduler()

        XCTAssertEqual(
            scheduler.request(sessionID: session.id, reason: "finished"),
            .scheduled
        )
        settle()

        XCTAssertTrue(due.isEmpty)
        XCTAssertTrue(scheduler.isPending(sessionID: session.id))

        reportActivity(.idle)
        settle()

        XCTAssertEqual(due.map(\.sessionID), [session.id])
    }

    /// A finished turn nobody was looking at ends up unread rather than idle, and a session whose
    /// agent exited ends up dormant. Neither is still answering, so both are the end of the turn.
    func testAnyFinishedTurnIsTheEndOfTheTurn() {
        for finished in [SessionActivity.needsAttention, .dormant] {
            due = []
            let scheduler = scheduler()
            scheduler.request(sessionID: session.id, reason: nil)

            reportActivity(finished)
            settle()

            XCTAssertEqual(due.count, 1, "\(finished) left the request armed")
        }
    }

    /// A session on the output heuristic goes quiet in the middle of a turn — the agent is
    /// waiting on the model, not finished — and starts writing again. The settle must be called
    /// off by that, or the archive lands mid-turn on the very sessions whose turn boundaries are
    /// a guess. The request itself survives, and is spent on the real end.
    func testTheRequestSurvivesTheTurnGoingQuietAndComingBack() {
        let scheduler = scheduler(settle: 0.15)
        scheduler.request(sessionID: session.id, reason: nil)

        reportActivity(.idle)
        reportActivity(.working)
        settle(0.4)

        XCTAssertTrue(due.isEmpty, "the settle fired for a session that went back to work")
        XCTAssertTrue(scheduler.isPending(sessionID: session.id))

        reportActivity(.idle)
        settle(0.4)

        XCTAssertEqual(due.count, 1, "the request never landed on the turn's real end")
    }

    /// Another session's turn ending is not this session's turn ending.
    func testAnotherSessionsTurnDoesNotSpendThisRequest() {
        let scheduler = scheduler()
        scheduler.request(sessionID: session.id, reason: nil)

        reportActivity(.idle, of: SessionID())
        settle()

        XCTAssertTrue(due.isEmpty)
        XCTAssertTrue(scheduler.isPending(sessionID: session.id))
    }

    // MARK: - Taking it back

    func testCancellingBeforeTheTurnEndsCallsTheWholeThingOff() {
        let scheduler = scheduler()
        scheduler.request(sessionID: session.id, reason: nil)

        XCTAssertEqual(scheduler.cancel(sessionID: session.id), .cancelled)
        XCTAssertEqual(
            scheduler.cancel(sessionID: session.id),
            .nothingPending,
            "cancelling twice reported a second request that never existed"
        )

        reportActivity(.idle)
        settle()
        XCTAssertTrue(due.isEmpty)
    }

    /// Cancelling has to reach the armed settle as well as the request, or an archive already
    /// counting down would land after being called off.
    func testCancellingDuringTheSettleStillCallsItOff() {
        let scheduler = scheduler(settle: 0.3)
        scheduler.request(sessionID: session.id, reason: nil)
        reportActivity(.idle)

        XCTAssertEqual(scheduler.cancel(sessionID: session.id), .cancelled)
        settle(0.5)

        XCTAssertTrue(due.isEmpty, "the settle outlived the cancellation")
    }

    /// The user may archive or delete the row themselves while the settle runs, and a second
    /// receipt for an archive that already happened is a receipt for nothing.
    func testASessionArchivedWhileTheSettleRunsIsNotArchivedAgain() {
        let scheduler = scheduler(settle: 0.15)
        scheduler.request(sessionID: session.id, reason: nil)
        reportActivity(.idle)

        session.isArchived = true
        settle(0.4)

        XCTAssertTrue(due.isEmpty)
        XCTAssertFalse(scheduler.isPending(sessionID: session.id))
    }

    // MARK: - What it refuses

    func testItRefusesWhatItCannotArchive() {
        let scheduler = scheduler()

        XCTAssertEqual(
            scheduler.request(sessionID: SessionID(), reason: nil),
            .refused("This session is not in Threading's sidebar.")
        )

        session.isArchived = true
        XCTAssertEqual(
            scheduler.request(sessionID: session.id, reason: nil),
            .refused("This session is already archived.")
        )
    }

    /// Asking twice is still one archive, and the second reason is the one that describes what
    /// was actually finished.
    func testAskingTwiceReplacesTheReasonRatherThanQueueingASecondArchive() {
        let scheduler = scheduler()

        XCTAssertEqual(scheduler.request(sessionID: session.id, reason: "committed"), .scheduled)
        XCTAssertEqual(
            scheduler.request(sessionID: session.id, reason: "committed and pushed"),
            .alreadyPending
        )

        reportActivity(.idle)
        settle()

        XCTAssertEqual(due.count, 1)
        XCTAssertEqual(due.first?.reason, "committed and pushed")
    }

    /// A request that never became due must not be spent on some later, unrelated turn hours
    /// afterwards — the one way this could archive a session nobody asked it to.
    func testARequestThatOutlivesItsTurnIsDropped() {
        let scheduler = scheduler()
        // Anything armed is already stale, which is the half-hour-old request without the wait.
        scheduler.requestExpiry = 0
        scheduler.request(sessionID: session.id, reason: nil)

        reportActivity(.idle)
        settle()

        XCTAssertTrue(due.isEmpty, "a stale request was spent on a later turn")
        XCTAssertFalse(scheduler.isPending(sessionID: session.id))
    }

    // MARK: - The reason

    /// The reason is agent-authored text on its way to a band in the sidebar's column, so it
    /// arrives on one line and bounded rather than however it was written.
    func testTheReasonArrivesOnOneLineAndBounded() throws {
        let scheduler = scheduler()
        scheduler.request(
            sessionID: session.id,
            reason: "  committed the fix\n\nand pushed it  " + String(repeating: "…", count: 400)
        )

        let request = try XCTUnwrap(scheduler.pendingRequest(for: session.id))
        let reason = try XCTUnwrap(request.reason)
        XCTAssertFalse(reason.contains("\n"))
        XCTAssertTrue(reason.hasPrefix("committed the fix and pushed it"))
        XCTAssertLessThanOrEqual(reason.count, SessionArchiveDefaults.maximumReasonLength)
    }

    func testAnEmptyReasonIsNoReasonAtAll() throws {
        let scheduler = scheduler()
        scheduler.request(sessionID: session.id, reason: "   \n  ")

        XCTAssertNil(try XCTUnwrap(scheduler.pendingRequest(for: session.id)).reason)
    }
}
