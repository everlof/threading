import XCTest
@testable import Skalman

final class StreamSessionLifecycleTests: XCTestCase {

    func testClaudeSpawnFailureArrivesAsynchronouslyOnMain() {
        let exited = expectation(description: "spawn failure callback")
        var startReturned = false

        let session = ClaudeStreamSession(sessionID: SessionID()) {
            AgentLaunchPlan(
                executable: "/path/that/does/not/exist/claude",
                arguments: [],
                resumeState: .unavailable
            )
        }
        session.onExit = { status in
            XCTAssertTrue(Thread.isMainThread)
            XCTAssertTrue(startReturned)
            XCTAssertEqual(status, -1)
            exited.fulfill()
        }

        session.start()
        startReturned = true

        wait(for: [exited], timeout: 1)
    }

    func testClaudeSurfacesCappedStderrBeforeFailedExit() {
        let diagnosticReceived = expectation(description: "stderr diagnostic")
        let exited = expectation(description: "failed child exit")
        var receivedDiagnostic = false

        let session = ClaudeStreamSession(sessionID: SessionID()) {
            self.shellPlan(
                "/bin/cat >/dev/null; "
                    + "printf 'claude exploded' >&2; /bin/sleep 0.05; exit 7"
            )
        }
        session.onEvent = { event in
            guard case .turnFinished(let text, let isError, _) = event else { return }
            XCTAssertTrue(Thread.isMainThread)
            XCTAssertEqual(text, "claude exploded")
            XCTAssertTrue(isError)
            receivedDiagnostic = true
            diagnosticReceived.fulfill()
        }
        session.onExit = { status in
            XCTAssertTrue(Thread.isMainThread)
            XCTAssertTrue(receivedDiagnostic)
            XCTAssertEqual(status, 7)
            exited.fulfill()
        }

        session.start()
        session.finish()

        wait(for: [diagnosticReceived, exited], timeout: 2)
    }

    func testCodexTerminalEventIsDeliveredOnceOnMain() {
        let finished = expectation(description: "terminal event")
        let rootPlan = expectation(description: "root plan")
        let childPlan = expectation(description: "child plan")
        let duplicate = expectation(description: "duplicate terminal event")
        duplicate.isInverted = true
        var finishCount = 0
        var rootPlanCount = 0

        let session = CodexStreamSession(sessionID: SessionID()) {
            self.shellPlan(
                "read -r initialize; "
                    + "printf '%s\\n' '{\"id\":1,\"result\":{}}'; "
                    + "read -r initialized; "
                    + "read -r open_thread; "
                    + "printf '%s\\n' "
                    + "'{\"id\":2,\"result\":{\"thread\":{\"id\":\"thread-1\","
                    + "\"model\":\"gpt-test\"}}}'; "
                    + "read -r start_turn; "
                    + "printf '%s\\n' '{\"id\":3,\"result\":{\"turn\":{\"id\":\"turn-1\"}}}'; "
                    + "printf '%s\\n' 'not-json'; "
                    + "printf '%s\\n' "
                    + "'{\"method\":\"thread/tokenUsage/updated\",\"params\":{"
                    + "\"threadId\":\"thread-1\",\"turnId\":\"turn-1\","
                    + "\"tokenUsage\":{\"last\":{\"outputTokens\":17},\"total\":{}}}}'; "
                    + "printf '%s\\n' "
                    + "'{\"method\":\"turn/plan/updated\",\"params\":{"
                    + "\"threadId\":\"thread-1\",\"turnId\":\"turn-1\",\"plan\":["
                    + "{\"step\":\"Inspect\",\"status\":\"completed\"},"
                    + "{\"step\":\"Verify\",\"status\":\"inProgress\"}]}}'; "
                    + "printf '%s\\n' "
                    + "'{\"method\":\"turn/plan/updated\",\"params\":{"
                    + "\"threadId\":\"child-1\",\"turnId\":\"child-turn\",\"plan\":["
                    + "{\"step\":\"Audit child\",\"status\":\"inProgress\"}]}}'; "
                    + "printf '%s\\n' "
                    + "'{\"method\":\"turn/completed\",\"params\":{\"threadId\":\"thread-1\","
                    + "\"turn\":{\"id\":\"turn-1\",\"items\":[],\"status\":\"completed\","
                    + "\"durationMs\":50}}}'; "
                    + "cat >/dev/null"
            )
        }
        session.onEvent = { event in
            switch event {
            case .runPlanUpdated(let steps):
                XCTAssertTrue(Thread.isMainThread)
                XCTAssertEqual(steps.map(\.title), ["Inspect", "Verify"])
                rootPlanCount += 1
                rootPlan.fulfill()
            case .turnFinished:
                XCTAssertTrue(Thread.isMainThread)
                finishCount += 1
                if finishCount == 1 {
                    finished.fulfill()
                } else {
                    duplicate.fulfill()
                }
            default:
                break
            }
        }
        session.onSubagentEvent = { event in
            guard case .conversation(let threadID, .runPlanUpdated(let steps)) = event else {
                return
            }
            XCTAssertTrue(Thread.isMainThread)
            XCTAssertEqual(threadID, "child-1")
            XCTAssertEqual(steps.map(\.title), ["Audit child"])
            childPlan.fulfill()
        }

        session.start()
        XCTAssertTrue(session.send("test prompt"))

        wait(for: [rootPlan, childPlan, finished, duplicate], timeout: 1)
        XCTAssertEqual(finishCount, 1)
        XCTAssertEqual(rootPlanCount, 1, "A child plan must not leak into the parent timeline")
        XCTAssertEqual(session.malformedLineCount, 1)
        XCTAssertTrue(session.canSend)
        session.terminate()
    }

    func testSetModelSendsControlRequestAndResolvesOnSuccessResponse() {
        let resolved = expectation(description: "control response resolved")

        let session = ClaudeStreamSession(sessionID: SessionID()) {
            // Consume the one control request, answer it (the first id is deterministic), then idle
            // so the child stays alive until the test tears it down.
            self.shellPlan(
                "read -r line; "
                    + "printf '%s\\n' "
                    + "'{\"type\":\"control_response\",\"response\":{\"subtype\":\"success\",\"request_id\":\"skalman-ctrl-1\"}}'; "
                    + "cat >/dev/null"
            )
        }

        session.start()
        session.setModel("claude-sonnet-5") { result in
            XCTAssertTrue(Thread.isMainThread)
            if case .failure(let error) = result {
                XCTFail("Expected success, got \(error)")
            }
            resolved.fulfill()
        }

        wait(for: [resolved], timeout: 2)
        session.terminate()
    }

    func testSetModelSurfacesRejectionFromErrorResponse() {
        let resolved = expectation(description: "control rejection resolved")

        let session = ClaudeStreamSession(sessionID: SessionID()) {
            self.shellPlan(
                "read -r line; "
                    + "printf '%s\\n' "
                    + "'{\"type\":\"control_response\",\"response\":{\"subtype\":\"error\","
                    + "\"request_id\":\"skalman-ctrl-1\",\"error\":\"unrecognized model\"}}'; "
                    + "cat >/dev/null"
            )
        }

        session.start()
        session.setModel("bogus-model") { result in
            guard case .failure(let error) = result else {
                return XCTFail("Expected a rejection")
            }
            XCTAssertEqual(error.localizedDescription, "unrecognized model")
            resolved.fulfill()
        }

        wait(for: [resolved], timeout: 2)
        session.terminate()
    }

