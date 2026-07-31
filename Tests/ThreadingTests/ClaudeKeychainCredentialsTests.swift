import XCTest
@testable import Threading

/// The keychain accessor behind live usage, tested at its pure seams: the item-naming recipe,
/// payload parsing, expiry, and the retry arithmetic that keeps polling polite. The one
/// impure fact asserted is the hermetic guard itself — that under tests the accessor refuses
/// to touch the developer's real keychain at all, which is also why nothing here can prompt.
final class ClaudeKeychainCredentialsTests: XCTestCase {

    // MARK: - Service Naming

    /// The default login owns the bare service name — no suffix, however the path is spelt.
    func testDefaultConfigDirectoryMapsToTheBareServiceName() {
        let home = FileManager.default.homeDirectoryForCurrentUser.path

        XCTAssertEqual(
            ClaudeKeychainCredentials.serviceName(forConfigPath: "\(home)/.claude"),
            "Claude Code-credentials"
        )
        // An unnormalised spelling of the same directory is still the default login.
        XCTAssertEqual(
            ClaudeKeychainCredentials.serviceName(forConfigPath: "\(home)/./.claude/"),
            "Claude Code-credentials"
        )
    }

    /// An alternate config directory earns the suffixed service: eight lowercase hex characters
    /// of the canonical path's SHA-256. The full recipe was verified against the CLI's real
    /// items (see the type's own documentation); what this pins is the shape and the stability.
    func testAlternateConfigDirectoryMapsToTheSuffixedServiceName() {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let service = ClaudeKeychainCredentials.serviceName(
            forConfigPath: "\(home)/.claude-fixture-login"
        )

        XCTAssertTrue(service.hasPrefix("Claude Code-credentials-"))
        let suffix = service.dropFirst("Claude Code-credentials-".count)
        XCTAssertEqual(suffix.count, 8)
        XCTAssertTrue(suffix.allSatisfy(\.isHexDigit))
        XCTAssertEqual(suffix.lowercased(), String(suffix), "hex must be lowercase")

        // Same directory, differently spelt, is the same item.
        XCTAssertEqual(
            service,
            ClaudeKeychainCredentials.serviceName(
                forConfigPath: "\(home)/./.claude-fixture-login/"
            )
        )
        // A different directory is a different item.
        XCTAssertNotEqual(
            service,
            ClaudeKeychainCredentials.serviceName(forConfigPath: "\(home)/.claude-other-login")
        )
    }

    // MARK: - Payload Parsing

    /// The shape the CLI stores: the `.credentials.json` document, keychain-resident.
    func testParsesTheWrappedOAuthPayload() throws {
        let token = try XCTUnwrap(ClaudeKeychainCredentials.parse(payload(
            #"{"claudeAiOauth": {"accessToken": "tok-123", "expiresAt": 1785500000000, "subscriptionType": "max"}}"#
        )))

        XCTAssertEqual(token.accessToken, "tok-123")
        XCTAssertEqual(
            token.expiresAt,
            Date(timeIntervalSince1970: 1_785_500_000_000 / 1000)
        )
        XCTAssertEqual(token.plan, "Max")
    }

    /// A CLI release that drops the envelope should degrade to a working read, not a nil.
    func testParsesABareOAuthPayload() throws {
        let token = try XCTUnwrap(ClaudeKeychainCredentials.parse(payload(
            #"{"accessToken": "tok-9", "subscriptionType": "team_plan"}"#
        )))

        XCTAssertEqual(token.accessToken, "tok-9")
        XCTAssertNil(token.expiresAt, "an absent expiry stays unknown, not fabricated")
        XCTAssertEqual(token.plan, "Team Plan")
    }

