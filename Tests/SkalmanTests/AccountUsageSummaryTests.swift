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
