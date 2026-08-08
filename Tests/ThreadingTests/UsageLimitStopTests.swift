import XCTest
@testable import Threading

/// Reading a provider's "you are out of allowance" back off a session's own record, and the
/// state the sidebar draws from it.
///
/// The specimen these are written against is real: session `f3ad7546` on CLI 2.1.223 was refused
/// at 10:45 on 2026-08-07 and went on drawing a working spinner until 11:04, when its user asked
/// what had happened. Everything here is a property that reading has to have for the row to stop
/// lying — the refusal is recognised, it stops being true when the conversation speaks again, a
/// subagent's refusal is not the session's, and nothing else in a transcript is mistaken for one.
final class UsageLimitStopTests: XCTestCase {

    // MARK: - Recognising the refusal

    /// The sentence the CLI actually wrote, verbatim from the specimen.
    func testTheCurrentRefusalIsRecognisedWithItsResetInTheProvidersOwnWords() {
        let stop = UsageLimitStop.recognised(
            in: "You've hit your session limit · resets 1:20pm (Europe/Rome)"
        )

        XCTAssertEqual(stop?.message, "You've hit your session limit · resets 1:20pm (Europe/Rome)")
        XCTAssertEqual(stop?.resetHint, "1:20pm (Europe/Rome)")
    }

    /// The separator has been a middle dot, a bullet operator and a pipe across three CLI
    /// versions, so the words are what is matched and never the punctuation between them.
    func testTheOtherShapesTheSameRefusalHasTakenAreRecognised() {
        XCTAssertEqual(
            UsageLimitStop.recognised(in: "5-hour limit reached ∙ resets 3pm")?.resetHint,
            "3pm"
        )
        XCTAssertEqual(
            UsageLimitStop.recognised(in: "You've hit your weekly limit · resets Tuesday at 9am")?
                .resetHint,
            "Tuesday at 9am"
        )
        XCTAssertNotNil(UsageLimitStop.recognised(in: "You've reached your usage limit."))
    }

    /// The one form that states an instant rather than prose. The number is a wire detail —
    /// pasted onto a row it reads as a corrupted message — so it leaves the sentence and comes
    /// back as a time.
    func testAnEpochTailBecomesATimeAndLeavesTheSentence() {
        let stop = UsageLimitStop.recognised(in: "Claude AI usage limit reached|1754575200")

        XCTAssertEqual(stop?.message, "Claude AI usage limit reached")
        XCTAssertNotNil(stop?.resetHint)
        XCTAssertFalse(
            stop?.resetHint?.contains("1754575200") ?? true,
            "the epoch second is not something to show anybody"
        )
    }

    /// A refusal that says nothing about when it lifts still stops the session; the hint is a
    /// detail, the stop is the fact.
    func testARefusalWithNoStatedResetStillReads() {
        let stop = UsageLimitStop.recognised(in: "Rate limit exceeded")

        XCTAssertEqual(stop?.message, "Rate limit exceeded")
        XCTAssertNil(stop?.resetHint)
    }

    func testUnrelatedFailureTextIsNotARefusal() {
        XCTAssertNil(UsageLimitStop.recognised(in: "Request timed out after 60s"))
        XCTAssertNil(UsageLimitStop.recognised(in: "API Error: Connection error"))
        XCTAssertNil(UsageLimitStop.recognised(in: ""))
        XCTAssertNil(UsageLimitStop.recognised(in: nil))
    }

    // MARK: - Reading it out of a transcript

    /// The whole record, exactly as CLI 2.1.223 wrote it.
    func testTheRefusalRecordIsReadWithItsSentence() throws {
        let url = try transcript([refusal()])

        let stop = ClaudeTranscriptUsageLimit.newestStop(at: url)

        XCTAssertEqual(stop?.message, "You've hit your session limit · resets 1:20pm (Europe/Rome)")
        XCTAssertEqual(stop?.resetHint, "1:20pm (Europe/Rome)")
    }

    /// The CLI appends bookkeeping *after* the refusal — `turn_duration`, then a queue operation
    /// when a background task reported five minutes later. None of it says the conversation has
    /// spoken, so none of it may clear the stop. This is the specimen's exact tail.
    func testBookkeepingWrittenAfterTheRefusalDoesNotClearIt() throws {
        let url = try transcript([
            refusal(),
            #"{"type":"system","subtype":"turn_duration","durationMs":5711446}"#,
            #"{"type":"queue-operation","operation":"enqueue","content":"<task-notification/>"}"#
        ])

        XCTAssertNotNil(ClaudeTranscriptUsageLimit.newestStop(at: url))
    }

