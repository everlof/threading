import XCTest
@testable import Threading

/// The Codex, usage and tool-input half of the reachable array-cast defect.
///
/// `value as? [[String: Any]]` fails **entirely** when any element is not a dictionary, and a
/// JSON `null` is an `NSNull` — so one null discards the whole array rather than itself. Every
/// fixture here is therefore built from **JSON text** and pushed through `JSONSerialization`:
/// a Swift array literal cannot hold an `NSNull` at all, so a literal-built test proves nothing
/// about this defect. That is the same blind spot that hid the boolean bug in `3277a3a0`.
///
/// Each case says which of the two answers its site chose. A site that recovers is asserted to
/// keep its readable neighbours; a site that still refuses is asserted to *still* refuse, so a
/// later blanket `compactMap` over this codebase fails here rather than quietly inverting a
/// check or shortening a diff.
///
/// **This file owns the Codex/usage/tool-input half.** `WireArrayNullElementTests` owns the other
/// one — the Claude, ACP and Grok transcript and catalogue readers — where recovery is nearly
/// always the right answer and the interesting cases are the two deliberate refusals. The split is
/// by reader, not by helper: one `WireList` serves both files, and the two never assert the same
/// site.
final class WireArrayNullRecoveryTests: XCTestCase {

    // MARK: - The defect itself

