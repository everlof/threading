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

    func testSubagentStopCarriesChildTranscriptMetadata() throws {
        let report = try XCTUnwrap(HookLifecycleReport(
            sessionID: SessionID(),
            event: .subagentStopped,
            payload: [
                "session_id": "parent-123",
                "turn_id": "turn-456",
                "agent_id": "child-789",
                "agent_type": "explorer",
                "agent_transcript_path": "/tmp/child.jsonl",
                "last_assistant_message": "Found the call site."
            ]
        ))

        XCTAssertEqual(report.agentSessionID, "parent-123")
        XCTAssertEqual(report.turnID, "turn-456")
        XCTAssertEqual(report.subagentID, "child-789")
        XCTAssertEqual(report.subagentType, "explorer")
        XCTAssertEqual(report.subagentTranscriptPath, "/tmp/child.jsonl")
        XCTAssertEqual(report.lastAssistantMessage, "Found the call site.")
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
        XCTAssertNil(report.subagentID)
        XCTAssertNil(report.subagentTranscriptPath)
        XCTAssertTrue(report.backgroundTaskIDs.isEmpty)
    }

    /// The shape Claude 2.1.220 sends on `Stop` beside a backgrounded shell. Only each entry's
    /// identity is taken, so the rest carries the provider's own vocabulary untouched.
    func testStopNamesTheWorkTheAgentLeftRunning() throws {
        let report = try XCTUnwrap(HookLifecycleReport(
            sessionID: SessionID(),
            event: .turnFinished,
            payload: [
                "session_id": "abc-123",
                "last_assistant_message": "Test run queued; will report when it lands.",
                "background_tasks": [
                    [
                        "id": "bwf9miuvg",
                        "type": "shell",
                        "status": "running",
                        "description": "Re-run the icon tests",
                        "command": "scripts/test.sh"
                    ],
                    ["id": "b8x1tqpxz", "type": "subagent", "status": "pending"]
                ]
            ]
        ))

        XCTAssertEqual(report.backgroundTaskIDs, ["bwf9miuvg", "b8x1tqpxz"])
    }

    /// An entry the schema should carry an id for but does not falls back to its position, so
    /// it still looks like the same task at the next boundary rather than a brand new one.
    func testAnUnidentifiedTaskFallsBackToAStablePosition() throws {
        let report = try XCTUnwrap(HookLifecycleReport(
            sessionID: SessionID(),
            event: .turnFinished,
            payload: ["background_tasks": [["type": "shell", "status": "running"]]]
        ))

        XCTAssertEqual(report.backgroundTaskIDs, ["#0"])
    }

    /// "Empty array when nothing is in flight" is the CLI's own contract, and it must read the
    /// same as a Codex report that has no such key at all — both mean the session is done.
    func testAnEmptyBackgroundListReadsTheSameAsNoneReported() throws {
        let empty = try XCTUnwrap(HookLifecycleReport(
            sessionID: SessionID(),
            event: .turnFinished,
            payload: ["background_tasks": []]
        ))
        let absent = try XCTUnwrap(HookLifecycleReport(
            sessionID: SessionID(),
            event: .turnFinished,
            payload: ["session_id": "codex-1"]
        ))

        XCTAssertTrue(empty.backgroundTaskIDs.isEmpty)
        XCTAssertTrue(absent.backgroundTaskIDs.isEmpty)
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

        tracker.noteTurnStarted()
        tracker.noteAwaitingUser()

        XCTAssertEqual(tracker.activity, .awaitingUser)
    }

    /// Blocked and unread are separate states because they cost the user different things: one
    /// is a turn stopped dead waiting on them, the other a turn nobody has read yet.
    @MainActor
    func testBlockedInsideATurnIsNotTheSameAsFinishedUnread() {
        let blocked = SessionActivityTracker()
        blocked.markRunning()
        blocked.noteTurnStarted()
        blocked.noteAwaitingUser()

        let unread = SessionActivityTracker()
        unread.markRunning()
        unread.isVisible = false
        unread.noteTurnStarted()
        unread.noteTurnFinished()

        XCTAssertEqual(blocked.activity, .awaitingUser)
        XCTAssertEqual(unread.activity, .needsAttention)
    }

    /// Claude also notifies once its prompt has sat idle a while, which arrives *after* `Stop`.
    /// Nothing is waiting on the user there — the turn is simply over — so it must not take the
    /// louder mark.
    @MainActor
    func testNotifyingAfterATurnEndsReadsAsUnreadRatherThanBlocked() {
        let tracker = SessionActivityTracker()
        tracker.markRunning()
        tracker.isVisible = false

        tracker.noteTurnStarted()
        tracker.noteTurnFinished()
        tracker.noteAwaitingUser()

        XCTAssertEqual(tracker.activity, .needsAttention)
    }

    // MARK: - Background Work Ledger

    /// The rule in isolation, without a tracker around it. Both CLIs wake a session when a
    /// background task ends, so "will this speak again" is true of everything in the list and
    /// separates nothing. When the work *appeared* is what separates them.
    func testOnlyWorkTheTurnItselfStartedPausesIt() {
        var ledger = BackgroundWorkLedger()

        XCTAssertTrue(ledger.turnEnded(leaving: ["a"]), "started in this turn")
        XCTAssertFalse(ledger.turnEnded(leaving: ["a"]), "carried over, so parked")
        XCTAssertTrue(ledger.turnEnded(leaving: ["a", "b"]), "b is new beside the parked a")
        XCTAssertFalse(ledger.turnEnded(leaving: ["a", "b"]))
        XCTAssertFalse(ledger.turnEnded(leaving: []), "nothing left to wait for")
    }

    /// Ids are replaced at each boundary rather than accumulated: a task that finished and one
    /// that never ran are the same thing to the next turn, and remembering it forever would
    /// make a task that comes back look familiar.
    func testWorkThatFinishedIsNotRememberedAsCarriedOver() {
        var ledger = BackgroundWorkLedger()

        XCTAssertTrue(ledger.turnEnded(leaving: ["a"]))
        XCTAssertFalse(ledger.turnEnded(leaving: []))
        XCTAssertTrue(ledger.turnEnded(leaving: ["a"]), "a second run of the same work is new")
    }

    func testForgettingMakesTheNextTaskNewAgain() {
        var ledger = BackgroundWorkLedger()

        XCTAssertTrue(ledger.turnEnded(leaving: ["a"]))
        ledger.forget()
        XCTAssertTrue(ledger.turnEnded(leaving: ["a"]), "a relaunched process inherits nothing")
    }

    // MARK: - Work Left Running

    /// The bug this exists for. An agent that backgrounds a test run ends its turn straight
    /// away, and the CLI wakes it a minute later with the result — so the `Stop` in between is
    /// not the session finishing. Reading it as one posted "finished its turn" and dropped a
    /// completed mark on a session that then went on talking.
    @MainActor
    func testATurnEndedOnTopOfItsOwnRunningWorkIsNotFinished() {
        let onScreen = SessionActivityTracker()
        onScreen.markRunning()
        onScreen.isVisible = true
        onScreen.noteTurnStarted()
        onScreen.noteTurnFinished(backgroundWork: ["bwf9miuvg"])

        let offScreen = SessionActivityTracker()
        offScreen.markRunning()
        offScreen.isVisible = false
        offScreen.noteTurnStarted()
        offScreen.noteTurnFinished(backgroundWork: ["bwf9miuvg"])

        XCTAssertEqual(onScreen.activity, .working, "nothing has finished yet")
        XCTAssertEqual(
            offScreen.activity,
            .working,
            "nor is there anything unread: the agent has not said its piece"
        )
    }

    /// The wake, and the real end. The task lands, the CLI submits it as a prompt of its own,
    /// and *that* turn's `Stop` carries an empty list — which is the one that finishes.
    @MainActor
    func testTheTurnThatOutlivesTheWorkIsTheOneThatFinishes() {
        let tracker = SessionActivityTracker()
        tracker.markRunning()
        tracker.isVisible = false

        tracker.noteTurnStarted()
        tracker.noteTurnFinished(backgroundWork: ["bwf9miuvg"])
        XCTAssertEqual(tracker.activity, .working)

        // The background task completed and Claude submitted its result as a new prompt.
        tracker.noteTurnStarted()
        XCTAssertEqual(tracker.activity, .working)

        tracker.noteTurnFinished()
        XCTAssertEqual(tracker.activity, .needsAttention)
    }

    /// The trade-off the ledger exists to remove. A dev server the agent parked keeps running
    /// across every later turn, and holding each of them open behind it would silence the
    /// session for as long as the server lives. Only the turn that *started* it is waiting.
    @MainActor
    func testWorkCarriedOverFromAnEarlierTurnNoLongerHoldsTheSessionOpen() {
        let tracker = SessionActivityTracker()
        tracker.markRunning()
        tracker.isVisible = false

        tracker.noteTurnStarted()
        tracker.noteTurnFinished(backgroundWork: ["dev-server"])
        XCTAssertEqual(tracker.activity, .working, "the turn that started it is waiting on it")

        tracker.noteTurnStarted()
        tracker.noteTurnFinished(backgroundWork: ["dev-server"])
        XCTAssertEqual(
            tracker.activity,
            .needsAttention,
            "a later turn handed back to the user with the server merely still running"
        )

        // And a genuinely new task still pauses, beside the one that was already there.
        tracker.noteTurnStarted()
        tracker.noteTurnFinished(backgroundWork: ["dev-server", "test-run"])
        XCTAssertEqual(tracker.activity, .working)
    }

    /// Work left running is held apart from the turn on purpose. Claude raises `Notification`
    /// once its prompt has sat idle a while, and the turn is the only thing that tells that
    /// from a permission prompt — so paused work must not borrow it, or a session waiting on
    /// its own shell would report the user as blocking it.
    @MainActor
    func testWorkLeftRunningDoesNotOpenATurnForTheNextNotificationToLandIn() {
        let tracker = SessionActivityTracker()
        tracker.markRunning()
        tracker.isVisible = false

        tracker.noteTurnStarted()
        tracker.noteTurnFinished(backgroundWork: ["bwf9miuvg"])
        tracker.noteAwaitingUser()

        XCTAssertEqual(tracker.activity, .needsAttention)
    }

    /// A relaunch clears it with everything else: the new process owns none of the old work,
    /// and nothing will ever report those tasks ending.
    @MainActor
    func testRelaunchForgetsWorkTheOldProcessLeftRunning() {
        let tracker = SessionActivityTracker()
        tracker.markRunning()
        tracker.isVisible = false
        tracker.noteTurnStarted()
        tracker.noteTurnFinished(backgroundWork: ["bwf9miuvg"])
        XCTAssertEqual(tracker.activity, .working)

        tracker.markDormant()
        XCTAssertEqual(tracker.activity, .dormant)

        tracker.markRunning()
        XCTAssertEqual(tracker.activity, .idle)
    }

    // MARK: - Output Versus Reports

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

    // MARK: - Asking Inside a Turn

    /// The bug the sidebar wore for a whole run: a permission prompt raises `Notification`
    /// mid-turn, so a question must not end the turn it was asked inside.
    @MainActor
    func testLookingAtAFlaggedSessionReturnsItToItsTurn() {
        let tracker = SessionActivityTracker()
        tracker.markRunning()
        tracker.isVisible = false

        tracker.noteTurnStarted()
        tracker.noteAwaitingUser()
        XCTAssertEqual(tracker.activity, .awaitingUser)

        tracker.isVisible = true

        XCTAssertEqual(
            tracker.activity,
            .working,
            "the turn is still open, and only the next prompt would ever have said so again"
        )
    }

    /// The other half of the same rule: a session that actually *finished* off screen goes idle
    /// when it is looked at, exactly as before. Answering a question and reading a result are
    /// different acts, and the turn is what tells them apart.
    @MainActor
    func testLookingAtAFinishedSessionStillGoesIdle() {
        let tracker = SessionActivityTracker()
        tracker.markRunning()
        tracker.isVisible = false

        tracker.noteTurnStarted()
        tracker.noteTurnFinished()
        XCTAssertEqual(tracker.activity, .needsAttention)

        tracker.isVisible = true

        XCTAssertEqual(tracker.activity, .idle)
    }

    /// Answering where you stand raises no hook at all, so the only evidence the agent resumed
    /// is that it started writing again. Admitted inside a flagged turn and nowhere else.
    @MainActor
    func testOutputInsideAFlaggedTurnReadsAsTheAnswer() {
        let tracker = SessionActivityTracker()
        tracker.markRunning()
        tracker.isVisible = true

        tracker.noteTurnStarted()
        tracker.noteAwaitingUser()
        XCTAssertEqual(tracker.activity, .awaitingUser)

        tracker.recordOutput(byteCount: ActivityDefaults.workingByteThreshold + 1)

        XCTAssertEqual(tracker.activity, .working)
    }

    /// Off screen the flag is the only thing saying a session is waiting, and nobody can have
    /// answered a prompt they are not looking at — so a redraw must not spend it.
    @MainActor
    func testOutputOffScreenLeavesTheFlagAlone() {
        let tracker = SessionActivityTracker()
        tracker.markRunning()
        tracker.isVisible = false

        tracker.noteTurnStarted()
        tracker.noteAwaitingUser()

        tracker.recordOutput(byteCount: ActivityDefaults.workingByteThreshold * 10)

        XCTAssertEqual(tracker.activity, .awaitingUser)
    }

    /// And it may only move towards working: once the turn is over, output is the CLI redrawing
    /// its footer, which is what the latch exists to ignore.
    @MainActor
    func testOutputCannotReopenAFinishedTurn() {
        let tracker = SessionActivityTracker()
        tracker.markRunning()
        tracker.isVisible = false

        tracker.noteTurnStarted()
        tracker.noteTurnFinished()
        tracker.noteAwaitingUser()

        tracker.recordOutput(byteCount: ActivityDefaults.workingByteThreshold * 10)

        XCTAssertEqual(tracker.activity, .needsAttention)
    }

    /// A bell is another way of asking, and agents ring one mid-turn as readily as at the end.
    @MainActor
    func testBellInsideAReportedTurnDoesNotEndIt() {
        let tracker = SessionActivityTracker()
        tracker.markRunning()
        tracker.isVisible = false

        tracker.noteTurnStarted()
        tracker.recordBell()
        XCTAssertEqual(tracker.activity, .awaitingUser)

        tracker.isVisible = true

        XCTAssertEqual(tracker.activity, .working)
    }

    /// Where nothing reports, the bell is the only boundary there is, so it still ends the
    /// inferred turn — otherwise a shell would sit working with no timer left to stop it.
    @MainActor
    func testBellEndsAnInferredTurn() {
        let tracker = SessionActivityTracker()
        tracker.markRunning()
        tracker.isVisible = true

        tracker.recordOutput(byteCount: ActivityDefaults.workingByteThreshold + 1)
        XCTAssertEqual(tracker.activity, .working)

        tracker.recordBell()

        XCTAssertEqual(tracker.activity, .idle)
    }

    /// A question asked before the session had a process is not a reason to show it working.
    @MainActor
    func testDormancyOutranksBothFacts() {
        let tracker = SessionActivityTracker()
        tracker.markRunning()
        tracker.noteTurnStarted()
        tracker.noteAwaitingUser()

        tracker.markDormant()

        XCTAssertEqual(tracker.activity, .dormant)

        tracker.isVisible = true
        XCTAssertEqual(tracker.activity, .dormant, "being looked at does not give it a process")
    }
}
