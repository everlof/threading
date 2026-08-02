import XCTest
@testable import Threading

final class AccountUsageSummaryTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    func testSummaryNamesEveryWindowWithItsValue() {
        let usage = makeUsage(windows: [
            window(id: "5h", fraction: 0.43, resetsIn: 3600),
            window(id: "7d", fraction: 0.73, resetsIn: 86_400)
        ])

        XCTAssertEqual(usage.compactSummary(at: now), "5h 43% · 7d 73%")
    }

    /// The pill's rule, applied to text: a window past its reset kept its identity but not
    /// its number, which belongs to the window before it.
    func testExpiredWindowLosesItsNumberButKeepsItsName() {
        let usage = makeUsage(windows: [
            window(id: "5h", fraction: 0.43, resetsIn: -60),
            window(id: "7d", fraction: 0.73, resetsIn: 86_400)
        ])

        XCTAssertEqual(usage.compactSummary(at: now), "5h — · 7d 73%")
    }

    func testUnknownFractionReadsAsUnknown() {
        let usage = makeUsage(windows: [window(id: "5h", fraction: nil, resetsIn: 3600)])
        XCTAssertEqual(usage.compactSummary(at: now), "5h —")
    }

    /// Nothing to say, so a caller shows no line at all rather than an empty one.
    func testNoWindowsHasNoSummary() {
        XCTAssertNil(makeUsage(windows: []).compactSummary(at: now))
    }

    func testPercentIsRounded() {
        let usage = makeUsage(windows: [window(id: "5h", fraction: 0.436, resetsIn: 3600)])
        XCTAssertEqual(usage.compactSummary(at: now), "5h 44%")
    }

    // MARK: - Model Limits

    /// The reason a per-model limit is kept out of `windows`: the toolbar's peak must report
    /// the *account's* pressure. A spent model limit says one model is finished, not that the
    /// plan is — folding it in would put the pill in the red over a model the session may not
    /// even be using.
    func testModelLimitDoesNotDistortTheAccountsPeak() {
        var usage = makeUsage(windows: [
            window(id: "5h", fraction: 0.10, resetsIn: 3600),
            window(id: "7d", fraction: 0.22, resetsIn: 86_400)
        ])
        usage.modelWindows = [window(id: "GPT-5.3-Codex-Spark", fraction: 1.0, resetsIn: 3600)]

        XCTAssertEqual(usage.peakWindow(at: now)?.id, "7d")
        XCTAssertEqual(usage.compactSummary(at: now), "5h 10% · 7d 22%")
    }

    /// …and the other half of that rule: the window that stops *this* session is the account's
    /// own or the one metering the model it runs, whichever is fuller. The pill gauges this,
    /// because a weekly window at 22% is comfortable as an account and spent as a session.
    func testBindingWindowIncludesTheModelTheSessionRuns() {
        var usage = makeUsage(windows: [
            window(id: "5h", fraction: 0.10, resetsIn: 3600),
            window(id: "7d", fraction: 0.22, resetsIn: 86_400)
        ])
        usage.modelWindows = [scopedWindow(model: "Fable", fraction: 0.89, resetsIn: 86_400)]

        XCTAssertEqual(usage.bindingWindow(at: now, metering: "claude-fable-5[1m]")?.id, "Fable")
        XCTAssertEqual(
            usage.compactSummary(at: now, metering: "claude-fable-5[1m]"),
            "5h 10% · 7d 22% · 7d Fable 89%"
        )
    }

    /// One vocabulary for every written-out window: a length, and the model it meters when it
    /// meters one. A scoped window printing as its model alone put a name in a list of durations,
    /// and left `Fable 89%` with nothing to say which period it covered.
    func testAScopedWindowIsNamedByLengthAndModel() {
        XCTAssertEqual(
            scopedWindow(model: "Fable", fraction: 0.89, resetsIn: 86_400).compactName,
            "7d Fable"
        )
        XCTAssertEqual(
            scopedWindow(
                model: "Fable",
                fraction: 0.89,
                resetsIn: 86_400,
                duration: UsageDefaults.fiveHourSeconds
            ).compactName,
            "5h Fable"
        )
        XCTAssertEqual(window(id: "7d", fraction: 0.22, resetsIn: 86_400).compactName, "7d")
    }

    /// A provider that reports a scoped limit without saying how long its window is leaves the
    /// model's name as the only thing that identifies it — which is what gets printed, rather
    /// than a length invented to fill the slot.
    func testAScopedWindowOfUnknownLengthKeepsItsModelName() {
        let unsized = scopedWindow(model: "Fable", fraction: 0.89, resetsIn: 86_400, duration: nil)
        XCTAssertEqual(unsized.compactName, "Fable")
    }

    /// Another model's limit is not this session's problem, and naming no model at all is not a
    /// licence to guess — both read as the account's own windows.
    func testBindingWindowIgnoresLimitsForOtherModels() {
        var usage = makeUsage(windows: [
            window(id: "5h", fraction: 0.10, resetsIn: 3600),
            window(id: "7d", fraction: 0.22, resetsIn: 86_400)
        ])
        usage.modelWindows = [scopedWindow(model: "Fable", fraction: 0.89, resetsIn: 86_400)]

        XCTAssertEqual(usage.bindingWindow(at: now, metering: "claude-opus-4-8")?.id, "7d")
        XCTAssertEqual(usage.bindingWindow(at: now, metering: nil)?.id, "7d")
        XCTAssertEqual(usage.compactSummary(at: now, metering: nil), "5h 10% · 7d 22%")
    }

    /// A scoped window past its reset is skipped like any other: its percentage describes the
    /// window before it, and gauging the ring from it would show pressure that has gone.
    func testExpiredModelWindowDoesNotBind() {
        var usage = makeUsage(windows: [window(id: "7d", fraction: 0.22, resetsIn: 86_400)])
        usage.modelWindows = [scopedWindow(model: "Fable", fraction: 0.89, resetsIn: -60)]

        XCTAssertEqual(usage.bindingWindow(at: now, metering: "fable")?.id, "7d")
        XCTAssertEqual(usage.compactSummary(at: now, metering: "fable"), "7d 22% · 7d Fable —")
    }

    // MARK: - Account Menu

    /// The line under each login where an account is picked. It carries the plan, every window
    /// metering the model that would run, and when the tight one comes back — because that is
    /// the moment the numbers change a decision, and the toolbar only speaks afterwards.
    @MainActor
    func testAccountMenuLineNamesPlanWindowsAndTheBindingReset() {
        var usage = AccountUsage(
            windows: [
                window(id: "5h", fraction: 0.07, resetsIn: 3600),
                window(id: "7d", fraction: 0.56, resetsIn: 54_000)
            ],
            planLabel: "Max",
            observedAt: now,
            source: .localCache
        )
        usage.modelWindows = [scopedWindow(model: "Fable", fraction: 0.89, resetsIn: 54_000)]

        XCTAssertEqual(
            AccountUsageMenu.summary(for: usage, metering: "claude-fable-5[1m]", at: now),
            "Max · 5h 7% · 7d 56% · 7d Fable 89% · 7d Fable resets in 15h"
        )
    }

    /// The account is picked before the model, so the line names a scoped window the account's
    /// *configured* default would never reach. Withholding it is what made a login whose Fable
    /// window was nearly spent read exactly like one that was barely touched.
    @MainActor
    func testAccountMenuNamesScopedWindowsTheChosenModelDoesNotMeter() {
        var usage = AccountUsage(
            windows: [
                window(id: "5h", fraction: 0.11, resetsIn: 3600),
                window(id: "7d", fraction: 0.62, resetsIn: 54_000)
            ],
            planLabel: "Max",
            observedAt: now,
            source: .localCache
        )
        usage.modelWindows = [scopedWindow(model: "Fable", fraction: 0.89, resetsIn: 54_000)]

        // Metering Opus: Fable is named, but 7d is still what binds — and what the ring gauges.
        XCTAssertEqual(
            AccountUsageMenu.summary(for: usage, metering: "opus[1m]", at: now),
            "Max · 5h 11% · 7d 62% · 7d Fable 89% · 7d resets in 15h"
        )
        XCTAssertEqual(usage.bindingWindow(at: now, metering: "opus[1m]")?.id, "7d")
    }

    /// A session already running a model is measured against that model and nothing else: the
    /// mirrored reading stays narrow, because there another model's limit is not its problem.
    func testARunningSessionsReadingStaysNarrow() {
        var usage = makeUsage(windows: [window(id: "7d", fraction: 0.62, resetsIn: 54_000)])
        usage.modelWindows = [scopedWindow(model: "Fable", fraction: 0.89, resetsIn: 54_000)]

        XCTAssertEqual(usage.compactSummary(at: now, metering: "opus[1m]"), "7d 62%")
        XCTAssertEqual(
            usage.compactSummary(at: now, metering: "opus[1m]", scoped: .all),
            "7d 62% · 7d Fable 89%"
        )
    }

    // MARK: - Model Menu

    /// The row where the choice is made states everything a session on it would be measured
    /// against — the account's windows and the model's own — and when the binding one comes back.
    @MainActor
    func testModelRowStatesEveryWindowThatWouldMeasureIt() {
        var usage = makeUsage(windows: [window(id: "7d", fraction: 0.62, resetsIn: 54_000)])
        usage.modelWindows = [scopedWindow(model: "Fable", fraction: 0.89, resetsIn: 54_000)]

        XCTAssertEqual(
            AccountUsageMenu.modelSummary(for: usage, running: "claude-fable-5[1m]", at: now),
            "7d 62% · 7d Fable 89% · 7d Fable resets in 15h"
        )
    }

    /// A model the plan meters no differently still carries its reading. The account's windows
    /// are the same on every such row and distinguish nothing — but a blank row does not read as
    /// "nothing of its own to say", it reads as a failed lookup beside the one row that worked.
    @MainActor
    func testModelRowWithoutAScopedWindowFallsBackToTheAccountsOwn() {
        var usage = makeUsage(windows: [window(id: "7d", fraction: 0.62, resetsIn: 54_000)])
        usage.modelWindows = [scopedWindow(model: "Fable", fraction: 0.89, resetsIn: 54_000)]

        XCTAssertEqual(
            AccountUsageMenu.modelSummary(for: usage, running: "claude-opus-4-8", at: now),
            "7d 62% · 7d resets in 15h"
        )
        // The row that leaves the choice to the CLI, on an account naming no default: nothing is
        // known about the model, so the account's own windows are the whole honest answer.
        XCTAssertEqual(
            AccountUsageMenu.modelSummary(for: usage, running: nil, at: now),
            "7d 62% · 7d resets in 15h"
        )
    }

    /// The one silence left: an account with no windows at all says nothing, rather than showing
    /// a row furnished with an empty line.
    @MainActor
    func testModelRowSaysNothingWhenTheAccountHasNoWindows() {
        XCTAssertNil(
            AccountUsageMenu.modelSummary(for: makeUsage(windows: []), running: "opus", at: now)
        )
    }

    /// An expired scoped window loses its number here too, and stops binding the countdown —
    /// a reset that has already happened is not a wait.
    @MainActor
    func testExpiredModelRowKeepsItsWindowAndDropsTheNumber() {
        var usage = makeUsage(windows: [window(id: "7d", fraction: 0.62, resetsIn: 54_000)])
        usage.modelWindows = [scopedWindow(model: "Fable", fraction: 0.89, resetsIn: -60)]

        XCTAssertEqual(
            AccountUsageMenu.modelSummary(for: usage, running: "fable", at: now),
            "7d 62% · 7d Fable — · 7d resets in 15h"
        )
    }

    /// A scoped window is identified by its model, so its *length* is recovered from the window
    /// it is measured in.
    func testWindowIDIsRecoveredFromItsLength() {
        XCTAssertEqual(UsageDefaults.windowID(forDuration: UsageDefaults.fiveHourSeconds), "5h")
        XCTAssertEqual(UsageDefaults.windowID(forDuration: UsageDefaults.sevenDaySeconds), "7d")
        XCTAssertEqual(UsageDefaults.windowID(forDuration: 12 * 3600), "12h")
        XCTAssertEqual(UsageDefaults.windowID(forDuration: 3 * 86_400), "3d")
        XCTAssertNil(UsageDefaults.windowID(forDuration: nil))
        XCTAssertNil(UsageDefaults.windowID(forDuration: 0))
    }

    /// Without a model the line says only what it knows, and an account with no plan label
    /// leads with its windows rather than an empty segment.
    @MainActor
    func testAccountMenuLineOmitsWhatItCannotSay() {
        let usage = makeUsage(windows: [window(id: "7d", fraction: 0.56, resetsIn: 54_000)])

        XCTAssertEqual(
            AccountUsageMenu.summary(for: usage, metering: nil, at: now),
            "7d 56% · 7d resets in 15h"
        )
        XCTAssertNil(AccountUsageMenu.summary(for: makeUsage(windows: []), metering: nil, at: now))
    }

    /// Banked resets are stated only when the account has some — a zero is what every account
    /// without them reports, and announcing it on all of them is noise.
    func testResetCreditsReadOnlyWhenPresent() {
        XCTAssertEqual(UsageFormat.resetCredits(1), "1 limit reset banked")
        XCTAssertEqual(UsageFormat.resetCredits(3), "3 limit resets banked")
    }

    // MARK: - Helpers

    private func window(
        id: String,
        fraction: Double?,
        resetsIn: TimeInterval,
        duration: TimeInterval? = nil
    ) -> AccountUsage.Window {
        AccountUsage.Window(
            id: id,
            label: id,
            fraction: fraction,
            resetsAt: now.addingTimeInterval(resetsIn),
            windowDuration: duration
        )
    }

    /// A model-scoped window as a provider builds one: identified by its model, and knowing the
    /// length it is measured in — which is what lets it be *named* like the account's own.
    private func scopedWindow(
        model: String,
        fraction: Double?,
        resetsIn: TimeInterval,
        duration: TimeInterval? = UsageDefaults.sevenDaySeconds
    ) -> AccountUsage.Window {
        AccountUsage.Window(
            id: model,
            label: "\(UsageDefaults.weeklyLabel)\(UsageDefaults.segmentSeparator)\(model)",
            fraction: fraction,
            resetsAt: now.addingTimeInterval(resetsIn),
            windowDuration: duration,
            scopeName: model
        )
    }

    private func makeUsage(windows: [AccountUsage.Window]) -> AccountUsage {
        AccountUsage(windows: windows, planLabel: nil, observedAt: now, source: .api)
    }
}
