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

    private func writeRollout(id: TranscriptID, in root: URL) throws {
        let directory = root
            .appendingPathComponent(AgentAccountDefaults.sessionsSubdirectory)
            .appendingPathComponent("2026/09/03")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("rollout-2026-09-03T10-00-00-\(id.rawValue).jsonl")
        try Data("{}\n".utf8).write(to: url)
    }
}
