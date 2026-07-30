import XCTest
@testable import Threading

final class HotPathCacheTests: XCTestCase {

    func testAccountDiscoveryCacheSeparatesProvidersAndExpires() {
        let cache = AgentAccountDiscoveryCache(lifetime: 7)
        let start = Date(timeIntervalSinceReferenceDate: 1_000)
        var claudeScans = 0
        var codexScans = 0

        func account(_ provider: AgentKind, suffix: Int) -> AgentAccount {
            AgentAccount(
                provider: provider,
                handle: .named("account-\(suffix)"),
                configPath: "/tmp/account-\(suffix)"
            )
        }

        let first = cache.accounts(for: .claude, at: start) {
            claudeScans += 1
            return [account(.claude, suffix: claudeScans)]
        }
        let cached = cache.accounts(for: .claude, at: start.addingTimeInterval(6)) {
            claudeScans += 1
            return [account(.claude, suffix: claudeScans)]
        }
        let otherProvider = cache.accounts(for: .codex, at: start) {
            codexScans += 1
            return [account(.codex, suffix: codexScans)]
        }
        let expired = cache.accounts(for: .claude, at: start.addingTimeInterval(8)) {
            claudeScans += 1
            return [account(.claude, suffix: claudeScans)]
        }

        XCTAssertEqual(first, cached)
        XCTAssertNotEqual(first, expired)
        XCTAssertEqual(otherProvider.first?.provider, .codex)
        XCTAssertEqual(claudeScans, 2)
        XCTAssertEqual(codexScans, 1)
    }

    func testCodexTranscriptMemoizesByAccountAndSession() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ThreadingTranscriptCache-\(UUID().uuidString)")
        let sessions = root.appendingPathComponent(AgentAccountDefaults.sessionsSubdirectory)
            .appendingPathComponent("2026/07/22")
        let transcriptID = TranscriptID("019be93b-80c7-7740-98ec-5c6873af3669")
        let rollout = sessions.appendingPathComponent("rollout-test-\(transcriptID.rawValue).jsonl")
        defer {
            CodexTranscript.invalidateCache()
            try? FileManager.default.removeItem(at: root)
        }

        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
        try Data("{}\n".utf8).write(to: rollout)
        let account = AgentAccount(
            provider: .codex,
            handle: .named("cache-test"),
            configPath: root.path
        )

        let located = try XCTUnwrap(
            CodexTranscript.url(sessionID: transcriptID, account: account)
        )
        XCTAssertEqual(
            located.resolvingSymlinksInPath(),
            rollout.resolvingSymlinksInPath()
        )

        // Rollout paths do not move during a conversation. Removing the fixture proves the
        // second lookup came from the memo instead of walking the sessions tree again.
        try FileManager.default.removeItem(at: rollout)
        XCTAssertEqual(CodexTranscript.url(sessionID: transcriptID, account: account), located)

        CodexTranscript.invalidateCache()
        XCTAssertNil(CodexTranscript.url(sessionID: transcriptID, account: account))
    }

    func testGitLocationMemoPersistsUntilCheckoutRefresh() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ThreadingGitCache-\(UUID().uuidString)")
        let dotGit = root.appendingPathComponent(".git")
        defer { try? FileManager.default.removeItem(at: root) }

        try FileManager.default.createDirectory(at: dotGit, withIntermediateDirectories: true)
        try Data("ref: refs/heads/main\n".utf8)
            .write(to: dotGit.appendingPathComponent(GitDefaults.headFile))

        let initial = try XCTUnwrap(GitInfo.worktreeLocation(for: root.path))
        XCTAssertEqual(initial.root, root.standardizedFileURL)

        try FileManager.default.removeItem(at: dotGit)
        XCTAssertEqual(GitInfo.worktreeLocation(for: root.path), initial)

        GitInfo.invalidateCache(for: root.path)
        XCTAssertNil(GitInfo.worktreeLocation(for: root.path))
    }
}
