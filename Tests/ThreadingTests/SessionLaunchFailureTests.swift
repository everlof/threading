import XCTest
@testable import Threading

/// The record that keeps a failed launch's own account of itself.
///
/// The bug this answers is not subtle and is worth restating where it will be read: an agent
/// that refuses to start prints why, exits, and Threading tore the terminal down — the message
/// was legible in one frame of a 60fps recording. Everything here exists so that the words
/// survive the teardown, and so that an ordinary exit is not mistaken for one of these.
final class SessionLaunchFailureTests: XCTestCase {

    // MARK: - Telling A Failure From An Ending

    func testAQuickNonZeroExitReadsAsAFailedLaunch() {
        XCTAssertTrue(SessionLaunchFailure.looksLikeLaunchFailure(exitCode: 1, ranFor: 0.4))
    }

    func testAgentsThatRanAndThenExitedNonZeroAreNotLaunchFailures() {
        // A session the user worked in for an hour and then quit with a non-zero status has
        // ended, not failed. Treating it as a failure would put an error surface over the
        // conversation they just finished.
        XCTAssertFalse(SessionLaunchFailure.looksLikeLaunchFailure(exitCode: 130, ranFor: 3_600))
    }

    func testACleanQuickExitIsNotAFailure() {
        // `--version`-shaped launches and an agent the user opened and immediately closed both
        // land here. Nothing went wrong, so nothing is recorded.
        XCTAssertFalse(SessionLaunchFailure.looksLikeLaunchFailure(exitCode: 0, ranFor: 0.2))
    }

    func testAnUnknownExitStatusIsNotGuessedAt() {
        // A PTY that closed before a status could be read says nothing about whether the launch
        // worked, and inventing a failure from it would put a band over a healthy session.
        XCTAssertFalse(SessionLaunchFailure.looksLikeLaunchFailure(exitCode: nil, ranFor: 0.1))
    }

    // MARK: - What It Keeps

    func testTheCaptureKeepsTheEndOfTheOutputRatherThanTheStart() {
        // A program that prints a banner and then fails puts the reason last. The banner is the
        // part already visible everywhere else.
        let lines = (1...200).map { "line \($0)" }
        let failure = SessionLaunchFailure(
            origin: .processExit,
            summary: "stopped",
            detail: lines
        )

        XCTAssertEqual(failure.detail.count, SessionLaunchFailureDefaults.capturedLineCount)
        XCTAssertEqual(failure.detail.last, "line 200")
    }

    func testBlankTerminalRowsAreDroppedRatherThanCounted() {
        // A terminal screen is mostly empty. Without this the budget is spent on the blank rows
        // under a four-line error and the error itself falls out of the record.
        let screen = ["Error: something went wrong"] + Array(repeating: "   ", count: 60)
        let failure = SessionLaunchFailure(
            origin: .processExit,
            summary: "stopped",
            detail: screen
        )

        XCTAssertEqual(failure.detail, ["Error: something went wrong"])
    }

    func testOneEnormousLineCannotSpendTheWholeBudget() {
        let failure = SessionLaunchFailure(
            origin: .processExit,
            summary: "stopped",
            detail: [String(repeating: "e", count: 5_000), "the real reason"]
        )

        XCTAssertEqual(failure.detail.count, 2)
        XCTAssertLessThanOrEqual(
            failure.detail[0].count,
            SessionLaunchFailureDefaults.capturedLineLength
                + SessionLaunchFailureDefaults.clipMarker.count
        )
        XCTAssertEqual(failure.detail[1], "the real reason")
    }

    func testTheReportCarriesEverythingSomebodyWouldNeedToAskAboutIt() {
        let failure = SessionLaunchFailure(
            origin: .processExit,
            exitCode: 1,
            ranFor: 0.3,
            summary: "Codex refused to resume this conversation.",
            detail: ["Error: missing an ordinal"],
            transcriptPath: "/Users/someone/.codex/sessions/rollout.jsonl"
        )

        let report = failure.report
        XCTAssertTrue(report.contains("Codex refused to resume this conversation."))
        XCTAssertTrue(report.contains("1"), "the exit status belongs in a report about an exit")
        XCTAssertTrue(report.contains("rollout.jsonl"))
        XCTAssertTrue(report.contains("Error: missing an ordinal"))
    }

