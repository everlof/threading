import XCTest
@testable import Threading

/// Tier 3: Threading's own spend standing down at a line the user drew.
///
/// The honesty boundary is what these assertions are about. Threading can guarantee its **own**
/// conduct — a scheduled send, a usage-window poke, a ranking's offer, a message from one agent to
/// another — and it cannot stop the keyboard. So a hold has to be exact about two things: that it
/// only ever holds Threading's initiative, and that it says *which* of the two refusing reasons
/// applies, because "over your line" and "cannot see" have opposite remedies.
@MainActor
final class CustomLimitHoldTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_770_000_000)
    private let weekly = UsageDefaults.weeklyWindowID
    private let fiveHour = UsageDefaults.fiveHourWindowID

    // MARK: - Fixtures

    private func window(
        id: String? = nil,
        fraction: Double?,
        resetsIn: TimeInterval = 3 * 86_400,
        duration: TimeInterval = UsageDefaults.sevenDaySeconds
    ) -> AccountUsage.Window {
        AccountUsage.Window(
            id: id ?? weekly,
            label: UsageDefaults.weeklyLabel,
            fraction: fraction,
            resetsAt: now.addingTimeInterval(resetsIn),
            windowDuration: duration
        )
    }

    private func usage(_ windows: [AccountUsage.Window]) -> AccountUsage {
        AccountUsage(windows: windows, planLabel: nil, observedAt: now, source: .api)
    }

    private func holdRule(at bound: Double, on windowID: String? = nil) -> CustomLimit {
        CustomLimit(windowID: windowID ?? weekly, bound: bound, tier: .hold)
    }

    // MARK: - When A Hold Engages

    func testAHoldEngagesAtTheLineAndNotBefore() {
        let rules = [holdRule(at: 0.5)]

        XCTAssertEqual(
            CustomLimitBounds.hold(on: usage([window(fraction: 0.49)]), in: rules, at: now),
            .clear
        )
        XCTAssertTrue(
            CustomLimitBounds.hold(on: usage([window(fraction: 0.5)]), in: rules, at: now)
                .isHolding
        )
    }

    /// A rule that was never armed to act cannot act. A line drawn to colour a bar or fire one
    /// notification has not been given permission to stop anything, and reading it as though it
    /// had would be the feature taking an authority nobody granted it.
    func testARuleBelowTierThreeHoldsNothing() {
        for tier in [CustomLimitTier.show, .notify] {
            let rule = CustomLimit(windowID: weekly, bound: 0.5, tier: tier)
            XCTAssertEqual(
                CustomLimitBounds.hold(on: usage([window(fraction: 0.99)]), in: [rule], at: now),
                .clear,
                "a \(tier.rawValue) rule held Threading's spend"
            )
        }
    }

    /// **Holds engage on unknowns**, asymmetrically with alerts, which go silent on them. "I could
    /// not look, so I spent anyway" is the wrong side of the ask that created the rule.
    func testAnUnknownReadingHoldsRatherThanPassing() throws {
        let rules = [holdRule(at: 0.5)]

        for reading in [usage([window(fraction: nil)]), usage([]), nil] as [AccountUsage?] {
            let hold = CustomLimitBounds.hold(on: reading, in: rules, at: now)
            guard case .cannotSee = hold else {
                return XCTFail("an unknown reading did not hold: \(hold)")
            }
        }
    }

    /// An expired window is an unknown reading here too: its percentage describes the turn before
    /// this one, and a hold released on it would be released on last window's spend.
    func testAnExpiredWindowHolds() {
        let hold = CustomLimitBounds.hold(
            on: usage([window(fraction: 0.1, resetsIn: -60)]),
            in: [holdRule(at: 0.5)],
            at: now
        )
        guard case .cannotSee = hold else { return XCTFail("an expired window released a hold") }
    }

    /// The two refusing reasons stay apart, and "cannot see" wins when both are present — it is
    /// the one whose remedy is "look again".
    func testCannotSeeOutranksOverLine() {
        let rules = [
            holdRule(at: 0.5),
            holdRule(at: 0.5, on: fiveHour)
        ]
        let reading = usage([
            window(fraction: 0.9),
            window(id: fiveHour, fraction: nil, resetsIn: 3_600, duration: UsageDefaults.fiveHourSeconds)
        ])

        guard case .cannotSee = CustomLimitBounds.hold(on: reading, in: rules, at: now) else {
            return XCTFail("the missing reading was reported as spend")
        }
    }

    /// The receipt words the two apart. A reader told "over your line" when the truth is "cannot
    /// see" goes hunting for spend that never happened.
    func testTheReceiptKeepsTheTwoRemediesApart() {
        let over = CustomLimitBounds.hold(
            on: usage([window(fraction: 0.9)]),
            in: [holdRule(at: 0.5)],
            at: now
        )
        let blind = CustomLimitBounds.hold(on: nil, in: [holdRule(at: 0.5)], at: now)

        XCTAssertTrue(CustomLimitReceipt.holdReason(over).contains("50%"))
        XCTAssertTrue(
            CustomLimitReceipt.holdReason(blind).localizedCaseInsensitiveContains("cannot read"),
            CustomLimitReceipt.holdReason(blind)
        )
        XCTAssertNotEqual(
            CustomLimitReceipt.holdSummary(over),
            CustomLimitReceipt.holdSummary(blind)
        )
        XCTAssertNil(CustomLimitReceipt.holdSummary(.clear))
    }

    // MARK: - The Poke's Guard Row

    /// The poke spends a message, so a line the user drew is a reason for it to stand down —
    /// beside `weeklyAheadOfPace`, and for the same kind of reason.
    func testThePokeStandsDownOnAUsersLine() throws {
        var input = pokeInput()
        XCTAssertEqual(UsageWindowPlan.decide(input), .poke)

        input.customLimitHold = .overLine(
            rule: holdRule(at: 0.5),
            windowName: UsageDefaults.weeklyLabel
        )
        guard case .hold(.customLimitReached) = UsageWindowPlan.decide(input) else {
            return XCTFail("the poke fired through one of the user's own limits")
        }
    }

    /// It is the *last* guard: every rule above it describes the provider's arithmetic, and a
    /// poke that was never going to fire should say the cheaper reason.
    func testTheProvidersOwnGuardsStillAnswerFirst() throws {
        var input = pokeInput()
        input.customLimitHold = .overLine(
            rule: holdRule(at: 0.5),
            windowName: UsageDefaults.weeklyLabel
        )
        input.isWorking = true

        XCTAssertEqual(UsageWindowPlan.decide(input), .hold(.working))
    }

    private func pokeInput() -> UsageWindowPlan.Input {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        // A Wednesday at 10:00 UTC, inside the default working day.
        let day = calendar.date(from: DateComponents(year: 2026, month: 2, day: 4, hour: 10))!

        return UsageWindowPlan.Input(
            now: day,
            schedule: UsageWindowSchedule(
                isEnabled: true,
                startMinute: 9 * 60,
                endMinute: 18 * 60,
                weekdays: Set(1...7),
                accountIDs: ["claude:work"]
            ),
            accountID: "claude:work",
            burn: 3 * 3_600,
            shortWindow: AccountUsage.Window(
                id: fiveHour,
                label: UsageDefaults.fiveHourLabel,
                fraction: 0.2,
                resetsAt: day.addingTimeInterval(-60),
                windowDuration: UsageDefaults.fiveHourSeconds
            ),
            weeklyWindow: nil,
            isWorking: false,
            pokesToday: 0,
            calendar: calendar
        )
    }

    // MARK: - The Escape Ranking

    /// The escape must never move a conversation *into* an account the user fenced off.
    func testARankingWillNotOfferAFencedOffLogin() {
        let reading = usage([window(fraction: 0.3)])
        let free = LimitEscapeRanking.Candidate(
            accountID: AccountID(provider: .claude, handle: .named("free")),
            usage: reading
        )
        let fenced = LimitEscapeRanking.Candidate(
            accountID: AccountID(provider: .claude, handle: .named("fenced")),
            usage: reading,
            limits: [holdRule(at: 0.25)]
        )

        XCTAssertEqual(
            LimitEscapeRanking.rank([free, fenced], metering: nil, at: now).map(\.accountID),
            [free.accountID]
        )
        XCTAssertFalse(LimitEscapeRanking.hasHeadroom(fenced, metering: nil, at: now))
    }

    /// And it says *why*. Silent exclusion reads as spent, which slanders an account with
    /// headroom — and points the user at the provider for a line they drew themselves.
    func testAFencedOffLoginIsReportedAsExcludedRatherThanSpent() throws {
        let fenced = LimitEscapeRanking.Candidate(
            accountID: AccountID(provider: .claude, handle: .named("fenced")),
            usage: usage([window(fraction: 0.3)]),
            limits: [holdRule(at: 0.25)]
        )

        let excluded = try XCTUnwrap(LimitEscapeRanking.exclusions([fenced], at: now).first)
        XCTAssertEqual(excluded.accountID, fenced.accountID)
        XCTAssertEqual(
            CustomLimitReceipt.holdSummary(excluded.hold),
            "Excluded by your limit"
        )
    }

    /// The pace deficit generalizes rather than changing: with no line drawn it is the shipped
    /// formula to the letter.
    func testTheRankingIsUnchangedWhereNoLineIsDrawn() throws {
        let candidates = [
            LimitEscapeRanking.Candidate(
                accountID: AccountID(provider: .claude, handle: .named("a")),
                usage: usage([window(fraction: 0.1)])
            ),
            LimitEscapeRanking.Candidate(
                accountID: AccountID(provider: .claude, handle: .named("b")),
                usage: usage([window(fraction: 0.6)])
            )
        ]

        let ranked = LimitEscapeRanking.rank(candidates, metering: nil, at: now)
        XCTAssertEqual(ranked.count, 2)
        XCTAssertEqual(ranked.first?.accountID, candidates[0].accountID)
    }

    /// A shared login far under the share reserved for its owner ranks **ahead** of a free login
    /// nearer its own cap — the "yours vs. theirs" answer, delivered where it is actionable.
    func testASharedLoginUnderItsShareOutranksAFreeOneNearerItsCap() throws {
        // Half a week elapsed; the shared login has spent a tenth of the week against a half
        // share, the free login has spent two thirds of its own window.
        let halfway = AccountUsage.Window(
            id: weekly,
            label: UsageDefaults.weeklyLabel,
            fraction: 0.1,
            resetsAt: now.addingTimeInterval(UsageDefaults.sevenDaySeconds / 2),
            windowDuration: UsageDefaults.sevenDaySeconds
        )
        let shared = LimitEscapeRanking.Candidate(
            accountID: AccountID(provider: .claude, handle: .named("shared")),
            usage: usage([halfway]),
            limits: [CustomLimit(windowID: weekly, metric: .paceShare, bound: 0.5, tier: .hold)]
        )
        let free = LimitEscapeRanking.Candidate(
            accountID: AccountID(provider: .claude, handle: .named("free")),
            usage: usage([AccountUsage.Window(
                id: weekly,
                label: UsageDefaults.weeklyLabel,
                fraction: 0.66,
                resetsAt: now.addingTimeInterval(UsageDefaults.sevenDaySeconds / 2),
                windowDuration: UsageDefaults.sevenDaySeconds
            )])
        )

        XCTAssertEqual(
            LimitEscapeRanking.rank([free, shared], metering: nil, at: now).first?.accountID,
            shared.accountID
        )
    }

    // MARK: - The Control Plane

    /// A message from one agent to another is Threading-initiated spend on the target's account,
    /// so a tier-3 rule refuses it — in the plane's own voice, naming the user's line rather than
    /// the provider's.
    func testTheControlPlaneRefusesASendIntoAHeldAccount() throws {
        let refusal = ControlRefusal.targetHeldByOwnLimit(
            reason: CustomLimitReceipt.holdReason(.overLine(
                rule: holdRule(at: 0.5),
                windowName: UsageDefaults.weeklyLabel
            ))
        )

        guard case .targetHeldByOwnLimit(let reason) = refusal else {
            return XCTFail("the refusal lost its reason")
        }
        XCTAssertTrue(reason.contains("50%"), reason)
        XCTAssertFalse(
            reason.localizedCaseInsensitiveContains("rate limit"),
            "the plane's refusal is borrowing the provider's vocabulary"
        )
    }
}
