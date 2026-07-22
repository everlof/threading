import XCTest
@testable import Skalman

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

    /// Banked resets are stated only when the account has some — a zero is what every account
    /// without them reports, and announcing it on all of them is noise.
    func testResetCreditsReadOnlyWhenPresent() {
        XCTAssertEqual(UsageFormat.resetCredits(1), "1 limit reset banked")
        XCTAssertEqual(UsageFormat.resetCredits(3), "3 limit resets banked")
    }

    // MARK: - Helpers

    private func window(id: String, fraction: Double?, resetsIn: TimeInterval) -> AccountUsage.Window {
        AccountUsage.Window(
            id: id,
            label: id,
            fraction: fraction,
            resetsAt: now.addingTimeInterval(resetsIn),
            windowDuration: nil
        )
    }

    private func makeUsage(windows: [AccountUsage.Window]) -> AccountUsage {
        AccountUsage(windows: windows, planLabel: nil, observedAt: now, source: .api)
    }
}
