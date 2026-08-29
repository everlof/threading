import XCTest
@testable import Threading

/// The rules that make the status line readable rather than merely varied: every word says
/// "busy", no word repeats until the rest have been used, and none repeats back to back.
final class WorkingWordsTests: XCTestCase {

    // MARK: - Vocabulary

    func testVocabularyIsDistinctAndNonEmpty() {
        XCTAssertEqual(Set(WorkingWords.all).count, WorkingWords.all.count, "duplicate word")
        XCTAssertFalse(WorkingWords.all.contains { $0.trimmingCharacters(in: .whitespaces).isEmpty })
    }

    /// A word without its ellipsis reads as a finished state rather than an ongoing one, which
    /// is the opposite of what the status line is for.
    func testEveryWordTrailsOff() {
        for word in WorkingWords.all {
            XCTAssertTrue(word.hasSuffix("…"), "\(word) does not read as ongoing")
        }
    }

    /// The familiar word is kept: the point is variety around it, not replacing it.
    func testVocabularyKeepsThinking() {
        XCTAssertTrue(WorkingWords.all.contains("Thinking…"))
    }

    // MARK: - Cycle

    func testDealsEveryWordBeforeRepeatingAny() {
        var cycle = WorkingWordCycle()
        let dealt = (0..<WorkingWords.all.count).map { _ in cycle.next() }

        XCTAssertEqual(Set(dealt), Set(WorkingWords.all), "a word repeated before the bag emptied")
    }

    func testRefillsRatherThanRunningOut() {
        var cycle = WorkingWordCycle()
        let dealt = (0..<(WorkingWords.all.count * 3)).map { _ in cycle.next() }

        XCTAssertEqual(dealt.count, WorkingWords.all.count * 3)
        XCTAssertFalse(dealt.contains(""))
    }

    /// The seam between two bags is the one place the shuffle alone does not prevent a repeat.
    /// Two words make it deterministic: any correct cycle can only alternate.
    func testNeverRepeatsAcrossTheSeam() {
        var cycle = WorkingWordCycle(words: ["one…", "two…"])
        let dealt = (0..<20).map { _ in cycle.next() }

        for (previous, next) in zip(dealt, dealt.dropFirst()) {
            XCTAssertNotEqual(previous, next, "the same word twice running")
        }
    }

    func testSingleWordCycleStillAnswers() {
        var cycle = WorkingWordCycle(words: ["only…"])

        XCTAssertEqual(cycle.next(), "only…")
        XCTAssertEqual(cycle.next(), "only…")
    }

    /// `next()` returns a word rather than an optional, so an empty vocabulary has to resolve
    /// to something at construction rather than at the call that needs a label.
    func testEmptyVocabularyFallsBackToTheRealOne() {
        var cycle = WorkingWordCycle(words: [])

        XCTAssertTrue(WorkingWords.all.contains(cycle.next()))
    }

    // MARK: - Turn Receipt

    func testWorkingStatusTicksWithEffort() {
        XCTAssertEqual(
            TurnStatusText.working(word: "Pondering…", elapsed: 89.9, effort: "xhigh"),
            "Pondering…  (1m 29s · xhigh effort)"
        )
    }

    func testFinishedStatusKeepsTheLastRoundTripVisible() {
        let metrics = TurnMetrics(duration: 89.9, outputTokens: 3_149, effort: "xhigh")

        XCTAssertEqual(
            TurnStatusText.ready(model: nil, lastTurn: metrics),
            "Ready · last turn 1m 29s · ↓ 3.1k tokens · xhigh effort"
        )
    }

    func testFinishedStatusSuppressesAZeroSecondReceipt() {
        XCTAssertEqual(
            TurnStatusText.ready(model: nil, lastTurn: TurnMetrics(duration: 0.7)),
            "Ready"
        )
        XCTAssertEqual(
            TurnStatusText.ready(
                model: nil,
                lastTurn: TurnMetrics(duration: 0.7, outputTokens: 12)
            ),
            "Ready · last turn ↓ 12 tokens"
        )
    }

