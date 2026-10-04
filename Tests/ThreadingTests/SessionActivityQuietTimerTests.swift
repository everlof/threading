import XCTest
@testable import Threading

@MainActor
final class SessionActivityQuietTimerTests: XCTestCase {
    private let burst = ActivityDefaults.workingByteThreshold * 4

    func testQueuedQuietExpiryCannotEndAHookDeclaredTurn() throws {
        let tracker = inferredTracker()
        var attentionCount = 0
        tracker.onAttention = { attentionCount += 1 }

        // Firing queues the timer's main-actor task. A hook arrives before that task runs.
        try quietTimer(in: tracker).fire()
        tracker.noteTurnStarted(turnID: "reported-turn")
        drainQueuedExpiry()

        XCTAssertEqual(tracker.activity, .working)
        XCTAssertTrue(tracker.runtimeSnapshot.hasOpenTurn)
        XCTAssertEqual(tracker.lastCause, .turnStarted)
        XCTAssertEqual(attentionCount, 0)
        tracker.noteTurnFinished()
        XCTAssertEqual(attentionCount, 1, "only the provider's finish earns attention")
    }

    func testQueuedQuietExpiryCannotEndATranscriptDeclaredTurn() throws {
        let tracker = inferredTracker()
        var attentionCount = 0
        tracker.onAttention = { attentionCount += 1 }

        try quietTimer(in: tracker).fire()
        tracker.noteTranscriptBoundarySourceAdopted()
        XCTAssertTrue(tracker.noteTurnStartedFromTranscript(turnID: "rollout-turn"))
        drainQueuedExpiry()

        XCTAssertEqual(tracker.activity, .working)
        XCTAssertTrue(tracker.runtimeSnapshot.hasOpenTurn)
        XCTAssertEqual(attentionCount, 0)
        tracker.markDormant()
    }

    func testQueuedQuietExpiryCannotConsumeAReplacementOutputTimer() throws {
        let tracker = inferredTracker()
        var attentionCount = 0
        tracker.onAttention = { attentionCount += 1 }

        try quietTimer(in: tracker).fire()
        tracker.recordOutput(byteCount: burst)
        let replacement = try quietTimer(in: tracker)
        drainQueuedExpiry()

        XCTAssertEqual(tracker.activity, .working)
        XCTAssertTrue(tracker.runtimeSnapshot.hasOpenTurn)
        XCTAssertEqual(attentionCount, 0)

        replacement.fire()
        drainQueuedExpiry()
        XCTAssertEqual(tracker.activity, .needsAttention)
        XCTAssertFalse(tracker.runtimeSnapshot.hasOpenTurn)
        XCTAssertEqual(tracker.lastCause, .quiet)
        XCTAssertEqual(attentionCount, 1)
    }

    private func inferredTracker() -> SessionActivityTracker {
        // Explicitly fire the production timer so no wall-clock race controls the ordering.
        let tracker = SessionActivityTracker(quietInterval: 60)
        tracker.markRunning()
        tracker.isVisible = false
        tracker.recordOutput(byteCount: burst)
        XCTAssertEqual(tracker.activity, .working)
        return tracker
    }

    private func quietTimer(in tracker: SessionActivityTracker) throws -> Timer {
        try XCTUnwrap(Mirror(reflecting: tracker).children.first {
            $0.label == "quietTimer"
        }?.value as? Timer)
    }

    private func drainQueuedExpiry() {
        RunLoop.current.run(until: Date().addingTimeInterval(0.02))
    }
}
