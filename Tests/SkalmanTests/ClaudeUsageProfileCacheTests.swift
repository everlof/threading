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

    override func setUpWithError() throws {
        try super.setUpWithError()
        configDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("claude-profile-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: configDirectory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: configDirectory)
        try super.tearDownWithError()
    }

    // MARK: - Tests

    /// The shape Claude Code writes, taken from a real account: the account's own windows in
    /// their fixed slots, and the scoped one findable only in `limits`.
    func testReadsAccountWindowsAndTheScopedModelWindow() throws {
        try write(profile(fetchedAtMs: Self.observedAtMs))

        let usage = try XCTUnwrap(ClaudeUsageProfileCache.read(account: account()))

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

        let usage = try XCTUnwrap(ClaudeUsageProfileCache.read(account: account()))

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

        let usage = try XCTUnwrap(ClaudeUsageProfileCache.read(account: account()))
        XCTAssertTrue(usage.modelWindows.isEmpty)
    }

    /// Freshness is the file's own stamp, and a snapshot claiming the future is not one.
    func testSnapshotFromTheFutureIsRejected() throws {
        let ahead = (Date().timeIntervalSince1970 + 3600) * 1000
        try write(profile(fetchedAtMs: ahead))

        XCTAssertNil(ClaudeUsageProfileCache.read(account: account()))
    }

    /// Every absent-source failure means one thing to the caller: no reading from here.
    func testMissingFileReadsAsNoSnapshot() {
        XCTAssertNil(ClaudeUsageProfileCache.read(account: account()))
    }

    func testProfileWithoutUsageReadsAsNoSnapshot() throws {
        try write(#"{"userID": "abc", "projects": {}}"#)

        XCTAssertNil(ClaudeUsageProfileCache.read(account: account()))
    }

    // MARK: - Helpers

    private func account() -> AgentAccount {
        AgentAccount(
            provider: .claude,
            handle: AccountHandle(storedName: "claude-test"),
            configPath: configDirectory.path
        )
    }

    private func write(_ json: String) throws {
        try json.write(
            to: configDirectory.appendingPathComponent(".claude.json"),
            atomically: true,
            encoding: .utf8
        )
    }

    private func profile(fetchedAtMs: Double) -> String {
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
                  "kind": "weekly_scoped", "group": "weekly", "percent": 89,
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