    func testPendingControlRequestFailsWhenProcessExits() {
        let resolved = expectation(description: "pending control request failed on exit")

        let session = ClaudeStreamSession(sessionID: SessionID()) {
            // Take the request but never answer, then exit — the pending completion must fail
            // rather than sit on its timeout.
            self.shellPlan("read -r line; exit 0")
        }

        session.start()
        session.setModel("claude-sonnet-5") { result in
            guard case .failure(let error) = result else {
                return XCTFail("Expected failure when the process exits")
            }
            guard case ClaudeControlError.notRunning = error else {
                return XCTFail("Expected notRunning, got \(error)")
            }
            resolved.fulfill()
        }

        wait(for: [resolved], timeout: 2)
    }

    func testControlRequestBeforeStartFailsImmediately() {
        let session = ClaudeStreamSession(sessionID: SessionID()) {
            self.shellPlan("cat >/dev/null")
        }

        var received: Result<Void, Error>?
        session.setModel("claude-sonnet-5") { received = $0 }

        // No process, so the failure is synchronous.
        guard case .failure(let error)? = received, case ClaudeControlError.notRunning = error else {
            return XCTFail("Expected an immediate notRunning failure, got \(String(describing: received))")
        }
    }

    func testClaudeRoutesForwardedChildOutputAwayFromParentOnMain() {
        let parentReceived = expectation(description: "parent task call")
        let childReceived = expectation(description: "forwarded child output")
        var parentMessageCount = 0

        let session = ClaudeStreamSession(sessionID: SessionID()) {
            self.shellPlan(
                "printf '%s\\n' "
                    + "'{\"type\":\"assistant\",\"parent_tool_use_id\":null,"
                    + "\"session_id\":\"root\",\"message\":{\"content\":[{"
                    + "\"type\":\"tool_use\",\"id\":\"task-1\",\"name\":\"Task\","
                    + "\"input\":{\"description\":\"Audit parser\","
                    + "\"prompt\":\"Find the routing bug\",\"subagent_type\":\"Explore\"}}]}}'; "
                    + "printf '%s\\n' "
                    + "'{\"type\":\"assistant\",\"parent_tool_use_id\":\"task-1\","
                    + "\"session_id\":\"root\",\"subagent_type\":\"Explore\","
                    + "\"task_description\":\"Audit parser\",\"message\":{"
                    + "\"model\":\"claude-sonnet-4-5\",\"content\":[{"
                    + "\"type\":\"text\",\"text\":\"Found the child-only bug.\"}]}}'; "
                    + "cat >/dev/null"
            )
        }

        session.onEvent = { event in
            guard case .assistantMessage = event else { return }
            XCTAssertTrue(Thread.isMainThread)
            parentMessageCount += 1
            parentReceived.fulfill()
        }
        session.onSubagentEvent = { event in
            guard case .conversation(let threadID, let childEvent) = event,
                  case .assistantMessage(let blocks) = childEvent,
                  case .text(let text) = blocks.first
            else { return }
            XCTAssertTrue(Thread.isMainThread)
            XCTAssertEqual(threadID, "task-1")
            XCTAssertEqual(text, "Found the child-only bug.")
            childReceived.fulfill()
        }

        session.start()

        wait(for: [parentReceived, childReceived], timeout: 2)
        XCTAssertEqual(parentMessageCount, 1, "Child text must not enter the parent transcript")
        session.terminate()
    }

    private func shellPlan(_ script: String) -> AgentLaunchPlan {
        AgentLaunchPlan(
            executable: "/bin/sh",
            arguments: ["-c", script],
            resumeState: .unavailable
        )
    }
}

@MainActor
final class SubagentSessionStateTests: XCTestCase {

    func testDescriptorNeverUsesATranscriptPathAsItsDisplayName() {
        let descriptor = SubagentDescriptor(
            threadID: "af90bc36f7d81e85c",
            nickname: "  ",
            role: "",
            path: "/Users/example/.claude/projects/session/subagents/agent-af90bc36.jsonl"
        )

        XCTAssertEqual(descriptor.displayName, "Agent af90bc36")
    }

    func testOnlyObservedProviderAnalysisEnvelopeBecomesPresentationText() {
        XCTAssertEqual(
            SubagentDefaults.compactActivity(
                "<analysis>\nChronology: inspected the renderer.\n</analysis>"
            ),
            "Reasoning: Chronology: inspected the renderer."
        )
        XCTAssertEqual(
            SubagentDefaults.compactActivity(
                "<analysis> Chronology: the stop report was truncated before its closing tag…"
            ),
            "Reasoning: Chronology: the stop report was truncated before its closing tag…"
        )
        XCTAssertEqual(
            SubagentDefaults.compactActivity("<thinking>Keep this literal.</thinking>"),
            "<thinking>Keep this literal.</thinking>"
        )
        XCTAssertEqual(
            SubagentDefaults.compactActivity("<final>Keep this literal.</final>"),
            "<final>Keep this literal.</final>"
        )
        XCTAssertEqual(
            SubagentDefaults.compactActivity("<Analysis>Keep this literal.</Analysis>"),
            "<Analysis>Keep this literal.</Analysis>"
        )
        XCTAssertEqual(
            SubagentDefaults.compactActivity("<code>analysis is a valid element</code>"),
            "<code>analysis is a valid element</code>"
        )

        var timeline = SubagentTimeline(sessionID: SessionID())
        timeline.apply(.state(
            threadID: "child-1",
            status: .completed,
            message: "<analysis>Chronology: live lifecycle message"
        ))
        XCTAssertEqual(
            timeline.agents.first?.message,
            "Reasoning: Chronology: live lifecycle message"
        )
        XCTAssertEqual(
            timeline.agents.first?.activity,
            ["Reasoning: Chronology: live lifecycle message"]
        )
    }

    func testSnapshotRestoreNormalizesLegacyProviderEnvelopes() throws {
        let descriptor = SubagentDescriptor(threadID: "child-1")
        let snapshot = SubagentTimeline.Snapshot(agents: [
            SubagentTimeline.AgentSnapshot(
                descriptor: descriptor,
                status: .completed,
                message: "<analysis>Chronology: legacy message",
                progress: nil,
                activity: [
                    "<analysis>Chronology: legacy message",
                    "<analysis>Chronology: legacy message"
                ]
            )
        ])

        let restored = SubagentTimeline(sessionID: SessionID(), snapshot: snapshot)
        let agent = try XCTUnwrap(restored.agents.first)

        XCTAssertEqual(agent.message, "Reasoning: Chronology: legacy message")
        XCTAssertEqual(agent.activity, ["Reasoning: Chronology: legacy message"])
    }

    func testSnapshotRestoresNavigatorMetadataAndSettlesLiveChildren() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let sessionID = SessionID()
        let store = SubagentStateStore(directory: directory)
        let nativeState = SubagentSessionState(sessionID: sessionID, store: store)
        nativeState.apply(.discovered(SubagentDescriptor(
            threadID: "child-1",
            parentThreadID: "parent",
            nickname: "Researcher",
            role: "explorer",
            path: "/tmp/child.jsonl",
            prompt: "Find the parser"
        )))
        nativeState.apply(.state(
            threadID: "child-1",
            status: .working,
            message: nil
        ))
        nativeState.apply(.progress(
            threadID: "child-1",
            progress: SubagentProgress(totalTokens: 1_234, toolUses: 5)
        ))
        nativeState.select(threadID: "child-1")
        nativeState.flushPersistence()

