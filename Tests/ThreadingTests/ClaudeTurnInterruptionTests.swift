import XCTest
@testable import Threading

/// A Claude terminal turn the user stopped by hand.
///
/// The specimen is this app's own session `a056a54c` on CLI 2.1.238: `UserPromptSubmit` fired, the
/// user pressed Escape, and at 06:17:52.733Z the CLI appended one user record carrying
/// `interruptedMessageId` and the marker sentence — then nothing. No `Stop` arrived, the turn start
/// had already latched `reportsOwnActivity`, and the sidebar drew a spinner for a conversation the
/// user had stopped themselves. It was still drawing it two hours later.
final class ClaudeTurnInterruptionTests: XCTestCase {

    // MARK: - Reading it out of a transcript

    /// The specimen record, field for field.
    func testTheEscapeRecordIsReadAsAnInterruption() throws {
        let url = try transcript([interrupted()])

        let interruption = ClaudeTranscriptInterruption.newestInterruption(at: url)

        XCTAssertEqual(interruption?.recordID, "5ec9af64-841c-4829-a4a9-a1e9b580239f")
        XCTAssertEqual(interruption?.interruptedMessageID, "msg_011CeFQXqQY5Z7Ur3FJfZckF")
    }

    /// Escape pressed during a tool call writes a different sentence for the same fact. Matching
    /// the marker as a prefix is what keeps the two one answer.
    func testAnInterruptDuringAToolCallIsTheSameFact() throws {
        let url = try transcript([interrupted(text: "[Request interrupted by user for tool use]")])

        XCTAssertNotNil(ClaudeTranscriptInterruption.newestInterruption(at: url))
    }

    /// The interrupt that beats the first token names no message, because there is none to name —
    /// measured on 2.1.222. A reader insisting on the id answers nothing for it, which is the
    /// interrupt a user is most likely to press.
    func testAnInterruptBeforeTheModelSpokeIsStillAnInterruption() throws {
        let url = try transcript([interrupted(messageID: nil)])

        let interruption = ClaudeTranscriptInterruption.newestInterruption(at: url)

        XCTAssertNotNil(interruption)
        XCTAssertNil(interruption?.interruptedMessageID)
    }

    /// The CLI appends bookkeeping after the marker — the specimen's own tail. None of it is the
    /// conversation speaking, so none of it may hide the interruption.
    func testBookkeepingWrittenAfterTheMarkerDoesNotHideIt() throws {
        let url = try transcript([
            interrupted(),
            #"{"type":"file-history-snapshot"}"#,
            #"{"type":"attachment","attachment":{"type":"nested_memory"}}"#,
            #"{"type":"system","subtype":"turn_duration","durationMs":23}"#
        ])

        XCTAssertNotNil(ClaudeTranscriptInterruption.newestInterruption(at: url))
    }

    /// What does clear it: the conversation saying anything at all, in either direction. That is
    /// why nothing has to remember when the interrupt was — and why a session resumed onto a
    /// transcript that still ends on last week's Escape is not stopped by it.
    func testANewerMessageClearsTheInterruption() throws {
        let assistant = try transcript([interrupted(), assistantText("Carrying on")])
        let user = try transcript([interrupted(), userText("continue with what you did")])

        XCTAssertNil(ClaudeTranscriptInterruption.newestInterruption(at: assistant))
        XCTAssertNil(ClaudeTranscriptInterruption.newestInterruption(at: user))
    }

    /// A delegated child the parent stopped is not the parent stopping. Ending the parent's turn
    /// on a sidechain record would blank the row of a session that is still answering.
    func testASidechainInterruptIsNotTheSessionsInterrupt() throws {
        let url = try transcript([interrupted(isSidechain: true)])

        XCTAssertNil(ClaudeTranscriptInterruption.newestInterruption(at: url))
    }

