import XCTest
@testable import Skalman

/// Covers the hook lifecycle vocabulary and the rule that decides whether a session's activity
/// comes from its own reports or from counting its output.
final class HookLifecycleTests: XCTestCase {

    // MARK: - Event Vocabulary

    func testEveryEventNamesAClaudeHook() {
        for event in HookLifecycleEvent.allCases {
            XCTAssertFalse(
                event.claudeEventName.isEmpty,
                "\(event) must name a Claude hook, or its settings entry writes an empty key"
            )
        }
    }

    /// Codex 0.144.6 carries Claude's event vocabulary apart from `Notification`. Pinning it
    /// means a release that adds the event fails here rather than silently staying unwired.
    func testCodexHasNoAwaitingUserEvent() {
        XCTAssertNil(HookLifecycleEvent.awaitingUser.codexEventName)

        for event in HookLifecycleEvent.allCases where event != .awaitingUser {
            XCTAssertNotNil(event.codexEventName, "\(event) should map onto a Codex hook")
        }
    }

    func testClaudeAndCodexAgreeOnSharedEventNames() {
        for event in HookLifecycleEvent.allCases {
            guard let codexName = event.codexEventName else { continue }
            XCTAssertEqual(codexName, event.claudeEventName)
        }
    }

    // MARK: - Report Parsing

    func testReportCarriesPromptAndAgentSessionID() throws {
        let sessionID = SessionID()
        let report = try XCTUnwrap(HookLifecycleReport(
            sessionID: sessionID,
            event: .turnStarted,
            payload: ["session_id": "abc-123", "prompt": "do the thing"]
        ))

        XCTAssertEqual(report.sessionID, sessionID)
        XCTAssertEqual(report.event, .turnStarted)
        XCTAssertEqual(report.agentSessionID, "abc-123")
        XCTAssertEqual(report.prompt, "do the thing")
    }

    /// An unnamed event is refused rather than defaulted. A lifecycle post whose query string
    /// was mangled says nothing about the turn, and guessing would move the session's state on
    /// no evidence.
    func testReportRefusesAnUnnamedEvent() {
        XCTAssertNil(HookLifecycleReport(
            sessionID: SessionID(),
            event: nil,
            payload: ["session_id": "abc-123"]
        ))
    }

    func testReportToleratesAnEmptyPayload() throws {
        let report = try XCTUnwrap(HookLifecycleReport(
            sessionID: SessionID(),
            event: .turnFinished,
            payload: [:]
        ))

        XCTAssertNil(report.agentSessionID)
        XCTAssertNil(report.prompt)
    }

    // MARK: - Query Parsing

    func testEventIsReadFromTheQueryString() {
        XCTAssertEqual(
            MCPServer.event(inQuery: "event=turnStarted"),
            .turnStarted
        )
        XCTAssertEqual(
            MCPServer.event(inQuery: "other=1&event=turnFinished"),
            .turnFinished
        )
    }

    /// Every unusable query resolves to nil rather than to a default, so a mangled URL leaves
    /// the session's state alone instead of moving it on no evidence.
    func testUnusableQueriesNameNoEvent() {
        XCTAssertNil(MCPServer.event(inQuery: nil))
        XCTAssertNil(MCPServer.event(inQuery: ""))
        XCTAssertNil(MCPServer.event(inQuery: "event="))
        XCTAssertNil(MCPServer.event(inQuery: "event=notAnEvent"))
        XCTAssertNil(MCPServer.event(inQuery: "notTheParameter=turnStarted"))
    }

    /// The writer and the reader have to agree, and they are in different files — a renamed
    /// case would otherwise write a URL nothing parses, silently.
    func testEveryEventRoundTripsThroughItsQueryString() {
        for event in HookLifecycleEvent.allCases {
            let query = "\(MCPDefaults.lifecycleEventParameter)=\(event.rawValue)"
            XCTAssertEqual(MCPServer.event(inQuery: query), event)
        }
    }

    // MARK: - Hook Failure Diagnostics

    /// The fixture is a real line, copied from a `--include-hook-events` run whose hook exited 7.
    private static let failingHookLine = """
        {"type":"system","subtype":"hook_response","hook_id":"abc","hook_name":"PreToolUse:Read",\
        "hook_event":"PreToolUse","output":"","stdout":"","stderr":"connection refused\\n",\
        "exit_code":7,"outcome":"error","uuid":"def","session_id":"ghi"}
        """

    func testFailingHookIsReported() throws {
        let failure = try XCTUnwrap(HookOutcomeLog.failure(inLine: Self.failingHookLine))

        XCTAssertEqual(failure.hookName, "PreToolUse:Read")
        XCTAssertEqual(failure.outcome, "error")
        XCTAssertEqual(failure.exitCode, "7")
        XCTAssertEqual(failure.stderr, "connection refused\n")
    }

    func testSuccessfulHookIsNotReported() {
        let line = """
            {"type":"system","subtype":"hook_response","hook_name":"Stop","output":"",\
            "stdout":"","stderr":"","exit_code":0,"outcome":"success"}
            """
        XCTAssertNil(HookOutcomeLog.failure(inLine: line))
    }