        // A renderer switch reads the same object and therefore keeps the live status.
        let terminalState = nativeState
        XCTAssertEqual(terminalState.timeline.agents.first?.status, .working)
        XCTAssertEqual(terminalState.timeline.agents.first?.descriptor.nickname, "Researcher")
        XCTAssertEqual(terminalState.selectedThreadID, "child-1")

        // A full app restart restores the durable summary, but cannot claim the old process is
        // still alive.
        let restored = SubagentSessionState(sessionID: sessionID, store: store)
        let agent = try XCTUnwrap(restored.timeline.agents.first)
        XCTAssertEqual(agent.status, .stopped)
        XCTAssertEqual(agent.descriptor.path, "/tmp/child.jsonl")
        XCTAssertEqual(agent.progress?.totalTokens, 1_234)
        XCTAssertEqual(agent.progress?.toolUses, 5)
    }

    func testStoreRetainOnlyRemovesDeletedSessions() {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let kept = SessionID()
        let removed = SessionID()
        let store = SubagentStateStore(directory: directory)
        let snapshot = SubagentTimeline.Snapshot(agents: [])
        store.save(snapshot, sessionID: kept)
        store.save(snapshot, sessionID: removed)

        store.retainOnly(sessionIDs: [kept])

        XCTAssertNotNil(store.load(sessionID: kept))
        XCTAssertNil(store.load(sessionID: removed))
    }

    func testInvalidatedStateIgnoresLateProviderUpdates() {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let sessionID = SessionID()
        let store = SubagentStateStore(directory: directory)
        let state = SubagentSessionState(sessionID: sessionID, store: store)

        // `retainOnly` invalidates the state while transcript usage may still be loading on a
        // background queue. That late result must not recreate the deleted session's file.
        state.invalidate()
        state.apply(.progress(
            threadID: "late-child",
            progress: SubagentProgress(totalTokens: 42)
        ))
        state.flushPersistence()

        XCTAssertTrue(state.timeline.agents.isEmpty)
        XCTAssertNil(store.load(sessionID: sessionID))
    }

    func testClaudeAgentAndToolUseIDsReconcileToOneDurableChild() throws {
        var timeline = SubagentTimeline(sessionID: SessionID())
        timeline.apply(.discovered(SubagentDescriptor(
            threadID: "agent-789",
            role: "Explore"
        )))
        timeline.apply(.state(
            threadID: "agent-789",
            status: .stopped,
            message: nil
        ))

        // Native history learns the spawning tool-use id and carries the terminal hook id as
        // its provider alias.
        timeline.apply(.discovered(SubagentDescriptor(
            threadID: "tool-use-123",
            alternateThreadIDs: ["agent-789"],
            path: "/tmp/agent-789.jsonl",
            prompt: "Audit the parser"
        )))
        timeline.apply(.state(
            threadID: "tool-use-123",
            status: .completed,
            message: "Done"
        ))

        let child = try XCTUnwrap(timeline.agents.first)
        XCTAssertEqual(timeline.agents.count, 1)
        XCTAssertEqual(child.descriptor.path, "/tmp/agent-789.jsonl")
        XCTAssertEqual(child.status, .completed)
        XCTAssertEqual(child.message, "Done")

        var restored = SubagentTimeline(
            sessionID: SessionID(),
            snapshot: timeline.snapshot
        )
        restored.apply(.state(
            threadID: "tool-use-123",
            status: .failed,
            message: "Late update"
        ))
        XCTAssertEqual(restored.agents.count, 1)
        XCTAssertEqual(restored.agents.first?.status, .failed)
    }

    func testTranscriptLoaderRejectsLogicalPathsAndAcceptsRegularFiles() throws {
        let logical = SubagentDescriptor(
            threadID: "child",
            path: "/root/review_pr612_codex"
        )
        XCTAssertFalse(SubagentTranscriptLoader.isLoadable(logical))

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("jsonl")
        defer { try? FileManager.default.removeItem(at: url) }
        try Data().write(to: url)

        XCTAssertTrue(SubagentTranscriptLoader.isLoadable(SubagentDescriptor(
            threadID: "child",
            path: url.path
        )))
        XCTAssertEqual(
            SubagentTranscriptLoader.transcriptURL(for: SubagentDescriptor(
                threadID: "child",
                path: url.path
            )),
            url
        )
    }

    func testEmptyTranscriptReplayIsRetriableAndSignatureChangesReload() {
        var cache = SubagentTranscriptLoadCache()
        let empty = SubagentTranscriptSignature(byteCount: 0, modifiedAt: nil)
        let filled = SubagentTranscriptSignature(byteCount: 128, modifiedAt: Date())

        XCTAssertTrue(cache.begin(threadID: "child", signature: empty))
        guard case .retryAfter = cache.finish(
            threadID: "child",
            signature: empty,
            eventCount: 0
        ) else {
            return XCTFail("An empty replay should be retried, not cached")
        }
        XCTAssertTrue(cache.begin(threadID: "child", signature: empty))

        guard case .loaded = cache.finish(
            threadID: "child",
            signature: empty,
            eventCount: 1
        ) else {
            return XCTFail("A parsed replay should be cached")
        }
        XCTAssertFalse(cache.begin(threadID: "child", signature: empty))
        XCTAssertTrue(cache.begin(threadID: "child", signature: filled))
    }

    func testUnreadableSnapshotIsQuarantinedBeforeNewStateIsSaved() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let sessionID = SessionID()
        let stateDirectory = directory.appendingPathComponent(
            SubagentDefaults.snapshotDirectoryName,
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: stateDirectory,
            withIntermediateDirectories: true
        )
        let file = stateDirectory
            .appendingPathComponent(sessionID.uuidString)
            .appendingPathExtension(SubagentDefaults.snapshotExtension)
        try Data("not-json".utf8).write(to: file)

        let store = SubagentStateStore(directory: directory)
        XCTAssertNil(store.load(sessionID: sessionID))
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))

        let quarantined = try FileManager.default.contentsOfDirectory(
            at: stateDirectory,
            includingPropertiesForKeys: nil
        )
        XCTAssertTrue(quarantined.contains {
            $0.lastPathComponent.hasPrefix(file.lastPathComponent + ".unreadable-")
        })

        store.save(SubagentTimeline.Snapshot(agents: []), sessionID: sessionID)
        XCTAssertNotNil(store.load(sessionID: sessionID))
    }

    func testClaudeChildUsageIncludesCachedAndUncachedTokens() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("jsonl")
        defer { try? FileManager.default.removeItem(at: url) }

        let line = """
        {"type":"assistant","requestId":"request-1","message":{"id":"message-1","usage":\
        {"input_tokens":10,"output_tokens":2,"cache_creation_input_tokens":3,\
        "cache_read_input_tokens":4}}}
        """
        try (line + "\n").write(to: url, atomically: true, encoding: .utf8)

        XCTAssertEqual(SubagentUsageReader.read(at: url, kind: .claude), 19)
    }

    func testCodexChildUsageCountsOnlyRequestsAfterChildBoundary() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("jsonl")
        defer { try? FileManager.default.removeItem(at: url) }

        let lines = [
            codexTokenCount(last: 999, total: 10_000),
            #"{"type":"inter_agent_communication_metadata","payload":{"trigger_turn":true}}"#,
            codexTokenCount(last: 30, total: 10_030),
            codexTokenCount(last: 40, total: 10_070)
        ]
        try (lines.joined(separator: "\n") + "\n")
            .write(to: url, atomically: true, encoding: .utf8)

        XCTAssertEqual(SubagentUsageReader.read(at: url, kind: .codex), 70)
    }

    private func codexTokenCount(last: Int, total: Int) -> String {
        """
        {"type":"event_msg","payload":{"type":"token_count","info":{\
        "last_token_usage":{"total_tokens":\(last)},\
        "total_token_usage":{"total_tokens":\(total)}}}}
        """
    }
}

