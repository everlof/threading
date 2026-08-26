import XCTest
@testable import Threading

/// Covers the hook lifecycle vocabulary and the rule that decides whether a session's activity
/// comes from its own reports or from counting its output.
final class HookLifecycleTests: XCTestCase {

    // MARK: - Event Vocabulary

    func testEveryEventNamesAClaudeHook() {
        for event in HookLifecycleEvent.allCases {
            XCTAssertTrue(
                event.claudeRegistration.isSupported,
                "\(event) must name a Claude hook, or nothing installs it"
            )
            XCTAssertFalse(
                event.claudeRegistration.eventNames.contains(where: \.isEmpty),
                "\(event) must not write an empty key into the settings file"
            )
        }
    }

    /// Codex 0.144.6 carries Claude's turn vocabulary apart from `Notification`, and exposes no
    /// tool whose result is the user's answer. Pinning it means a release that adds either fails
    /// here rather than silently staying unwired.
    func testCodexReportsTurnsButNeverThatItIsWaiting() {
        let unsupported: Set<HookLifecycleEvent> = [
            .awaitingUser, .blockingAskOpened, .blockingAskClosed
        ]

        for event in HookLifecycleEvent.allCases {
            XCTAssertEqual(
                event.codexRegistration.isSupported,
                !unsupported.contains(event),
                "\(event) is registered with Codex against expectation"
            )
        }
    }

    func testClaudeAndCodexAgreeOnSharedEventNames() {
        for event in HookLifecycleEvent.allCases {
            let codex = event.codexRegistration
            guard codex.isSupported else { continue }
            XCTAssertEqual(codex.eventNames, event.claudeRegistration.eventNames)
        }
    }

    // MARK: - Blocking Asks

    /// The two halves of an ask are registered on the tool hooks, scoped to the tools that ask.
    /// Unscoped, the opening hook would report every `Read` as a question.
    func testAnAskIsRegisteredOnTheToolHooksAndScopedToTheAskingTools() {
        let opened = HookLifecycleEvent.blockingAskOpened.claudeRegistration
        let closed = HookLifecycleEvent.blockingAskClosed.claudeRegistration

        XCTAssertEqual(opened.eventNames, ["PreToolUse"])
        XCTAssertEqual(closed.eventNames, ["PostToolUse", "PostToolUseFailure"])

        let matcher = TurnBlockingTools.names(for: .claude).joined(separator: "|")
        XCTAssertEqual(opened.toolMatcher, matcher)
        XCTAssertEqual(closed.toolMatcher, matcher)
    }

    /// Everything else fires on its own boundary and must stay unscoped, or a matcher meant for
    /// one event would quietly stop another from ever arriving.
    func testOnlyTheAskEventsAreScopedToTools() {
        for event in HookLifecycleEvent.allCases
        where event != .blockingAskOpened && event != .blockingAskClosed {
            XCTAssertNil(event.claudeRegistration.toolMatcher, "\(event) must not be scoped")
            XCTAssertNil(event.codexRegistration.toolMatcher, "\(event) must not be scoped")
        }
    }

    /// A runtime that names no asking tool registers nothing at all. The alternative — an
    /// unmatched hook — would report every tool call as a turn stopped on the user.
    func testARuntimeWithNoAskingToolRegistersNoHookRatherThanAnUnmatchedOne() {
        XCTAssertEqual(
            HookRegistration.matched(eventNames: ["PreToolUse"], tools: []),
            .unsupported
        )

        for kind in AgentKind.allCases {
            let tools = TurnBlockingTools.names(for: kind)
            let registration = HookRegistration.matched(eventNames: ["PreToolUse"], tools: tools)

            XCTAssertEqual(
                registration.isSupported,
                !tools.isEmpty,
                "\(kind) may register a hook only when it names a tool to scope it to"
            )
            XCTAssertEqual(
                registration.toolMatcher == nil,
                tools.isEmpty,
                "\(kind) must never register a tool-scoped hook without its matcher"
            )
        }
    }

    func testClaudeStopsOnTheQuestionAndThePlanApproval() {
        XCTAssertEqual(
            TurnBlockingTools.names(for: .claude),
            ["AskUserQuestion", "ExitPlanMode"]
        )
    }

    // MARK: - Report Parsing

    func testReportCarriesPromptAndAgentSessionID() throws {
        let sessionID = SessionID()
        let report = try XCTUnwrap(HookLifecycleReport(
            sessionID: sessionID,
            event: .turnStarted,
            payload: [
                "session_id": "abc-123",
                "turn_id": "turn-456",
                "transcript_path": "/tmp/rollout-abc-123.jsonl",
                "prompt": "do the thing"
            ]
        ))

        XCTAssertEqual(report.sessionID, sessionID)
        XCTAssertEqual(report.event, .turnStarted)
        XCTAssertEqual(report.agentSessionID, TranscriptID("abc-123"))
        XCTAssertEqual(report.turnID, "turn-456")
        XCTAssertEqual(report.transcriptPath, "/tmp/rollout-abc-123.jsonl")
        XCTAssertEqual(report.prompt, "do the thing")
    }

    // MARK: - Codex Interrupted Turns

    /// A scrubbed copy of the structured record behind Codex 0.147.0's red
    /// "Conversation interrupted" notice. The presentation string is absent on purpose: the
    /// lifecycle fact is the event, its reason, and the turn it names.
    func testCodexReadsAStructuredInterruptedTurn() throws {
        let record: [String: Any] = [
            "timestamp": "2026-08-08T21:16:13.332Z",
            "type": "event_msg",
            "payload": [
                "type": "turn_aborted",
                "turn_id": "019fe33b-9f27-7e72-a5f1-6f54723f468c",
                "reason": "interrupted"
            ]
        ]

        XCTAssertEqual(
            CodexTranscriptInterruption.interruption(in: record),
            CodexTurnInterruption(turnID: "019fe33b-9f27-7e72-a5f1-6f54723f468c")
        )
    }

    /// Similar prose in a response item is terminal presentation, not authority to move state.
    func testCodexDoesNotParseRenderedInterruptionText() {
        let record: [String: Any] = [
            "type": "response_item",
            "payload": [
                "role": "developer",
                "content": [
                    ["type": "input_text", "text": "<turn_aborted>Conversation interrupted</turn_aborted>"]
                ]
            ]
        ]

        XCTAssertNil(CodexTranscriptInterruption.interruption(in: record))
    }

