import XCTest
@testable import Threading
import ThreadingUsage

/// Adapter records carried through the app's own aggregation and session projection. The
/// adapters themselves are tested in `Packages/ThreadingUsage`.
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

    @discardableResult
    private func write(_ name: String, lines: [String]) throws -> URL {
        let url = directory.appendingPathComponent(name)
        try lines.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
        return url
    }
}