final class ClaudeSubagentEventTests: XCTestCase {

    func testTaskLaunchAndForwardedOutputBuildOneChildTimeline() throws {
        var adapter = ClaudeSubagentEventAdapter()
        var timeline = SubagentTimeline(sessionID: SessionID())

        let launch = try XCTUnwrap(adapter.route("""
            {"type":"assistant","parent_tool_use_id":null,"session_id":"root",
             "message":{"content":[{"type":"tool_use","id":"task-1","name":"Task",
             "input":{"description":"Audit parser","prompt":"Find the routing bug",
             "subagent_type":"Explore","model":"sonnet"}}]}}
            """))
        XCTAssertTrue(launch.belongsToParent)
        for event in launch.events { timeline.apply(event) }

        var child = try XCTUnwrap(timeline.agents.first)
        XCTAssertEqual(timeline.workingCount, 1)
        XCTAssertEqual(child.descriptor.threadID, "task-1")
        XCTAssertEqual(child.descriptor.parentThreadID, "root")
        XCTAssertEqual(child.descriptor.nickname, "Audit parser")
        XCTAssertEqual(child.descriptor.role, "Explore")
        XCTAssertEqual(child.descriptor.prompt, "Find the routing bug")

        let forwarded = try XCTUnwrap(adapter.route("""
            {"type":"assistant","parent_tool_use_id":"task-1","session_id":"root",
             "subagent_type":"Explore","task_description":"Audit parser",
             "message":{"model":"claude-sonnet-4-5","content":[
               {"type":"thinking","thinking":"Inspect routing."},
               {"type":"text","text":"Found the bug."}
             ]}}
            """))
        XCTAssertFalse(forwarded.belongsToParent)
        for event in forwarded.events { timeline.apply(event) }

        child = try XCTUnwrap(timeline.agents.first)
        XCTAssertEqual(child.descriptor.model, "claude-sonnet-4-5")
        XCTAssertEqual(
            child.conversation.rows,
            [.thinking("Inspect routing."), .assistant(markdown: "Found the bug.")]
        )
    }

    func testForwardedToolCallsResultsAndNestedAgentsStayInChildTimeline() throws {
        var adapter = ClaudeSubagentEventAdapter()
        var timeline = SubagentTimeline(sessionID: SessionID())
        applyLaunch(taskID: "task-parent", adapter: &adapter, timeline: &timeline)

        let toolCalls = try XCTUnwrap(adapter.route("""
            {"type":"assistant","parent_tool_use_id":"task-parent","session_id":"root",
             "message":{"content":[
               {"type":"tool_use","id":"bash-1","name":"Bash",
                "input":{"command":"swift test"}},
               {"type":"tool_use","id":"task-child","name":"Agent",
                "input":{"description":"Inspect failure","prompt":"Read the failing test",
                         "subagent_type":"Explore"}}
             ]}}
            """))
        XCTAssertFalse(toolCalls.belongsToParent)
        for event in toolCalls.events { timeline.apply(event) }

        let result = try XCTUnwrap(adapter.route("""
            {"type":"user","parent_tool_use_id":"task-parent","session_id":"root",
             "message":{"content":[{"type":"tool_result","tool_use_id":"bash-1",
             "is_error":false,"content":"All tests passed"}]}}
            """))
        for event in result.events { timeline.apply(event) }

        XCTAssertEqual(timeline.agents.count, 2)
        let parent = try XCTUnwrap(timeline.agents.first {
            $0.descriptor.threadID == "task-parent"
        })
        let nested = try XCTUnwrap(timeline.agents.first {
            $0.descriptor.threadID == "task-child"
        })
        XCTAssertEqual(nested.descriptor.parentThreadID, "task-parent")
        XCTAssertEqual(nested.descriptor.nickname, "Inspect failure")

        guard parent.conversation.rows.count == 2,
              case .toolCall(let bash) = parent.conversation.rows[0],
              case .toolCall(let agentCall) = parent.conversation.rows[1] else {
            return XCTFail("Expected the child transcript to retain both tool calls")
        }
        XCTAssertEqual(bash.tool, .bash)
        XCTAssertEqual(bash.result?.text, "All tests passed")
        XCTAssertEqual(agentCall.tool, .task)
    }

    func testForwardedClaudeTasksSurfaceChildRunProgressUntilCompletion() throws {
        var adapter = ClaudeSubagentEventAdapter()
        var timeline = SubagentTimeline(sessionID: SessionID())
        applyLaunch(taskID: "task-parent", adapter: &adapter, timeline: &timeline)

        let lines = [
            """
            {"type":"assistant","parent_tool_use_id":"task-parent","session_id":"root",
             "message":{"content":[{"type":"tool_use","id":"create-1","name":"TaskCreate",
             "input":{"subject":"Verify child","activeForm":"Verifying child"}}]}}
            """,
            """
            {"type":"user","parent_tool_use_id":"task-parent","session_id":"root",
             "message":{"content":[{"type":"tool_result","tool_use_id":"create-1",
             "is_error":false,"content":"Task #1 created successfully"}]}}
            """,
            """
            {"type":"assistant","parent_tool_use_id":"task-parent","session_id":"root",
             "message":{"content":[{"type":"tool_use","id":"update-1","name":"TaskUpdate",
             "input":{"taskId":"1","status":"in_progress",
             "activeForm":"Verifying child"}}]}}
            """
        ]

        for line in lines {
            let route = try XCTUnwrap(adapter.route(line))
            for event in route.events { timeline.apply(event) }
        }

        XCTAssertEqual(timeline.agents.first?.runProgress?.label, "Step 1 / 1")
        XCTAssertEqual(timeline.agents.first?.statusDetail, "Step 1 / 1")

        timeline.apply(.state(
            threadID: "task-parent",
            status: .completed,
            message: "Finished"
        ))
        XCTAssertNil(timeline.agents.first?.runProgress)
        XCTAssertNil(timeline.agents.first?.statusDetail)
    }

    func testCompletedClaudeChildIgnoresTaskProgressFromHistoricalReplay() throws {
        var adapter = ClaudeSubagentEventAdapter()
        var timeline = SubagentTimeline(sessionID: SessionID())
        applyLaunch(taskID: "task-parent", adapter: &adapter, timeline: &timeline)
        timeline.apply(.state(
            threadID: "task-parent",
            status: .completed,
            message: "Finished"
        ))

        let historicalLines = [
            """
            {"type":"assistant","parent_tool_use_id":"task-parent","session_id":"root",
             "message":{"content":[{"type":"tool_use","id":"create-1","name":"TaskCreate",
             "input":{"subject":"Verify child","activeForm":"Verifying child"}}]}}
            """,
            """
            {"type":"user","parent_tool_use_id":"task-parent","session_id":"root",
             "message":{"content":[{"type":"tool_result","tool_use_id":"create-1",
             "is_error":false,"content":"Task #1 created successfully"}]}}
            """,
            """
            {"type":"assistant","parent_tool_use_id":"task-parent","session_id":"root",
             "message":{"content":[{"type":"tool_use","id":"update-1","name":"TaskUpdate",
             "input":{"taskId":"1","status":"in_progress",
             "activeForm":"Verifying child"}}]}}
            """
        ]

        for line in historicalLines {
            let route = try XCTUnwrap(adapter.route(line))
            // Lazy history supplies only the selected child's StreamEvents. The adapter's
            // synthetic live `.working` observation is deliberately not part of replay.
            for event in route.events {
                guard case .conversation = event else { continue }
                timeline.apply(event)
            }
        }

        XCTAssertEqual(timeline.agents.first?.status, .completed)
        XCTAssertNil(timeline.agents.first?.runProgress)
        XCTAssertNil(timeline.agents.first?.statusDetail)
    }

