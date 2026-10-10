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

    // MARK: - Usage Feed

    /// The input Claude Code 2.1.296 hands the line once a session has had its first API
    /// response, trimmed. The one before that has no `rate_limits` key at all.
    private let inputWithLimits = #"{"session_id":"s","version":"2.1.296","rate_limits":{"five_hour":{"used_percentage":3,"resets_at":1791628800},"seven_day":{"used_percentage":16,"resets_at":1791968400}}}"#
    private let inputWithoutLimits = #"{"session_id":"s","version":"2.1.296","cost":{"total_cost_usd":0}}"#

    /// The feed is run, not inspected: what matters is what a shell does with it. A payload
    /// naming no limits must not replace a good reading, and with no command of the account's
    /// own the line prints nothing — which the CLI draws as no line at all.
    func testFeedSavesOnlyInputThatCarriesRateLimitsAndPrintsNothingOnItsOwn() throws {
        let directory = try makeDirectory(named: "status-feed")
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("not-yet-created/profile.json")
        let command = ClaudeStatusLineSettings.feedCommand(writingTo: file, then: nil)

        XCTAssertEqual(try run(command, input: inputWithoutLimits), "")
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))

        XCTAssertEqual(try run(command, input: inputWithLimits), "")
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), inputWithLimits)
        let mode = try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? Int
        XCTAssertEqual(mode, 0o600, "the input names the session's paths; it stays the user's")

        XCTAssertEqual(try run(command, input: inputWithoutLimits), "")
        XCTAssertEqual(
            try String(contentsOf: file, encoding: .utf8),
            inputWithLimits,
            "an input before the first API response keeps the last good reading"
        )
    }

    /// The account's own line still gets the CLI's exact input on stdin and still draws.
    func testFeedHandsTheInputOnToTheAccountsOwnCommand() throws {
        let directory = try makeDirectory(named: "status-feed-chain")
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("profile.json")

        let command = ClaudeStatusLineSettings.feedCommand(writingTo: file, then: "cat; printf ' drawn'")

        XCTAssertEqual(try run(command, input: inputWithLimits), inputWithLimits + " drawn")
        XCTAssertEqual(try run(command, input: inputWithoutLimits), inputWithoutLimits + " drawn")
    }

    /// What the feed saved reads back as this account's usage, timed by the file.
    func testSavedFeedReadsBackAsTheAccountsUsage() throws {
        let account = AgentAccount(
            provider: .claude,
            handle: .named("status-feed"),
            configPath: try makeDirectory(named: "status-feed-account").path
        )
        let file = ClaudeUsageCache.feedFileURL(forConfigPath: account.configPath)
        defer {
            try? FileManager.default.removeItem(at: file)
            try? FileManager.default.removeItem(atPath: account.configPath)
        }
        let command = ClaudeStatusLineSettings.feedCommand(writingTo: file, then: nil)
        _ = try run(command, input: inputWithLimits)

        let usage = try XCTUnwrap(ClaudeUsageCache.readFeed(account: account))

        XCTAssertEqual(usage.source, .localCache)
        XCTAssertEqual(usage.windows.map(\.id), [UsageDefaults.fiveHourWindowID, UsageDefaults.weeklyWindowID])
        XCTAssertEqual(usage.windows.map(\.fraction), [0.03, 0.16])
        XCTAssertEqual(usage.windows.first?.resetsAt, Date(timeIntervalSince1970: 1_791_628_800))
        XCTAssertLessThan(abs(usage.observedAt.timeIntervalSinceNow), 60)
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

    /// Runs a status-line command the way the CLI does: through a shell, with the input on stdin.
    private func run(_ command: String, input: String) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", command]
        let stdin = Pipe()
        let stdout = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        try process.run()
        stdin.fileHandleForWriting.write(Data(input.utf8))
        try stdin.fileHandleForWriting.close()
        let output = stdout.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: output, as: UTF8.self)
    }

    private func makeDirectory(named name: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(name)-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
