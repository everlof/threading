import XCTest
@testable import Threading

/// A Claude terminal turn the provider refused for something other than the account's allowance.
///
/// The specimen is this app's own session `e7a26edf` on CLI 2.1.226: `UserPromptSubmit` fired at
/// 12:26:02.464, an `authentication_failed` record landed 23 ms later saying "Login expired ·
/// Please run /login", a `turn_duration` was written beside it, and no `Stop` ever came. The turn
/// start had already latched `reportsOwnActivity`, so the sidebar drew a spinner for a
/// conversation that had stopped.
final class ClaudeTurnRefusalTests: XCTestCase {

    // MARK: - Reading it out of a transcript

    /// The whole record, field for field, as 2.1.226 wrote it — including the absent
    /// `apiErrorStatus`, which is why neither field may be required.
    func testTheExpiredLoginRecordIsReadAsARefusal() throws {
        let url = try transcript([expiredLogin()])

        let refusal = ClaudeTranscriptTurnRefusal.newestRefusal(at: url)

        XCTAssertEqual(refusal?.reason, "authentication_failed")
        XCTAssertEqual(refusal?.message, "Login expired · Please run /login")
        XCTAssertEqual(refusal?.recordID, "9e8a3095-20fc-4663-97b2-68b829098c2e")
    }

    /// The other half of the same record shape belongs to `ClaudeTranscriptUsageLimit`, which has
    /// a park, a reset and a chooser to answer. Admitting it here as well would end the turn from
    /// under the recovery before it could read the screen.
    func testASpentAllowanceIsLeftToTheLimitReader() throws {
        let url = try transcript([rateLimited()])

        XCTAssertNil(ClaudeTranscriptTurnRefusal.newestRefusal(at: url))
        XCTAssertNotNil(ClaudeTranscriptUsageLimit.newestStop(at: url))
    }

