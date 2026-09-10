import XCTest
@testable import Threading

/// `SessionStart` latches reporting.
///
/// The hook proves this process's hooks reach Threading, which is the fact the output heuristic
/// exists to stand in for. Measured on 10 September 2026: a Codex chat resumed with no prompt
/// repainted its idle input box faster than the 0.8-second quiet timer, nothing had latched
/// because no turn had been reported since the resume, and the moment the chat was selected one
/// burst opened an inferred turn that no silence could close. The row spun over a CLI sitting
/// at its prompt for as long as the chat stayed selected.
@MainActor
final class SessionStartLatchTests: XCTestCase {

    private let burst = ActivityDefaults.workingByteThreshold * 4

    func testAfterSessionStartIdleRepaintsCannotOpenATurn() {
        let tracker = SessionActivityTracker()
        tracker.markRunning()
        tracker.noteSessionStarted()

        XCTAssertTrue(tracker.reportsOwnActivity)
        XCTAssertTrue(tracker.runtimeSnapshot.reportsOwnTurns)
        for _ in 0..<20 {
            XCTAssertNil(tracker.recordOutput(byteCount: burst))
        }
        XCTAssertEqual(tracker.activity, .idle)
        XCTAssertFalse(tracker.runtimeSnapshot.hasOpenTurn)
    }

    /// Selecting the chat is what re-armed inference in the measured case. Being looked at must
    /// not hand the repaints a second chance either.
    func testViewingAfterSessionStartDoesNotReArmInference() {
        let tracker = SessionActivityTracker()
        tracker.markRunning()
        tracker.isVisible = false
        tracker.noteSessionStarted()
        tracker.isVisible = true
        XCTAssertNil(tracker.recordOutput(byteCount: burst))
        tracker.isVisible = false
        XCTAssertNil(tracker.recordOutput(byteCount: burst))

        XCTAssertEqual(tracker.activity, .idle)
    }

    /// A turn output inferred before the announcement is boot paint. A process that has just
    /// said it started has nothing in flight, and nobody's result is waiting to be read.
    func testSessionStartClosesABootInferredTurnWithoutFlaggingIt() {
        let tracker = SessionActivityTracker()
        tracker.markRunning()
        tracker.isVisible = false
        XCTAssertNotNil(tracker.recordOutput(byteCount: burst))
        XCTAssertEqual(tracker.activity, .working)

        tracker.noteSessionStarted()

        XCTAssertEqual(tracker.activity, .idle, "boot paint is not an unread result")
        XCTAssertFalse(tracker.runtimeSnapshot.hasOpenTurn)
        XCTAssertEqual(tracker.lastCause, .sessionStarted)
    }

    /// Only an *inferred* turn is boot paint. A turn a hook or the rollout declared is stronger
    /// evidence than a start announcement that arrives late, and only its own boundary ends it.
    func testSessionStartKeepsADeclaredTurn() {
        let tracker = SessionActivityTracker()
        tracker.markRunning()
        tracker.noteTurnStarted()
        XCTAssertTrue(tracker.runtimeSnapshot.hasOpenTurn)

        tracker.noteSessionStarted()

        XCTAssertEqual(tracker.activity, .working)
        XCTAssertTrue(tracker.runtimeSnapshot.hasOpenTurn)
        XCTAssertTrue(tracker.noteTurnStartedFromTranscript(turnID: "goal-1"),
                      "the rollout may still name the turn a hook opened")
    }

    /// The grace ends at the first input or the first turn, and a start announcement is neither:
    /// a relaunched session must still not flag its own boot, and a runtime notice that arrives
    /// during it is still ignored.
    func testSessionStartLeavesTheUnattendedLaunchGraceInPlace() {
        let tracker = SessionActivityTracker()
        tracker.markRunning()
        tracker.isVisible = false
        tracker.noteUnattendedLaunch()
        tracker.noteSessionStarted()

        XCTAssertNil(tracker.recordOutput(byteCount: burst))
        tracker.noteAwaitingUser(.idlePrompt)
        XCTAssertEqual(tracker.activity, .idle, "an idle prompt on an unattended boot is not a request")

        tracker.noteTurnStarted()
        XCTAssertEqual(tracker.activity, .working, "the first real turn ends the grace as before")
    }

    /// Reported boundaries are unchanged by the earlier latch.
    func testReportedTurnsStillDriveTheStateAfterSessionStart() {
        let tracker = SessionActivityTracker()
        tracker.markRunning()
        tracker.isVisible = false
        tracker.noteSessionStarted()

        tracker.noteTurnStarted()
        XCTAssertEqual(tracker.activity, .working)
        tracker.recordOutput(byteCount: burst)
        XCTAssertEqual(tracker.runtimeSnapshot.turn, .inFlight(.reported),
                       "bytes inside a declared turn neither restart nor end it")
        tracker.noteTurnFinished()
        XCTAssertEqual(tracker.activity, .needsAttention)
    }

    /// Codex's one-shot continuation grant survives: a reported finish may still let output
    /// open exactly one inferred continuation inside its grace, because that is a finish the
    /// runtime declared, not a repaint.
    func testTheCodexContinuationGrantIsUnaffected() {
        let tracker = SessionActivityTracker()
        tracker.markRunning()
        tracker.isVisible = false
        tracker.noteSessionStarted()
        tracker.noteTurnStarted()
        tracker.noteTurnFinished(
            continuationGrace: 10,
            allowsOutputInferredContinuation: true
        )

        XCTAssertNotNil(tracker.recordOutput(byteCount: burst), "the granted continuation opens")
        XCTAssertEqual(tracker.activity, .working)
    }

    /// Runtimes that never announce themselves — shells, Grok, OpenCode — keep the heuristic,
    /// because it is all they have.
    func testWithoutASessionStartOutputStillOpensATurn() {
        let tracker = SessionActivityTracker()
        tracker.markRunning()
        tracker.isVisible = false

        XCTAssertNotNil(tracker.recordOutput(byteCount: burst))
        XCTAssertEqual(tracker.activity, .working)
        XCTAssertFalse(tracker.reportsOwnActivity)
    }

    /// A new process proves itself over again: the settings file carrying the hooks is written
    /// per launch and can fail, and a latched tracker with no reports coming would sit idle.
    func testANewProcessMustAnnounceItselfAgain() {
        let tracker = SessionActivityTracker()
        tracker.markRunning()
        tracker.noteSessionStarted()
        XCTAssertTrue(tracker.reportsOwnActivity)

        tracker.markDormant()
        tracker.markRunning()

        XCTAssertFalse(tracker.reportsOwnActivity)
        XCTAssertFalse(tracker.hasHeardFromProcess)
        tracker.isVisible = false
        XCTAssertNotNil(tracker.recordOutput(byteCount: burst))
        XCTAssertEqual(tracker.activity, .working)
    }
}