    // MARK: - Persistence

    func testARecordSurvivesTheRoundTripThroughASessionsStoredForm() throws {
        // The record has to outlive the app: a failure the user comes back to tomorrow must
        // still say what happened, which a live terminal buffer could never do.
        let failure = SessionLaunchFailure(
            origin: .preflight,
            summary: "The saved file cannot be reopened.",
            detail: ["one", "two"],
            transcriptPath: "/tmp/rollout.jsonl",
            knownCause: SessionLaunchDiagnosis.Cause.transcriptUnreadable
        )

        let decoded = try JSONDecoder().decode(
            SessionLaunchFailure.self,
            from: JSONEncoder().encode(failure)
        )
        XCTAssertEqual(decoded, failure)
    }
}

// MARK: - Diagnosis

/// The rules that turn a runtime's own words into a sentence the user can act on.
final class SessionLaunchDiagnosisTests: XCTestCase {

    /// The specimen, as it appeared on screen.
    private let codexOrdinalRefusal = [
        "Error: Failed to resume session from /Users/x/.codex/sessions/2026/08/20/rollout.jsonl:",
        "thread/resume failed during TUI bootstrap: thread/resume failed: error resuming thread:",
        "Fatal error: Failed to initialize session: thread-store internal error: failed to",
        "resume local thread recorder: final paginated rollout record at /Users/x/.codex/",
        "sessions/2026/08/20/rollout.jsonl is missing an ordinal (code -32603)",
    ]

    func testTheSpecimenIsRecognisedAsAnUnreadableConversation() {
        let match = SessionLaunchDiagnosis.classify(lines: codexOrdinalRefusal, kind: .codex)

        XCTAssertEqual(match?.knownCause, SessionLaunchDiagnosis.Cause.transcriptUnreadable)
        XCTAssertEqual(match?.isRecoverable, true)
        XCTAssertEqual(match?.summary.contains("Codex"), true)
    }

    func testARecognisedTranscriptFaultIsWhatOffersTheRecoveryRoute() {
        // The two halves of the offer's gate, held together: a cause about the file, and a file
        // to work on. Either alone must not put an agent to work in the user's home directory.
        let recognised = SessionLaunchFailure(
            origin: .processExit,
            summary: "refused",
            transcriptPath: "/tmp/rollout.jsonl",
            knownCause: SessionLaunchDiagnosis.Cause.transcriptUnreadable
        )
        XCTAssertTrue(LaunchRecoveryBrief.canAttempt(recognised))

        let noFile = SessionLaunchFailure(
            origin: .processExit,
            summary: "refused",
            knownCause: SessionLaunchDiagnosis.Cause.transcriptUnreadable
        )
        XCTAssertFalse(LaunchRecoveryBrief.canAttempt(noFile))

        let notAboutTheFile = SessionLaunchFailure(
            origin: .processExit,
            summary: "no such command",
            transcriptPath: "/tmp/rollout.jsonl",
            knownCause: SessionLaunchDiagnosis.Cause.executableMissing
        )
        XCTAssertFalse(LaunchRecoveryBrief.canAttempt(notAboutTheFile))

        let unrecognised = SessionLaunchFailure(
            origin: .processExit,
            summary: "stopped right after starting",
            transcriptPath: "/tmp/rollout.jsonl"
        )
        XCTAssertFalse(LaunchRecoveryBrief.canAttempt(unrecognised))
    }

    func testAMissingExecutableIsDiagnosedButNotOfferedForRepair() {
        let match = SessionLaunchDiagnosis.classify(
            lines: ["bash: line 1: codex: command not found"],
            kind: .codex
        )

        XCTAssertEqual(match?.knownCause, SessionLaunchDiagnosis.Cause.executableMissing)
        XCTAssertEqual(match?.isRecoverable, false)
    }

    func testUnrecognisedOutputProducesNoDiagnosisRatherThanAGuess() {
        // A wrong cause is worse than none: a user told the wrong reason stops reading the lines
        // that say the right one.
        XCTAssertNil(SessionLaunchDiagnosis.classify(
            lines: ["Something nobody has written a rule for"],
            kind: .codex
        ))
        XCTAssertNil(SessionLaunchDiagnosis.classify(lines: [], kind: .codex))
    }
}
