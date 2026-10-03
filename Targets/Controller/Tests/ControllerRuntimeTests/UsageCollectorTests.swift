import Foundation
import Testing
import ThreadingController
@testable import ControllerRuntime

struct UsageCollectorTests {
    @Test func consecutiveCodexRunsUseTheirOwnBoundTranscript() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        for index in 0..<2 {
            let id = UUID().uuidString
            let path = root.appendingPathComponent("rollout-\(index).jsonl")
            try Data("{\"type\":\"session_meta\",\"payload\":{\"id\":\"\(id)\",\"cwd\":\"/same\"}}\n".utf8).write(to: path)
            let result = ControllerUsageCollector.codex(home: root.path,
                transcript: ProviderTranscript(sessionID: id, path: path.path), account: "fixture")
            #expect(result.1 == .complete)
            let wrong = ControllerUsageCollector.codex(home: root.path,
                transcript: ProviderTranscript(sessionID: "wrong", path: path.path), account: "fixture")
            #expect(wrong.1 == .failed)
        }
    }

    @Test func tooManyClaudeChildrenCannotReportCompleteCoverage() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let project = root.appendingPathComponent("projects/fixture")
        let children = project.appendingPathComponent("session/subagents")
        try FileManager.default.createDirectory(at: children, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data().write(to: project.appendingPathComponent("session.jsonl"))
        for index in 0..<201 { try Data().write(to: children.appendingPathComponent("\(index).jsonl")) }
        let result = ControllerUsageCollector.claude(home: root.path, session: "session", account: "fixture")
        #expect(result.1 == .partial && result.2 == "subagent_transcripts_incomplete")
    }

    @Test func mailTransportTimeoutReturnsAndNextExchangeCanRun() async throws {
        let start = Date()
        let failure = await #expect(throws: ControllerRuntimeError.self) {
            try await ControllerMailSync.run(["/bin/sh", "-c", "trap '' TERM; sleep 30 & wait"], input: Data(), limit: 1024, timeout: 0.2)
        }
        guard case .timedOut = failure else { Issue.record("Expected timedOut"); return }
        #expect(Date().timeIntervalSince(start) < 3)
        let result = try await ControllerMailSync.run(["/bin/sh", "-c", "cat"], input: Data("ok".utf8), limit: 1024, timeout: 1)
        #expect(result == Data("ok".utf8))
    }
}
