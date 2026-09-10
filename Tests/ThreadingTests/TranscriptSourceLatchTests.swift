import XCTest
@testable import Threading

/// Adopting a validated Codex rollout latches reporting.
///
/// A reattach after an app restart restarts no CLI and so fires no `SessionStart`, and it
/// clears every latch. Measured on 10 September 2026: 17 sessions were taken back from the
/// PTY host, the idle Codex chats among them repainted their prompts, inference opened a turn
/// on the first burst after the replay, and the rows spun over idle programs whose rollouts
/// ended in `task_complete` — while the rollout reader, which knew better, refused to act on
/// a session that had not latched.
@MainActor
final class TranscriptSourceLatchTests: XCTestCase {

    private let burst = ActivityDefaults.workingByteThreshold * 4

    func testAdoptingTheRolloutLatchesReportingSoRepaintsCannotOpenATurn() {
        let tracker = SessionActivityTracker()
        tracker.markRunning()
        tracker.isVisible = false
        tracker.noteTranscriptBoundarySourceAdopted()

        XCTAssertTrue(tracker.reportsOwnActivity)
        for _ in 0..<20 {
            XCTAssertNil(tracker.recordOutput(byteCount: burst))
        }
        XCTAssertEqual(tracker.activity, .idle)
        XCTAssertEqual(tracker.lastCause, .transcriptAdopted)
    }

    /// The rollout lookup is asynchronous, so the replay grace can end and a repaint can open
    /// an inferred turn before the rollout is found. That turn is a repaint, not a result.
    func testAdoptingTheRolloutClosesAPlainInferredTurnWithoutFlagging() {
        let tracker = SessionActivityTracker()
        tracker.markRunning()
        tracker.isVisible = false
        XCTAssertNotNil(tracker.recordOutput(byteCount: burst))
        XCTAssertEqual(tracker.activity, .working)

        tracker.noteTranscriptBoundarySourceAdopted()

        XCTAssertEqual(tracker.activity, .idle, "a repaint is not an unread result")
        XCTAssertFalse(tracker.runtimeSnapshot.hasOpenTurn)
    }

    /// The reader's first read is what recovers a turn the CLI already had open. It is
    /// admitted only because adoption latched.
    func testAfterAdoptionTheRolloutRecoversARunningTurnAndEndsIt() {
        let tracker = SessionActivityTracker()
        tracker.markRunning()
        tracker.isVisible = false
        tracker.noteTranscriptBoundarySourceAdopted()

        XCTAssertTrue(tracker.noteTurnStartedFromTranscript(turnID: "turn-1"))
        XCTAssertEqual(tracker.activity, .working)
        XCTAssertEqual(tracker.runtimeSnapshot.turn, .inFlight(.reported))
        tracker.recordOutput(byteCount: burst)
        XCTAssertEqual(tracker.runtimeSnapshot.turn, .inFlight(.reported),
                       "bytes neither restart nor end a declared turn")

        XCTAssertTrue(tracker.noteTurnFinishedFromTranscript(turnID: "turn-1"))
        XCTAssertEqual(tracker.activity, .needsAttention)
    }

    /// Without adoption the same read is refused — the fallback contract the reader keeps for
    /// a session whose rollout has not been found.
    func testWithoutAdoptionTheRolloutReadIsStillRefused() {
        let tracker = SessionActivityTracker()
        tracker.markRunning()

        XCTAssertFalse(tracker.noteTurnStartedFromTranscript(turnID: "turn-1"))
        XCTAssertEqual(tracker.activity, .idle)
    }

    /// A continuation the one-shot grant opened is the runtime's own reported finish speaking,
    /// and the rollout is about to name it. Adoption must not close it. The grant belongs to an
    /// ending-only runtime, one whose first report was a `Stop`.
    func testAdoptionKeepsAGrantedContinuation() {
        let tracker = SessionActivityTracker()
        tracker.markRunning()
        tracker.isVisible = false
        tracker.noteTurnFinished(continuationGrace: 10, allowsOutputInferredContinuation: true)
        XCTAssertNotNil(tracker.recordOutput(byteCount: burst))
        XCTAssertEqual(tracker.activity, .working)

        tracker.noteTranscriptBoundarySourceAdopted()

        XCTAssertEqual(tracker.activity, .working)
        XCTAssertTrue(tracker.noteTurnStartedFromTranscript(turnID: "goal-2"),
                      "the rollout then names the continuation it opened")
    }

    /// A reported finish inside its continuation grace is deliberately provisional. Adoption
    /// during that grace must not settle the state early: the finish would then follow with the
    /// badge the grace exists to avoid.
    func testAdoptionLeavesAProvisionalFinishAlone() {
        let tracker = SessionActivityTracker()
        tracker.markRunning()
        tracker.isVisible = false
        tracker.noteTurnStarted()
        tracker.noteTurnFinished(continuationGrace: 10)
        XCTAssertEqual(tracker.activity, .working, "provisional until the grace decides")
        XCTAssertTrue(tracker.hasPendingReportedTurnFinish)

        tracker.noteTranscriptBoundarySourceAdopted()

        XCTAssertEqual(tracker.activity, .working)
        XCTAssertTrue(tracker.hasPendingReportedTurnFinish)
    }

    /// The replay grace is the reattach's own protection and is left to end at the replay's
    /// boundary, as before.
    func testAdoptionLeavesTheReplayGraceInPlace() {
        let tracker = SessionActivityTracker()
        tracker.markRunning()
        tracker.isVisible = false
        tracker.noteUnattendedLaunch()
        tracker.noteTranscriptBoundarySourceAdopted()

        XCTAssertNil(tracker.recordOutput(byteCount: burst))
        tracker.endUnattendedLaunchGrace()
        XCTAssertNil(tracker.recordOutput(byteCount: burst), "latched: bytes still open nothing")
        XCTAssertEqual(tracker.activity, .idle)
    }

    /// A new process proves itself over again, rollout or not.
    func testANewProcessClearsTheAdoption() {
        let tracker = SessionActivityTracker()
        tracker.markRunning()
        tracker.noteTranscriptBoundarySourceAdopted()
        tracker.markDormant()
        tracker.markRunning()

        XCTAssertFalse(tracker.reportsOwnActivity)
        tracker.isVisible = false
        XCTAssertNotNil(tracker.recordOutput(byteCount: burst))
    }
}
