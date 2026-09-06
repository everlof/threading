import XCTest
@testable import Threading

final class SessionActivityRelaunchContinuationTests: XCTestCase {
    /// A resumed Codex session may already be in a turn when Threading relaunches. The start
    /// hook went to the previous app process, so `Stop` is the first lifecycle event the new
    /// tracker receives. Goal mode then opens another turn without a start hook. Keeping the
    /// unattended-launch grace after that real finish suppresses the continuation forever —
    /// the phone shows no loader while the terminal visibly says "Working".
    @MainActor
    func testFirstReportedFinishReconcilesAResumedGoalContinuation() {
        let tracker = SessionActivityTracker()
        var states: [SessionActivity] = []
        var attentionCount = 0
        tracker.onChange = { states.append($0) }
        tracker.onAttention = { attentionCount += 1 }
        tracker.noteUnattendedLaunch()
        tracker.markRunning()

        tracker.recordOutput(byteCount: ActivityDefaults.workingByteThreshold * 4)
        XCTAssertEqual(tracker.activity, .idle, "the resume repaint remains inert")

        tracker.noteTurnFinished(
            continuationGrace: 0.02,
            allowsOutputInferredContinuation: true
        )
        XCTAssertEqual(tracker.activity, .idle, "the provisional finish keeps the prior state")
        XCTAssertTrue(tracker.hasPendingReportedTurnFinish)
        XCTAssertEqual(attentionCount, 0, "an internal continuation is not an unread result")

        tracker.recordOutput(byteCount: ActivityDefaults.workingByteThreshold * 4)
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))

        XCTAssertEqual(
            tracker.activity,
            .working,
            "the first real boundary ends launch suppression for Codex's self-opened turn"
        )
        XCTAssertFalse(tracker.hasPendingReportedTurnFinish)
        XCTAssertEqual(states, [.working])
        XCTAssertEqual(attentionCount, 0)
    }
}