    func testStructuredTaskLifecycleMergesTypedProgress() throws {
        var adapter = ClaudeSubagentEventAdapter()
        var timeline = SubagentTimeline(sessionID: SessionID())
        applyLaunch(taskID: "task-background", adapter: &adapter, timeline: &timeline)

        let lines = [
            """
            {"type":"system","subtype":"task_started","task_id":"runtime-7",
             "tool_use_id":"task-background","task_type":"local_agent",
             "description":"Audit parser","subagent_type":"Explore"}
            """,
            """
            {"type":"system","subtype":"task_progress","task_id":"runtime-7",
             "summary":"Checking the event adapter","last_tool_name":"Grep",
             "usage":{"total_tokens":12450,"tool_uses":7,"duration_ms":32000}}
            """,
            """
            {"type":"tool_progress","parent_tool_use_id":"task-background",
             "task_id":"runtime-7","tool_name":"Read","elapsed_time_seconds":34}
            """,
            """
            {"type":"system","subtype":"task_updated","task_id":"runtime-7",
             "patch":{"status":"running","is_backgrounded":true}}
            """,
            """
            {"type":"system","subtype":"task_notification","task_id":"runtime-7",
             "status":"completed","summary":"Parser audit complete",
             "usage":{"total_tokens":13700,"tool_uses":9,"duration_ms":41000}}
            """
        ]

        for line in lines {
            let route = try XCTUnwrap(adapter.route(line))
            for event in route.events { timeline.apply(event) }
        }

        let agent = try XCTUnwrap(timeline.agents.first)
        let progress = try XCTUnwrap(agent.progress)
        XCTAssertEqual(agent.status, .completed)
        XCTAssertEqual(progress.taskID, "runtime-7")
        XCTAssertEqual(progress.summary, "Parser audit complete")
        XCTAssertEqual(progress.currentTool, "Read")
        XCTAssertEqual(progress.totalTokens, 13_700)
        XCTAssertEqual(progress.toolUses, 9)
        XCTAssertEqual(progress.duration, 41)
        XCTAssertEqual(progress.elapsed, 34)
        XCTAssertEqual(progress.isBackgrounded, true)
        XCTAssertEqual(
            progress.displayText,
            "Parser audit complete · 41s · 9 tools · 13.7k tokens"
        )
        XCTAssertEqual(agent.activity.last, "Parser audit complete")
    }

    func testStructuredBackgroundBashDoesNotCreateSubagent() throws {
        var adapter = ClaudeSubagentEventAdapter()
        let route = try XCTUnwrap(adapter.route("""
            {"type":"system","subtype":"task_started","task_id":"bash-runtime",
             "tool_use_id":"bash-tool","task_type":"local_bash",
             "description":"Run the test suite"}
            """))

        XCTAssertTrue(route.belongsToParent)
        XCTAssertTrue(route.events.isEmpty)
    }

    func testForwardedResumePreservesRecoveredNestedParent() throws {
        var adapter = ClaudeSubagentEventAdapter()
        var timeline = SubagentTimeline(sessionID: SessionID())
        timeline.apply(.discovered(SubagentDescriptor(
            threadID: "task-child",
            parentThreadID: "task-parent",
            nickname: "Recovered child"
        )))

        let route = try XCTUnwrap(adapter.route("""
            {"type":"assistant","parent_tool_use_id":"task-child","session_id":"root",
             "message":{"content":[{"type":"text","text":"Resumed output"}]}}
            """))
        for event in route.events { timeline.apply(event) }

        XCTAssertEqual(timeline.agents.first?.descriptor.parentThreadID, "task-parent")
        XCTAssertEqual(
            timeline.agents.first?.conversation.rows,
            [.assistant(markdown: "Resumed output")]
        )
    }

    func testForegroundResultCompletesTask() throws {
        var adapter = ClaudeSubagentEventAdapter()
        var timeline = SubagentTimeline(sessionID: SessionID())
        applyLaunch(taskID: "task-foreground", adapter: &adapter, timeline: &timeline)

        let result = try XCTUnwrap(adapter.route("""
            {"type":"user","parent_tool_use_id":null,"message":{"content":[{
              "type":"tool_result","tool_use_id":"task-foreground",
              "is_error":false,"content":"Done"
            }]}}
            """))
        for event in result.events { timeline.apply(event) }

        XCTAssertEqual(timeline.workingCount, 0)
        XCTAssertEqual(timeline.doneCount, 1)
        XCTAssertEqual(timeline.agents.first?.status, .completed)
    }

    func testAsyncReceiptWaitsForTaskNotificationAndMergesAgentID() throws {
        var adapter = ClaudeSubagentEventAdapter()
        var timeline = SubagentTimeline(sessionID: SessionID())
        applyLaunch(taskID: "task-background", adapter: &adapter, timeline: &timeline)

        let receipt = try XCTUnwrap(adapter.route("""
            {"type":"user","parent_tool_use_id":null,
             "message":{"content":[{"type":"tool_result",
             "tool_use_id":"task-background","is_error":false,
             "content":"Async agent launched"}]},
             "tool_use_result":{"isAsync":true,"status":"async_launched",
             "agentId":"agent-7","description":"Research",
             "resolvedModel":"claude-haiku-4-5"}}
            """))
        for event in receipt.events { timeline.apply(event) }

        XCTAssertEqual(timeline.workingCount, 1)
        XCTAssertEqual(timeline.doneCount, 0)
        XCTAssertEqual(timeline.agents.first?.descriptor.model, "claude-haiku-4-5")

        let notification = try XCTUnwrap(adapter.route("""
            {"type":"user","parent_tool_use_id":null,"message":{"content":
             "<task-notification><task-id>agent-7</task-id><status>completed</status>\
             <summary>Agent finished its audit</summary></task-notification>"}}
            """))
        for event in notification.events { timeline.apply(event) }

        XCTAssertEqual(timeline.workingCount, 0)
        XCTAssertEqual(timeline.doneCount, 1)
        XCTAssertEqual(timeline.agents.count, 1)
        XCTAssertEqual(timeline.agents.first?.descriptor.threadID, "task-background")
        XCTAssertEqual(timeline.agents.first?.status, .completed)
        XCTAssertEqual(timeline.agents.first?.activity.last, "Agent finished its audit")
    }

    func testSessionTerminationClosesOnlyActiveTasks() {
        var adapter = ClaudeSubagentEventAdapter()
        var timeline = SubagentTimeline(sessionID: SessionID())
        applyLaunch(taskID: "task-active", adapter: &adapter, timeline: &timeline)

        for event in adapter.terminationEvents(status: 7) { timeline.apply(event) }

        XCTAssertEqual(timeline.agents.first?.status, .failed)
        XCTAssertEqual(
            timeline.agents.first?.activity.last,
            "Failed when the Claude session exited"
        )
        XCTAssertTrue(adapter.terminationEvents(status: 7).isEmpty)
    }