    func testReceiptFormattingScalesWithoutFalsePrecision() {
        XCTAssertEqual(TurnStatusText.duration(7_445), "2h 4m 5s")
        XCTAssertEqual(TurnStatusText.tokenCount(999), "999")
        XCTAssertEqual(TurnStatusText.tokenCount(12_000), "12k")
        XCTAssertEqual(TurnStatusText.tokenCount(1_250_000), "1.3m")
    }

    // MARK: - Run Progress

    func testCodexPlanReportsTheActiveStep() throws {
        let progress = try XCTUnwrap(RunProgress(tool: .plan, input: [
            "plan": [
                ["step": "Inspect", "status": "completed"],
                ["step": "Implement", "status": "in_progress"],
                ["step": "Verify", "status": "pending"],
                ["step": "Document", "status": "pending"],
            ]
        ]))

        assertSummary(progress, equals: RunProgress(step: 2, total: 4))
        XCTAssertEqual(progress.steps.map(\.title), ["Inspect", "Implement", "Verify", "Document"])
        XCTAssertEqual(progress.currentStep?.title, "Implement")
        XCTAssertEqual(progress.compactLabel, "Implement · 2 of 4")
        XCTAssertEqual(progress.label, "Step 2 / 4")
    }

    func testClaudeTodoUsesTheSameProgressModel() throws {
        let progress = try XCTUnwrap(RunProgress(tool: .todoWrite, input: [
            "todos": [
                ["content": "Inspect", "status": "completed"],
                ["content": "Implement", "status": "completed"],
                ["content": "Verify", "status": "pending"],
            ]
        ]))

        assertSummary(progress, equals: RunProgress(step: 3, total: 3))
        XCTAssertEqual(progress.steps.map(\.title), ["Inspect", "Implement", "Verify"])
    }

    func testUnrelatedAndEmptyToolsDoNotInventProgress() {
        XCTAssertNil(RunProgress(tool: .bash, input: ["cmd": "swift test"]))
        XCTAssertNil(RunProgress(tool: .plan, input: ["plan": []]))
    }

    func testLegacySummariesRetainTheirReportedCounts() {
        let step = RunProgress(step: 2, total: 4)
        XCTAssertEqual(step.completed, 1)
        XCTAssertEqual(step.active, 1)

        let tasks = RunProgress(completed: 3, active: 2, total: 8)
        XCTAssertEqual(tasks.completed, 3)
        XCTAssertEqual(tasks.active, 2)
    }

    func testClaudeIncrementalTasksReconcileCreateResultsAndUpdates() throws {
        var reducer = RunProgressReducer()

        assertSummary(
            try changedProgress(reducer.apply(
                toolUseID: "create-1",
                tool: .taskCreate,
                input: ["subject": "Inspect", "activeForm": "Inspecting"]
            )),
            equals: RunProgress(step: 1, total: 1)
        )
        assertSummary(
            try changedProgress(reducer.apply(result: ToolResult(
                toolUseID: "create-1",
                text: "Task #1 created successfully: Inspect",
                isError: false
            ))),
            equals: RunProgress(step: 1, total: 1)
        )

        _ = reducer.apply(
            toolUseID: "create-2",
            tool: .taskCreate,
            input: ["subject": "Implement"]
        )
        _ = reducer.apply(result: ToolResult(
            toolUseID: "create-2",
            text: "Task #2 created successfully: Implement",
            isError: false
        ))
        assertSummary(
            try changedProgress(reducer.apply(
                toolUseID: "update-1",
                tool: .taskUpdate,
                input: ["taskId": "1", "status": "completed"]
            )),
            equals: RunProgress(step: 2, total: 2)
        )
        assertSummary(
            try changedProgress(reducer.apply(
                toolUseID: "update-2",
                tool: .taskUpdate,
                input: ["taskId": "2", "status": "in_progress"]
            )),
            equals: RunProgress(step: 2, total: 2)
        )
    }