    /// The measurement the whole sweep rests on, taken through the bridge that produces it.
    func testTheAllOrNothingCastLosesTheWholeArrayForOneNull() throws {
        let list = try XCTUnwrap(jsonValue(#"["c1", null]"#) as? [Any])
        XCTAssertEqual(list.count, 2)

        XCTAssertNil(
            list as? [[String: Any]],
            "one null discards both elements, not just itself"
        )
        XCTAssertNil(list as? [String], "and the string form fails the same way")

        XCTAssertEqual(
            WireList.strings(list, site: "test", log: ThreadingLogger.agent),
            ["c1"]
        )
    }

    /// An array that is entirely unreadable is empty rather than nil: the array was there, and
    /// nil is reserved for "this was not an array", which is a different statement.
    func testRecoveringSeparatesAnUnreadableElementFromAnUnreadableShape() {
        XCTAssertEqual(
            WireList.objects(
                jsonValue("[null, 7]"), site: "test", log: ThreadingLogger.agent
            )?.count,
            0
        )
        XCTAssertNil(
            WireList.objects(
                jsonValue(#"{"a": 1}"#), site: "test", log: ThreadingLogger.agent
            ),
            "an object is not an array and answers nil"
        )
        XCTAssertNil(
            WireList.objects(nil, site: "test", log: ThreadingLogger.agent)
        )
    }

    /// The dictionary-valued form draws the same line one level in: nil is "this was not an
    /// object", and a key whose value is unreadable costs that key and no other.
    func testTheDictionaryFormSeparatesAnUnreadableValueFromAnUnreadableShape() {
        let values = WireList.values(
            jsonValue(#"{"c1": {"status": "running"}, "c2": null}"#),
            site: "test",
            log: ThreadingLogger.agent
        )

        XCTAssertEqual(values?.count, 1)
        XCTAssertEqual(values?["c1"]?["status"] as? String, "running")

        XCTAssertNil(
            WireList.values(jsonValue("[1, 2]"), site: "test", log: ThreadingLogger.agent),
            "an array is not an object and answers nil"
        )
        XCTAssertNil(WireList.values(nil, site: "test", log: ThreadingLogger.agent))
    }

    /// Positions come from the wire, not from what survived compaction — an entry named by its
    /// index must not be renamed because a neighbour broke.
    func testRecoveringReportsTheOffsetTheWireUsed() {
        let indexed = WireList.indexed(
            jsonValue(#"[null, {"id": "b"}]"#), site: "test", log: ThreadingLogger.agent
        )

        XCTAssertEqual(indexed?.count, 1)
        XCTAssertEqual(indexed?.first?.offset, 1)
        XCTAssertEqual(indexed?.first?.element["id"] as? String, "b")
    }

    // MARK: - Codex app server: recovered

    /// RECOVERS. A user turn keeps the blocks that read; the alternative was an assistant answer
    /// to a message nobody appears to have typed.
    func testACodexUserMessageKeepsTheBlocksItCanReadPastANull() {
        let events = codexEvents(
            method: "item/completed",
            #"""
            {"threadId":"t1","item":{"id":"u1","type":"userMessage",
             "content":[{"type":"text","text":"first"},null,{"type":"text","text":"second"}]}}
            """#
        )

        guard case .userMessage(let text)? = events.first else {
            return XCTFail("expected a user message, got \(events)")
        }
        XCTAssertEqual(text, "first\nsecond")
        XCTAssertEqual(events.count, 1)
    }

    /// RECOVERS. `receiverThreadIds` is the only announcement a delegated child ever gets, so
    /// one unreadable id used to cost every sibling its session.
    func testACollaborationCallStillDiscoversTheChildrenItCanName() {
        let events = codexSubagentEvents(
            method: "item/started",
            #"""
            {"threadId":"t1","item":{"type":"collabAgentToolCall","senderThreadId":"t1",
             "receiverThreadIds":["c1",null,"c2"],"prompt":"go"}}
            """#
        )

        XCTAssertEqual(discoveredThreadIDs(events), ["c1", "c2"])
    }

    /// RECOVERS. The states map is all-or-nothing across *keys*, so one null value used to send
    /// every other child to the fallback status — reporting a running agent as pending.
    func testACollaborationCallKeepsTheChildStatesItCanRead() {
        let events = codexSubagentEvents(
            method: "item/started",
            #"""
            {"threadId":"t1","item":{"type":"collabAgentToolCall","senderThreadId":"t1",
             "receiverThreadIds":["c1","c2"],"prompt":"go",
             "agentsStates":{"c1":{"status":"running"},"c2":null}}}
            """#
        )

        XCTAssertEqual(status(of: "c1", in: events), .working)
        XCTAssertEqual(
            status(of: "c2", in: events), .pending,
            "the child whose own state is unreadable still falls back, and only that child"
        )
    }

    // MARK: - Codex app server: still refused

    /// REFUSES. A plan is drawn as "step N of total", so keeping the readable half would move
    /// the denominator and redraw progress the agent never reported.
    func testACodexPlanNotificationIsStillWithdrawnWholeByANullStep() {
        let complete = codexEvents(
            method: "turn/plan/updated",
            #"{"threadId":"t1","plan":[{"step":"Read","status":"pending"},{"step":"Edit","status":"in_progress"}]}"#
        )
        guard case .runPlanUpdated(let steps)? = complete.first else {
            return XCTFail("expected a plan update, got \(complete)")
        }
        XCTAssertEqual(steps.count, 2)

        let withNull = codexEvents(
            method: "turn/plan/updated",
            #"{"threadId":"t1","plan":[{"step":"Read","status":"pending"},null]}"#
        )
        XCTAssertTrue(
            withNull.isEmpty,
            "a partial plan would state a total the agent did not; the snapshot is withdrawn"
        )
    }

    // MARK: - Hook lifecycle: recovered

    /// RECOVERS, at the wire's own offsets. Losing the whole list makes every surviving task
    /// read as new again next turn, which is exactly what the `#index` fallback exists to stop.
    func testBackgroundTasksSurviveANullNeighbourAtTheirWirePositions() throws {
        let report = try XCTUnwrap(HookLifecycleReport(
            sessionID: SessionID(),
            event: .turnFinished,
            payload: object(#"""
            {"background_tasks":[null,{"id":"bwf9","type":"subagent"},{"type":"shell"}]}
            """#)
        ))

        XCTAssertEqual(report.backgroundWork, [
            BackgroundTask(id: "bwf9", kind: .delegated),
            BackgroundTask(id: "#2", kind: .standing)
        ])
    }

    /// The position really is the wire's: compacting first would have named the last task `#1`.
    func testANullNeighbourDoesNotRenumberTheTasksAfterIt() throws {
        let report = try XCTUnwrap(HookLifecycleReport(
            sessionID: SessionID(),
            event: .turnFinished,
            payload: object(#"{"background_tasks":[null,{"type":"shell"}]}"#)
        ))

        XCTAssertEqual(report.backgroundWork.map(\.id), ["#1"])
    }

    // MARK: - Usage: still refused, and now by name

    /// REFUSES. A usage total is one number a person reads as *the* cost of a session, and
    /// there is nowhere on the figure to say a message was skipped — so a smaller total must
    /// not be presented as complete. `TranscriptUsageService` turns the throw into visible
    /// `.partial`/`.failed` coverage; recovering would replace a visible gap with a hidden one.
    func testAnOpenCodeExportStillRefusesAnUnreadableMessage() {
        let data = Data(#"""
        {"info":{"id":"s1","directory":"/tmp"},"messages":[{"info":{
          "id":"m1","role":"assistant","providerID":"anthropic","modelID":"m",
          "cost":0.25,"tokens":{"input":1000,"output":50},"time":{"created":1754654400}}}, null]}
        """#.utf8)

        XCTAssertThrowsError(try OpenCodeUsageAdapter.records(fromExport: data)) { error in
            XCTAssertEqual(
                error as? OpenCodeUsageAdapter.Failure,
                .unreadableMessage(index: 1),
                "the refusal names which message stopped it, not just that something did"
            )
        }
    }

    /// The two failures stay distinct: a document this adapter does not recognise at all is not
    /// the same report as one it recognises and cannot finish.
    func testAnUnfamiliarExportIsStillADifferentFailure() {
        XCTAssertThrowsError(
            try OpenCodeUsageAdapter.records(fromExport: Data(#"{"info":{}}"#.utf8))
        ) { error in
            XCTAssertEqual(error as? OpenCodeUsageAdapter.Failure, .unfamiliarExport)
        }
    }

    /// A message that reads fine and simply is not a billable assistant turn is still skipped —
    /// that is the export saying so, rather than this reader failing to read it.
    func testAReadableNonAssistantMessageIsStillSkippedWithoutRefusingTheExport() throws {
        let data = Data(#"""
        {"info":{"id":"s1","directory":"/tmp"},"messages":[
          {"info":{"id":"u1","role":"user","time":{"created":1754654400}}},
          {"info":{"id":"m1","role":"assistant","providerID":"anthropic","modelID":"m",
           "cost":0.25,"tokens":{"input":1000,"output":50},"time":{"created":1754654400}}}]}
        """#.utf8)

        let records = try OpenCodeUsageAdapter.records(fromExport: data)

        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(records.first?.reportedCostUSD, 0.25)
    }

    // MARK: - Tool input: still refused

    /// REFUSES. A diff is read as *the* change a call will make. A hunk left out does not
    /// under-report the edit, it misdescribes it, and nothing on the card would say so.
    func testAMultiEditWithAnUnreadableHunkDrawsNoDiffAtAll() throws {
        let complete = try XCTUnwrap(EditDiff.lines(
            forTool: "MultiEdit",
            input: object(#"""
            {"edits":[{"old_string":"a","new_string":"A"},{"old_string":"b","new_string":"B"}]}
            """#)
        ))
        XCTAssertEqual(complete.filter { $0.kind == .added }.map(\.text), ["A", "B"])

        XCTAssertNil(EditDiff.lines(
            forTool: "MultiEdit",
            input: object(#"{"edits":[{"old_string":"a","new_string":"A"},null]}"#)
        ), "a null hunk withdraws the diff rather than drawing the half it can")

        XCTAssertNil(EditDiff.lines(
            forTool: "MultiEdit",
            input: object(#"{"edits":[{"old_string":"a","new_string":"A"},{"old_string":7}]}"#)
        ), "and an unreadable member of a hunk says exactly as much")
    }

    /// The file-level form follows, so the row falls back to naming the file rather than
    /// showing a change that omits part of itself.
    func testAMultiEditWithAnUnreadableHunkReportsNoFileChange() {
        let changes = EditDiff.fileChanges(
            forTool: "MultiEdit",
            input: object(#"""
            {"file_path":"/tmp/a.txt","edits":[{"old_string":"a","new_string":"A"},null]}
            """#)
        )

        XCTAssertTrue(changes.isEmpty)
    }

    /// REFUSES. A chart missing a series is not a smaller chart; the axis, the legend and the
    /// comparison all move around the missing one with nothing on the picture to admit it.
    func testAChartSpecRefusesASeriesListHoldingANull() throws {
        let complete = try XCTUnwrap(ChartSpec.decoded(
            fromToolNamed: "display_chart",
            input: object(#"""
            {"title":"Cost","categories":["a","b"],
             "series":[{"name":"before","values":[1,2]},{"name":"after","values":[3,4]}]}
            """#)
        ))
        XCTAssertEqual(complete.series.map(\.name), ["before", "after"])

        XCTAssertNil(ChartSpec.decoded(
            fromToolNamed: "display_chart",
            input: object(#"""
            {"title":"Cost","categories":["a","b"],
             "series":[{"name":"before","values":[1,2]},null]}
            """#)
        ))
    }

    /// REFUSES. Same reason as the Codex plan: this list is reduced to "step N of total", so
    /// every element is part of the denominator.
    func testARunProgressChecklistRefusesAnItemThatIsNotAnObject() throws {
        let complete = try XCTUnwrap(RunProgress.steps(
            tool: .todoWrite,
            input: object(#"""
            {"todos":[{"content":"one","status":"completed"},{"content":"two","status":"pending"}]}
            """#)
        ))
        XCTAssertEqual(complete.count, 2)

        XCTAssertNil(RunProgress.steps(
            tool: .todoWrite,
            input: object(#"{"todos":[{"content":"one","status":"completed"},null]}"#)
        ))
        XCTAssertNil(RunProgress.steps(
            tool: .plan,
            input: object(#"{"plan":[{"step":"one","status":"pending"},null]}"#)
        ))
    }

    // MARK: - Model catalog: recovered

    /// RECOVERS. The extra-model menu is a list of independent choices, and the reader already
    /// drops an entry with no usable `value` while keeping its neighbours.
    func testTheAdditionalModelListKeepsTheEntriesItCanRead() {
        let entries = WireList.objects(
            jsonValue(#"""
            [{"value":"claude-x","label":"X"},null,{"value":"claude-y","label":"Y"}]
            """#),
            site: "test",
            log: ThreadingLogger.agent
        )

        XCTAssertEqual(entries?.compactMap { $0["value"] as? String }, ["claude-x", "claude-y"])
    }

    // MARK: - Helpers

    private func jsonValue(_ text: String) -> Any? {
        try? JSONSerialization.jsonObject(with: Data(text.utf8), options: [.fragmentsAllowed])
    }

    private func object(_ text: String) -> [String: Any] {
        jsonValue(text) as? [String: Any] ?? [:]
    }

    private func codexEvents(method: String, _ text: String) -> [StreamEvent] {
        CodexAppServerEvent.streamEvents(method: method, parameters: object(text))
    }

    private func codexSubagentEvents(method: String, _ text: String) -> [SubagentEvent] {
        CodexSubagentEvent.events(
            method: method, parameters: object(text), rootThreadID: "t1"
        )
    }

    private func discoveredThreadIDs(_ events: [SubagentEvent]) -> [String] {
        events.compactMap { event in
            guard case .discovered(let descriptor) = event else { return nil }
            return descriptor.threadID
        }
    }

    private func status(of threadID: String, in events: [SubagentEvent]) -> SubagentStatus? {
        events.compactMap { event -> SubagentStatus? in
            guard case .state(let id, let status, _) = event, id == threadID else { return nil }
            return status
        }.first
    }
}

// MARK: - Skills Catalog

/// The Codex skills catalog, driven through the real transport because the three containers in
/// `applySkills` answer the array question three different ways and the disagreement only shows
/// end to end.
@MainActor
final class CodexSkillsWireArrayTests: XCTestCase {

    /// RECOVERS. `data` holds one entry per requested cwd and only this checkout's entry is ever
    /// read, so an unreadable entry belongs to some other scope — it must not delete this
    /// session's skills.
    func testAnUnreadableScopeEntryDoesNotHideThisCheckoutsSkills() {
        let discovered = expectation(description: "skill discovered past an unreadable scope")
        let session = CodexStreamSession(sessionID: SessionID(), workingDirectory: "/repo") {
            self.shellPlan(
                Self.handshake
                    + "read -r skills; printf '%s\\n' '{\"id\":3,\"result\":{\"data\":[null,{"
                    + "\"cwd\":\"/repo\",\"errors\":[],\"skills\":[{\"name\":\"release\","
                    + "\"path\":\"/repo/release/SKILL.md\",\"description\":\"Ship safely\","
                    + "\"enabled\":true,\"scope\":\"repo\"}]}]}}'; /bin/sleep 0.4"
            )
        }
        session.onComposerCapabilitiesChange = {
            guard session.composerCapabilities.contains(where: { $0.name == "release" }) else {
                return
            }
            discovered.fulfill()
        }

        session.start()
        wait(for: [discovered], timeout: 3)
        session.terminate()
    }

    /// REFUSES, and this is the one that must never be recovered. The guard trusts the catalog
    /// only when `errors` is **empty**, so skipping an error entry this client cannot open would
    /// turn "this scan reported problems" into "this scan was clean" and invert the check.
    ///
    /// The session is given a clean catalog first, so the assertion is about the *second*
    /// response being refused rather than about nothing ever arriving.
    func testAnUnreadableScanErrorStillRefusesTheCatalog() {
        let discovered = expectation(description: "first clean catalog adopted")
        let exited = expectation(description: "fixture consumed")
        let session = CodexStreamSession(sessionID: SessionID(), workingDirectory: "/repo") {
            self.shellPlan(
                Self.handshake
                    + "read -r skills; printf '%s\\n' '{\"id\":3,\"result\":{\"data\":[{"
                    + "\"cwd\":\"/repo\",\"errors\":[],\"skills\":[{\"name\":\"release\","
                    + "\"path\":\"/repo/release/SKILL.md\",\"description\":\"Ship safely\","
                    + "\"enabled\":true,\"scope\":\"repo\"}]}]}}'; "
                    + "printf '%s\\n' '{\"method\":\"skills/changed\",\"params\":{}}'; "
                    + "read -r rescan; printf '%s\\n' '{\"id\":4,\"result\":{\"data\":[{"
                    + "\"cwd\":\"/repo\",\"errors\":[null],\"skills\":[{\"name\":\"arrived\","
                    + "\"path\":\"/repo/arrived/SKILL.md\",\"description\":\"Should not show\","
                    + "\"enabled\":true,\"scope\":\"repo\"}]}]}}'; /bin/sleep 0.4"
            )
        }
        session.onComposerCapabilitiesChange = {
            guard session.composerCapabilities.contains(where: { $0.name == "release" }) else {
                return
            }
            discovered.fulfill()
        }
        session.onExit = { _ in exited.fulfill() }

        session.start()
        wait(for: [discovered, exited], timeout: 4)

        XCTAssertFalse(
            session.composerCapabilities.contains { $0.name == "arrived" },
            "an unreadable error entry must count as a scan error, not as a clean scan"
        )
        XCTAssertTrue(
            session.composerCapabilities.contains { $0.name == "release" },
            "and the last complete snapshot is kept"
        )
        session.terminate()
    }

    /// REFUSES. The loop already rejects the whole response for one skill whose metadata does
    /// not read, because a catalog missing a skill is indistinguishable from one that never had
    /// it — the user reaches for `$name` and is told there is no such skill.
    func testAnUnreadableSkillEntryStillRefusesTheCatalog() {
        let exited = expectation(description: "fixture consumed")
        let session = CodexStreamSession(sessionID: SessionID(), workingDirectory: "/repo") {
            self.shellPlan(
                Self.handshake
                    + "read -r skills; printf '%s\\n' '{\"id\":3,\"result\":{\"data\":[{"
                    + "\"cwd\":\"/repo\",\"errors\":[],\"skills\":[{\"name\":\"release\","
                    + "\"path\":\"/repo/release/SKILL.md\",\"description\":\"Ship safely\","
                    + "\"enabled\":true,\"scope\":\"repo\"},null]}]}}'; /bin/sleep 0.4"
            )
        }
        // Required, and not decoration: `requestSkillsIfNeeded` refuses to ask for a catalog
        // nobody is listening for, so a session with no handler never sends `skills/list`, the
        // fixture blocks on its `read`, and the test times out instead of testing anything.
        session.onComposerCapabilitiesChange = {}
        session.onExit = { _ in exited.fulfill() }

        session.start()
        wait(for: [exited], timeout: 3)

        XCTAssertFalse(session.composerCapabilities.contains { $0.name == "release" })
        session.terminate()
    }

    // MARK: - Helpers

    /// Answers `initialize` and `thread/open` so the session reaches its skills request.
    private static let handshake =
        "read -r initialize; printf '%s\\n' '{\"id\":1,\"result\":{}}'; "
        + "read -r initialized; read -r open_thread; "
        + "printf '%s\\n' '{\"id\":2,\"result\":{\"thread\":{\"id\":\"thread-1\","
        + "\"model\":\"gpt-test\"}}}'; "

    private func shellPlan(_ script: String) -> AgentLaunchPlan {
        AgentLaunchPlan(
            executable: "/bin/sh",
            arguments: ["-c", script],
            resumeState: .unavailable
        )
    }
}
