import XCTest
@testable import Threading

/// Covers how Threading resolves the `statusLine` command an account would run, and the wrapper
/// that silences it for the terminals Threading launches.
///
/// Nothing here runs the command. Threading used to, to learn which facts the line already showed
/// so the status card could drop them; the card now shows every fact it can extract and the probe
/// is gone — see `ClaudeStatusLineSettings`. What is left reads settings files, which is why
/// resolution order is the thing worth pinning.
final class ClaudeStatusLineSettingsTests: XCTestCase {

    // MARK: - Suppression

    /// The wrapper the launcher writes when the user hides the line: the command survives
    /// whole — a pipeline or list wraps as one group — and neither stdout nor stderr reaches
    /// the terminal. The shape was verified against the real Claudex bridge, which kept
    /// writing its cache while printing nothing.
    func testSilencingWrapsTheWholeCommandAndBothStreams() {
        XCTAssertEqual(
            ClaudeStatusLineSettings.silencedCommand(wrapping: "statusline.sh"),
            "{ statusline.sh ; } >/dev/null 2>&1"
        )
        XCTAssertEqual(
            ClaudeStatusLineSettings.silencedCommand(wrapping: "read x | jq . && echo done"),
            "{ read x | jq . && echo done ; } >/dev/null 2>&1"
        )
    }

    // MARK: - Resolution

    /// Resolution follows the CLI's own layer order, most-specific-first: a project's
    /// `.claude/settings.local.json` beats its `settings.json`, which beats the account's.
    /// Only `type: "command"` resolves — any other shape draws nothing, so there is nothing
    /// to silence.
    func testResolutionFollowsTheSettingsLayers() throws {
        // A managed policy replaces every writable layer outright, so on a machine that has
        // one this test would truthfully resolve the managed command and prove nothing.
        try XCTSkipIf(
            FileManager.default.fileExists(atPath: ClaudeSettingsDefaults.managedSettingsPath),
            "managed settings replace the layers under test"
        )

        let account = try makeDirectory(named: "status-line-account")
        let project = try makeDirectory(named: "status-line-project")
        defer {
            try? FileManager.default.removeItem(at: account)
            try? FileManager.default.removeItem(at: project)
        }

        func write(_ json: String, to url: URL) throws {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try Data(json.utf8).write(to: url)
        }

        let fixture = AgentAccount(
            provider: .claude,
            handle: .named("status-line"),
            configPath: account.path
        )

        // Only the account layer: its command resolves.
        try write(
            #"{"statusLine": {"type": "command", "command": "account-line"}}"#,
            to: account.appendingPathComponent("settings.json")
        )
        XCTAssertEqual(
            ClaudeStatusLineSettings.resolvedCommand(
                account: fixture,
                projectDirectory: project.path
            ),
            "account-line"
        )

        // A project layer overrides the account's.
        try write(
            #"{"statusLine": {"type": "command", "command": "project-line"}}"#,
            to: project.appendingPathComponent(".claude/settings.json")
        )
        XCTAssertEqual(
            ClaudeStatusLineSettings.resolvedCommand(
                account: fixture,
                projectDirectory: project.path
            ),
            "project-line"
        )

        // The local file overrides both.
        try write(
            #"{"statusLine": {"type": "command", "command": "local-line"}}"#,
            to: project.appendingPathComponent(".claude/settings.local.json")
        )
        XCTAssertEqual(
            ClaudeStatusLineSettings.resolvedCommand(
                account: fixture,
                projectDirectory: project.path
            ),
            "local-line"
        )

        // A shape that draws nothing resolves nothing — that layer simply does not count.
        try write(
            #"{"statusLine": {"type": "static", "text": "hello"}}"#,
            to: project.appendingPathComponent(".claude/settings.local.json")
        )
        XCTAssertEqual(
            ClaudeStatusLineSettings.resolvedCommand(
                account: fixture,
                projectDirectory: project.path
            ),
            "project-line",
            "a non-command layer is skipped, not resolved as empty"
        )
    }

    /// An account with no `statusLine` at all — `~/.claude-science` here — resolves nothing, so
    /// the launcher writes no override and the user's configuration is left exactly as it was.
    func testAnAccountWithNoStatusLineResolvesNothing() throws {
        try XCTSkipIf(
            FileManager.default.fileExists(atPath: ClaudeSettingsDefaults.managedSettingsPath),
            "managed settings replace the layers under test"
        )

        let account = try makeDirectory(named: "status-line-bare-account")
        let project = try makeDirectory(named: "status-line-bare-project")
        defer {
            try? FileManager.default.removeItem(at: account)
            try? FileManager.default.removeItem(at: project)
        }

        try Data(#"{"effortLevel": "high"}"#.utf8)
            .write(to: account.appendingPathComponent("settings.json"))

        XCTAssertNil(
            ClaudeStatusLineSettings.resolvedCommand(
                account: AgentAccount(
                    provider: .claude,
                    handle: .named("bare"),
                    configPath: account.path
                ),
                projectDirectory: project.path
            )
        )
    }

    private func makeDirectory(named name: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(name)-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