    func testRejectsPayloadsThatCarryNoToken() {
        XCTAssertNil(ClaudeKeychainCredentials.parse(payload(#"{"claudeAiOauth": {}}"#)))
        XCTAssertNil(ClaudeKeychainCredentials.parse(payload(
            #"{"claudeAiOauth": {"accessToken": ""}}"#
        )))
        XCTAssertNil(ClaudeKeychainCredentials.parse(payload("not json")))
        XCTAssertNil(
            ClaudeKeychainCredentials.parse(Data(repeating: 0x20, count: 128 * 1024)),
            "an implausibly large item is not a credentials payload"
        )
    }

    // MARK: - Expiry

    /// The skew rule the credentials file already follows: about to expire is expired.
    func testTokenExpiryHonoursTheSkew() {
        let now = Date()
        let token = ClaudeKeychainCredentials.Token(
            accessToken: "tok",
            expiresAt: now.addingTimeInterval(KeychainCredentialsDefaults.expirySkew - 1),
            plan: nil
        )
        XCTAssertFalse(ClaudeKeychainCredentials.isUsable(token, at: now))

        let fresh = ClaudeKeychainCredentials.Token(
            accessToken: "tok",
            expiresAt: now.addingTimeInterval(KeychainCredentialsDefaults.expirySkew + 60),
            plan: nil
        )
        XCTAssertTrue(ClaudeKeychainCredentials.isUsable(fresh, at: now))

        let unbounded = ClaudeKeychainCredentials.Token(
            accessToken: "tok", expiresAt: nil, plan: nil
        )
        XCTAssertTrue(ClaudeKeychainCredentials.isUsable(unbounded, at: now))
    }

    // MARK: - Hermetic Guard

    /// A hosted test runs beside the developer's real keychain; the accessor must answer as
    /// though every item were absent rather than read one, however harmlessly. This is the
    /// assertion that keeps every other test in this bundle honest.
    func testTheAccessorRefusesTheRealKeychainUnderTests() {
        let home = FileManager.default.homeDirectoryForCurrentUser.path

        XCTAssertNil(ClaudeKeychainCredentials.token(forConfigPath: "\(home)/.claude"))
        XCTAssertEqual(
            ClaudeKeychainCredentials.availability(forConfigPath: "\(home)/.claude"),
            .missing
        )
        XCTAssertFalse(ClaudeKeychainCredentials.requestAccess(forConfigPath: "\(home)/.claude"))
    }

    // MARK: - Retry Schedule

    /// `Retry-After` is authoritative but floored: the server's own number is obeyed, unless
    /// obeying it would mean asking again faster than the app ever asks.
    func testRetryAfterIsHonouredAndFloored() {
        XCTAssertEqual(
            UsageRetrySchedule.delay(retryAfter: 300, consecutiveRateLimits: 1, jitter: 0),
            300
        )
        XCTAssertEqual(
            UsageRetrySchedule.delay(retryAfter: 5, consecutiveRateLimits: 1, jitter: 0),
            UsageDefaults.minimumRefreshSpacing
        )
    }

    /// Without a `Retry-After`, refusals back off exponentially from the ordinary interval and
    /// stop growing at the cap.
    func testRefusalsBackOffExponentiallyToTheCap() {
        XCTAssertEqual(
            UsageRetrySchedule.delay(retryAfter: nil, consecutiveRateLimits: 1, jitter: 0),
            UsageDefaults.refreshInterval
        )
        XCTAssertEqual(
            UsageRetrySchedule.delay(retryAfter: nil, consecutiveRateLimits: 2, jitter: 0),
            UsageDefaults.refreshInterval * 2
        )
        XCTAssertEqual(
            UsageRetrySchedule.delay(retryAfter: nil, consecutiveRateLimits: 10, jitter: 0),
            UsageDefaults.rateLimitBackoffCap
        )
    }

    /// Jitter stretches, never shortens: refusals dealt together must not return together, and
    /// none of them may come back early.
    func testJitterOnlyEverStretchesTheWait() {
        let base = UsageRetrySchedule.delay(retryAfter: 120, consecutiveRateLimits: 1, jitter: 0)
        let stretched = UsageRetrySchedule.delay(
            retryAfter: 120, consecutiveRateLimits: 1, jitter: 1
        )

        XCTAssertGreaterThanOrEqual(stretched, base)
        XCTAssertEqual(stretched, base * (1 + UsageDefaults.rateLimitJitterFraction))
    }

    /// Both spellings of `Retry-After`: delta-seconds, and an HTTP-date read against "now".
    func testRetryAfterHeaderParsesBothForms() {
        XCTAssertEqual(UsageRetrySchedule.retryAfter(fromHeader: "120"), 120)
        XCTAssertEqual(UsageRetrySchedule.retryAfter(fromHeader: "  45 "), 45)
        XCTAssertEqual(UsageRetrySchedule.retryAfter(fromHeader: "-5"), 0)
        XCTAssertNil(UsageRetrySchedule.retryAfter(fromHeader: nil))
        XCTAssertNil(UsageRetrySchedule.retryAfter(fromHeader: ""))
        XCTAssertNil(UsageRetrySchedule.retryAfter(fromHeader: "soon"))

        let now = Date(timeIntervalSince1970: 1_785_400_000)
        let delta = UsageRetrySchedule.retryAfter(
            fromHeader: "Thu, 30 Jul 2026 21:08:20 GMT",
            now: now
        )
        XCTAssertEqual(delta ?? -1, 1_785_445_700 - 1_785_400_000, accuracy: 1)

        let past = UsageRetrySchedule.retryAfter(
            fromHeader: "Thu, 01 Jan 2026 00:00:00 GMT",
            now: now
        )
        XCTAssertEqual(past, 0, "a date already passed means \"now\", never a negative wait")
    }

    // MARK: - Fixtures

    private func payload(_ json: String) -> Data {
        Data(json.utf8)
    }
}