    /// The tool result of a command that printed the marker is a `tool_result` block, not the
    /// conversation being interrupted — as this very test file's own session proved by grepping
    /// for the sentence and reading its own output back.
    func testAToolResultQuotingTheMarkerIsNotAnInterruption() throws {
        let url = try transcript([
            #"""
            {"type":"user","uuid":"result-1","message":{"role":"user","content":\#
            [{"tool_use_id":"toolu_1","type":"tool_result",\#
            "content":"[Request interrupted by user]"}]}}
            """#
        ])

        XCTAssertNil(ClaudeTranscriptInterruption.newestInterruption(at: url))
    }

    func testAnOrdinaryPromptIsNoInterruption() throws {
        let url = try transcript([userText("we added remove terminal sessions yesterday")])

        XCTAssertNil(ClaudeTranscriptInterruption.newestInterruption(at: url))
    }

    /// The rule the reader's change-gate rests on. `TranscriptFactReader` calls back only when the
    /// answer *moves*, and two interrupts in a row are otherwise identical records — so without
    /// the record's own identity the second equals the first, no callback fires, and that session
    /// strands `working`, which is the failure this reader exists to end.
    func testASecondInterruptWithIdenticalWordsIsADifferentAnswer() throws {
        let first = try transcript([interrupted(uuid: "record-1", messageID: nil)])
        let second = try transcript([
            interrupted(uuid: "record-1", messageID: nil),
            userText("try again"),
            interrupted(uuid: "record-2", messageID: nil)
        ])

        let before = ClaudeTranscriptInterruption.newestInterruption(at: first)
        let after = ClaudeTranscriptInterruption.newestInterruption(at: second)

        XCTAssertEqual(
            before?.interruptedMessageID,
            after?.interruptedMessageID,
            "the specimen stops the same way twice"
        )
        XCTAssertNotEqual(before, after, "each interrupt has to move the reader's answer")
    }

    func testATranscriptThatWasNeverWrittenAnswersNothingRatherThanFailing() {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("never-written-\(UUID().uuidString).jsonl")

        XCTAssertNil(ClaudeTranscriptInterruption.newestInterruption(at: url))
    }

    /// Nothing touches the disk on the main thread: the terminal-output callback that asks for
    /// this runs per burst.
    @MainActor
    func testTheAnswerArrivesThroughTheBackgroundRead() throws {
        let url = try transcript([interrupted()])
        ClaudeTranscriptInterruption.forgetAll()
        defer { ClaudeTranscriptInterruption.forgetAll() }

        let landed = expectation(description: "transcript read")
        ClaudeTranscriptInterruption.revalidate(at: url) { interruption in
            XCTAssertEqual(interruption?.interruptedMessageID, "msg_011CeFQXqQY5Z7Ur3FJfZckF")
            landed.fulfill()
        }
        wait(for: [landed], timeout: 5)
    }

    // MARK: - Crossing the activity edge

    /// The boundary `Stop` never delivered, crossed exactly where it would have been: the turn is
    /// over, the CLI is back at its prompt, and a session being watched needs no mark.
    @MainActor
    func testAnInterruptionEndsTheReportedTurn() {
        let tracker = SessionActivityTracker()
        tracker.markRunning()
        tracker.isVisible = true
        tracker.noteTurnStarted()

        XCTAssertEqual(tracker.activity, .working)
        XCTAssertTrue(tracker.noteTurnInterrupted(turn: tracker.turnGeneration))
        XCTAssertEqual(tracker.activity, .idle)
        XCTAssertFalse(tracker.runtimeSnapshot.hasOpenTurn)
    }

    /// Off screen it takes the unread mark, settling exactly as Codex's interruption and as `Stop`
    /// itself do. Escape can be pressed through the remote mirror as readily as at the keyboard,
    /// so the row that stopped is still a result nobody has seen.
    @MainActor
    func testAnInterruptionSeenOffScreenTakesTheUnreadMark() {
        let tracker = SessionActivityTracker()
        tracker.markRunning()
        tracker.isVisible = false
        tracker.noteTurnStarted()

        XCTAssertTrue(tracker.noteTurnInterrupted(turn: tracker.turnGeneration))
        XCTAssertEqual(tracker.activity, .needsAttention)
    }

    /// The tail scan is asynchronous, and Claude names no turn in its hook payload — so the count
    /// of turns begun is what stands in for the identity Codex supplies. A read that outlived the
    /// turn it was made for may not stop the work now in flight.
    @MainActor
    func testAStaleInterruptionCannotEndANewerTurn() {
        let tracker = SessionActivityTracker()
        tracker.markRunning()
        tracker.isVisible = true
        tracker.noteTurnStarted()
        let interruptedTurn = tracker.turnGeneration
        tracker.noteTurnStarted()

        XCTAssertFalse(tracker.noteTurnInterrupted(turn: interruptedTurn))
        XCTAssertEqual(tracker.activity, .working)
        XCTAssertTrue(tracker.runtimeSnapshot.hasOpenTurn)
    }

    /// A fallback, not a second activity source. A session whose hooks never arrived is driven by
    /// its output, and handing it a transcript fact would end turns the byte heuristic still owns.
    @MainActor
    func testAnInterruptionCannotEndAnInferredSessionsTurn() {
        let tracker = SessionActivityTracker()
        tracker.markRunning()
        tracker.isVisible = true
        tracker.recordOutput(byteCount: ActivityDefaults.workingByteThreshold + 1)

        XCTAssertEqual(tracker.activity, .working)
        XCTAssertFalse(tracker.reportsOwnActivity)
        XCTAssertFalse(tracker.noteTurnInterrupted(turn: tracker.turnGeneration))
        XCTAssertEqual(tracker.activity, .working)
    }

    /// A resumed conversation whose transcript still ends on an old Escape has no turn to end, and
    /// must not be marked for one.
    @MainActor
    func testAnInterruptionCannotEndASessionThatIsNotWorking() {
        let tracker = SessionActivityTracker()
        tracker.markRunning()
        tracker.isVisible = true
        tracker.noteTurnStarted()
        tracker.noteTurnFinished()

        XCTAssertEqual(tracker.activity, .idle)
        XCTAssertFalse(tracker.noteTurnInterrupted(turn: tracker.turnGeneration))
        XCTAssertEqual(tracker.activity, .idle)
    }

    // MARK: - The table and its contract

    /// The capability is what the output callback asks before it resolves a transcript path. Only
    /// Claude writes this record shape; Codex's own missing boundary names a turn, and its reader
    /// is declared separately.
    @MainActor
    func testOnlyClaudeDeclaresAnInterruptedMessageRecord() {
        for kind in AgentKind.allCases {
            XCTAssertEqual(
                kind.supports(.transcriptInterruptedMessageRecord),
                kind == .claude,
                "\(kind) disagrees about whether its interrupted turns are readable"
            )
        }
    }

    // MARK: - Helpers

    /// The specimen record, field for field, as 2.1.238 wrote it.
    private func interrupted(
        uuid: String = "5ec9af64-841c-4829-a4a9-a1e9b580239f",
        messageID: String? = "msg_011CeFQXqQY5Z7Ur3FJfZckF",
        text: String = "[Request interrupted by user]",
        isSidechain: Bool = false
    ) -> String {
        let interruptedMessage = messageID.map { #""interruptedMessageId":"\#($0)","# } ?? ""
        return #"""
        {"type":"user","uuid":"\#(uuid)","isSidechain":\#(isSidechain),\#(interruptedMessage)\#
        "promptId":"51b70a85-b5c3-4b7d-936f-55d93ec53fc9",\#
        "message":{"role":"user","content":[{"type":"text","text":"\#(text)"}]}}
        """#
    }

    private func assistantText(_ text: String) -> String {
        #"{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"\#(text)"}]}}"#
    }

    private func userText(_ text: String) -> String {
        #"{"type":"user","uuid":"prompt-\#(abs(text.hashValue))","message":{"role":"user","content":"\#(text)"}}"#
    }

    private func transcript(_ lines: [String]) throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("turn-interruption-\(UUID().uuidString).jsonl")
        try (lines.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }
}
