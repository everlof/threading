import XCTest
@testable import Threading

/// Why a bell rang, as `SessionActivityTracker` classifies it.
///
/// The four causes come out of the three facts the tracker already keeps — visibility, an
/// unattended launch, and who holds the PTY — so this is a reading of state that exists rather
/// than new instrumentation. What is worth holding is the **order**: the causes overlap, another
/// program can ring in a visible session or during a boot, and the precedence is what decides
/// which of two true answers the sound is chosen by.
///
/// The foreground question never runs here. It is two syscalls against a live PTY, and it is
/// gated on somebody having asked to hear the distinction — so the tests assert the gate as much
/// as the answer.
@MainActor
final class BellCauseTests: XCTestCase {

    // MARK: - One Cause at a Time

    func testABellInAVisibleSessionIsTheVisibleBell() {
        let tracker = SessionActivityTracker()
        tracker.markRunning()
        tracker.isVisible = true

        XCTAssertEqual(tracker.recordBell(), .bellAgentVisible)
    }

    func testABellInASessionNobodyIsWatchingIsTheAsk() {
        let tracker = SessionActivityTracker()
        tracker.markRunning()
        tracker.isVisible = false

        XCTAssertEqual(tracker.recordBell(), .bellAgentAsking)
        XCTAssertEqual(
            tracker.activity,
            .needsAttention,
            "the edge it has always been — a raised flag with no turn open is unread"
        )
    }

    func testABellDuringAnUnattendedLaunchIsBootNoise() {
        let tracker = SessionActivityTracker()
        tracker.noteUnattendedLaunch()
        tracker.markRunning()

        XCTAssertEqual(tracker.recordBell(), .bellLaunch)
        XCTAssertEqual(tracker.activity, .idle, "and still raises no flag")
    }

    // MARK: - Precedence

    /// A launch nobody watched outranks being on screen. The two can hold at once — a session
    /// selected in the sidebar while its relaunch boots — and boot noise is what the bell is.
    func testTheLaunchOutranksVisibility() {
        let tracker = SessionActivityTracker()
        tracker.isVisible = true
        tracker.noteUnattendedLaunch()
        tracker.markRunning()

        XCTAssertEqual(tracker.recordBell(), .bellLaunch)
    }

    /// Visibility outranks attribution: while you are watching, who rang matters less than that
    /// you saw it. The probe is not even asked.
    func testVisibilityOutranksAttribution() {
        let tracker = SessionActivityTracker()
        tracker.markRunning()
        tracker.isVisible = true

        var asked = 0
        let cause = tracker.recordBell(
            attributesOtherPrograms: true,
            otherProgramHoldsPTY: {
                asked += 1
                return true
            }
        )

        XCTAssertEqual(cause, .bellAgentVisible)
        XCTAssertEqual(asked, 0)
    }

    func testAnotherProgramOutranksTheAskWhenNobodyIsWatching() {
        let tracker = SessionActivityTracker()
        tracker.markRunning()
        tracker.isVisible = false

        let cause = tracker.recordBell(
            attributesOtherPrograms: true,
            otherProgramHoldsPTY: { true }
        )

        XCTAssertEqual(cause, .bellOtherProgram)
        XCTAssertEqual(
            tracker.activity,
            .needsAttention,
            "the cause names the sound; the edge is the same one either way"
        )
    }

    func testTheAgentHoldingItsOwnTerminalIsStillTheAsk() {
        let tracker = SessionActivityTracker()
        tracker.markRunning()
        tracker.isVisible = false

        XCTAssertEqual(
            tracker.recordBell(attributesOtherPrograms: true, otherProgramHoldsPTY: { false }),
            .bellAgentAsking
        )
    }

    // MARK: - The Gate

    /// Without an entry of its own, `bell.otherProgram` resolves to the same sound as the bell
    /// that asks — so asking the kernel who holds the PTY would buy a distinction nobody could
    /// hear. Nobody pays for attribution they have not asked for.
    func testTheForegroundIsNotAskedWithoutAnEntryToHearItThrough() {
        let tracker = SessionActivityTracker()
        tracker.markRunning()
        tracker.isVisible = false

        var asked = 0
        let cause = tracker.recordBell(
            attributesOtherPrograms: false,
            otherProgramHoldsPTY: {
                asked += 1
                return true
            }
        )

        XCTAssertEqual(asked, 0)
        XCTAssertEqual(cause, .bellAgentAsking)
    }

    /// And the gate the caller reads is the resolution chain's own answer, so the two cannot
    /// disagree: an entry for the event is what turns the syscalls on.
    func testTheGateIsTheSameQuestionTheChainAnswers() {
        XCTAssertFalse(
            SoundResolution.attributesOtherPrograms(
                through: [SoundResolution.Scope(kinds: [.bell: .named("Glass.aiff")])]
            )
        )
        XCTAssertTrue(
            SoundResolution.attributesOtherPrograms(
                through: [SoundResolution.Scope(events: [.bellOtherProgram: .named("Tink.aiff")])]
            )
        )
    }

    // MARK: - The Edge Is Unchanged

    /// The classification is a reading, not a rewrite: every state the bell used to move is
    /// still moved the same way.
    func testTheBellStillEndsAnInferredTurn() {
        let tracker = SessionActivityTracker()
        tracker.markRunning()
        tracker.isVisible = true

        tracker.recordOutput(byteCount: ActivityDefaults.workingByteThreshold + 1)
        XCTAssertEqual(tracker.activity, .working)

        XCTAssertEqual(tracker.recordBell(), .bellAgentVisible)
        XCTAssertEqual(tracker.activity, .idle)
    }
}