    func testOnlyAnExplicitInterruptedReasonClosesTheTurn() {
        let record: [String: Any] = [
            "type": "event_msg",
            "payload": [
                "type": "turn_aborted",
                "turn_id": "turn-1",
                "reason": "unknown-future-reason"
            ]
        ]

        XCTAssertNil(CodexTranscriptInterruption.interruption(in: record))
    }

    func testCodexReadsAnInterruptionOnlyWhenItIsTheNewestTurnBoundary() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("threading-codex-interruption-\(UUID().uuidString)")
        let transcript = directory.appendingPathComponent("rollout.jsonl")
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let interrupted = [
            #"{"type":"event_msg","payload":{"type":"task_started","turn_id":"turn-1"}}"#,
            #"{"type":"event_msg","payload":{"type":"turn_aborted","turn_id":"turn-1","reason":"interrupted"}}"#
        ].joined(separator: "\n") + "\n"
        try Data(interrupted.utf8).write(to: transcript)

        XCTAssertEqual(
            CodexTranscriptInterruption.newestInterruption(at: transcript),
            CodexTurnInterruption(turnID: "turn-1")
        )

        let newerTurn =
            #"{"type":"event_msg","payload":{"type":"task_started","turn_id":"turn-2"}}"# + "\n"
        let handle = try FileHandle(forWritingTo: transcript)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(newerTurn.utf8))
        try handle.close()

        XCTAssertNil(CodexTranscriptInterruption.newestInterruption(at: transcript))
    }

    /// The call's own id, so an ask is closed by the tool that opened it rather than by the next
    /// tool of the same name.
    func testAnAskNamesTheToolCallItDescribes() throws {
        let report = try XCTUnwrap(HookLifecycleReport(
            sessionID: SessionID(),
            event: .blockingAskOpened,
            payload: ["tool_name": "AskUserQuestion", "tool_use_id": "toolu_01"]
        ))

        XCTAssertEqual(report.toolCallID, "toolu_01")
    }

    /// A runtime that identifies no call still pairs, on the tool's name.
    func testAnAskWithoutACallIDFallsBackToTheToolName() throws {
        let report = try XCTUnwrap(HookLifecycleReport(
            sessionID: SessionID(),
            event: .blockingAskOpened,
            payload: ["tool_name": "AskUserQuestion", "tool_use_id": ""]
        ))

        XCTAssertEqual(report.toolCallID, "AskUserQuestion")
    }

    func testAnEventAboutNoToolNamesNoCall() throws {
        let report = try XCTUnwrap(HookLifecycleReport(
            sessionID: SessionID(),
            event: .turnStarted,
            payload: ["prompt": "do the thing"]
        ))

        XCTAssertNil(report.toolCallID)
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

        XCTAssertEqual(report.agentSessionID, TranscriptID("parent-123"))
        XCTAssertEqual(report.turnID, "turn-456")
        XCTAssertEqual(report.subagentID, "child-789")
        XCTAssertEqual(report.subagentType, "explorer")
        XCTAssertEqual(report.subagentTranscriptPath, "/tmp/child.jsonl")
        XCTAssertEqual(report.lastAssistantMessage, "Found the call site.")
    }

    // MARK: - Child Admission

    /// The measured shape of Claude reporting its **own** turn through `SubagentStop`: the root
    /// agent's id, an *empty* `agent_type`, a transcript path under `<session>/subagents/` that
    /// the CLI never writes, and the parent's own closing message.
    ///
    /// Taken verbatim from a persisted navigator, where seventeen of twenty recorded children
    /// had this shape — each one a row that opened onto nothing and could never be dismissed.
    private func mainAgentStopReport(
        transcriptPath: String = "/Users/x/.claude/projects/-p/sess/subagents/agent-a1b2c3.jsonl"
    ) throws -> HookLifecycleReport {
        try XCTUnwrap(HookLifecycleReport(
            sessionID: SessionID(),
            event: .subagentStopped,
            payload: [
                "session_id": "ea15ac11-65a0-4dd0-9380-6bb6e6fe2e34",
                "agent_id": "a1b2c3",
                "agent_type": "",
                "agent_transcript_path": transcriptPath,
                "last_assistant_message": "Goal: fix the navigator. Nothing is changed yet."
            ]
        ))
    }

    func testTheParentReportingItsOwnTurnIsNotAChild() throws {
        let report = try mainAgentStopReport()

        XCTAssertFalse(report.describesChildAgent(
            isAlreadyTracked: false,
            transcriptExists: { _ in false }
        ))
    }

    func testANamedAgentTypeIsAChild() throws {
        let report = try XCTUnwrap(HookLifecycleReport(
            sessionID: SessionID(),
            event: .subagentStarted,
            payload: ["agent_id": "child-1", "agent_type": "Explore"]
        ))

        XCTAssertTrue(
            report.describesChildAgent(
                isAlreadyTracked: false,
                transcriptExists: { _ in false }
            ),
            "A child names its type before it has written anything"
        )
    }

    /// The terminal analogue of native's "accepted only when its tool-use id is already known":
    /// with no type to go on, a transcript on disk is what proves there is a child behind it.
    func testAnUnnamedTypeIsAdmittedOnlyWithATranscriptOnDisk() throws {
        let report = try mainAgentStopReport()

        XCTAssertTrue(report.describesChildAgent(
            isAlreadyTracked: false,
            transcriptExists: { _ in true }
        ))
    }

    /// A child admitted at `SubagentStart` must still receive its `SubagentStop`, or it stays
    /// working for the rest of the session.
    func testAChildAlreadyTrackedStaysAdmitted() throws {
        let report = try XCTUnwrap(HookLifecycleReport(
            sessionID: SessionID(),
            event: .subagentStopped,
            payload: ["agent_id": "child-1", "agent_type": ""]
        ))

        XCTAssertFalse(report.describesChildAgent(
            isAlreadyTracked: false,
            transcriptExists: { _ in false }
        ))
        XCTAssertTrue(report.describesChildAgent(
            isAlreadyTracked: true,
            transcriptExists: { _ in false }
        ))
    }

    /// The injected predicate is a test seam, not the behaviour — this pins the default the app
    /// actually runs with against a real file and a real absence.
    func testTheDefaultTranscriptCheckReadsTheFileSystem() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("threading-hook-admission-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let written = directory.appendingPathComponent("agent-child.jsonl")
        try Data("{}\n".utf8).write(to: written)

        XCTAssertTrue(try mainAgentStopReport(transcriptPath: written.path)
            .describesChildAgent(isAlreadyTracked: false))
        XCTAssertFalse(try mainAgentStopReport(
            transcriptPath: directory.appendingPathComponent("absent.jsonl").path
        ).describesChildAgent(isAlreadyTracked: false))
    }

    func testAReportWithNoTranscriptPathAndNoTypeIsRefused() throws {
        let report = try XCTUnwrap(HookLifecycleReport(
            sessionID: SessionID(),
            event: .subagentStopped,
            payload: ["agent_id": "child-1"]
        ))

        XCTAssertFalse(report.describesChildAgent(isAlreadyTracked: false))
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
        XCTAssertTrue(report.backgroundWork.isEmpty)
    }

    /// The shape Claude 2.1.220 sends on `Stop` beside a backgrounded shell. Only each entry's
    /// identity and kind are taken, so the rest carries the provider's own vocabulary untouched.
    ///
    /// The hook spells the kind as the friendly label from its own schema — `shell`, `subagent`
    /// — where the stream sends the raw discriminant. `BackgroundWorkKind` reads both.
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

        XCTAssertEqual(report.backgroundWork, [
            BackgroundTask(id: "bwf9miuvg", kind: .standing),
            BackgroundTask(id: "b8x1tqpxz", kind: .delegated)
        ])
    }

    /// An entry the schema should carry an id for but does not falls back to its position, so
    /// it still looks like the same task at the next boundary rather than a brand new one.
    ///
    /// A missing *type* falls back to `.standing`, which is the reading that changes nothing:
    /// the entry is judged by age, exactly as every entry was before kinds were read at all.
    func testAnUnidentifiedTaskFallsBackToAStablePosition() throws {
        let report = try XCTUnwrap(HookLifecycleReport(
            sessionID: SessionID(),
            event: .turnFinished,
            payload: ["background_tasks": [["status": "running"]]]
        ))

        XCTAssertEqual(report.backgroundWork, [BackgroundTask(id: "#0", kind: .standing)])
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

        XCTAssertTrue(empty.backgroundWork.isEmpty)
        XCTAssertTrue(absent.backgroundWork.isEmpty)
    }

    /// Every task type the CLI can name, read off the two spellings it uses to name them.
    ///
    /// Taken from 2.1.224's own label table rather than from a list: the hook maps each raw
    /// discriminant through it, and the stream sends the discriminant untouched. Only the two
    /// delegated kinds pause a session regardless of age, and anything unrecognised — including
    /// a type added by a later CLI — must read as standing, which is the direction that leaves
    /// today's behaviour alone.
    func testBothSpellingsOfEveryTaskTypeAreRead() {
        for delegated in ["subagent", "local_agent", "workflow", "local_workflow"] {
            XCTAssertEqual(
                BackgroundWorkKind(reportedType: delegated),
                .delegated,
                "\(delegated) reports back into the conversation on its own"
            )
        }

        for standing in [
            "shell", "local_bash",
            "monitor", "monitor_mcp", "monitor_ws",
            "MCP task", "mcp_task",
            "teammate", "in_process_teammate",
            "cloud session", "remote_agent",
            "dream", "auto-mode scan", "auto_mode_scan",
            "something_a_later_cli_invents"
        ] {
            XCTAssertEqual(
                BackgroundWorkKind(reportedType: standing),
                .standing,
                "\(standing) may stand indefinitely, so it is judged by age"
            )
        }

        XCTAssertEqual(BackgroundWorkKind(reportedType: nil), .standing)
    }

    // MARK: - Notification Kind

    /// The shape Claude 2.1.238 sends when its prompt has sat idle for
    /// `messageIdleNotifThresholdMs`. The hook name is the same one a permission prompt arrives
    /// under, so the type is the only thing that tells the two apart.
    func testTheIdlePromptNoticeIsReadOffItsType() throws {
        let report = try XCTUnwrap(HookLifecycleReport(
            sessionID: SessionID(),
            event: .awaitingUser,
            payload: [
                "session_id": "abc-123",
                "message": "Claude is waiting for your input",
                "notification_type": "idle_prompt"
            ]
        ))

        XCTAssertEqual(report.notification, .idlePrompt)
    }

    /// Every other notice is `.unspecified`, and that is the reading suppression is opt-in
    /// against: a permission prompt, a type a later CLI invents, and a payload that names none
    /// at all all stay loud. The list is 2.1.238's own, minus the one case above.
    func testEveryOtherNoticeReadsAsOneWorthFlagging() {
        for named in [
            "permission_prompt", "worker_permission_prompt",
            "agent_needs_input", "agent_completed",
            "elicitation_complete", "elicitation_response",
            "computer_use_enter", "computer_use_exit",
            "auth_success", "push_notification",
            "quota_auto_resume_disabled", "quota_auto_resume_fired", "quota_auto_resume_stale",
            "something_a_later_cli_invents"
        ] {
            XCTAssertEqual(
                HookNotificationKind(reportedType: named),
                .unspecified,
                "\(named) may be a real question, so it must not be quietly dropped"
            )
        }

        XCTAssertEqual(HookNotificationKind(reportedType: nil), .unspecified)
        XCTAssertEqual(HookNotificationKind(reportedType: ""), .unspecified)
    }

    /// A Codex report, and every event that is not a notice, carry no type — and must read the
    /// same as a notice that named none, since only an exact match is ever treated as weak.
    func testAnEventThatIsNotANoticeCarriesNoKind() throws {
        let report = try XCTUnwrap(HookLifecycleReport(
            sessionID: SessionID(),
            event: .turnFinished,
            payload: ["session_id": "codex-1"]
        ))

        XCTAssertEqual(report.notification, .unspecified)
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

    // MARK: - Provoked Output

    /// Moving the pointer over a CLI that tracks the mouse repaints the row under it, which is
    /// far over the byte threshold for a sweep of a few cells. The session was reading that as
    /// a turn: a spinner started by nothing but the mouse, on a session sitting at its prompt.
    @MainActor
    func testPointerMotionRepaintDoesNotStartATurn() {
        let tracker = SessionActivityTracker()
        tracker.markRunning()
        tracker.isVisible = true

        tracker.noteMouseReportForwarded()
        tracker.recordOutput(byteCount: ActivityDefaults.workingByteThreshold * 4)

        XCTAssertEqual(tracker.activity, .idle)
    }

    /// The same repaint on a session that reports its own turns took the other route: a burst
    /// inside a flagged turn means the user answered where they stood, which a hover highlight
    /// is not. The question is still open, so the mark stays up.
    @MainActor
    func testPointerMotionRepaintDoesNotAnswerAQuestion() {
        let tracker = SessionActivityTracker()
        tracker.markRunning()
        tracker.isVisible = true

        tracker.noteTurnStarted()
        tracker.noteAwaitingUser()
        tracker.noteMouseReportForwarded()
        tracker.recordOutput(byteCount: ActivityDefaults.workingByteThreshold * 4)

        XCTAssertEqual(tracker.activity, .awaitingUser)
    }

    /// Suppression blocks a session *entering* `working` and must not end one that already is —
    /// otherwise moving the mouse mid-task would report the agent as finished.
    @MainActor
    func testPointerMotionDoesNotEndAnInflightTurn() {
        let tracker = SessionActivityTracker()
        tracker.markRunning()
        tracker.isVisible = true

        tracker.recordOutput(byteCount: ActivityDefaults.workingByteThreshold * 4)
        XCTAssertEqual(tracker.activity, .working)

        tracker.noteMouseReportForwarded()
        tracker.recordOutput(byteCount: ActivityDefaults.workingByteThreshold * 4)

        XCTAssertEqual(tracker.activity, .working)
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

    /// Codex returns to its prompt after this event but omits `Stop`; the rollout fallback must
    /// cross the exact same activity edge that hook would have crossed.
    @MainActor
    func testAMatchingCodexInterruptionEndsTheReportedTurn() {
        let tracker = SessionActivityTracker()
        tracker.markRunning()
        tracker.isVisible = true
        tracker.noteTurnStarted(turnID: "turn-1")

        XCTAssertTrue(tracker.noteTurnInterrupted(turnID: "turn-1"))
        XCTAssertEqual(tracker.activity, .idle)
        XCTAssertFalse(tracker.activity.hasTurnInFlight)
    }

    /// The tail scan is asynchronous. If another prompt starts before it lands, an old abort may
    /// not close the new turn.
    @MainActor
    func testAStaleCodexInterruptionCannotEndANewerTurn() {
        let tracker = SessionActivityTracker()
        tracker.markRunning()
        tracker.isVisible = true
        tracker.noteTurnStarted(turnID: "turn-1")
        tracker.noteTurnStarted(turnID: "turn-2")

        XCTAssertFalse(tracker.noteTurnInterrupted(turnID: "turn-1"))
        XCTAssertEqual(tracker.activity, .working)
        XCTAssertTrue(tracker.activity.hasTurnInFlight)
    }

    /// A provider version that stops naming turns cannot safely use a delayed transcript fact:
    /// without the identity there is no proof the abort belongs to the work now in flight.
    @MainActor
    func testACodexInterruptionCannotEndAnUnidentifiedTurn() {
        let tracker = SessionActivityTracker()
        tracker.markRunning()
        tracker.isVisible = true
        tracker.noteTurnStarted()

        XCTAssertFalse(tracker.noteTurnInterrupted(turnID: "turn-1"))
        XCTAssertEqual(tracker.activity, .working)
        XCTAssertTrue(tracker.activity.hasTurnInFlight)
    }

    @MainActor
    func testAnOffscreenCodexInterruptionBecomesUnread() {
        let tracker = SessionActivityTracker()
        tracker.markRunning()
        tracker.isVisible = false
        tracker.noteTurnStarted(turnID: "turn-1")

        XCTAssertTrue(tracker.noteTurnInterrupted(turnID: "turn-1"))
        XCTAssertEqual(tracker.activity, .needsAttention)
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

    // MARK: - Blocking Asks

    /// The bug this exists for. A question tool is called *inside* a turn, so `Stop` never fires
    /// and the session is genuinely still mid-turn — the sidebar spun a loader at a session that
    /// had stopped dead on a question, for as long as the user was looking at it.
    @MainActor
    func testAnOpenAskShowsAsBlockedRatherThanWorking() {
        let tracker = SessionActivityTracker()
        tracker.markRunning()
        tracker.isVisible = true

        tracker.noteTurnStarted()
        XCTAssertEqual(tracker.activity, .working)

        tracker.noteBlockingAskOpened(id: "toolu_01")
        XCTAssertEqual(tracker.activity, .awaitingUser)
    }

    /// Being looked at answers the runtime's own vague notice, because answering happens in the
    /// terminal and raises no hook. It answers nothing here: the tool call is still open, and
    /// the hook that closes it is registered.
    @MainActor
    func testLookingAtASessionDoesNotAnswerAnOpenAsk() {
        let tracker = SessionActivityTracker()
        tracker.markRunning()
        tracker.isVisible = false

        tracker.noteTurnStarted()
        tracker.noteBlockingAskOpened(id: "toolu_01")
        tracker.isVisible = true

        XCTAssertEqual(tracker.activity, .awaitingUser)
    }

    /// Reading the question repaints the box it is drawn in, and arrowing through its options
    /// repaints it again — far over the byte threshold. That output is the question being asked,
    /// not the question being answered.
    @MainActor
    func testRepaintingTheQuestionIsNotAnAnswer() {
        let tracker = SessionActivityTracker()
        tracker.markRunning()
        tracker.isVisible = true

        tracker.noteTurnStarted()
        tracker.noteBlockingAskOpened(id: "toolu_01")
        tracker.recordOutput(byteCount: ActivityDefaults.workingByteThreshold * 4)

        XCTAssertEqual(tracker.activity, .awaitingUser)
    }

    /// Answering returns the session to the turn it was always in — the agent goes on working
    /// with nobody having typed a prompt.
    @MainActor
    func testAnsweringTheAskReturnsToTheTurn() {
        let tracker = SessionActivityTracker()
        tracker.markRunning()
        tracker.isVisible = true

        tracker.noteTurnStarted()
        tracker.noteBlockingAskOpened(id: "toolu_01")
        tracker.noteBlockingAskClosed(id: "toolu_01")

        XCTAssertEqual(tracker.activity, .working)
    }

    /// Claude notifies about the question six seconds after the keyboard goes quiet in front of
    /// it, so the ask and the notice describe the same wait. Answering has to clear both, or the
    /// session goes from blocked straight to blocked with nothing blocking it.
    @MainActor
    func testAnsweringAlsoClearsTheNoticeRaisedAboutTheSameQuestion() {
        let tracker = SessionActivityTracker()
        tracker.markRunning()
        tracker.isVisible = true

        tracker.noteTurnStarted()
        tracker.noteBlockingAskOpened(id: "toolu_01")
        tracker.noteAwaitingUser()
        tracker.noteBlockingAskClosed(id: "toolu_01")

        XCTAssertEqual(tracker.activity, .working)
    }

    /// A close belongs to its own open. Two asks in one turn — a question, then a plan to
    /// approve — must not have the first's answer clear the second.
    @MainActor
    func testAnAskIsClosedOnlyByTheCallThatOpenedIt() {
        let tracker = SessionActivityTracker()
        tracker.markRunning()
        tracker.isVisible = true

        tracker.noteTurnStarted()
        tracker.noteBlockingAskOpened(id: "toolu_01")
        tracker.noteBlockingAskOpened(id: "toolu_02")
        tracker.noteBlockingAskClosed(id: "toolu_01")

        XCTAssertEqual(tracker.activity, .awaitingUser, "the second ask is still open")

        tracker.noteBlockingAskClosed(id: "toolu_02")
        XCTAssertEqual(tracker.activity, .working)
    }

    /// An unidentified ask still has to pair with its close, or the mark would never come down.
    @MainActor
    func testAnUnidentifiedAskStillPairsWithItsClose() {
        let tracker = SessionActivityTracker()
        tracker.markRunning()
        tracker.isVisible = true

        tracker.noteTurnStarted()
        tracker.noteBlockingAskOpened(id: nil)
        XCTAssertEqual(tracker.activity, .awaitingUser)

        tracker.noteBlockingAskClosed(id: nil)
        XCTAssertEqual(tracker.activity, .working)
    }

    /// A close whose open was never seen, or seen twice, must converge rather than drift — the
    /// hooks are a network of curl calls and neither delivery nor ordering is promised.
    @MainActor
    func testDuplicateAndOrphanedReportsConverge() {
        let tracker = SessionActivityTracker()
        tracker.markRunning()
        tracker.isVisible = true
        tracker.noteTurnStarted()

        tracker.noteBlockingAskOpened(id: "toolu_01")
        tracker.noteBlockingAskOpened(id: "toolu_01")
        tracker.noteBlockingAskClosed(id: "toolu_01")
        XCTAssertEqual(tracker.activity, .working, "one call is one ask, however often reported")

        tracker.noteBlockingAskClosed(id: "toolu_09")
        XCTAssertEqual(tracker.activity, .working, "a close nobody opened changes nothing")
    }

    /// `Stop` is the stronger statement: the agent is back at its prompt, so an ask whose close
    /// was lost ends with the turn rather than outliving it.
    @MainActor
    func testATurnEndingClearsAnAskWhoseCloseWasLost() {
        let tracker = SessionActivityTracker()
        tracker.markRunning()
        tracker.isVisible = true

        tracker.noteTurnStarted()
        tracker.noteBlockingAskOpened(id: "toolu_01")
        tracker.noteTurnFinished()

        XCTAssertEqual(tracker.activity, .idle)
    }

    /// The next prompt is proof the user is past whatever the last turn asked.
    @MainActor
    func testANewTurnClearsAnAskWhoseCloseWasLost() {
        let tracker = SessionActivityTracker()
        tracker.markRunning()
        tracker.isVisible = true

        tracker.noteTurnStarted()
        tracker.noteBlockingAskOpened(id: "toolu_01")
        tracker.noteTurnStarted()

        XCTAssertEqual(tracker.activity, .working)
    }

    /// A session with no process is holding nothing, and the next process starts from nothing.
    @MainActor
    func testDormancyAndRelaunchForgetAnOpenAsk() {
        let tracker = SessionActivityTracker()
        tracker.markRunning()
        tracker.isVisible = true
        tracker.noteTurnStarted()
        tracker.noteBlockingAskOpened(id: "toolu_01")

        tracker.markDormant()
        XCTAssertEqual(tracker.activity, .dormant)

        tracker.markRunning()
        XCTAssertEqual(tracker.activity, .idle)
    }

    /// An ask is a report like any other, so a session that only ever reports one still stops
    /// counting bytes — the two signals disagree by design.
    @MainActor
    func testAnAskSwitchesTheSessionOffTheOutputHeuristic() {
        let tracker = SessionActivityTracker()
        tracker.markRunning()
        XCTAssertFalse(tracker.reportsOwnActivity)

        tracker.noteBlockingAskOpened(id: "toolu_01")

        XCTAssertTrue(tracker.reportsOwnActivity)
    }

    // MARK: - Unattended Launch

    /// A startup relaunch boots with nobody looking, and a resume's TUI repaint is a burst
    /// over the byte threshold. Read as work, it goes quiet and lands every restored session
    /// on `needsAttention` — one unread mark and one notification per session, for work
    /// nobody did.
    @MainActor
    func testBootOutputOfAnUnattendedLaunchOpensNoTurn() {
        let tracker = SessionActivityTracker()
        tracker.noteUnattendedLaunch()
        tracker.markRunning()

        tracker.recordOutput(byteCount: ActivityDefaults.workingByteThreshold * 4)

        XCTAssertEqual(tracker.activity, .idle)
    }

    @MainActor
    func testBeingLookedAtDoesNotEndTheLaunchGrace() {
        let tracker = SessionActivityTracker()
        tracker.noteUnattendedLaunch()
        tracker.markRunning()

        tracker.isVisible = true
        tracker.isVisible = false
        tracker.recordOutput(byteCount: ActivityDefaults.workingByteThreshold * 4)

        XCTAssertEqual(
            tracker.activity,
            .idle,
            "presenting a restored TUI does not prove that anybody started a turn"
        )
    }

    @MainActor
    func testUserInputEndsTheLaunchGrace() {
        let tracker = SessionActivityTracker()
        tracker.noteUnattendedLaunch()
        tracker.markRunning()

        tracker.noteUserInput(submitsLine: true)
        tracker.recordOutput(byteCount: ActivityDefaults.workingByteThreshold * 4)

        XCTAssertEqual(tracker.activity, .working, "input makes later output actionable again")
    }

    /// A reported turn means someone is driving the session — the remote mirror can type into
    /// an unattended terminal — so from that turn on the session flags like any other.
    @MainActor
    func testAReportedTurnEndsTheLaunchGrace() {
        let tracker = SessionActivityTracker()
        tracker.noteUnattendedLaunch()
        tracker.markRunning()

        tracker.noteTurnStarted()
        XCTAssertEqual(tracker.activity, .working)

        tracker.noteTurnFinished()
        XCTAssertEqual(tracker.activity, .needsAttention, "a real turn finishing off screen flags")
    }

    /// Claude notifies once its prompt has sat idle a while, and a session relaunched in the
    /// background is precisely a prompt sitting idle. A real ask arrives inside a turn, whose
    /// start already ended the grace.
    @MainActor
    func testTheIdlePromptNoticeIsIgnoredWhileUnattended() {
        let tracker = SessionActivityTracker()
        tracker.noteUnattendedLaunch()
        tracker.markRunning()

        tracker.noteAwaitingUser()

        XCTAssertEqual(tracker.activity, .idle)
        XCTAssertTrue(tracker.reportsOwnActivity, "the report still proves the hooks reached it")
    }

    /// A reattach arms the grace for the **replay** and ends it at the replay's own boundary.
    ///
    /// Output inference is the only thing that can say a reattached session is busy: a turn that
    /// began before the relaunch raised its `turnStarted` hook into a socket nobody was listening
    /// on, so nothing is coming to say the session is working and — before
    /// `endUnattendedLaunchGrace` existed — nothing was coming to end the grace either. A Codex
    /// session painting "Working" sat at idle in the sidebar until its next turn ended.
    @MainActor
    func testEndingTheLaunchGraceLetsAReattachedSessionInferWorkFromItsOutput() {
        let tracker = SessionActivityTracker()
        tracker.markDormant()
        tracker.markRunning()
        tracker.noteUnattendedLaunch()

        XCTAssertNotEqual(
            tracker.activity,
            .dormant,
            "a successful attach is a running session, whatever the row said a moment ago"
        )

        tracker.recordOutput(byteCount: ActivityDefaults.workingByteThreshold * 4)
        XCTAssertEqual(
            tracker.activity,
            .idle,
            "the replay is a repaint of a screen that was already there"
        )

        tracker.endUnattendedLaunchGrace()
        tracker.recordOutput(byteCount: ActivityDefaults.workingByteThreshold * 4)

        XCTAssertEqual(
            tracker.activity,
            .working,
            "everything after the replay is the child writing now"
        )
    }

    @MainActor
    func testABellDuringAnUnattendedBootRaisesNoFlag() {
        let tracker = SessionActivityTracker()
        tracker.noteUnattendedLaunch()
        tracker.markRunning()

        tracker.recordBell()

        XCTAssertEqual(tracker.activity, .idle)
    }

    // MARK: - Background Work Ledger

    /// The rule in isolation, without a tracker around it. Both CLIs wake a session when a
    /// background task ends, so "will this speak again" is true of everything in the list and
    /// separates nothing. For work that may stand indefinitely, when it *appeared* separates it.
    func testOnlyStandingWorkTheTurnItselfStartedPausesIt() {
        var ledger = BackgroundWorkLedger()

        XCTAssertTrue(ledger.turnEnded(leaving: [standingWork("a")]), "started in this turn")
        XCTAssertFalse(ledger.turnEnded(leaving: [standingWork("a")]), "carried over, so parked")
        XCTAssertTrue(
            ledger.turnEnded(leaving: [standingWork("a"), standingWork("b")]),
            "b is new beside the parked a"
        )
        XCTAssertFalse(ledger.turnEnded(leaving: [standingWork("a"), standingWork("b")]))
        XCTAssertFalse(ledger.turnEnded(leaving: []), "nothing left to wait for")
    }

    /// The bug age alone could not see. A background subagent is in flight at every boundary
    /// until it finishes, so by age it is new exactly once and carried over forever after — the
    /// session showed `working` for one turn and `idle` for the rest while its child worked on.
    /// Measured on 2.1.224 across four consecutive turns that each ended with the same one
    /// pending agent.
    func testDelegatedWorkPausesTheTurnHoweverOldItIs() {
        var ledger = BackgroundWorkLedger()

        XCTAssertTrue(ledger.turnEnded(leaving: [delegatedWork("child")]), "spawned this turn")
        XCTAssertTrue(
            ledger.turnEnded(leaving: [delegatedWork("child")]),
            "still delegated, still unanswered, however many turns have passed"
        )
        XCTAssertTrue(ledger.turnEnded(leaving: [delegatedWork("child")]))
        XCTAssertFalse(ledger.turnEnded(leaving: []), "and it ends when the child reports back")
    }

    /// The two rules coexisting, which is the whole point of asking the kind first: a parked dev
    /// server must not hold the session open, and a subagent running beside it must.
    func testADelegatedChildPausesEvenBesideAParkedServer() {
        var ledger = BackgroundWorkLedger()

        XCTAssertTrue(ledger.turnEnded(leaving: [standingWork("dev-server")]))
        XCTAssertFalse(
            ledger.turnEnded(leaving: [standingWork("dev-server")]),
            "the server alone is parked"
        )
        XCTAssertTrue(
            ledger.turnEnded(leaving: [standingWork("dev-server"), delegatedWork("child")]),
            "the child is what this turn handed off"
        )
        XCTAssertTrue(
            ledger.turnEnded(leaving: [standingWork("dev-server"), delegatedWork("child")]),
            "and it keeps pausing while the server beside it stays parked"
        )
        XCTAssertFalse(
            ledger.turnEnded(leaving: [standingWork("dev-server")]),
            "the child reported back; the server is parked as it always was"
        )
    }

    /// Ids are replaced at each boundary rather than accumulated: a task that finished and one
    /// that never ran are the same thing to the next turn, and remembering it forever would
    /// make a task that comes back look familiar.
    func testWorkThatFinishedIsNotRememberedAsCarriedOver() {
        var ledger = BackgroundWorkLedger()

        XCTAssertTrue(ledger.turnEnded(leaving: [standingWork("a")]))
        XCTAssertFalse(ledger.turnEnded(leaving: []))
        XCTAssertTrue(
            ledger.turnEnded(leaving: [standingWork("a")]),
            "a second run of the same work is new"
        )
    }

    func testForgettingMakesTheNextTaskNewAgain() {
        var ledger = BackgroundWorkLedger()

        XCTAssertTrue(ledger.turnEnded(leaving: [standingWork("a")]))
        ledger.forget()
        XCTAssertTrue(
            ledger.turnEnded(leaving: [standingWork("a")]),
            "a relaunched process inherits nothing"
        )
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
        onScreen.noteTurnFinished(backgroundWork: [standingWork("bwf9miuvg")])

        let offScreen = SessionActivityTracker()
        offScreen.markRunning()
        offScreen.isVisible = false
        offScreen.noteTurnStarted()
        offScreen.noteTurnFinished(backgroundWork: [standingWork("bwf9miuvg")])

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
        tracker.noteTurnFinished(backgroundWork: [standingWork("bwf9miuvg")])
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
        tracker.noteTurnFinished(backgroundWork: [standingWork("dev-server")])
        XCTAssertEqual(tracker.activity, .working, "the turn that started it is waiting on it")

        tracker.noteTurnStarted()
        tracker.noteTurnFinished(backgroundWork: [standingWork("dev-server")])
        XCTAssertEqual(
            tracker.activity,
            .needsAttention,
            "a later turn handed back to the user with the server merely still running"
        )

        // And a genuinely new task still pauses, beside the one that was already there.
        tracker.noteTurnStarted()
        tracker.noteTurnFinished(
            backgroundWork: [standingWork("dev-server"), standingWork("test-run")]
        )
        XCTAssertEqual(tracker.activity, .working)
    }

    /// The reported symptom, end to end: "no progress circle, but a subagent is working".
    ///
    /// A background subagent stays in flight across every turn the user spends asking after it,
    /// and each of those turns used to settle the session to `idle` — a blank row beside a child
    /// that was still writing. Off screen it was louder: the same boundary handed the session an
    /// unread mark and, through `AttentionAlertPolicy`, a "finished its turn" notification for a
    /// turn whose child had not reported.
    @MainActor
    func testAskingAfterABackgroundChildDoesNotBlankTheSession() {
        let tracker = SessionActivityTracker()
        tracker.markRunning()
        tracker.isVisible = true

        // The turn that spawned it.
        tracker.noteTurnStarted()
        tracker.noteTurnFinished(backgroundWork: [delegatedWork("agent-a904492d00a55f1da")])
        XCTAssertEqual(tracker.activity, .working)

        // Three turns of "is it still going?", each ending with the same child in flight.
        for turn in 1...3 {
            tracker.noteTurnStarted()
            tracker.noteTurnFinished(backgroundWork: [delegatedWork("agent-a904492d00a55f1da")])
            XCTAssertEqual(
                tracker.activity,
                .working,
                "the child was still working after turn \(turn)"
            )
        }

        // Off screen the same boundary must not post an unread mark either: nothing has been
        // handed back to read.
        tracker.isVisible = false
        tracker.noteTurnStarted()
        tracker.noteTurnFinished(backgroundWork: [delegatedWork("agent-a904492d00a55f1da")])
        XCTAssertEqual(tracker.activity, .working)

        // The child reported back, and the turn that outlives it is the one that finishes.
        tracker.noteTurnStarted()
        tracker.noteTurnFinished()
        XCTAssertEqual(tracker.activity, .needsAttention)
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
        tracker.noteTurnFinished(backgroundWork: [standingWork("bwf9miuvg")])
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
        tracker.noteTurnFinished(backgroundWork: [standingWork("bwf9miuvg")])
        XCTAssertEqual(tracker.activity, .working)

        tracker.markDormant()
        XCTAssertEqual(tracker.activity, .dormant)

        tracker.markRunning()
        XCTAssertEqual(tracker.activity, .idle)
    }

    // MARK: - Idle Prompts Against Work Left Running

    /// The reported symptom, measured on CLI 2.1.238: "it showed no activity for 1–2 minutes,
    /// even if it had subagents working".
    ///
    /// The ledger had the session right — its `Stop` named the child, so the row read `working`
    /// — and then the CLI's own idle-prompt notice arrived 60s later and overwrote it with
    /// `needsAttention`, for a session nobody was being asked anything by. It came back only
    /// when the user opened the session, which is what made it look like a rendering fault
    /// rather than a state one, and dropped again on the next quiet stretch.
    ///
    /// Off screen it also spent an attention episode: an unread mark and a "finished its turn"
    /// notification for a turn whose child had not reported. `attentionCount` is here for that
    /// half, which no assertion about `activity` alone would catch.
    @MainActor
    func testAnIdlePromptDoesNotUnmarkASessionWaitingOnItsOwnChild() {
        let tracker = SessionActivityTracker()
        var attentionCount = 0
        tracker.onAttention = { attentionCount += 1 }
        tracker.markRunning()
        tracker.isVisible = false

        tracker.noteTurnStarted()
        tracker.noteTurnFinished(backgroundWork: [delegatedWork("agent-abac596acbf5c268f")])
        XCTAssertEqual(tracker.activity, .working)

        tracker.noteAwaitingUser(.idlePrompt)
        XCTAssertEqual(tracker.activity, .working, "the prompt is idle because the child is not")
        XCTAssertEqual(attentionCount, 0, "nothing has been handed back to read")
        XCTAssertEqual(
            tracker.lastCause,
            .awaitingUserReported,
            "a refused notice still names itself, or nothing can answer why no mark appeared"
        )

        // Looking at it must not be what fixes it — but it must not break it either.
        tracker.isVisible = true
        XCTAssertEqual(tracker.activity, .working)

        // The child reported back, and the turn that outlives it is the one that finishes.
        tracker.isVisible = false
        tracker.noteTurnStarted()
        tracker.noteTurnFinished()
        XCTAssertEqual(tracker.activity, .needsAttention)
        XCTAssertEqual(attentionCount, 1)
    }

    /// The fail-closed half, and the reason suppression is opt-in by exact name: a permission
    /// prompt is a real question, and a terminal session has no other signal for one —
    /// `blockingAskOpened` is scoped to the tools that ask outright, which a `Bash` approval is
    /// not. Swallowing this notice would leave the agent waiting on an answer nobody knows it
    /// wants, for as long as the child runs.
    @MainActor
    func testAPermissionPromptStillFlagsASessionPausedOnItsOwnChild() {
        let tracker = SessionActivityTracker()
        tracker.markRunning()
        tracker.isVisible = false

        tracker.noteTurnStarted()
        tracker.noteTurnFinished(backgroundWork: [delegatedWork("agent-abac596acbf5c268f")])
        tracker.noteAwaitingUser(HookNotificationKind(reportedType: "permission_prompt"))

        XCTAssertEqual(tracker.activity, .needsAttention)
    }

    /// The same fail-closed reading for a runtime that names no type at all — an older CLI, or
    /// one whose payload changes shape. `.unspecified` is the default for exactly this reason,
    /// so a build that stops recognising the field behaves as every build did before it.
    @MainActor
    func testAnUntypedNoticeStillFlagsASessionPausedOnItsOwnChild() {
        let tracker = SessionActivityTracker()
        tracker.markRunning()
        tracker.isVisible = false

        tracker.noteTurnStarted()
        tracker.noteTurnFinished(backgroundWork: [delegatedWork("agent-abac596acbf5c268f")])
        tracker.noteAwaitingUser()

        XCTAssertEqual(tracker.activity, .needsAttention)
    }

    /// The narrowing to delegated work, which is the other half of failing closed. A subagent
    /// ends and reports back, so a suppressed notice costs nothing — the row corrects itself. A
    /// backgrounded shell carries no such promise: `npm test` and `npm run dev` are the same
    /// entry in the payload, so a session parked on one is exactly where a late "nothing is
    /// happening here" is worth keeping.
    @MainActor
    func testAnIdlePromptStillFlagsASessionParkedOnAShellThatMayNeverEnd() {
        let tracker = SessionActivityTracker()
        tracker.markRunning()
        tracker.isVisible = false

        tracker.noteTurnStarted()
        tracker.noteTurnFinished(backgroundWork: [standingWork("bwf9miuvg")])
        XCTAssertEqual(tracker.activity, .working)

        tracker.noteAwaitingUser(.idlePrompt)
        XCTAssertEqual(tracker.activity, .needsAttention)
    }

    /// An idle prompt on a session that left nothing running is untouched: the prompt really is
    /// idle for want of the user, and that is the ordinary case this notice exists for.
    @MainActor
    func testAnIdlePromptStillFlagsASessionThatLeftNothingRunning() {
        let tracker = SessionActivityTracker()
        tracker.markRunning()
        tracker.isVisible = false

        tracker.noteTurnStarted()
        tracker.noteTurnFinished()
        tracker.noteAwaitingUser(.idlePrompt)

        XCTAssertEqual(tracker.activity, .needsAttention)
    }

    /// `AgentRuntime` asks the same question before recording the notice as a reason to wake a
    /// snoozed session, so the rule is asserted directly rather than only through its effect on
    /// the row: a notice must not be too weak for the sidebar and loud enough to end a snooze.
    @MainActor
    func testOneRuleAnswersBothTheRowAndTheSnooze() {
        let tracker = SessionActivityTracker()
        tracker.markRunning()
        tracker.isVisible = false

        XCTAssertTrue(tracker.honoursAwaitingUserNotice(.idlePrompt), "nothing is running yet")

        tracker.noteTurnStarted()
        tracker.noteTurnFinished(backgroundWork: [delegatedWork("agent-abac596acbf5c268f")])
        XCTAssertFalse(tracker.honoursAwaitingUserNotice(.idlePrompt))
        XCTAssertTrue(tracker.honoursAwaitingUserNotice(.unspecified))

        // A pause on standing work is not the same claim: it may never end, so the notice keeps
        // its say. Same tracker, so this also pins that the pause is re-read per boundary.
        tracker.noteTurnStarted()
        tracker.noteTurnFinished(backgroundWork: [standingWork("bwf9miuvg")])
        XCTAssertTrue(tracker.honoursAwaitingUserNotice(.idlePrompt))

        // The unattended grace refuses every notice, and refuses it for both readers — a
        // restored session's idle prompt is the "request that predates Snooze" that
        // `SessionSnoozeCenter.record` exists to keep out.
        let restored = SessionActivityTracker()
        restored.noteUnattendedLaunch()
        restored.markRunning()
        XCTAssertFalse(restored.honoursAwaitingUserNotice(.unspecified))
        XCTAssertFalse(restored.honoursAwaitingUserNotice(.idlePrompt))
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
        let admitted = tracker.recordOutput(byteCount: ActivityDefaults.workingByteThreshold * 10)

        XCTAssertEqual(tracker.activity, .idle)
        XCTAssertNil(admitted, "a finished turn's repaint must not pulse the analyzer")
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

        let admitted = tracker.recordOutput(byteCount: ActivityDefaults.workingByteThreshold + 1)

        XCTAssertEqual(tracker.activity, .working)
        XCTAssertFalse(tracker.reportsOwnActivity)
        XCTAssertEqual(admitted, ActivityDefaults.workingByteThreshold + 1)
    }

    // MARK: - Asking Inside a Turn

    /// Merely presenting a permission prompt is not an answer. The old visibility edge made a
    /// blocked session look working as soon as somebody opened it, before they chose anything.
    @MainActor
    func testLookingAtAFlaggedSessionKeepsItWaiting() {
        let tracker = SessionActivityTracker()
        tracker.markRunning()
        tracker.isVisible = false

        tracker.noteTurnStarted()
        tracker.noteAwaitingUser()
        XCTAssertEqual(tracker.activity, .awaitingUser)

        tracker.isVisible = true

        XCTAssertEqual(
            tracker.activity,
            .awaitingUser,
            "presentation does not say whether the question was answered"
        )
    }

    /// Claude has no hook for the complementary permission-answer edge. A submitted terminal
    /// answer is that boundary, including through a remote controller and while the Mac surface
    /// is off screen. Without it a long, silent Bash command runs while the phone says the turn
    /// is still waiting on input.
    @MainActor
    func testSubmittedInputReturnsAFlaggedSessionToItsOpenTurn() {
        let tracker = SessionActivityTracker()
        tracker.markRunning()
        tracker.isVisible = false

        tracker.noteTurnStarted()
        tracker.noteAwaitingUser()
        tracker.noteUserInput(submitsLine: true)

        XCTAssertEqual(tracker.activity, .working)
        XCTAssertEqual(tracker.lastCause, .userInput)
    }

    @MainActor
    func testEditingInputDoesNotClaimAQuestionWasAnswered() {
        let tracker = SessionActivityTracker()
        tracker.markRunning()
        tracker.isVisible = true

        tracker.noteTurnStarted()
        tracker.noteAwaitingUser()
        tracker.noteUserInput(submitsLine: false)

        XCTAssertEqual(tracker.activity, .awaitingUser)
    }

    @MainActor
    func testSubmittedInputDoesNotCloseAnExplicitAskTool() {
        let tracker = SessionActivityTracker()
        tracker.markRunning()
        tracker.isVisible = true

        tracker.noteTurnStarted()
        tracker.noteBlockingAskOpened(id: "toolu_01")
        tracker.noteUserInput(submitsLine: true)

        XCTAssertEqual(tracker.activity, .awaitingUser, "the tool's close hook owns this edge")
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
        XCTAssertEqual(tracker.activity, .awaitingUser)

        tracker.noteUserInput(submitsLine: true)
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

// MARK: - Background Work Fixtures

/// A shell, a monitor, or anything else whose lifetime the payload does not state — the work
/// `BackgroundWorkLedger` has to judge by when it appeared.
private func standingWork(_ id: String) -> BackgroundTask {
    BackgroundTask(id: id, kind: .standing)
}

/// A subagent or a workflow: bounded, and it re-enters the conversation on its own.
private func delegatedWork(_ id: String) -> BackgroundTask {
    BackgroundTask(id: id, kind: .delegated)
}