    /// What *does* clear it: the conversation saying anything at all, in either direction. That
    /// is why nothing has to remember when the refusal was.
    func testANewerMessageClearsTheStop() throws {
        let assistant = try transcript([refusal(), assistantText("Carrying on")])
        let user = try transcript([refusal(), userText("continue")])

        XCTAssertNil(ClaudeTranscriptUsageLimit.newestStop(at: assistant))
        XCTAssertNil(ClaudeTranscriptUsageLimit.newestStop(at: user))
    }

    /// A subagent that runs out of allowance is reported to its parent as a failed task, and the
    /// parent goes on working — the specimen's main thread kept going for five more minutes. A
    /// sidechain record must not stop the session that owns it.
    func testASidechainRefusalIsNotTheSessionsRefusal() throws {
        let url = try transcript([refusal(isSidechain: true), assistantText("still here")])

        XCTAssertNil(ClaudeTranscriptUsageLimit.newestStop(at: url))
    }

    /// The flag is the fact and the sentence is only the words: a CLI that rewords itself still
    /// stops the session.
    func testARefusalWhoseWordingIsUnrecognisedStillStopsTheSession() throws {
        let url = try transcript([refusal(text: "Something new the CLI says now")])

        XCTAssertEqual(
            ClaudeTranscriptUsageLimit.newestStop(at: url)?.message,
            "Something new the CLI says now"
        )
    }

    /// An ordinary failed turn is not a refusal. `isApiErrorMessage` without the rate-limit
    /// class is a network fault, and stopping a session for one would be worse than the spinner.
    func testAnOrdinaryApiErrorIsNotARefusal() throws {
        let url = try transcript([
            #"""
            {"type":"assistant","isApiErrorMessage":true,"error":"connection_error",\#
            "apiErrorStatus":500,"message":{"content":[{"type":"text","text":"API Error"}]}}
            """#
        ])

        XCTAssertNil(ClaudeTranscriptUsageLimit.newestStop(at: url))
    }

    func testATranscriptThatWasNeverWrittenAnswersNothingRatherThanFailing() {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("never-written-\(UUID().uuidString).jsonl")

        XCTAssertNil(ClaudeTranscriptUsageLimit.newestStop(at: url))
    }

    // MARK: - Answering the row

    /// The order a poll depends on: nothing on the main thread while it decides, the answer in
    /// memory afterwards.
    @MainActor
    func testTheAnswerIsKnownOnlyAfterTheBackgroundReadLands() throws {
        let url = try transcript([refusal()])
        ClaudeTranscriptUsageLimit.forgetAll()
        defer { ClaudeTranscriptUsageLimit.forgetAll() }

        XCTAssertNil(ClaudeTranscriptUsageLimit.known(at: url))

        let landed = expectation(description: "transcript read")
        ClaudeTranscriptUsageLimit.revalidate(at: url) { stop in
            XCTAssertEqual(stop?.resetHint, "1:20pm (Europe/Rome)")
            landed.fulfill()
        }
        wait(for: [landed], timeout: 5)

        XCTAssertNotNil(ClaudeTranscriptUsageLimit.known(at: url))
    }

    // MARK: - The table and its contract

    /// The capability is what a surface asks before it has a session in hand; the switch in
    /// `record(for:)` is what answers. A runtime claiming one without the other would either be
    /// silently unreadable or read through a branch nothing declared.
    @MainActor
    func testEveryRuntimeThatClaimsTheCapabilityHasARecordToRead() {
        for kind in AgentKind.allCases {
            XCTAssertEqual(
                ObservedUsageLimit.record(for: kind) != nil,
                kind.supports(.transcriptUsageLimitRecord),
                "\(kind) disagrees with itself about whether its refusals can be observed"
            )
        }
    }

    // MARK: - Helpers

    /// The specimen record, field for field.
    private func refusal(
        text: String = "You've hit your session limit · resets 1:20pm (Europe/Rome)",
        isSidechain: Bool = false
    ) -> String {
        #"""
        {"type":"assistant","isSidechain":\#(isSidechain),"isApiErrorMessage":true,\#
        "error":"rate_limit","apiErrorStatus":429,"message":{"model":"<synthetic>",\#
        "role":"assistant","content":[{"type":"text","text":"\#(text)"}]}}
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
            .appendingPathComponent("usage-limit-\(UUID().uuidString).jsonl")
        try (lines.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }
}