    private func applyLaunch(
        taskID: String,
        adapter: inout ClaudeSubagentEventAdapter,
        timeline: inout SubagentTimeline
    ) {
        let route = adapter.route("""
            {"type":"assistant","parent_tool_use_id":null,"session_id":"root",
             "message":{"content":[{"type":"tool_use","id":"\(taskID)",
             "name":"Task","input":{"description":"Child"}}]}}
            """)
        for event in route?.events ?? [] { timeline.apply(event) }
    }
}

final class ClaudeControlRequestTests: XCTestCase {

    func testSetModelProducesControlRequestEnvelope() throws {
        let data = try XCTUnwrap(ClaudeControlRequest.line(
            subtype: ClaudeControlRequest.setModel,
            requestID: "skalman-ctrl-3",
            body: ["model": "claude-sonnet-5"]
        ))
        XCTAssertEqual(data.last, 0x0A, "The line must be newline-terminated like a turn")

        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(object["type"] as? String, "control_request")
        XCTAssertEqual(object["request_id"] as? String, "skalman-ctrl-3")

        let request = try XCTUnwrap(object["request"] as? [String: Any])
        XCTAssertEqual(request["subtype"] as? String, "set_model")
        XCTAssertEqual(request["model"] as? String, "claude-sonnet-5")
    }

    func testFastModeProducesApplyFlagSettingsEnvelope() throws {
        let data = try XCTUnwrap(ClaudeControlRequest.line(
            subtype: ClaudeControlRequest.applyFlagSettings,
            requestID: "skalman-ctrl-4",
            body: ["settings": ["fastMode": true]]
        ))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let request = try XCTUnwrap(object["request"] as? [String: Any])
        XCTAssertEqual(request["subtype"] as? String, "apply_flag_settings")
        let settings = try XCTUnwrap(request["settings"] as? [String: Any])
        XCTAssertEqual(settings["fastMode"] as? Bool, true)
    }

    func testNilModelSerializesAsJSONNullToResetToDefault() throws {
        let data = try XCTUnwrap(ClaudeControlRequest.line(
            subtype: ClaudeControlRequest.setModel,
            requestID: "skalman-ctrl-5",
            body: ["model": NSNull()]
        ))
        // The CLI resets to the default on null; the key must be present as null, not omitted.
        let text = try XCTUnwrap(String(data: data, encoding: .utf8))
        XCTAssertTrue(text.contains("\"model\":null"), "Expected a null model, got: \(text)")
    }

