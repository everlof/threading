import XCTest
@testable import Threading

/// The Claude usage chain, tested where it can be tested without a network: the credentials
/// file's own verdict, and the fall-through that must happen when that verdict is "no".
///
/// The bug these pin: a `<config>/.credentials.json` left behind by an older layout goes stale
/// while the CLI refreshes the *Keychain* item it actually uses. Reading the stale file's expiry
/// as the account's verdict put "The account's login has expired" under a login that was
/// serving a turn at that moment — with a status-line reading minutes old on disk, unread.
final class ClaudeUsageFetcherTests: XCTestCase {

    /// Both halves of the skew rule are asserted against one clock rather than `Date()`.
    private let now = Date(timeIntervalSince1970: 1_785_513_600)

    private var configDirectory: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        configDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("claude-usage-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: configDirectory,
            withIntermediateDirectories: true
        )
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: configDirectory)
        try super.tearDownWithError()
    }

    // MARK: - The Credentials File's Own Verdict

    /// The shape the CLI writes, with a token that still has hours left.
    func testLiveTokenIsUsableAndCarriesItsDisplayCasedPlan() {
        let source = ClaudeUsageFetcher.credentials(
            fromFile: payload(expiresAt: now.addingTimeInterval(3600)),
            at: now
        )

        XCTAssertEqual(source, .usable(token: "sk-fixture", plan: "Max"))
    }

    /// A token with no stated expiry is taken at its word — the CLI is the one refreshing it.
    func testTokenWithoutAnExpiryIsUsable() {
        let source = ClaudeUsageFetcher.credentials(fromFile: payload(expiresAt: nil), at: now)

        XCTAssertEqual(source, .usable(token: "sk-fixture", plan: "Max"))
    }

    /// A stale token is `.unusable`, never `.absent`: the distinction is what lets the chain
    /// still say "expired" if nothing else can serve either.
    func testExpiredTokenIsUnusableRatherThanAbsent() {
        let source = ClaudeUsageFetcher.credentials(
            fromFile: payload(expiresAt: now.addingTimeInterval(-1)),
            at: now
        )

        XCTAssertEqual(source, .unusable(reason: .tokenExpired))
    }

    /// A token about to expire is already expired, so the API call is not wasted.
    func testTokenInsideTheExpirySkewIsAlreadyExpired() {
        let source = ClaudeUsageFetcher.credentials(
            fromFile: payload(
                expiresAt: now.addingTimeInterval(ClaudeUsageDefaults.expirySkew - 1)
            ),
            at: now
        )

        XCTAssertEqual(source, .unusable(reason: .tokenExpired))
    }

    /// A file that is there but says nothing usable is a file that cannot serve — and the
    /// message names the file rather than the login, because the login is not what failed.
    func testUnreadablePayloadIsUnusableWithoutBlamingTheLogin() {
        let source = ClaudeUsageFetcher.credentials(fromFile: Data("not json".utf8), at: now)

        XCTAssertEqual(
            source,
            .unusable(reason: .noCredential("The account's credentials file is unreadable."))
        )
    }

    /// A credentials file is a few hundred bytes; anything huge is not one, and is not parsed.
    func testOversizedPayloadIsRefusedUnparsed() {
        let bloat = Data(count: ClaudeUsageDefaults.credentialsMaxBytes + 1)

        guard case .unusable = ClaudeUsageFetcher.credentials(fromFile: bloat, at: now) else {
            return XCTFail("an oversized payload must not be trusted")
        }
    }

    func testOversizedCredentialsFileIsBoundedBeforeAllocationAndParsing() throws {
        try Data(count: ClaudeUsageDefaults.credentialsMaxBytes + 1).write(
            to: configDirectory.appendingPathComponent(".credentials.json")
        )

        guard case .unusable = ClaudeUsageFetcher.readCredentialsFile(account: account()) else {
            return XCTFail("an oversized credentials file must be refused at the read boundary")
        }
    }

    // MARK: - The Chain

    /// The regression itself. A stale credentials file must not answer for the whole account:
    /// the sources below it still hold real numbers, and this one returns them.
    ///
    /// No network is reached — the file token never gets to the API, the Keychain is hermetically
    /// closed under tests, and Claudex's cache has no file for a temporary config directory. What
    /// is left is the CLI's own `.claude.json` snapshot, which is exactly the point.
    func testStaleCredentialsFileFallsThroughToTheLocalSnapshot() async throws {
        try writeCredentialsFile(expiresAt: Date().addingTimeInterval(-3600))
        try writeProfileSnapshot()

        let usage = try await ClaudeUsageFetcher.fetch(account: account())

        XCTAssertEqual(usage.windows.map(\.id), ["5h", "7d"])
        XCTAssertEqual(try XCTUnwrap(usage.windows.first?.fraction), 0.07, accuracy: 0.0001)
    }

    /// And when the stale file really is all there was, the chain still says so — the honest
    /// case the message was written for.
    func testExpiredLoginIsStillReportedWhenNothingElseCanServe() async throws {
        try writeCredentialsFile(expiresAt: Date().addingTimeInterval(-3600))

        do {
            _ = try await ClaudeUsageFetcher.fetch(account: account())
            XCTFail("a login with no readable source must not report usage")
        } catch let error as UsageFetchError {
            XCTAssertEqual(error, .tokenExpired)
        }
    }

    /// An account with no credentials file anywhere is not an expired login, and must never be
    /// described as one.
    func testAccountWithNoTokenAtAllIsNotCalledExpired() async throws {
        do {
            _ = try await ClaudeUsageFetcher.fetch(account: account())
            XCTFail("an account with no source must not report usage")
        } catch let error as UsageFetchError {
            XCTAssertEqual(
                error,
                .noCredential("No readable usage source for this Claude account.")
            )
        }
    }

    // MARK: - Scoped-Window Backfill

    /// The status-line feed owns the fresh account windows but has no scoped limits. A profile
    /// snapshot from the previous Fable window must not poison that fresh reading: downstream
    /// admission rejects any expired relevant window, which used to make an account at 8% / 36%
    /// look as though it had no headroom at all.
    func testExpiredProfileScopedWindowIsNotMergedIntoFreshStatusReading() {
        let status = usage(
            windows: [window(id: "5h", fraction: 0.08, resetsAt: now.addingTimeInterval(3600))]
        )
        var profile = usage(windows: [])
        profile.modelWindows = [
            window(
                id: "Fable",
                fraction: 0.64,
                resetsAt: now.addingTimeInterval(-1),
                scopeName: "Fable"
            ),
        ]

        let merged = ClaudeUsageFetcher.withModelWindows(from: profile, on: status, at: now)

        XCTAssertTrue(merged.modelWindows.isEmpty)
        XCTAssertEqual(merged.windows, status.windows)
    }

    func testOnlyCurrentProfileScopedWindowsAreMerged() {
        let status = usage(
            windows: [window(id: "7d", fraction: 0.36, resetsAt: now.addingTimeInterval(7200))]
        )
        var profile = usage(windows: [])
        let expired = window(
            id: "Fable",
            fraction: 0.64,
            resetsAt: now.addingTimeInterval(-1),
            scopeName: "Fable"
        )
        let current = window(
            id: "Opus",
            fraction: 0.12,
            resetsAt: now.addingTimeInterval(3600),
            scopeName: "Opus"
        )
        profile.modelWindows = [expired, current]

        let merged = ClaudeUsageFetcher.withModelWindows(from: profile, on: status, at: now)

        XCTAssertEqual(merged.modelWindows, [current])
    }

    // MARK: - The Endpoint Document

    /// The usage endpoint serves the same utilization document the CLI caches, scoped limits
    /// included — and the live fetch must decode all of it. It used to read only the fixed
    /// `five_hour`/`seven_day` pair, so every account whose reading came from the API showed
    /// its Fable window nowhere: the response named it and the fetcher threw it away, then
    /// hoped to recover it from a `.claude.json` cache that often does not exist.
    ///
    /// The fixture is the endpoint's real shape, quirks included: a scoped limit can carry
    /// `resets_at: null` and a zero percent, and its model is named by `display_name` with a
    /// null `id`.
    func testEndpointDocumentCarriesItsOwnScopedWindows() throws {
        let payload = Data("""
        {
          "five_hour": {"utilization": 41, "resets_at": "2026-07-27T16:29:59.872906+00:00"},
          "seven_day": {"utilization": 77, "resets_at": "2026-07-28T09:59:59.872925+00:00"},
          "seven_day_opus": null,
          "limits": [
            {"kind": "session", "group": "session", "percent": 41, "scope": null,
             "resets_at": "2026-07-27T16:29:59.872906+00:00", "is_active": true},
            {"kind": "weekly_all", "group": "weekly", "percent": 77, "scope": null,
             "resets_at": "2026-07-28T09:59:59.872925+00:00", "is_active": false},
            {"kind": "weekly_scoped", "group": "weekly", "percent": 0, "resets_at": null,
             "scope": {"model": {"id": null, "display_name": "Fable"}, "surface": null},
             "is_active": false}
          ]
        }
        """.utf8)

        let document = try UsageHTTP.snakeCaseDecoder()
            .decode(ClaudeUtilization.self, from: payload)

        XCTAssertEqual(document.accountWindows().map(\.id), ["5h", "7d"])
        XCTAssertEqual(
            try XCTUnwrap(document.accountWindows().first?.fraction),
            0.41,
            accuracy: 0.0001
        )

        let scoped = try XCTUnwrap(document.modelWindows().first)
        XCTAssertEqual(document.modelWindows().count, 1)
        XCTAssertEqual(scoped.scopeName, "Fable")
        XCTAssertEqual(scoped.compactName, "7d Fable")
        XCTAssertEqual(scoped.fraction, 0)
        XCTAssertNil(scoped.resetsAt)
    }

    /// An account slot that is present with its value missing keeps its identity — the reading
    /// renders `—` for it — rather than vanishing from the list.
    func testWindowWithUnknownValueKeepsItsIdentity() throws {
        let payload = Data("""
        {
          "five_hour": {"utilization": null, "resets_at": "2026-07-27T16:29:59.872906+00:00"},
          "seven_day": {"utilization": 77, "resets_at": "2026-07-28T09:59:59.872925+00:00"}
        }
        """.utf8)

        let document = try UsageHTTP.snakeCaseDecoder()
            .decode(ClaudeUtilization.self, from: payload)

        XCTAssertEqual(document.accountWindows().map(\.id), ["5h", "7d"])
        XCTAssertNil(try XCTUnwrap(document.accountWindows().first).fraction)
    }

    // MARK: - Helpers

    /// An alternate login, so the default account's `~/.claude.json` is never consulted and the
    /// fixture directory is the only thing read.
    private func account() -> AgentAccount {
        AgentAccount(
            provider: .claude,
            handle: AccountHandle(storedName: "claude-usage-fixture"),
            configPath: configDirectory.path
        )
    }

    private func usage(windows: [AccountUsage.Window]) -> AccountUsage {
        AccountUsage(
            windows: windows,
            planLabel: "Max",
            observedAt: now,
            source: .localCache
        )
    }

    private func window(
        id: String,
        fraction: Double,
        resetsAt: Date,
        scopeName: String? = nil
    ) -> AccountUsage.Window {
        AccountUsage.Window(
            id: id,
            label: id,
            fraction: fraction,
            resetsAt: resetsAt,
            windowDuration: 7 * 24 * 60 * 60,
            scopeName: scopeName
        )
    }

    /// The CLI's own document, trimmed to what the fetcher reads.
    private func payload(expiresAt: Date?) -> Data {
        let expiry = expiresAt.map { "\"expiresAt\": \(Int($0.timeIntervalSince1970 * 1000))," }
        return Data("""
        {
          "claudeAiOauth": {
            "accessToken": "sk-fixture",
            \(expiry ?? "")
            "subscriptionType": "max"
          }
        }
        """.utf8)
    }

    private func writeCredentialsFile(expiresAt: Date?) throws {
        try payload(expiresAt: expiresAt).write(
            to: configDirectory.appendingPathComponent(".credentials.json")
        )
    }

    /// `cachedUsageUtilization` as the CLI writes it, stamped just now so it reads as a
    /// snapshot from the past.
    private func writeProfileSnapshot() throws {
        let fetchedAtMs = Int(Date().addingTimeInterval(-60).timeIntervalSince1970 * 1000)
        try """
        {
          "userID": "abc",
          "cachedUsageUtilization": {
            "fetchedAtMs": \(fetchedAtMs),
            "utilization": {
              "five_hour": {"utilization": 7, "resets_at": "2026-07-27T16:29:59.820092+00:00"},
              "seven_day": {"utilization": 56, "resets_at": "2026-07-28T09:59:59.820119+00:00"}
            }
          }
        }
        """.write(
            to: configDirectory.appendingPathComponent(".claude.json"),
            atomically: true,
            encoding: .utf8
        )
    }
}
