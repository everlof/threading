import XCTest
@testable import Threading

/// Reading back the posture a terminal session is *in*, rather than the one it launched with.
///
/// Nothing in the app showed the permission mode of a running terminal. The record on the
/// session states what the next launch will ask for, and Claude's own Shift+Tab moves the live
/// posture without telling this app — so the only honest source is the transcript, where Claude
/// writes `{"type":"permission-mode","permissionMode":…}` down. These hold the properties that
/// make reading it usable: the newest record wins, the search is bounded, Claude's own spelling
/// of Manual survives the round trip, and anything unrecognised stays unrecognised.
final class ObservedPermissionModeTests: XCTestCase {

    // MARK: - Reading backwards

    /// The posture is asserted repeatedly rather than only when it changes — measured at 9 to 48
    /// records per transcript — so the newest one is the answer and the ones behind it are
    /// history.
    func testTheNewestRecordedModeWins() throws {
        let url = try transcript([
            mode("plan"),
            mode("acceptEdits"),
            mode("auto"),
            toolResult("bash")
        ])

        XCTAssertEqual(ClaudeTranscriptPermissionMode.newestMode(at: url), .auto)
    }

    /// Claude hands back its **internal** name for Manual, in the transcript as on its control
    /// channel. A reader that took only the external `manual` would report "unknown" for the
    /// most ordinary posture there is.
    func testClaudesOwnSpellingOfManualReadsAsManual() throws {
        XCTAssertEqual(
            ClaudeTranscriptPermissionMode.newestMode(at: try transcript([mode("default")])),
            .manual
        )
        XCTAssertEqual(
            ClaudeTranscriptPermissionMode.newestMode(at: try transcript([mode("manual")])),
            .manual
        )
    }

    /// Every one of the six survives the round trip out to a launch flag and back, which is the
    /// property that keeps the reader and `launchFlags(for:)` from drifting apart in the one
    /// direction the compiler cannot check.
    func testEveryModeSurvivesItsOwnRuntimesVocabulary() {
        for mode in AgentPermissionMode.allCases {
            XCTAssertEqual(
                AgentPermissionMode(externalValue: mode.claudeFlagValue, for: .claude),
                mode,
                "Claude's own value for \(mode) did not read back as it"
            )
            XCTAssertEqual(
                AgentPermissionMode(externalValue: mode.grokFlagValue, for: .grok),
                mode,
                "Grok's own value for \(mode) did not read back as it"
            )
        }
    }

    /// A newer CLI's seventh mode must leave the card silent rather than get rounded to a
    /// posture it is not. The raw value is still readable, which is what tells a stated-but-
    /// unknown mode apart from a transcript that states none.
    func testAnUnknownValueIsNotRoundedToAKnownMode() throws {
        let url = try transcript([mode("supervised")])

        XCTAssertEqual(ClaudeTranscriptPermissionMode.newestRecordedValue(at: url), "supervised")
        XCTAssertNil(ClaudeTranscriptPermissionMode.newestMode(at: url))
    }

    /// Codex spends the posture on two axes and emits no single value naming one of the six, so
    /// there is nothing for a value-shaped reader to interpret — nil by construction rather than
    /// by omission.
    func testARuntimeWithNoSharedVocabularyReadsNothing() {
        XCTAssertNil(AgentPermissionMode(externalValue: "auto", for: .codex))
        XCTAssertNil(AgentPermissionMode(externalValue: "auto", for: .openCode))
    }

    /// The bound is the point, and the measurement behind it is that the newest record sat
    /// between 101 bytes and 20 KB from the end of real transcripts. A posture pushed past the
    /// budget by one enormous turn answers nothing rather than triggering a whole-file read.
    func testAModeBeyondTheScanBudgetIsNotReachedFor() throws {
        let url = try transcript([
            mode("plan"),
            toolResult(String(repeating: "x", count: TranscriptPermissionModeDefaults.scanBytes)),
            toolResult("tail")
        ])

        XCTAssertNil(ClaudeTranscriptPermissionMode.newestMode(at: url))
    }

    func testATranscriptWithNoPostureRecordAnswersNothing() throws {
        let url = try transcript([toolResult("read"), toolResult("grep")])

        XCTAssertNil(ClaudeTranscriptPermissionMode.newestRecordedValue(at: url))
        XCTAssertNil(ClaudeTranscriptPermissionMode.newestMode(at: url))
    }

