import XCTest
import ThreadingRemoteKit
@testable import Threading

/// The phone rings a model's own window only for a chat on that model, and the match has to be
/// the Mac's: `ModelName.scope` reads a families table the phone does not have, so the wire
/// carries its answer per model choice rather than the two strings it was asked about.
@MainActor
final class RemoteAccountUsageWindowsTests: XCTestCase {

    private let reset = Date(timeIntervalSince1970: 1_800_000_000)
    private let weekSeconds: TimeInterval = 7 * 24 * 60 * 60

    private var usage: AccountUsage {
        var usage = AccountUsage(
            windows: [
                AccountUsage.Window(
                    id: UsageDefaults.fiveHourWindowID,
                    label: UsageDefaults.fiveHourLabel,
                    fraction: 0.43,
                    resetsAt: reset,
                    windowDuration: UsageDefaults.fiveHourSeconds
                ),
                AccountUsage.Window(
                    id: UsageDefaults.weeklyWindowID,
                    label: UsageDefaults.weeklyLabel,
                    fraction: 0.73,
                    resetsAt: nil,
                    windowDuration: weekSeconds
                ),
            ],
            planLabel: "Max",
            observedAt: reset,
            source: .api
        )
        usage.modelWindows = [
            AccountUsage.Window(
                id: "Fable",
                label: "Weekly · Fable",
                fraction: 0.89,
                resetsAt: nil,
                windowDuration: weekSeconds,
                scopeName: "Fable"
            ),
        ]
        return usage
    }

    func testAScopedWindowNamesTheModelChoicesItMetersAndAnAccountWindowNamesNone() {
        let windows = RemoteAccountBridge.usageWindows(
            for: usage,
            modelChoices: ["claude-fable-5", "claude-opus-5", "claude-fable-5[1m]"]
        )

        XCTAssertEqual(
            windows.map(\.id),
            ["5h", "7d", "Fable"],
            "the Mac's reading order, so the phone's words match the pill's"
        )
        XCTAssertEqual(windows.map(\.name), ["5h", "7d", "7d Fable"])
        XCTAssertEqual(
            windows.map(\.metersModelIDs),
            [nil, nil, ["claude-fable-5", "claude-fable-5[1m]"]]
        )
        XCTAssertEqual(windows[0].resetsAt, reset.timeIntervalSince1970)
        XCTAssertEqual(windows[0].windowDuration, UsageDefaults.fiveHourSeconds)
        XCTAssertEqual(windows[2].fraction, 0.89)
    }

    /// A scoped window that meters nothing on offer still travels, with an empty list, so the
    /// wire is the reading and not an edited one; the phone simply never rings it.
    func testAScopedWindowMeteringNoChoiceTravelsWithAnEmptyList() {
        let windows = RemoteAccountBridge.usageWindows(for: usage, modelChoices: ["claude-opus-5"])

        XCTAssertEqual(windows.last?.metersModelIDs, [])
    }
}
