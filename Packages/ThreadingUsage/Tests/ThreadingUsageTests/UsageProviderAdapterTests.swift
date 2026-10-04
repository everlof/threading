import XCTest
@testable import ThreadingUsage

final class UsageProviderAdapterTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("threading-provider-usage-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    func testClaudePreservesEveryTokenClassAndReportedCost() throws {
        let line = #"{"requestId":"request-1","timestamp":"2026-08-08T10:00:00.000Z","cwd":"/work","costUSD":1.5,"message":{"id":"message-1","model":"claude-test","usage":{"input_tokens":10,"cache_read_input_tokens":20,"cache_creation_input_tokens":30,"cache_creation":{"ephemeral_5m_input_tokens":18,"ephemeral_1h_input_tokens":12},"output_tokens":40}}}"#
        let url = try write("claude.jsonl", lines: [line])

        let record = try XCTUnwrap(try ClaudeUsageAdapter.records(
            inTranscriptAt: url,
            accountID: "claude:default",
            accountName: "Claude"
        ).first)

        XCTAssertEqual(record.identity, "claude|message-1|request-1")
        XCTAssertEqual(record.tokens, .init(
            uncachedInput: 10,
            cachedInput: 20,
            cacheWrite: 30,
            cacheWrite1h: 12,
            output: 40
        ))
        XCTAssertEqual(record.reportedCostUSD, 1.5)
    }

    func testCodexCarriesSessionContextAndIgnoresImmediateRestatement() throws {
        let usage = #"{"type":"event_msg","timestamp":"2026-08-08T10:02:00Z","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":100,"cached_input_tokens":60,"output_tokens":20,"reasoning_output_tokens":10}}}}"#
        let url = try write("rollout.jsonl", lines: [
            #"{"type":"session_meta","payload":{"id":"session-1","cwd":"/work"}}"#,
            #"{"type":"turn_context","payload":{"model":"gpt-5.4","cwd":"/worktree"}}"#,
            usage,
            usage
        ])

        let records = try CodexUsageAdapter.records(
            inRolloutAt: url,
            accountID: "codex:default",
            accountName: "Codex"
        )

        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(records[0].sessionID, "session-1")
        XCTAssertEqual(records[0].workingDirectory, "/worktree")
        XCTAssertEqual(records[0].model, "gpt-5.4")
        XCTAssertEqual(records[0].tokens, .init(
            uncachedInput: 40,
            cachedInput: 60,
            output: 20,
            reasoning: 10
        ))
    }

    func testCodexRetainsEqualLaterResponsesWhenCumulativeUsageAdvances() throws {
        func usage(timestamp: String, total: Int) -> String {
            #"{"type":"event_msg","timestamp":"\#(timestamp)","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":\#(total),"cached_input_tokens":0,"output_tokens":20,"reasoning_output_tokens":0},"last_token_usage":{"input_tokens":100,"cached_input_tokens":60,"output_tokens":20,"reasoning_output_tokens":10}}}}"#
        }
        let first = usage(timestamp: "2026-08-08T10:02:00Z", total: 100)
        let second = usage(timestamp: "2026-08-08T10:03:00Z", total: 200)
        let url = try write("rollout.jsonl", lines: [
            #"{"type":"session_meta","payload":{"id":"session-1","cwd":"/work"}}"#,
            #"{"type":"turn_context","payload":{"model":"gpt-5.4"}}"#,
            first,
            first,
            second
        ])

        let records = try CodexUsageAdapter.records(
            inRolloutAt: url,
            accountID: "codex:default",
            accountName: "Codex"
        )

        XCTAssertEqual(records.count, 2)
        XCTAssertEqual(records[0].tokens, records[1].tokens)
        XCTAssertNotEqual(records[0].identity, records[1].identity)
    }

    func testCodexIdentitySurvivesLineNumberChangesInCopiedRollout() throws {
        let usage = #"{"type":"event_msg","timestamp":"2026-08-08T10:02:00Z","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":100,"cached_input_tokens":60,"output_tokens":20,"reasoning_output_tokens":10}}}}"#
        let first = try write("rollout-a.jsonl", lines: [
            #"{"type":"session_meta","payload":{"id":"session-1"}}"#,
            usage
        ])
        let second = try write("rollout-b.jsonl", lines: [
            #"{"unrelated":true}"#,
            #"{"type":"session_meta","payload":{"id":"session-1"}}"#,
            usage
        ])

        let firstIdentity = try XCTUnwrap(try CodexUsageAdapter.records(
            inRolloutAt: first,
            accountID: "codex:default",
            accountName: "Codex"
        ).first?.identity)
        let secondIdentity = try XCTUnwrap(try CodexUsageAdapter.records(
            inRolloutAt: second,
            accountID: "codex:default",
            accountName: "Codex"
        ).first?.identity)

        XCTAssertEqual(firstIdentity, secondIdentity)
    }

    func testCodexChildFixtureDropsCopiedParentPrefixFromCanonicalLedger() throws {
        let records = try CodexUsageAdapter.records(
            inRolloutAt: fixture("codex-reasoning.jsonl"),
            accountID: "codex:default",
            accountName: "Codex"
        )
        let tokens = records.reduce(into: UsageTokenCounts()) { $0 += $1.tokens }

        XCTAssertFalse(records.isEmpty)
        XCTAssertTrue(records.allSatisfy { $0.sessionKind == .subagent })
        XCTAssertEqual(tokens.uncachedInput, 63_471)
        XCTAssertEqual(tokens.cachedInput, 678_656)
        XCTAssertEqual(tokens.output, 8_957)
        XCTAssertEqual(tokens.reasoning, 4_622)
        XCTAssertEqual(tokens.processed, 751_084)
    }

    func testOpenCodePreservesProviderRouteAndAssistantUsage() throws {
        let export = #"{"info":{"id":"session-1","directory":"/root"},"messages":[{"info":{"id":"message-1","role":"assistant","sessionID":"session-1","providerID":"openrouter","modelID":"anthropic/claude-test","cost":0.42,"path":{"cwd":"/checkout"},"time":{"created":1786183200000},"tokens":{"input":10,"output":40,"reasoning":15,"cache":{"read":20,"write":30}}}}]}"#

        let record = try XCTUnwrap(OpenCodeUsageAdapter.records(
            fromExport: Data(export.utf8)
        ).first)

        XCTAssertEqual(record.origin.runtimeID, UsageRuntime.openCode.rawValue)
        XCTAssertEqual(record.origin.billingProviderID, "openrouter")
        XCTAssertEqual(record.model, "anthropic/claude-test")
        XCTAssertEqual(record.workingDirectory, "/checkout")
        XCTAssertEqual(record.tokens, .init(
            uncachedInput: 10,
            cachedInput: 20,
            cacheWrite: 30,
            output: 40,
            reasoning: 15
        ))
        XCTAssertEqual(record.reportedCostUSD, 0.42)
    }

    func testUnknownOpenCodeShapeFailsInsteadOfInventingUsage() {
        XCTAssertThrowsError(try OpenCodeUsageAdapter.records(fromExport: Data("[]".utf8))) { error in
            XCTAssertEqual(error as? OpenCodeUsageAdapter.Failure, .unfamiliarExport)
        }
    }

    @discardableResult
    /// A receipt keeps every readable record around an unreadable line and names the gap; the
    /// Mac's strict entry point still refuses the same file.
    func testRecoveringReadingKeepsRecordsAroundAnUnreadableLine() throws {
        let good = { (id: String) in
            #"{"requestId":"r-\#(id)","message":{"id":"m-\#(id)","model":"claude-test","usage":{"input_tokens":10,"output_tokens":4}}}"#
        }
        let bad = #"{"message":{"id":"broken","usage":"not an object"}}"#
        let url = try write("claude.jsonl", lines: [good("1"), bad, good("2"), ""])

        XCTAssertThrowsError(try ClaudeUsageAdapter.records(inTranscriptAt: url, accountID: "a", accountName: "a"))
        let reading = try ClaudeUsageAdapter.reading(transcriptAt: url, accountID: "a", accountName: "a")
        XCTAssertEqual(reading.records.map(\.identity), ["claude|m-1|r-1", "claude|m-2|r-2"])
        XCTAssertEqual(reading.unreadableRecordCount, 1)
        XCTAssertEqual(reading.firstUnreadableLine, 2)
        XCTAssertFalse(reading.endsUnterminated)
        XCTAssertFalse(reading.isComplete)
    }

    /// A process stopped mid-write leaves a final line with no newline. Earlier records stay,
    /// and the reading says it cannot be complete, even when the cut bytes happen to parse.
    func testUnterminatedFinalLineIsAnExplicitGap() throws {
        let first = #"{"requestId":"r1","message":{"id":"m1","model":"claude-test","usage":{"input_tokens":10,"output_tokens":4}}}"#
        let cut = #"{"requestId":"r2","message":{"id":"m2","model":"claude-test","usage":{"input_tok"#
        let url = try write("claude.jsonl", lines: [first, cut])

        let reading = try ClaudeUsageAdapter.reading(transcriptAt: url, accountID: "a", accountName: "a")
        XCTAssertEqual(reading.records.map(\.identity), ["claude|m1|r1"])
        XCTAssertTrue(reading.endsUnterminated)
        XCTAssertFalse(reading.isComplete)

        let whole = try write("whole.jsonl", lines: [first])
        let parsed = try ClaudeUsageAdapter.reading(transcriptAt: whole, accountID: "a", accountName: "a")
        XCTAssertEqual(parsed.records.count, 1)
        XCTAssertTrue(parsed.endsUnterminated, "an unterminated tail is a gap even when it parses")

        let terminated = try write("terminated.jsonl", lines: [first, ""])
        XCTAssertTrue(try ClaudeUsageAdapter.reading(transcriptAt: terminated, accountID: "a", accountName: "a").isComplete)
    }

    func testCodexRecoveringReadingKeepsLaterResponses() throws {
        let usage = { (stamp: String, output: Int) in
            #"{"type":"event_msg","timestamp":"\#(stamp)","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":100,"cached_input_tokens":60,"output_tokens":\#(output),"reasoning_output_tokens":0}}}}"#
        }
        let broken = #"{"type":"event_msg","payload":{"type":"token_count","info":{"total_tokens":5}}}"#
        let url = try write("rollout.jsonl", lines: [
            #"{"type":"session_meta","payload":{"id":"s","cwd":"/w"}}"#,
            usage("2026-08-08T10:00:00Z", 1), broken, usage("2026-08-08T10:01:00Z", 2), ""
        ])
        XCTAssertThrowsError(try CodexUsageAdapter.records(inRolloutAt: url, accountID: "a", accountName: "a"))
        let reading = try CodexUsageAdapter.reading(rolloutAt: url, accountID: "a", accountName: "a")
        XCTAssertEqual(reading.records.map(\.tokens.output), [1, 2])
        XCTAssertEqual(reading.unreadableRecordCount, 1)
        XCTAssertEqual(reading.firstUnreadableLine, 3)
    }

    private func write(_ name: String, lines: [String]) throws -> URL {
        let url = directory.appendingPathComponent(name)
        try lines.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private func fixture(_ name: String) -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // this file
            .deletingLastPathComponent() // ThreadingUsageTests
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // ThreadingUsage
            .deletingLastPathComponent() // Packages
            .appendingPathComponent("Tests/Fixtures/Transcripts")
            .appendingPathComponent(name)
    }
}
