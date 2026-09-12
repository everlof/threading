import XCTest
@testable import Threading

/// The search projection runs inside a project-store observer on the main actor, once per
/// event, over every retained session. Placing a Codex conversation means finding its rollout
/// in the account's sessions tree, and the projection used to do that per conversation, in
/// that observer — the sidebar-click stall of 2026-09-03. This pins the split that replaced it:
/// the main-actor pass reads nothing, and one walk on a worker places what is on disk.
@MainActor
final class TranscriptSearchRolloutDiscoveryTests: HostedStoreTestCase {

    func testTheCatalogueIsPlacedByOneWalkOffTheMainActor() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ThreadingSearchRollouts-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let handle = AccountHandle.named("search-rollouts")
        let account = AgentAccount(provider: .codex, handle: handle, configPath: root.path)
        CodexTranscript.invalidateCache()
        defer {
            CodexTranscript.invalidateCache()
            try? FileManager.default.removeItem(at: root)
        }

        let project = try XCTUnwrap(ProjectStore.shared.addProject(folderURL: root))
        var onDisk: [SessionID] = []
        for index in 0..<24 {
            let transcriptID = TranscriptID(UUID().uuidString.lowercased())
            let session = try XCTUnwrap(ProjectStore.shared.addSession(
                to: project.id,
                kind: .codex,
                accountHandle: handle,
                title: "Conversation \(index)"
            ))
            _ = ProjectStore.shared.update(sessionID: session.id) { session in
                session.resumeState = .resumable(transcriptID)
            }
            // Most of a retained catalogue has no rollout any more; four of these do.
            if index < 4 {
                try writeRollout(id: transcriptID, in: root)
                onDisk.append(session.id)
            }
        }

        let walksBefore = CodexTranscript.rolloutWalkCount
        let store = TranscriptSearchIndexStore(
            projectStore: .shared,
            databaseURL: root.appendingPathComponent("search-index.sqlite"),
            notificationCenter: NotificationCenter(),
            accountResolver: { _, _ in account }
        )

        // The main-actor projection placed nothing it would have had to walk for.
        XCTAssertEqual(store.projectedSourceCount, 0)
        XCTAssertEqual(CodexTranscript.rolloutWalkCount, walksBefore)

        // One walk on the worker places exactly the conversations that are on disk.
        let deadline = Date().addingTimeInterval(5)
        while store.projectedSourceCount < onDisk.count, Date() < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(store.projectedSourceCount, onDisk.count)
        XCTAssertEqual(CodexTranscript.rolloutWalkCount - walksBefore, 1)
        withExtendedLifetime(store) {}
    }

    func testWorkOnAnotherAccountCannotDiscardAnInflightDiscovery() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("search-account-work-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let first = AgentAccount(provider: .codex, handle: .named("first"), configPath: root.appendingPathComponent("first").path)
        let second = AgentAccount(provider: .codex, handle: .named("second"), configPath: root.appendingPathComponent("second").path)
        CodexTranscript.invalidateCache()
        defer {
            CodexTranscript.invalidateCache()
            try? FileManager.default.removeItem(at: root)
        }
        let project = try XCTUnwrap(ProjectStore.shared.addProject(folderURL: root))
        let firstID = TranscriptID(UUID().uuidString.lowercased())
        let secondID = TranscriptID(UUID().uuidString.lowercased())
        try writeRollout(id: firstID, in: URL(fileURLWithPath: first.configPath))
        try writeRollout(id: secondID, in: URL(fileURLWithPath: second.configPath))
        let firstSession = try XCTUnwrap(ProjectStore.shared.addSession(
            to: project.id, kind: .codex, accountHandle: first.handle, title: "First"
        ))
        ProjectStore.shared.update(sessionID: firstSession.id) {
            $0.accountHandle = first.handle
            $0.resumeState = .resumable(firstID)
        }
        let walksBefore = CodexTranscript.rolloutWalkCount
        let store = TranscriptSearchIndexStore(
            databaseURL: root.appendingPathComponent("index.sqlite"),
            accountResolver: { _, handle in handle == first.handle ? first : second }
        )
        // The first worker cannot deliver its result on the main actor until this turn yields.
        let secondSession = try XCTUnwrap(ProjectStore.shared.addSession(
            to: project.id, kind: .codex, accountHandle: second.handle, title: "Second"
        ))
        ProjectStore.shared.update(sessionID: secondSession.id) {
            $0.accountHandle = second.handle
            $0.resumeState = .resumable(secondID)
        }
        ProjectStore.shared.noteTurnStarted(sessionID: secondSession.id)
        let deadline = Date().addingTimeInterval(5)
        while store.projectedSourceCount < 2, Date() < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(store.projectedSourceCount, 2)
        XCTAssertEqual(CodexTranscript.rolloutWalkCount - walksBefore, 2)
        withExtendedLifetime(store) {}
    }

    private func writeRollout(id: TranscriptID, in root: URL) throws {
        let directory = root
            .appendingPathComponent(AgentAccountDefaults.sessionsSubdirectory)
            .appendingPathComponent("2026/09/03")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("rollout-2026-09-03T10-00-00-\(id.rawValue).jsonl")
        try Data("{}\n".utf8).write(to: url)
    }
}
