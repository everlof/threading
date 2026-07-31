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