    /// This runs on every line of every stream, so everything that is not a hook response must
    /// fall out before anything is decoded.
    func testOrdinaryStreamLinesAreIgnored() {
        let lines = [
            #"{"type":"assistant","message":{"content":[{"type":"text","text":"hi"}]}}"#,
            #"{"type":"system","subtype":"init","tools":["Read"]}"#,
            #"{"type":"result","subtype":"success"}"#,
            "",
            "not json at all",
            #"{"type":"system","subtype":"hook_started","hook_name":"Stop"}"#
        ]

        for line in lines {
            XCTAssertNil(HookOutcomeLog.failure(inLine: line), "should ignore: \(line)")
        }
    }

    /// The schema belongs to the CLI. A renamed `outcome` should make the journal noisy rather
    /// than quietly stop reporting failures.
    func testMissingOutcomeIsTreatedAsAFailure() throws {
        let line = """
            {"type":"system","subtype":"hook_response","hook_name":"PreToolUse:Bash",\
            "exit_code":1}
            """
        let failure = try XCTUnwrap(HookOutcomeLog.failure(inLine: line))
        XCTAssertEqual(failure.outcome, "unknown")
    }

    /// The journal is appended synchronously, so one pathological hook must not be able to
    /// bury every record written after it.
    func testStderrIsCapped() throws {
        let noisy = String(repeating: "x", count: 5_000)
        let line = """
            {"type":"system","subtype":"hook_response","hook_name":"Stop",\
            "outcome":"error","exit_code":1,"stderr":"\(noisy)"}
            """
        let failure = try XCTUnwrap(HookOutcomeLog.failure(inLine: line))
        XCTAssertEqual(failure.stderr.count, HookOutcomeDefaults.maximumStderrCharacters)
    }

    // MARK: - Activity Reporting

    @MainActor
    func testReportedTurnsDriveActivity() {
        let tracker = SessionActivityTracker()
        tracker.markRunning()
        tracker.isVisible = true

        XCTAssertFalse(tracker.reportsOwnActivity)

        tracker.noteTurnStarted()
        XCTAssertEqual(tracker.activity, .working)
        XCTAssertTrue(tracker.reportsOwnActivity)

        tracker.noteTurnFinished()
        XCTAssertEqual(tracker.activity, .idle, "a visible session needs no attention flag")
    }

    @MainActor
    func testFinishingOffScreenNeedsAttention() {
        let tracker = SessionActivityTracker()
        tracker.markRunning()
        tracker.isVisible = false

        tracker.noteTurnStarted()
        tracker.noteTurnFinished()

        XCTAssertEqual(tracker.activity, .needsAttention)
    }

    /// Waiting on the user flags even a visible session, unlike merely finishing: the agent is
    /// blocked until someone answers, and a session being looked at but not attended to is the
    /// case worth marking.
    @MainActor
    func testAwaitingUserFlagsEvenWhenVisible() {
        let tracker = SessionActivityTracker()
        tracker.markRunning()
        tracker.isVisible = true

        tracker.noteAwaitingUser()

        XCTAssertEqual(tracker.activity, .needsAttention)
    }

    /// The whole point of the latch. A working agent is *quiet* while it waits on the model and
    /// *noisy* after its turn ends while the CLI redraws — so once it reports, its output must
    /// stop moving the state or the two signals fight.
    @MainActor
    func testOutputIsIgnoredOnceTheAgentReports() {
        let tracker = SessionActivityTracker()
        tracker.markRunning()
        tracker.isVisible = true

        tracker.noteTurnStarted()
        tracker.noteTurnFinished()
        XCTAssertEqual(tracker.activity, .idle)

        // A burst of redraw after the turn ended must not read as new work.
        tracker.recordOutput(byteCount: ActivityDefaults.workingByteThreshold * 10)

        XCTAssertEqual(tracker.activity, .idle)
    }

    /// A relaunched process has to earn belief again: the settings file carrying the hooks is
    /// written per launch and can fail, and a latched tracker with no reports coming would sit
    /// idle forever.
    @MainActor
    func testRelaunchClearsTheLatch() {
        let tracker = SessionActivityTracker()
        tracker.markRunning()
        tracker.noteTurnStarted()
        XCTAssertTrue(tracker.reportsOwnActivity)

        tracker.markDormant()
        tracker.markRunning()

        XCTAssertFalse(tracker.reportsOwnActivity)

        // Output drives the state again, since nothing has reported on this launch.
        tracker.recordOutput(byteCount: ActivityDefaults.workingByteThreshold + 1)
        XCTAssertEqual(tracker.activity, .working)
    }

    /// Shells never report, so they keep the heuristic in full.
    @MainActor
    func testOutputStillDrivesSessionsThatNeverReport() {
        let tracker = SessionActivityTracker()
        tracker.markRunning()

        tracker.recordOutput(byteCount: ActivityDefaults.workingByteThreshold + 1)

        XCTAssertEqual(tracker.activity, .working)
        XCTAssertFalse(tracker.reportsOwnActivity)
    }
}
