import XCTest
@testable import Threading

/// Reading a provider's "you are out of allowance" back off a session's own record, and the
/// state the sidebar draws from it.
///
/// The specimens these are written against are real: session `f3ad7546` on CLI 2.1.223 recorded
/// the root refusal directly, while `3149ae34` on 2026-08-23 completed its root turn and then
/// received a failed background-task notification as the terminal moved to the limit chooser.
/// Everything here is a property that reading has to have for the row to stop lying — the refusal
/// is recognised, it stops being true when the conversation speaks again, a subagent's failure is
/// provisional until the root screen confirms it, and nothing else is mistaken for one.
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
        let url = try transcript([refusal(uuid: "refusal-one")])

        let stop = ClaudeTranscriptUsageLimit.newestStop(at: url)

        XCTAssertEqual(stop?.message, "You've hit your session limit · resets 1:20pm (Europe/Rome)")
        XCTAssertEqual(stop?.resetHint, "1:20pm (Europe/Rome)")
        XCTAssertEqual(stop?.recordID, "refusal-one")
    }

    /// A loop retries while the account is still spent, and the provider repeats the same
    /// sentence. Changed-only observation must see the new refusal record rather than mistaking
    /// equal prose for the old stop still standing.
    func testTwoIdenticallyWordedRefusalsAreDistinctStops() throws {
        let first = try transcript([refusal(uuid: "refusal-one")])
        let second = try transcript([refusal(uuid: "refusal-two")])

        let firstStop = ClaudeTranscriptUsageLimit.newestStop(at: first)
        let secondStop = ClaudeTranscriptUsageLimit.newestStop(at: second)

        XCTAssertEqual(firstStop?.message, secondStop?.message)
        XCTAssertNotEqual(firstStop, secondStop)
        XCTAssertEqual(secondStop?.recordID, "refusal-two")
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

    /// A newer provider outcome clears the stop. A newer user record does not: it proves only
    /// that a retry was submitted locally, and `/loop` can be refused again immediately.
    func testOnlyANewerAssistantOutcomeClearsTheStop() throws {
        let assistant = try transcript([refusal(), assistantText("Carrying on")])
        let user = try transcript([refusal(), userText("continue")])

        XCTAssertNil(ClaudeTranscriptUsageLimit.newestStop(at: assistant))
        XCTAssertNotNil(ClaudeTranscriptUsageLimit.newestStop(at: user))
    }

    /// A subagent that runs out of allowance is reported to its parent as a failed task, and the
    /// parent goes on working — the specimen's main thread kept going for five more minutes. A
    /// sidechain record must not stop the session that owns it.
    func testASidechainRefusalIsNotTheSessionsRefusal() throws {
        let url = try transcript([refusal(isSidechain: true), assistantText("still here")])

        XCTAssertNil(ClaudeTranscriptUsageLimit.newestStop(at: url))
    }

    /// Session 3149ae34's exact missing edge: the root had already completed, then the provider
    /// delivered a failed background task whose API error was the session limit. That is evidence
    /// worth checking, but it is not yet permission to stop the parent row.
    func testAFailedBackgroundTaskAfterACompletedRootTurnIsProvisionalLimitEvidence() throws {
        let url = try transcript([
            assistantText("Finished the root turn", stopReason: "end_turn"),
            try taskNotification(
                status: "failed",
                summary: """
                Agent "Slice 4" failed: Agent terminated early due to an API error: \
                You've hit your session limit · resets 4:50pm (Europe/Stockholm) · progress saved
                """
            )
        ])

        let observation = ClaudeTranscriptUsageLimit.newestObservation(at: url)

        XCTAssertEqual(observation?.evidence, .failedBackgroundTask)
        XCTAssertEqual(
            observation?.stop.recordID,
            "task-notification:toolu_01GPpDkxiWLPRBEbYLpNP1fi"
        )
        XCTAssertNil(
            observation?.confirmedStop(screenLines: ["Finished the root turn", "❯"]),
            "a child failure alone must never stop its parent"
        )
    }

    /// The second key from the same specimen is the provider-owned chooser in the root terminal.
    /// Once both keys agree, the clean visible refusal — not the task wrapper — is what the ribbon
    /// should say.
    func testTheLiveLimitChooserConfirmsAndCleansTheProvisionalStop() throws {
        let observation = try XCTUnwrap(provisionalObservation())
        let stop = try XCTUnwrap(observation.confirmedStop(screenLines: [
            "You've hit your session limit · resets 4:50pm (Europe/Stockholm)",
            "❯ 1. Stop and wait for limit to reset",
            "  2. Upgrade your plan"
        ]))

        XCTAssertEqual(
            stop.message,
            "You've hit your session limit · resets 4:50pm (Europe/Stockholm)"
        )
        XCTAssertEqual(stop.resetHint, "4:50pm (Europe/Stockholm)")
        XCTAssertEqual(stop.recordID, observation.stop.recordID)
    }

    func testTheInlineLimitNoticeAlsoConfirmsTheProvisionalStop() throws {
        let observation = try XCTUnwrap(provisionalObservation())

        XCTAssertNotNil(observation.confirmedStop(screenLines: [
            "You've hit your session limit · resets 4:50pm (Europe/Stockholm)",
            "/upgrade to increase your usage limit."
        ]))
    }

    /// A background task can fail for ordinary reasons, and a successful task can quote limit
    /// language in its summary. Neither is a candidate regardless of the root's turn boundary.
    func testOnlyAFailedTaskWhoseFailureIsALimitBecomesACandidate() throws {
        let ordinaryFailure = try transcript([
            assistantText("Done", stopReason: "end_turn"),
            try taskNotification(status: "failed", summary: "Agent crashed while reading a file")
        ])
        let successfulLimitReport = try transcript([
            assistantText("Done", stopReason: "end_turn"),
            try taskNotification(status: "completed", summary: "Found a usage limit in the docs")
        ])

        XCTAssertNil(ClaudeTranscriptUsageLimit.newestObservation(at: ordinaryFailure))
        XCTAssertNil(ClaudeTranscriptUsageLimit.newestObservation(at: successfulLimitReport))
    }

    /// The task notification belongs to delegated work still in flight when the root assistant
    /// ended on a tool call. It cannot describe a stopped parent until that root turn completes.
    func testAChildLimitFailureDuringAnUnfinishedRootTurnIsNotACandidate() throws {
        let url = try transcript([
            assistantText("Starting a background task", stopReason: "tool_use"),
            try taskNotification(
                status: "failed",
                summary: "You've hit your session limit · resets 4:50pm"
            )
        ])

        XCTAssertNil(ClaudeTranscriptUsageLimit.newestObservation(at: url))
    }

    func testANewerRootAssistantSupersedesAChildLimitFailure() throws {
        let url = try transcript([
            assistantText("Done", stopReason: "end_turn"),
            try taskNotification(
                status: "failed",
                summary: "You've hit your session limit · resets 4:50pm"
            ),
            assistantText("The parent carried on", stopReason: "end_turn")
        ])

        XCTAssertNil(ClaudeTranscriptUsageLimit.newestObservation(at: url))
    }

    /// The provider's synthetic root 429 remains authoritative even if task bookkeeping follows
    /// it, and therefore needs no terminal confirmation.
    func testARootRateLimitRemainsAuthoritativeBesideALaterTaskFailure() throws {
        let url = try transcript([
            refusal(uuid: "root-refusal"),
            try taskNotification(
                status: "failed",
                summary: "You've hit your session limit · resets 4:50pm"
            )
        ])
        let observation = try XCTUnwrap(ClaudeTranscriptUsageLimit.newestObservation(at: url))

        XCTAssertEqual(observation.evidence, .providerRefusal)
        XCTAssertEqual(observation.confirmedStop(screenLines: [])?.recordID, "root-refusal")
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

    /// This is the changed-only cache boundary exercised as a sequence, not just value equality:
    /// a retry can receive the exact same sentence, and its new provider record must still wake
    /// recovery for the new refusal.
    @MainActor
    func testARepeatedIdenticalRefusalMovesTheChangedOnlyReader() throws {
        let url = try transcript([refusal(uuid: "refusal-one")])
        ClaudeTranscriptUsageLimit.forgetAll()
        defer { ClaudeTranscriptUsageLimit.forgetAll() }

        let firstRead = expectation(description: "first refusal read")
        ClaudeTranscriptUsageLimit.revalidate(at: url) { stop in
            XCTAssertEqual(stop?.recordID, "refusal-one")
            firstRead.fulfill()
        }
        wait(for: [firstRead], timeout: 5)

        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data((refusal(uuid: "refusal-two") + "\n").utf8))
        try handle.close()

        let secondRead = expectation(description: "repeated refusal read")
        ClaudeTranscriptUsageLimit.revalidate(at: url) { stop in
            XCTAssertEqual(stop?.message, "You've hit your session limit · resets 1:20pm (Europe/Rome)")
            XCTAssertEqual(stop?.recordID, "refusal-two")
            secondRead.fulfill()
        }
        wait(for: [secondRead], timeout: 5)
    }

    /// The regression from session 4ce20d8d: moving the refused transcript to Nova copied the
    /// old account's 429 to a new path, whose empty cache announced it as a fresh Nova refusal
    /// and immediately offered Viktor. A migration carries the copied byte boundary, but not the
    /// account-scoped stop, and still notices genuinely appended output afterwards.
    @MainActor
    func testAMigratedRefusalIsNotAnnouncedAgainOnTheDestinationAccount() throws {
        let source = try transcript([refusal()])
        let destination = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("migrated-usage-limit-\(UUID().uuidString).jsonl")
        try FileManager.default.copyItem(at: source, to: destination)
        addTeardownBlock { try? FileManager.default.removeItem(at: destination) }

        ClaudeTranscriptUsageLimit.forgetAll()
        defer { ClaudeTranscriptUsageLimit.forgetAll() }

        let sourceRead = expectation(description: "source refusal read")
        ClaudeTranscriptUsageLimit.revalidate(at: source) { stop in
            XCTAssertNotNil(stop)
            sourceRead.fulfill()
        }
        wait(for: [sourceRead], timeout: 5)

        let copiedByteCount = try XCTUnwrap(
            destination.resourceValues(forKeys: [.fileSizeKey]).fileSize
        )
        ClaudeTranscriptUsageLimit.acknowledgeAccountMigration(
            to: destination,
            copiedByteCount: copiedByteCount
        )
        XCTAssertNil(
            ClaudeTranscriptUsageLimit.known(at: destination),
            "the copied refusal belongs to the account the conversation left"
        )

        let copiedRefusal = expectation(description: "copied refusal announced")
        copiedRefusal.isInverted = true
        ClaudeTranscriptUsageLimit.revalidate(at: destination) { _ in
            copiedRefusal.fulfill()
        }
        wait(for: [copiedRefusal], timeout: 0.5)

        let handle = try FileHandle(forWritingTo: destination)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data((refusal(text: "Nova reached a new limit") + "\n").utf8))
        try handle.close()

        let destinationRefusal = expectation(description: "destination refusal read")
        ClaudeTranscriptUsageLimit.revalidate(at: destination) { stop in
            XCTAssertEqual(stop?.message, "Nova reached a new limit")
            destinationRefusal.fulfill()
        }
        wait(for: [destinationRefusal], timeout: 5)
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
        isSidechain: Bool = false,
        uuid: String? = nil
    ) -> String {
        let identity = uuid.map { ",\"uuid\":\"\($0)\"" } ?? ""
        return #"""
        {"type":"assistant","isSidechain":\#(isSidechain),"isApiErrorMessage":true,\#
        "error":"rate_limit","apiErrorStatus":429\#(identity),"message":{"model":"<synthetic>",\#
        "role":"assistant","content":[{"type":"text","text":"\#(text)"}]}}
        """#
    }

    private func assistantText(_ text: String, stopReason: String? = nil) -> String {
        let boundary = stopReason.map { #", "stop_reason":"\#($0)""# } ?? ""
        return #"{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"\#(text)"}]\#(boundary)}}"#
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

    private func taskNotification(status: String, summary: String) throws -> String {
        let content = """
        <task-notification>
        <task-id>a6b89dbdeb0b95025</task-id>
        <tool-use-id>toolu_01GPpDkxiWLPRBEbYLpNP1fi</tool-use-id>
        <status>\(status)</status>
        <summary>\(summary)</summary>
        </task-notification>
        """
        let data = try JSONSerialization.data(withJSONObject: [
            "type": "queue-operation",
            "operation": "enqueue",
            "content": content
        ], options: [.sortedKeys])
        return try XCTUnwrap(String(data: data, encoding: .utf8))
    }

    private func provisionalObservation() throws -> UsageLimitObservation? {
        let url = try transcript([
            assistantText("Finished", stopReason: "end_turn"),
            try taskNotification(
                status: "failed",
                summary: """
                Agent failed due to an API error: You've hit your session limit · \
                resets 4:50pm (Europe/Stockholm) · progress saved
                """
            )
        ])
        return ClaudeTranscriptUsageLimit.newestObservation(at: url)
    }
}