    func testControlResponseParsesSuccess() throws {
        let response = try XCTUnwrap(ControlResponse.parse(
            #"{"type":"control_response","response":{"subtype":"success","request_id":"skalman-ctrl-1"}}"#))
        XCTAssertEqual(response.requestID, "skalman-ctrl-1")
        XCTAssertFalse(response.isError)
    }

    func testControlResponseParsesErrorWithMessage() throws {
        let response = try XCTUnwrap(ControlResponse.parse(
            #"{"type":"control_response","response":{"subtype":"error","request_id":"skalman-ctrl-1","error":"unrecognized model"}}"#))
        XCTAssertTrue(response.isError)
        XCTAssertEqual(response.error, "unrecognized model")
    }

    func testControlResponseIgnoresOrdinaryEvents() {
        XCTAssertNil(ControlResponse.parse(#"{"type":"assistant","message":{"content":[]}}"#))
        XCTAssertNil(ControlResponse.parse(#"{"type":"result","result":"done"}"#))
        XCTAssertNil(ControlResponse.parse("not json at all"))
    }
}

final class StreamEventParserTests: XCTestCase {

    func testClaudeDecodesKnownEventsAndToleratesOptionalFieldDrift() throws {
        let event = try onlyEvent(StreamEvent.parse("""
            {"type":"system","subtype":"init","session_id":"thread-1","model":42,
             "future_field":{"nested":true}}
            """))

        guard case .initialised(let sessionID, let model) = event else {
            return XCTFail("Expected Claude init event")
        }
        XCTAssertEqual(sessionID, TranscriptID("thread-1"))
        XCTAssertNil(model)
    }

    func testClaudeToolArgumentsAndResultsKeepStructuredJSON() throws {
        let call = try onlyEvent(StreamEvent.parse("""
            {"type":"assistant","message":{"content":[{
              "type":"tool_use","id":"call-1","name":"Bash",
              "input":{"command":"echo hi","options":{"quiet":true},"retries":2}
            }]}}
            """))
        guard case .assistantMessage(let blocks) = call,
              case .toolUse(let id, let tool, let input) = try XCTUnwrap(blocks.first) else {
            return XCTFail("Expected Claude tool call")
        }
        XCTAssertEqual(id, "call-1")
        XCTAssertEqual(tool, .bash)
        XCTAssertEqual(input["command"] as? String, "echo hi")
        XCTAssertEqual((input["options"] as? [String: Any])?["quiet"] as? Bool, true)
        XCTAssertEqual(input["retries"] as? Int, 2)

        let result = try onlyEvent(StreamEvent.parse("""
            {"type":"user","message":{"content":[{
              "type":"tool_result","tool_use_id":"call-1","is_error":false,
              "content":[{"type":"text","text":"first"},{"type":"text","text":"second"}]
            }]}}
            """))
        guard case .toolResults(let results) = result else {
            return XCTFail("Expected Claude tool result")
        }
        XCTAssertEqual(try XCTUnwrap(results.first).text, "first\nsecond")
    }

    func testCodexDecodesStringEncodedMCPArgumentsAndErrorObjects() throws {
        let call = try onlyEvent(CodexStreamEvent.parse(##"{"type":"item.started","item":{"id":"call-2","type":"mcp_tool_call","server":"web","tool":"query","arguments":"{\"selector\":\"#main\"}"}}"##))
        guard case .assistantMessage(let blocks) = call,
              case .toolUse(let id, let tool, let input) = try XCTUnwrap(blocks.first) else {
            return XCTFail("Expected Codex MCP tool call")
        }
        XCTAssertEqual(id, "call-2")
        XCTAssertEqual(tool, .mcp("mcp__web__query"))
        XCTAssertEqual(input["selector"] as? String, "#main")

        let failed = try onlyEvent(CodexStreamEvent.parse("""
            {"type":"turn.failed","error":{"message":"sandbox denied","code":17}}
            """))
        guard case .turnFinished(let text, let isError, _) = failed else {
            return XCTFail("Expected failed Codex turn")
        }
        XCTAssertEqual(text, "sandbox denied")
        XCTAssertTrue(isError)
    }

    func testBothProvidersDecodeExactTurnReceipts() throws {
        let claude = try onlyEvent(StreamEvent.parse("""
            {"type":"result","is_error":false,"duration_ms":89432,
             "usage":{"input_tokens":12000,"output_tokens":3149}}
            """))
        guard case .turnFinished(_, false, let claudeMetrics) = claude else {
            return XCTFail("Expected Claude result")
        }
        XCTAssertEqual(
            try XCTUnwrap(claudeMetrics.duration),
            89.432,
            accuracy: 0.0001
        )
        XCTAssertEqual(claudeMetrics.outputTokens, 3_149)

        let codex = try onlyEvent(CodexStreamEvent.parse("""
            {"type":"turn.completed",
             "usage":{"input_tokens":12000,"cached_input_tokens":9000,"output_tokens":3149}}
            """))
        guard case .turnFinished(_, false, let codexMetrics) = codex else {
            return XCTFail("Expected Codex result")
        }
        XCTAssertNil(codexMetrics.duration, "Codex duration comes from the wrapper's local clock")
        XCTAssertEqual(codexMetrics.outputTokens, 3_149)
    }

    /// Claude restates the whole in-flight list whenever it changes, so the event is a level
    /// and the empty one is as meaningful as the full one — it is what says the session may
    /// finish. Both shapes measured against CLI 2.1.220 running a backgrounded shell.
    func testClaudeReportsBackgroundWorkAsAWholeList() throws {
        let started = try onlyEvent(StreamEvent.parse("""
            {"type":"system","subtype":"background_tasks_changed","tasks":[
              {"task_id":"b4vc22id4","task_type":"local_bash","description":"scripts/test.sh"},
              {"task_id":"b8x1tqpxz","task_type":"local_agent","description":"explore"}
            ],"session_id":"thread-1"}
            """))
        guard case .backgroundWork(let inFlight) = started else {
            return XCTFail("Expected a background-work level")
        }
        // Identities, not a count: the ledger has to tell these apart across turns, and the
        // stream spells the key `task_id` where the hook payload spells it `id`.
        XCTAssertEqual(inFlight, ["b4vc22id4", "b8x1tqpxz"])

        let drained = try onlyEvent(StreamEvent.parse(
            #"{"type":"system","subtype":"background_tasks_changed","tasks":[]}"#
        ))
        guard case .backgroundWork(let none) = drained else {
            return XCTFail("An empty list is still a level, not an unknown event")
        }
        XCTAssertTrue(none.isEmpty)
    }

    /// A system subtype nothing consumes stays `unknown`, so a future one is ignored rather
    /// than mistaken for a background-work level.
    func testOtherSystemSubtypesStayUnknown() throws {
        let event = try onlyEvent(StreamEvent.parse(
            #"{"type":"system","subtype":"task_started","task_id":"b4vc22id4"}"#
        ))
        guard case .unknown(let type) = event else {
            return XCTFail("Expected an unknown system event")
        }
        XCTAssertEqual(type, "system")
    }

    func testUnknownKindsAreEventsButMalformedLinesAreCountable() throws {
        let claudeUnknown = try onlyEvent(StreamEvent.parse(#"{"type":"future.event"}"#))
        guard case .unknown(let claudeType) = claudeUnknown else {
            return XCTFail("Expected unknown Claude event")
        }
        XCTAssertEqual(claudeType, "future.event")

        let codexUnknown = try onlyEvent(CodexStreamEvent.parse(#"{"type":"future.event"}"#))
        guard case .unknown(let codexType) = codexUnknown else {
            return XCTFail("Expected unknown Codex event")
        }
        XCTAssertEqual(codexType, "future.event")

        guard case .malformed = StreamEvent.parse("not-json") else {
            return XCTFail("Invalid Claude JSON must be malformed")
        }
        guard case .malformed = CodexStreamEvent.parse(#"{"message":"missing type"}"#) else {
            return XCTFail("A Codex record without a type must be malformed")
        }

        var diagnostics = StreamParseDiagnostics()
        diagnostics.recordMalformedLine(provider: "test")
        diagnostics.recordMalformedLine(provider: "test")
        XCTAssertEqual(diagnostics.malformedLineCount, 2)
        diagnostics.reset()
        XCTAssertEqual(diagnostics.malformedLineCount, 0)
    }

    private func onlyEvent(_ result: StreamLineParseResult) throws -> StreamEvent {
        guard case .events(let events) = result else {
            throw ParserTestError.malformed
        }
        XCTAssertEqual(events.count, 1)
        return try XCTUnwrap(events.first)
    }

    private enum ParserTestError: Error {
        case malformed
    }
}

final class CodexAppServerEventTests: XCTestCase {

    func testEnvelopeDistinguishesResponsesRequestsAndNotifications() throws {
        guard case .response(let responseID, let result, let error)? =
                CodexAppServerEnvelope.parse(
                    #"{"id":4,"result":{"thread":{"id":"root"}}}"#
                ) else {
            return XCTFail("Expected response")
        }
        XCTAssertEqual(responseID, .integer(4))
        XCTAssertEqual(
            (result?["thread"] as? [String: Any])?["id"] as? String,
            "root"
        )
        XCTAssertNil(error)

        guard case .request(let requestID, let method, let parameters)? =
                CodexAppServerEnvelope.parse(
                    #"{"id":"approval-1","method":"item/commandExecution/requestApproval","params":{"command":"make"}}"#
                ) else {
            return XCTFail("Expected request")
        }
        XCTAssertEqual(requestID, .string("approval-1"))
        XCTAssertEqual(method, "item/commandExecution/requestApproval")
        XCTAssertEqual(parameters["command"] as? String, "make")

        guard case .notification(let notification, let parameters)? =
                CodexAppServerEnvelope.parse(
                    #"{"method":"item/agentMessage/delta","params":{"threadId":"root","delta":"Hi"}}"#
                ) else {
            return XCTFail("Expected notification")
        }
        XCTAssertEqual(notification, "item/agentMessage/delta")
        XCTAssertEqual(parameters["delta"] as? String, "Hi")
    }

    func testAppServerParentItemsReuseConversationEvents() throws {
        let started = CodexAppServerEvent.streamEvents(
            method: "item/started",
            parameters: [
                "threadId": "root",
                "item": [
                    "id": "command-1",
                    "type": "commandExecution",
                    "command": "swift test",
                    "status": "inProgress"
                ]
            ]
        )
        guard case .assistantMessage(let blocks) = try XCTUnwrap(started.first),
              case .toolUse(let id, let tool, let input) = try XCTUnwrap(blocks.first) else {
            return XCTFail("Expected command tool use")
        }
        XCTAssertEqual(id, "command-1")
        XCTAssertEqual(tool, .bash)
        XCTAssertEqual(input["command"] as? String, "swift test")

        let completed = CodexAppServerEvent.streamEvents(
            method: "item/completed",
            parameters: [
                "threadId": "root",
                "item": [
                    "id": "message-1",
                    "type": "agentMessage",
                    "text": "All green."
                ]
            ]
        )
        guard case .assistantMessage(let completedBlocks) = try XCTUnwrap(completed.first),
              case .text(let text) = try XCTUnwrap(completedBlocks.first) else {
            return XCTFail("Expected completed agent message")
        }
        XCTAssertEqual(text, "All green.")
    }

    func testAppServerPlanNotificationCarriesTheAuthoritativeOrderedSnapshot() throws {
        let events = CodexAppServerEvent.streamEvents(
            method: "turn/plan/updated",
            parameters: [
                "threadId": "root",
                "turnId": "turn-1",
                "plan": [
                    ["step": "Inspect", "status": "completed"],
                    ["step": "Implement", "status": "inProgress"],
                    ["step": "Verify", "status": "pending"],
                ]
            ]
        )

        guard case .runPlanUpdated(let steps) = try XCTUnwrap(events.first) else {
            return XCTFail("Expected a provider-neutral plan snapshot")
        }
        XCTAssertEqual(steps.count, 3)
        XCTAssertEqual(steps[1].title, "Implement")
        XCTAssertEqual(steps[1].status, .inProgress)

        var timeline = ConversationTimeline(sessionID: SessionID())
        XCTAssertEqual(
            timeline.apply(events[0]),
            [.runProgress(RunProgress(step: 2, total: 3))]
        )
    }

    func testAppServerRejectsAPartiallyMalformedPlanSnapshot() {
        let events = CodexAppServerEvent.streamEvents(
            method: "turn/plan/updated",
            parameters: [
                "threadId": "root",
                "turnId": "turn-1",
                "plan": [
                    ["step": "Inspect", "status": "completed"],
                    ["step": "Broken"],
                ]
            ]
        )

        XCTAssertTrue(events.isEmpty)
    }

    func testCodexChildPlanLivesInChildSummaryAndClearsAtCompletion() throws {
        let parameters: [String: Any] = [
            "threadId": "child-1",
            "turnId": "child-turn",
            "plan": [
                ["step": "Inspect", "status": "completed"],
                ["step": "Verify", "status": "inProgress"],
                ["step": "Report", "status": "pending"],
            ]
        ]
        let events = CodexSubagentEvent.events(
            method: "turn/plan/updated",
            parameters: parameters,
            rootThreadID: "root"
        )

        var timeline = SubagentTimeline(sessionID: SessionID())
        for event in events { timeline.apply(event) }

        XCTAssertEqual(timeline.agents.first?.runProgress?.label, "Step 2 / 3")
        XCTAssertEqual(timeline.agents.first?.statusDetail, "Step 2 / 3")
        XCTAssertTrue(CodexSubagentEvent.events(
            method: "turn/plan/updated",
            parameters: parameters.merging(["threadId": "root"]) { _, newer in newer },
            rootThreadID: "root"
        ).isEmpty)

        timeline.apply(.state(threadID: "child-1", status: .completed, message: nil))
        XCTAssertNil(timeline.agents.first?.runProgress)
        XCTAssertNil(timeline.agents.first?.statusDetail)
    }

    func testCodexChildCanResumeAfterIdleAndReportANewPlan() {
        var timeline = SubagentTimeline(sessionID: SessionID())

        func applyStatus(_ type: String) {
            for event in CodexSubagentEvent.events(
                method: "thread/status/changed",
                parameters: [
                    "threadId": "child-1",
                    "status": ["type": type]
                ],
                rootThreadID: "root"
            ) {
                timeline.apply(event)
            }
        }

        func applyPlan(_ steps: [[String: String]]) {
            for event in CodexSubagentEvent.events(
                method: "turn/plan/updated",
                parameters: [
                    "threadId": "child-1",
                    "turnId": "child-turn",
                    "plan": steps
                ],
                rootThreadID: "root"
            ) {
                timeline.apply(event)
            }
        }

        applyStatus("active")
        applyPlan([["step": "First turn", "status": "inProgress"]])
        XCTAssertEqual(timeline.agents.first?.runProgress?.label, "Step 1 / 1")

        applyStatus("idle")
        XCTAssertEqual(timeline.agents.first?.status, .completed)
        XCTAssertNil(timeline.agents.first?.runProgress)

        applyStatus("active")
        applyPlan([
            ["step": "Inspect follow-up", "status": "inProgress"],
            ["step": "Report", "status": "pending"]
        ])

        XCTAssertEqual(timeline.agents.first?.status, .working)
        XCTAssertEqual(timeline.agents.first?.runProgress?.label, "Step 1 / 2")
        XCTAssertEqual(timeline.agents.first?.statusDetail, "Step 1 / 2")
    }

    func testCollaborationEventsBuildAChildTimelineAndCounts() throws {
        let parameters: [String: Any] = [
            "threadId": "root",
            "item": [
                "id": "collab-1",
                "type": "collabAgentToolCall",
                "tool": "spawnAgent",
                "status": "inProgress",
                "senderThreadId": "root",
                "receiverThreadIds": ["child-1"],
                "prompt": "Audit the parser",
                "model": "gpt-5.6-sol",
                "reasoningEffort": "high",
                "agentsStates": [
                    "child-1": ["status": "running"]
                ]
            ]
        ]

        var timeline = SubagentTimeline(sessionID: SessionID())
        for event in CodexSubagentEvent.events(
            method: "item/started",
            parameters: parameters,
            rootThreadID: "root"
        ) {
            timeline.apply(event)
        }

        XCTAssertEqual(timeline.workingCount, 1)
        XCTAssertEqual(timeline.doneCount, 0)
        let child = try XCTUnwrap(timeline.agents.first)
        XCTAssertEqual(child.descriptor.threadID, "child-1")
        XCTAssertEqual(child.descriptor.parentThreadID, "root")
        XCTAssertEqual(child.descriptor.prompt, "Audit the parser")
        XCTAssertEqual(child.descriptor.model, "gpt-5.6-sol")

        for event in CodexSubagentEvent.events(
            method: "turn/completed",
            parameters: [
                "threadId": "child-1",
                "turn": [
                    "id": "child-turn",
                    "items": [],
                    "status": "completed"
                ]
            ],
            rootThreadID: "root"
        ) {
            timeline.apply(event)
        }

        XCTAssertEqual(timeline.workingCount, 0)
        XCTAssertEqual(timeline.doneCount, 1)
        XCTAssertEqual(timeline.agents.first?.status, .completed)
    }

    func testChildAgentMessagesStayOutOfParentAndPopulateDrillIn() throws {
        let parameters: [String: Any] = [
            "threadId": "child-2",
            "turnId": "child-turn",
            "item": [
                "id": "message-2",
                "type": "agentMessage",
                "text": "Found a race in shutdown."
            ]
        ]
        let events = CodexSubagentEvent.events(
            method: "item/completed",
            parameters: parameters,
            rootThreadID: "root"
        )

        var timeline = SubagentTimeline(sessionID: SessionID())
        for event in events { timeline.apply(event) }

        let child = try XCTUnwrap(timeline.agents.first)
        XCTAssertEqual(
            child.conversation.rows,
            [.assistant(markdown: "Found a race in shutdown.")]
        )
    }

    func testLogicalCodexAgentPathIsNotStoredAsATranscriptFile() throws {
        let events = CodexSubagentEvent.events(
            method: "item/started",
            parameters: [
                "threadId": "root",
                "item": [
                    "id": "activity-1",
                    "type": "subAgentActivity",
                    "agentThreadId": "child-3",
                    "agentPath": "/root/review_pr612_codex",
                    "kind": "started"
                ]
            ],
            rootThreadID: "root"
        )

        var timeline = SubagentTimeline(sessionID: SessionID())
        for event in events { timeline.apply(event) }

        let child = try XCTUnwrap(timeline.agents.first)
        XCTAssertNil(child.descriptor.path)
        XCTAssertEqual(child.status, .working)
    }
}

final class AppEventTests: XCTestCase {

    func testTypedEventDeliversItsPayload() {
        let center = NotificationCenter()
        let observations = AppEventObservations(center: center)
        let sessionID = SessionID()
        var receivedSessionID: SessionID?

        observations.observe(TerminalSessionDidEnd.self) { event in
            receivedSessionID = event.sessionID
        }
        center.post(TerminalSessionDidEnd(sessionID: sessionID))

        XCTAssertEqual(receivedSessionID, sessionID)
    }

    func testObservationLifetimeUnregistersItsTokens() {
        let center = NotificationCenter()
        var deliveryCount = 0
        var observations: AppEventObservations? = AppEventObservations(center: center)

        observations?.observe(ProjectsDidChange.self) { _ in deliveryCount += 1 }
        center.post(ProjectsDidChange())
        observations = nil
        center.post(ProjectsDidChange())

        XCTAssertEqual(deliveryCount, 1)
    }
}