    func testClaudeFailedCreateAndDeletedTaskRemoveTheirProgressEntries() throws {
        var reducer = RunProgressReducer()
        _ = reducer.apply(
            toolUseID: "create-1",
            tool: .taskCreate,
            input: ["subject": "Temporary"]
        )
        XCTAssertNil(try changedProgress(reducer.apply(result: ToolResult(
            toolUseID: "create-1",
            text: "Could not create task",
            isError: true
        ))))

        _ = reducer.apply(
            toolUseID: "update-unknown",
            tool: .taskUpdate,
            input: ["taskId": "7", "status": "in_progress", "subject": "Recovered"]
        )
        XCTAssertNil(try changedProgress(reducer.apply(
            toolUseID: "delete-7",
            tool: .taskUpdate,
            input: ["taskId": "7", "status": "deleted"]
        )))
    }

    func testClaudeFailedTaskUpdateClearsItsOptimisticProgress() throws {
        var reducer = RunProgressReducer()
        _ = reducer.apply(
            toolUseID: "update-1",
            tool: .taskUpdate,
            input: ["taskId": "1", "status": "in_progress", "subject": "Implement"]
        )

        XCTAssertNil(try changedProgress(reducer.apply(result: ToolResult(
            toolUseID: "update-1",
            text: "Task update failed",
            isError: true
        ))))
        XCTAssertNil(reducer.snapshot)
    }

    func testParallelClaudeTasksUseCountsInsteadOfInventingALinearStep() throws {
        var reducer = RunProgressReducer()
        _ = reducer.apply(
            toolUseID: "update-1",
            tool: .taskUpdate,
            input: ["taskId": "1", "status": "in_progress", "subject": "Audit"]
        )
        let progress = try XCTUnwrap(try changedProgress(reducer.apply(
            toolUseID: "update-2",
            tool: .taskUpdate,
            input: ["taskId": "2", "status": "in_progress", "subject": "Test"]
        )))

        XCTAssertNil(progress.step)
        XCTAssertEqual(progress.label, "0 / 2 done · 2 active")
        XCTAssertEqual(progress.currentPosition, 1)
        XCTAssertEqual(progress.compactLabel, "Audit · 1 of 2")
    }

    // MARK: - Context Meter

    func testContextReadsAsAPercentageOnlyWhenTheWindowIsKnown() {
        // Codex states its window; Claude does not, and inventing one per model name is how
        // t3code earned its wrong-context-math bug (#2034). Absolute tokens are honest.
        XCTAssertEqual(TurnStatusText.context(tokens: 108_291, window: 258_400), "42% context")
        XCTAssertEqual(TurnStatusText.context(tokens: 216_000, window: nil), "216k context")
        XCTAssertEqual(TurnStatusText.context(tokens: 950, window: nil), "950 context")
    }

    func testContextNeverReadsPastFull() {
        // A reading past the window is the accounting drifting, not a number to show.
        XCTAssertEqual(TurnStatusText.context(tokens: 300_000, window: 258_400), "100% context")
    }

    func testContextWarnsPastNinetyPercent() {
        XCTAssertTrue(TurnStatusText.contextIsNearlyFull(tokens: 233_000, window: 258_400))
        XCTAssertFalse(TurnStatusText.contextIsNearlyFull(tokens: 200_000, window: 258_400))
        // With no window there is no fraction to warn about.
        XCTAssertFalse(TurnStatusText.contextIsNearlyFull(tokens: 999_999, window: nil))
    }

    private func changedProgress(_ update: RunProgressReducer.Update) throws -> RunProgress? {
        guard case .changed(let progress) = update else {
            throw ProgressTestError.unchanged
        }
        return progress
    }

    private func assertSummary(
        _ actual: RunProgress?,
        equals expected: RunProgress,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(actual?.step, expected.step, file: file, line: line)
        XCTAssertEqual(actual?.total, expected.total, file: file, line: line)
        XCTAssertEqual(actual?.label, expected.label, file: file, line: line)
    }

    private enum ProgressTestError: Error {
        case unchanged
    }
}
