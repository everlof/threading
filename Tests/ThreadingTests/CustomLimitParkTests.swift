import AppKit
import XCTest
@testable import Threading

/// Tier 4: a session held at its next turn boundary by a line the user drew.
///
/// The two differences from a provider park are what these assertions are for, because both are
/// differences a reader has to be able to *see*:
///
/// - **It is not the triangle.** A self-imposed cap is conduct, not weather.
/// - **Continue Anyway is real, and scoped.** The rule is theirs, so walking through it is
///   legitimate; the permission belongs to this turn of the window and expires with it, so one
///   late-night exception does not quietly disable the rule.
@MainActor
final class CustomLimitParkTests: XCTestCase {

    /// One scratch suite for the whole class, cleared at both ends — see
    /// `UsageAlertLedgerTests` for why this is not a fresh UUID per method.
    private var suiteName = ""
    private var defaults: UserDefaults!
    private var overrides: CustomLimitOverrideStore!

    private let account = AccountID(provider: .claude, handle: .named("claude-work"))
    private let now = Date(timeIntervalSince1970: 1_770_000_000)
    private let weekly = UsageDefaults.weeklyWindowID

    override func setUpWithError() throws {
        try super.setUpWithError()
        suiteName = "CustomLimitParkTests"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        overrides = CustomLimitOverrideStore(defaults: defaults)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    // MARK: - Fixtures

    private func window(fraction: Double?, resetsIn: TimeInterval = 3 * 86_400) -> AccountUsage.Window {
        AccountUsage.Window(
            id: weekly,
            label: UsageDefaults.weeklyLabel,
            fraction: fraction,
            resetsAt: now.addingTimeInterval(resetsIn),
            windowDuration: UsageDefaults.sevenDaySeconds
        )
    }

    private func usage(_ windows: [AccountUsage.Window]) -> AccountUsage {
        AccountUsage(windows: windows, planLabel: nil, observedAt: now, source: .api)
    }

    private func parkRule(at bound: Double = 0.5) -> CustomLimit {
        CustomLimit(windowID: weekly, bound: bound, tier: .park)
    }

    // MARK: - When A Park Engages

    func testAParkEngagesOnlyForATierFourRule() {
        for tier in [CustomLimitTier.show, .notify, .hold] {
            let rule = CustomLimit(windowID: weekly, bound: 0.5, tier: tier)
            XCTAssertEqual(
                CustomLimitBounds.park(on: usage([window(fraction: 0.99)]), in: [rule], at: now),
                .clear,
                "a \(tier.rawValue) rule parked a session"
            )
        }
        XCTAssertTrue(
            CustomLimitBounds.park(
                on: usage([window(fraction: 0.99)]),
                in: [parkRule()],
                at: now
            ).isHolding
        )
    }

    /// A tier-4 rule holds Threading's own spend too — the ladder is cumulative, so a park that
    /// did not also hold would be a session stopped while its scheduled sends kept going.
    func testAParkAlsoHolds() {
        XCTAssertTrue(
            CustomLimitBounds.hold(
                on: usage([window(fraction: 0.99)]),
                in: [parkRule()],
                at: now
            ).isHolding
        )
    }

    // MARK: - Continue Anyway

    func testAnOverrideStandsTheRuleDownForThisWindowOnly() {
        let rule = parkRule()
        let live = window(fraction: 0.9)

        XCTAssertTrue(
            CustomLimitBounds.park(on: usage([live]), in: [rule], at: now).isHolding
        )

        overrides.grant(rule: rule, window: live, for: account, at: now)

        XCTAssertEqual(
            CustomLimitBounds.park(
                on: usage([live]),
                in: [rule],
                overrides: overrides.granted(for: account, at: now),
                at: now
            ),
            .clear,
            "Continue Anyway did not stand the rule down"
        )
    }

    /// The permission expires with the window it was given in. A rule the user walked through on
    /// Tuesday is back in force on Wednesday without them having to remember to re-arm it.
    func testAnOverrideExpiresWithItsWindow() {
        let rule = parkRule()
        overrides.grant(rule: rule, window: window(fraction: 0.9), for: account, at: now)

        let nextWeek = now.addingTimeInterval(4 * 86_400)
        XCTAssertTrue(
            overrides.granted(for: account, at: nextWeek).isEmpty,
            "an override outlived the window instance it was given in"
        )

        // And the next turn of the window is a different instance, so even an unpruned record
        // would not match it.
        XCTAssertTrue(
            CustomLimitBounds.park(
                on: usage([window(fraction: 0.9, resetsIn: 10 * 86_400)]),
                in: [rule],
                overrides: overrides.granted(for: account, at: nextWeek),
                at: nextWeek
            ).isHolding
        )
    }

    func testAnOverrideSurvivesARelaunchInsideItsWindow() {
        let rule = parkRule()
        overrides.grant(rule: rule, window: window(fraction: 0.9), for: account, at: now)

        let reopened = CustomLimitOverrideStore(defaults: defaults)
        XCTAssertEqual(reopened.granted(for: account, at: now).count, 1)
    }

    func testPruningDropsExpiredOverridesAndDeletedRules() {
        let rule = parkRule()
        overrides.grant(rule: rule, window: window(fraction: 0.9), for: account, at: now)

        XCTAssertEqual(overrides.prune(accountID: account, liveRuleIDs: [rule.id], now: now), 0)
        XCTAssertEqual(overrides.count, 1)

        XCTAssertEqual(overrides.prune(accountID: account, liveRuleIDs: [], now: now), 1)
        XCTAssertEqual(overrides.count, 0)
    }

    /// One account's override says nothing about another's, for the reason the alert ledger keys
    /// by account: an app-wide rule is the same rule id on every login.
    func testAnOverrideOnOneAccountDoesNotFreeAnother() {
        let other = AccountID(provider: .claude, handle: .named("claude-personal"))
        overrides.grant(rule: parkRule(), window: window(fraction: 0.9), for: account, at: now)

        XCTAssertTrue(overrides.granted(for: other, at: now).isEmpty)
    }

    // MARK: - The Strip

    /// The park's strip is the escape strip's surface with different words — and, deliberately,
    /// a different mark.
    func testTheStripSaysWhoseLimitStoppedThis() throws {
        let strip = LimitEscapeStripView()

        strip.setOffer(LimitEscapeStripView.Offer(source: .provider, resetHint: "in 2h"))
        let providerSentence = try XCTUnwrap(strip.accessibilityLabel())

        strip.setOffer(LimitEscapeStripView.Offer(source: .ownLimit, resetHint: "in 2h"))
        let ownSentence = try XCTUnwrap(strip.accessibilityLabel())

        XCTAssertNotEqual(providerSentence, ownSentence)
        XCTAssertTrue(
            ownSentence.localizedCaseInsensitiveContains("your own limit"),
            ownSentence
        )
        XCTAssertFalse(
            ownSentence.localizedCaseInsensitiveContains("limit reached"),
            "a line the user drew is borrowing the provider's words"
        )
    }

    /// Continue Anyway is offered with no second login to move to — the rule is the user's own,
    /// so walking through it needs no destination.
    func testTheParkOffersContinueAnywayWithNoSecondLogin() {
        let strip = LimitEscapeStripView()

        strip.setOffer(LimitEscapeStripView.Offer(source: .provider))
        XCTAssertTrue(
            strip.continueControl.isHidden,
            "a provider refusal with nowhere to go should not offer a Continue"
        )

        strip.setOffer(LimitEscapeStripView.Offer(source: .ownLimit))
        XCTAssertFalse(strip.continueControl.isHidden)
        XCTAssertEqual(strip.continueControl.title, "Continue Anyway")
    }

    /// The one button routes to two different acts. A park's Continue must not migrate the
    /// conversation to another login — it leaves it exactly where it is.
    func testTheStripsOneButtonRoutesByWhoseLimitItIs() {
        let strip = LimitEscapeStripView()
        var migrated = false
        var continued = false
        strip.onContinue = { migrated = true }
        strip.onContinueAnyway = { continued = true }

        strip.setOffer(LimitEscapeStripView.Offer(source: .ownLimit))
        // `ThemedButton` routes its own press: the AppKit `performClick(_:)` is not the path a
        // user's click takes here, and pressing that instead would test AppKit rather than us.
        strip.continueControl.performClick()

        XCTAssertTrue(continued)
        XCTAssertFalse(migrated, "a park's Continue moved the conversation to another account")
    }

    // MARK: - The Row's Mark

    /// A parked row wears the conduct mark, not the triangle: the process really is idle and the
    /// provider really would accept a turn.
    func testAParkedRowReadsAsConductRatherThanAsAWarning() {
        let summary = RowConductSummary(statements: [
            RowConductStrings.parkedByOwnLimit(
                CustomLimitReceipt.holdSummaryLine(
                    .overLine(rule: parkRule(), windowName: UsageDefaults.weeklyLabel),
                    rule: parkRule()
                )
            )
        ])

        XCTAssertTrue(summary.sentence.localizedCaseInsensitiveContains("your limit"), summary.sentence)
        XCTAssertTrue(summary.sentence.contains("50%"), summary.sentence)
    }
}
