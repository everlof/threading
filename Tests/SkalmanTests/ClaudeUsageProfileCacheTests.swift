import XCTest
@testable import Skalman

/// The CLI's own `.claude.json` usage snapshot, which is the only local source that names a
/// model-scoped limit — the window that is routinely the binding one on a plan metering some
/// models separately.
final class ClaudeUsageProfileCacheTests: XCTestCase {

    /// The stamp the fixture claims, and the moment its windows are read against: a snapshot is
    /// only usable if it was taken in the past, so both have to sit before the reset times the
    /// fixture carries.
    private static let observedAtMs: Double = 1_785_153_531_896
    private var readAt: Date { Date(timeIntervalSince1970: Self.observedAtMs / 1000) }

    private var configDirectory: URL!
    private var homeDirectory: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        configDirectory = try makeDirectory(named: "claude-profile")
        homeDirectory = try makeDirectory(named: "claude-home")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: configDirectory)
        try? FileManager.default.removeItem(at: homeDirectory)
        try super.tearDownWithError()
    }

    // MARK: - Tests

    /// The shape Claude Code writes, taken from a real account: the account's own windows in
    /// their fixed slots, and the scoped one findable only in `limits`.
    func testReadsAccountWindowsAndTheScopedModelWindow() throws {
        try write(profile(fetchedAtMs: Self.observedAtMs))

        let usage = try XCTUnwrap(read(account: account()))

        XCTAssertEqual(usage.windows.map(\.id), ["5h", "7d"])
        XCTAssertEqual(try XCTUnwrap(usage.windows.first?.fraction), 0.07, accuracy: 0.0001)
        XCTAssertEqual(usage.source, .localCache)

        let scoped = try XCTUnwrap(usage.modelWindows.first)
        XCTAssertEqual(usage.modelWindows.count, 1)
        XCTAssertEqual(scoped.label, "Weekly · Fable")
        XCTAssertEqual(scoped.fraction ?? 0, 0.89, accuracy: 0.0001)
        XCTAssertEqual(scoped.windowDuration, UsageDefaults.sevenDaySeconds)
        XCTAssertNotNil(scoped.resetsAt)
    }

    /// The scoped window is kept out of `windows`, so the toolbar's peak still reports the
    /// account's pressure rather than one model's — the rule Codex's limits already follow.
    func testScopedWindowDoesNotBecomeTheAccountsPeak() throws {
        try write(profile(fetchedAtMs: Self.observedAtMs))

        let usage = try XCTUnwrap(read(account: account()))

        XCTAssertEqual(usage.peakWindow(at: readAt)?.id, "7d")
    }

    /// An entry with no model in its scope is the account's own window under another name;
    /// drawing it again would put two bars on one number.
    func testUnscopedLimitsAreNotTakenTwice() throws {
        try write("""
        {
          "cachedUsageUtilization": {
            "fetchedAtMs": \(Int(Self.observedAtMs)),
            "utilization": {
              "five_hour": {"utilization": 7, "resets_at": "2026-07-27T16:29:59.820092+00:00"},
              "seven_day": {"utilization": 56, "resets_at": "2026-07-28T09:59:59.820119+00:00"},
              "limits": [
                {"kind": "session", "group": "session", "percent": 7, "scope": null},
                {"kind": "weekly_all", "group": "weekly", "percent": 56, "scope": null}
              ]
            }
          }
        }
        """)

        let usage = try XCTUnwrap(read(account: account()))
        XCTAssertTrue(usage.modelWindows.isEmpty)
    }

    /// Freshness is the file's own stamp, and a snapshot claiming the future is not one.
    func testSnapshotFromTheFutureIsRejected() throws {
        let ahead = (Date().timeIntervalSince1970 + 3600) * 1000
        try write(profile(fetchedAtMs: ahead))

        XCTAssertNil(read(account: account()))
    }

    /// Every absent-source failure means one thing to the caller: no reading from here.
    func testMissingFileReadsAsNoSnapshot() {
        XCTAssertNil(read(account: account()))
    }

    func testProfileWithoutUsageReadsAsNoSnapshot() throws {
        try write(#"{"userID": "abc", "projects": {}}"#)

        XCTAssertNil(read(account: account()))
    }

    /// The default login's config directory is `~/.claude`, but the file the CLI writes is
    /// `~/.claude.json` — one level up. Reading only under the config directory is how the
    /// default account lost its scoped window while every alternate login kept theirs.
    func testDefaultAccountReadsTheProfileInTheHomeDirectory() throws {
        try write(profile(fetchedAtMs: Self.observedAtMs), to: homeDirectory)

        let usage = try XCTUnwrap(read(account: defaultAccount()))

        XCTAssertEqual(usage.modelWindows.map(\.id), ["Fable"])
        XCTAssertEqual(usage.windows.map(\.id), ["5h", "7d"])
    }

    /// Both places are read because the CLI has been moving the file; the later stamp is the
    /// one it is writing now, and a leftover under the config directory must not win.
    func testTheNewerOfTheTwoProfilesWins() throws {
        try write(profile(fetchedAtMs: Self.observedAtMs - 86_400_000, percent: 12), to: configDirectory)
        try write(profile(fetchedAtMs: Self.observedAtMs), to: homeDirectory)

        let usage = try XCTUnwrap(read(account: defaultAccount()))

        XCTAssertEqual(try XCTUnwrap(usage.modelWindows.first?.fraction), 0.89, accuracy: 0.0001)
    }

    /// An alternate login keeps its own `.claude.json` under `CLAUDE_CONFIG_DIR`. The home file
    /// belongs to the default login, and reporting its windows here would name another
    /// account's usage.
    func testAlternateAccountIgnoresTheHomeProfile() throws {
        try write(profile(fetchedAtMs: Self.observedAtMs), to: homeDirectory)

        XCTAssertNil(read(account: account()))
    }

    // MARK: - Helpers

    private func read(account: AgentAccount) -> AccountUsage? {
        ClaudeUsageProfileCache.read(account: account, home: homeDirectory)
    }

    private func account() -> AgentAccount {
        AgentAccount(
            provider: .claude,
            handle: AccountHandle(storedName: "claude-test"),
            configPath: configDirectory.path
        )
    }

    private func defaultAccount() -> AgentAccount {
        AgentAccount(
            provider: .claude,
            handle: .standard,
            configPath: configDirectory.path
        )
    }

    private func makeDirectory(named name: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(name)-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func write(_ json: String, to directory: URL? = nil) throws {
        try json.write(
            to: (directory ?? configDirectory).appendingPathComponent(".claude.json"),
            atomically: true,
            encoding: .utf8
        )
    }

    private func profile(fetchedAtMs: Double, percent: Int = 89) -> String {
        """
        {
          "userID": "abc",
          "cachedUsageUtilization": {
            "fetchedAtMs": \(Int(fetchedAtMs)),
            "utilization": {
              "five_hour": {"utilization": 7, "resets_at": "2026-07-27T16:29:59.820092+00:00"},
              "seven_day": {"utilization": 56, "resets_at": "2026-07-28T09:59:59.820119+00:00"},
              "seven_day_opus": null,
              "limits": [
                {
                  "kind": "session", "group": "session", "percent": 7,
                  "resets_at": "2026-07-27T16:29:59.820092+00:00", "scope": null
                },
                {
                  "kind": "weekly_all", "group": "weekly", "percent": 56,
                  "resets_at": "2026-07-28T09:59:59.820119+00:00", "scope": null
                },
                {
                  "kind": "weekly_scoped", "group": "weekly", "percent": \(percent),
                  "resets_at": "2026-07-28T09:59:59.820666+00:00",
                  "scope": {"model": {"id": null, "display_name": "Fable"}, "surface": null}
                }
              ]
            }
          }
        }
        """
    }
}