    /// The two readers partition the record shape rather than overlapping on it: every failure is
    /// read by exactly one of them, whichever class the CLI names.
    func testADroppedConnectionIsARefusalTheLimitReaderDeclines() throws {
        let url = try transcript([
            #"""
            {"type":"assistant","uuid":"conn-1","isApiErrorMessage":true,\#
            "error":"connection_error","apiErrorStatus":500,\#
            "message":{"content":[{"type":"text","text":"API Error"}]}}
            """#
        ])

        XCTAssertEqual(ClaudeTranscriptTurnRefusal.newestRefusal(at: url)?.reason, "connection_error")
        XCTAssertNil(ClaudeTranscriptUsageLimit.newestStop(at: url))
    }

    /// The CLI appends bookkeeping after the failure — the specimen's exact tail. None of it is
    /// the conversation speaking, so none of it may hide the refusal.
    func testBookkeepingWrittenAfterTheFailureDoesNotHideIt() throws {
        let url = try transcript([
            expiredLogin(),
            #"{"type":"system","subtype":"turn_duration","durationMs":23,"messageCount":5}"#,
            #"{"type":"file-history-snapshot"}"#
        ])

        XCTAssertNotNil(ClaudeTranscriptTurnRefusal.newestRefusal(at: url))
    }

    /// What does clear it: the conversation saying anything at all, in either direction. That is
    /// why nothing has to remember when the failure was — and why a session resumed after an
    /// expired login is not stopped by the record its previous run left behind.
    func testANewerMessageClearsTheRefusal() throws {
        let assistant = try transcript([expiredLogin(), assistantText("Carrying on")])
        let user = try transcript([expiredLogin(), userText("/login")])

        XCTAssertNil(ClaudeTranscriptTurnRefusal.newestRefusal(at: assistant))
        XCTAssertNil(ClaudeTranscriptTurnRefusal.newestRefusal(at: user))
    }

    /// A delegated child whose request fails is reported to its parent as a failed task, and the
    /// parent goes on working. Ending the parent's turn on a child's failure would blank the row
    /// of a session that is still answering.
    func testASidechainFailureIsNotTheSessionsFailure() throws {
        let url = try transcript([expiredLogin(isSidechain: true), assistantText("still here")])

        XCTAssertNil(ClaudeTranscriptTurnRefusal.newestRefusal(at: url))
    }

    func testAnOrdinaryAssistantMessageIsNoRefusal() throws {
        let url = try transcript([assistantText("Here is the answer")])

        XCTAssertNil(ClaudeTranscriptTurnRefusal.newestRefusal(at: url))
    }

    /// The rule the reader's change-gate rests on. `TranscriptFactReader` calls back only when the
    /// answer *moves*, and an expired login refuses every turn with the same class and the same
    /// sentence — so without the record's own identity the second refusal is equal to the first,
    /// no callback fires, and that session strands `working`. The user record between them is not
    /// enough: it lands half a second before the failure, well inside one settled output burst.
    func testASecondFailureWithIdenticalWordsIsADifferentAnswer() throws {
        let first = try transcript([expiredLogin(uuid: "record-1")])
        let second = try transcript([
            expiredLogin(uuid: "record-1"),
            userText("try again"),
            expiredLogin(uuid: "record-2")
        ])

        let before = ClaudeTranscriptTurnRefusal.newestRefusal(at: first)
        let after = ClaudeTranscriptTurnRefusal.newestRefusal(at: second)

        XCTAssertEqual(before?.message, after?.message, "the specimen fails the same way twice")
        XCTAssertNotEqual(before, after, "each failure has to move the reader's answer")
    }

    func testATranscriptThatWasNeverWrittenAnswersNothingRatherThanFailing() {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("never-written-\(UUID().uuidString).jsonl")

        XCTAssertNil(ClaudeTranscriptTurnRefusal.newestRefusal(at: url))
    }

    /// Nothing touches the disk on the main thread: the terminal-output callback that asks for
    /// this runs per burst.
    @MainActor
    func testTheAnswerArrivesThroughTheBackgroundRead() throws {
        let url = try transcript([expiredLogin()])
        ClaudeTranscriptTurnRefusal.forgetAll()
        defer { ClaudeTranscriptTurnRefusal.forgetAll() }

        let landed = expectation(description: "transcript read")
        ClaudeTranscriptTurnRefusal.revalidate(at: url) { refusal in
            XCTAssertEqual(refusal?.reason, "authentication_failed")
            landed.fulfill()
        }
        wait(for: [landed], timeout: 5)
    }

    // MARK: - Crossing the activity edge

    /// The boundary `Stop` never delivered, crossed exactly where it would have been: the turn is
    /// over, the CLI is back at its prompt, and a session being watched needs no mark.
    @MainActor
    func testARefusalEndsTheReportedTurn() {
        let tracker = SessionActivityTracker()
        tracker.markRunning()
        tracker.isVisible = true
        tracker.noteTurnStarted()

        XCTAssertEqual(tracker.activity, .working)
        XCTAssertTrue(tracker.noteTurnRefused(turn: tracker.turnGeneration))
        XCTAssertEqual(tracker.activity, .idle)
        XCTAssertFalse(tracker.runtimeSnapshot.hasOpenTurn)
    }

    /// Off screen it takes the unread mark, which is the only thing that will tell the user their
    /// login expired an hour ago. Deliberately not `limitReached`: nothing here says the account
    /// is spent, and a row claiming so sends them to a usage dashboard to explain a login.
    @MainActor
    func testARefusalSeenOffScreenTakesTheUnreadMark() {
        let tracker = SessionActivityTracker()
        tracker.markRunning()
        tracker.isVisible = false
        tracker.noteTurnStarted()

        XCTAssertTrue(tracker.noteTurnRefused(turn: tracker.turnGeneration))
        XCTAssertEqual(tracker.activity, .needsAttention)
    }

    /// The tail scan is asynchronous, and Claude names no turn in its hook payload — so the count
    /// of turns begun is what stands in for the identity Codex supplies. A read that outlived the
    /// turn it was made for may not stop the work now in flight.
    @MainActor
    func testAStaleRefusalCannotEndANewerTurn() {
        let tracker = SessionActivityTracker()
        tracker.markRunning()
        tracker.isVisible = true
        tracker.noteTurnStarted()
        let refusedTurn = tracker.turnGeneration
        tracker.noteTurnStarted()

        XCTAssertFalse(tracker.noteTurnRefused(turn: refusedTurn))
        XCTAssertEqual(tracker.activity, .working)
        XCTAssertTrue(tracker.runtimeSnapshot.hasOpenTurn)
    }

    /// A fallback, not a second activity source. A session whose hooks never arrived is driven by
    /// its output, and handing it a transcript fact would end turns the byte heuristic still owns.
    @MainActor
    func testARefusalCannotEndAnInferredSessionsTurn() {
        let tracker = SessionActivityTracker()
        tracker.markRunning()
        tracker.isVisible = true
        tracker.recordOutput(byteCount: ActivityDefaults.workingByteThreshold + 1)

        XCTAssertEqual(tracker.activity, .working)
        XCTAssertFalse(tracker.reportsOwnActivity)
        XCTAssertFalse(tracker.noteTurnRefused(turn: tracker.turnGeneration))
        XCTAssertEqual(tracker.activity, .working)
    }

    /// A resumed conversation whose transcript still ends on last week's expired login has no turn
    /// to end, and must not be marked for one.
    @MainActor
    func testARefusalCannotEndASessionThatIsNotWorking() {
        let tracker = SessionActivityTracker()
        tracker.markRunning()
        tracker.isVisible = true
        tracker.noteTurnStarted()
        tracker.noteTurnFinished()

        XCTAssertEqual(tracker.activity, .idle)
        XCTAssertFalse(tracker.noteTurnRefused(turn: tracker.turnGeneration))
        XCTAssertEqual(tracker.activity, .idle)
    }

    // MARK: - The table and its contract

    /// The capability is what the output callback asks before it resolves a transcript path. Only
    /// Claude writes this record; Codex's own missing boundary is an interruption, and its reader
    /// is declared separately.
    @MainActor
    func testOnlyClaudeDeclaresARefusedTurnRecord() {
        for kind in AgentKind.allCases {
            XCTAssertEqual(
                kind.supports(.transcriptRefusedTurnRecord),
                kind == .claude,
                "\(kind) disagrees about whether its refused turns are readable"
            )
        }
    }

    // MARK: - Helpers

    /// The specimen record, field for field — no `apiErrorStatus`, because 2.1.226 wrote none.
    private func expiredLogin(
        uuid: String = "9e8a3095-20fc-4663-97b2-68b829098c2e",
        isSidechain: Bool = false
    ) -> String {
        #"""
        {"type":"assistant","uuid":"\#(uuid)","isSidechain":\#(isSidechain),\#
        "isApiErrorMessage":true,"error":"authentication_failed",\#
        "message":{"model":"<synthetic>","role":"assistant",\#
        "content":[{"type":"text","text":"Login expired · Please run /login"}]}}
        """#
    }

    private func rateLimited() -> String {
        #"""
        {"type":"assistant","uuid":"limit-1","isApiErrorMessage":true,"error":"rate_limit",\#
        "apiErrorStatus":429,"message":{"model":"<synthetic>","role":"assistant",\#
        "content":[{"type":"text","text":"You've hit your session limit · resets 1:20pm"}]}}
        """#
    }

    private func assistantText(_ text: String) -> String {
        #"{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"\#(text)"}]}}"#
    }

    private func userText(_ text: String) -> String {
        #"{"type":"user","message":{"role":"user","content":"\#(text)"}}"#
    }

    private func transcript(_ lines: [String]) throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("turn-refusal-\(UUID().uuidString).jsonl")
        try (lines.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }
}
