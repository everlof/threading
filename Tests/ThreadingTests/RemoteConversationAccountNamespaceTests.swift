import XCTest
@testable import Threading

@MainActor
final class RemoteConversationAccountNamespaceTests: XCTestCase {
    func testNewChatsUseACopiedAccountOnlyWithConsent() {
        for kind in [AgentKind.claude, .codex] {
            for native in [false, true] {
                let session = AgentSession(kind: kind, title: "New remote chat", usesNativeUI: native)
                XCTAssertTrue(RemoteConversationAccount.usesCopiedAccount(for: session, reuseCredentials: true))
                XCTAssertFalse(RemoteConversationAccount.usesCopiedAccount(for: session, reuseCredentials: false))
            }
        }
    }

    func testLegacyRemoteHistoryKeepsTheHostAccountWhenNativePresentationOpens() {
        var session = AgentSession(kind: .claude, title: "Existing remote chat", usesNativeUI: false)
        session.resumeState = .resumable(TranscriptID(UUID().uuidString))
        session.usesNativeUI = true
        XCTAssertFalse(RemoteConversationAccount.usesCopiedAccount(for: session, reuseCredentials: true))
    }

    func testPinnedChatAccountsSurviveLaterConsentChanges() {
        var session = AgentSession(kind: .codex, title: "Existing remote chat", usesNativeUI: true)
        session.resumeState = .resumable(TranscriptID(UUID().uuidString))
        session.remoteUsesCopiedAccount = true
        XCTAssertTrue(RemoteConversationAccount.usesCopiedAccount(for: session, reuseCredentials: false))
        session.remoteUsesCopiedAccount = false
        XCTAssertFalse(RemoteConversationAccount.usesCopiedAccount(for: session, reuseCredentials: true))
    }

    func testUsingTheHostLoginNeverSelectsAnEmptyMacAccountNamespace() throws {
        let account = AgentAccount(provider: .claude, handle: .named("claude-work"), configPath: "/Users/me/.claude-work")
        let remote = try RemoteConversationAccount.make(account: account, home: "/home/remote", reuse: false)
        XCTAssertEqual(remote.directory, "/home/remote/.claude")
    }

    func testCopiedClaudeLoginOverridesShellProfileTokensWithoutChangingHostOwnedLogins() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("remote-login-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: home) }
        let local = AgentAccount(provider: .claude, handle: .standard, configPath: "/Users/me/.claude")
        let copied = try RemoteConversationAccount.make(account: local, home: home.path, reuse: true)
        let script = try XCTUnwrap(copied.credentialEnvironmentScript(for: .claude))
        let oauthEnvironment = try environmentAfterScript(script)
        XCTAssertNil(oauthEnvironment["CLAUDE_CODE_OAUTH_TOKEN"])
        XCTAssertNil(oauthEnvironment["ANTHROPIC_API_KEY"])
        XCTAssertNil(oauthEnvironment["ANTHROPIC_AUTH_TOKEN"])
        XCTAssertEqual(oauthEnvironment["CLAUDE_CONFIG_DIR"], copied.directory)
        try FileManager.default.createDirectory(atPath: copied.directory, withIntermediateDirectories: true)
        try Data("selected-fixture".utf8).write(to: URL(fileURLWithPath: copied.directory + "/threading-login-token"))
        XCTAssertEqual(try environmentAfterScript(script)["CLAUDE_CODE_OAUTH_TOKEN"], "selected-fixture")
        let host = try RemoteConversationAccount.make(account: local, home: home.path, reuse: false)
        XCTAssertEqual(try environmentAfterScript(host.credentialEnvironmentScript(for: .claude) ?? ":")["CLAUDE_CODE_OAUTH_TOKEN"], "profile-fixture")
    }

    func testCopiedCodexLoginClearsProfileAPIKeysAndRestoresItsSelectedHome() throws {
        let local = AgentAccount(provider: .codex, handle: .standard, configPath: "/Users/me/.codex")
        let copied = try RemoteConversationAccount.make(account: local, home: "/home/remote", reuse: true)
        let environment = try environmentAfterScript(try XCTUnwrap(copied.credentialEnvironmentScript(for: .codex)))
        XCTAssertNil(environment["OPENAI_API_KEY"])
        XCTAssertNil(environment["CODEX_API_KEY"])
        XCTAssertEqual(environment["CODEX_HOME"], copied.directory)
    }

    private func environmentAfterScript(_ script: String) throws -> [String: String] {
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", script + "\n/usr/bin/env"]
        process.environment = ["PATH": "/usr/bin:/bin", "CLAUDE_CODE_OAUTH_TOKEN": "profile-fixture",
            "ANTHROPIC_API_KEY": "profile-key", "ANTHROPIC_AUTH_TOKEN": "profile-token",
            "OPENAI_API_KEY": "profile-key", "CODEX_API_KEY": "profile-key",
            "CLAUDE_CONFIG_DIR": "/profile/claude", "CODEX_HOME": "/profile/codex"]
        process.standardOutput = output
        try process.run()
        let bytes = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
        return Dictionary(uniqueKeysWithValues: String(decoding: bytes, as: UTF8.self).split(separator: "\n").compactMap { line in
            let parts = line.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2 else { return nil }
            return (String(parts[0]), String(parts[1]))
        })
    }
}