    func testAnAbsentTranscriptAnswersNothingRatherThanFailing() {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("never-written-\(UUID().uuidString).jsonl")

        XCTAssertNil(ClaudeTranscriptPermissionMode.newestMode(at: url))
    }

    // MARK: - Answering the card

    /// The order the card depends on: nothing on the main thread before the paint, the answer in
    /// memory after it.
    @MainActor
    func testTheAnswerIsKnownOnlyAfterTheBackgroundReadLands() throws {
        let url = try transcript([mode("plan"), toolResult("read")])
        ClaudeTranscriptPermissionMode.forgetAll()
        defer { ClaudeTranscriptPermissionMode.forgetAll() }

        XCTAssertNil(
            ClaudeTranscriptPermissionMode.known(at: url),
            "the card must not wait on a file read"
        )

        let landed = expectation(description: "transcript read")
        ClaudeTranscriptPermissionMode.revalidate(at: url) { mode in
            XCTAssertEqual(mode, .plan)
            landed.fulfill()
        }
        wait(for: [landed], timeout: 5)

        XCTAssertEqual(ClaudeTranscriptPermissionMode.known(at: url), .plan)
    }

    /// The size gate, from the outside: a file that has not grown is not re-read, so a card
    /// refreshing on every `ProjectsDidChange` costs one stat rather than one scan.
    @MainActor
    func testAnUnchangedTranscriptCallsBackOnlyOnce() throws {
        let url = try transcript([mode("auto")])
        ClaudeTranscriptPermissionMode.forgetAll()
        defer { ClaudeTranscriptPermissionMode.forgetAll() }

        let first = expectation(description: "first read")
        ClaudeTranscriptPermissionMode.revalidate(at: url) { _ in first.fulfill() }
        wait(for: [first], timeout: 5)

        let again = expectation(description: "second read")
        again.isInverted = true
        ClaudeTranscriptPermissionMode.revalidate(at: url) { _ in again.fulfill() }
        wait(for: [again], timeout: 1)

        XCTAssertEqual(ClaudeTranscriptPermissionMode.known(at: url), .auto)
    }

    /// Two facts read off one file keep separate caches, so forgetting the posture does not
    /// throw away the model the card is also showing.
    @MainActor
    func testTheTwoTranscriptFactsDoNotShareACache() throws {
        let url = try transcript([
            #"{"type":"assistant","message":{"role":"assistant","model":"claude-opus-5"}}"#,
            mode("auto")
        ])
        ClaudeTranscriptPermissionMode.forgetAll()
        ClaudeTranscriptModel.forgetAll()
        defer {
            ClaudeTranscriptPermissionMode.forgetAll()
            ClaudeTranscriptModel.forgetAll()
        }

        let both = expectation(description: "both read")
        both.expectedFulfillmentCount = 2
        ClaudeTranscriptPermissionMode.revalidate(at: url) { _ in both.fulfill() }
        ClaudeTranscriptModel.revalidate(at: url) { _ in both.fulfill() }
        wait(for: [both], timeout: 5)

        ClaudeTranscriptPermissionMode.forgetAll()

        XCTAssertNil(ClaudeTranscriptPermissionMode.known(at: url))
        XCTAssertEqual(
            ClaudeTranscriptModel.known(at: url),
            "claude-opus-5",
            "the model reader kept its own answer"
        )
    }

    // MARK: - The table and its contract

    /// The capability is what surfaces ask before they have a session in hand; the switch in
    /// `record(for:)` is what actually answers. A runtime that claimed one without the other
    /// would either be silently unreadable or read through a branch nothing declared.
    @MainActor
    func testEveryRuntimeThatClaimsTheCapabilityHasARecordToRead() {
        for kind in AgentKind.allCases {
            XCTAssertEqual(
                ObservedPermissionMode.record(for: kind) != nil,
                kind.supports(.transcriptPermissionModeRecord),
                "\(kind) disagrees with itself about whether its posture can be observed"
            )
        }
    }

    // MARK: - Helpers

    private func mode(_ value: String) -> String {
        #"{"type":"permission-mode","permissionMode":"\#(value)","sessionId":"s"}"#
    }

    private func toolResult(_ name: String) -> String {
        #"{"type":"user","message":{"role":"user","content":"\#(name)"}}"#
    }

    private func transcript(_ lines: [String]) throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("posture-\(UUID().uuidString).jsonl")
        try (lines.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }
}
