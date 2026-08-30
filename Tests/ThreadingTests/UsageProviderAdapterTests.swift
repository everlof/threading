import XCTest
@testable import Threading

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

    func testClaudeChildTranscriptCarriesDurableParentProvenance() throws {
        let subagents = directory
            .appendingPathComponent("parent-session")
            .appendingPathComponent(AgentDefaults.claudeSubagentsSubdirectory)
        try FileManager.default.createDirectory(at: subagents, withIntermediateDirectories: true)
        let url = subagents.appendingPathComponent("agent-child.jsonl")
        try #"{"requestId":"r1","message":{"id":"m1","usage":{"input_tokens":10,"output_tokens":2}}}"#
            .write(to: url, atomically: true, encoding: .utf8)

        let record = try XCTUnwrap(try ClaudeUsageAdapter.records(
            inTranscriptAt: url,
            accountID: "claude:default",
            accountName: "Claude"
        ).first)

        XCTAssertEqual(record.sessionID, "agent-child")
        XCTAssertEqual(record.sessionKind, .subagent)
        XCTAssertEqual(record.parentSessionID, "parent-session")

        // Terminal hooks and the native child stream are enrichment only. A child neither
        // surface observed still joins the parent's receipt from transcript provenance alone.
        let report = UsageLedgerBuilder.build(
            records: [record],
            coverage: [],
            projects: [],
            scan: .init()
        )
        let snapshot = SessionUsageProjector.project(
            report: report,
            input: .init(
                sessionID: SessionID(),
                runtimeID: AgentKind.claude.rawValue,
                mainIdentities: ["parent-session"],
                children: []
            )
        )
        XCTAssertEqual(snapshot.subagents.processedTokens, 12)
        XCTAssertEqual(snapshot.total.processedTokens, 12)
        XCTAssertTrue(snapshot.children.isEmpty)
    }

    func testCodexChildMetadataCarriesParentWithoutRequiringBoundary() throws {
        let url = try write("codex-child.jsonl", lines: [
            #"{"type":"session_meta","payload":{"id":"child-thread","parent_thread_id":"parent-thread","source":{"subagent":{"agent_type":"worker"}}}}"#,
            #"{"type":"turn_context","payload":{"model":"gpt-5.6-terra","cwd":"/work"}}"#,
            #"{"type":"event_msg","timestamp":"2026-08-08T10:02:00Z","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":100,"cached_input_tokens":60,"output_tokens":20,"reasoning_output_tokens":10}}}}"#
        ])

        let record = try XCTUnwrap(try CodexUsageAdapter.records(
            inRolloutAt: url,
            accountID: "codex:default",
            accountName: "Codex"
        ).first)

        XCTAssertEqual(record.sessionID, "child-thread")
        XCTAssertEqual(record.sessionKind, .subagent)
        XCTAssertEqual(record.parentSessionID, "parent-thread")
        XCTAssertEqual(record.tokens.processed, 120)

        let report = UsageLedgerBuilder.build(
            records: [record],
            coverage: [],
            projects: [],
            scan: .init()
        )
        let snapshot = SessionUsageProjector.project(
            report: report,
            input: .init(
                sessionID: SessionID(),
                runtimeID: AgentKind.codex.rawValue,
                mainIdentities: ["parent-thread"],
                children: []
            )
        )
        XCTAssertEqual(snapshot.subagents.processedTokens, 120)
        XCTAssertEqual(snapshot.total.processedTokens, 120)
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

        XCTAssertEqual(record.origin.runtimeID, AgentKind.openCode.rawValue)
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
    private func write(_ name: String, lines: [String]) throws -> URL {
        let url = directory.appendingPathComponent(name)
        try lines.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private func fixture(_ name: String) -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/Transcripts")
            .appendingPathComponent(name)
    }
}
