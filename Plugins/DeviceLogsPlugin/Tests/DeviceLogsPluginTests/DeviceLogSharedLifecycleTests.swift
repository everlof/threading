import AppKit
import XCTest
@testable import DeviceLogsPlugin

@MainActor
final class DeviceLogSharedLifecycleTests: XCTestCase {
    /// A context read must not wait for the table's expensive projection before honoring a short
    /// wait deadline. Pending is an observable state, rather than an empty completed result.
    func testContextWaitTimesOutWhileAdversarialProjectionIsPending() async throws {
        let (pane, source) = makePaneWithAdversarialRows()
        defer { pane.setRowsPresented(false); pane.stopCapture() }
        try await configureAdversarialFilter(on: pane, showingContext: true)
        source.markTransportActivity()

        let pending = try await pane.readPanel()
        XCTAssertTrue(pending.pending)
        XCTAssertTrue(pending.hasMore)
        XCTAssertTrue(pending.rows.isEmpty)
        let started = DispatchTime.now().uptimeNanoseconds
        let result = try await pane.waitPanel(cursor: pending.cursor, timeout: 0.04)
        let elapsed = Double(DispatchTime.now().uptimeNanoseconds - started) / 1_000_000_000

        XCTAssertTrue(result.timedOut)
        XCTAssertTrue(result.pending || result.outputTruncated,
                      "an unfinished or budget-limited projection must be disclosed even if its worker completes while waiting")
        XCTAssertTrue(result.hasMore)
        XCTAssertTrue(result.rows.isEmpty)
        XCTAssertFalse(result.changed)
        XCTAssertLessThan(elapsed, 0.4, "the caller's deadline must bound waiting for context projection")
        XCTAssertEqual(result.state.filter.textMode, .regex)
        XCTAssertEqual(result.state.readScope, "matches_context_and_expanded_folds")
    }

    /// Each row has its own regex safety allowance. A page also needs an aggregate allowance,
    /// otherwise a short wait can still scan thousands of individually bounded slow matches.
    func testStrictRegexWaitUsesOneAggregateDeadlineAndDisclosesLimitedEvaluation() async throws {
        let (pane, source) = makePaneWithAdversarialRows()
        defer { pane.setRowsPresented(false); pane.stopCapture() }
        try await configureAdversarialFilter(on: pane, showingContext: false)
        source.markTransportActivity()
        let first = try await pane.readPanel(limit: 1)
        XCTAssertTrue(first.rows.isEmpty)
        XCTAssertTrue(first.hasMore)
        XCTAssertTrue(first.outputTruncated)

        let started = DispatchTime.now().uptimeNanoseconds
        let result = try await pane.waitPanel(cursor: first.cursor, limit: 1, timeout: 0.04)
        let elapsed = Double(DispatchTime.now().uptimeNanoseconds - started) / 1_000_000_000

        XCTAssertTrue(result.timedOut)
        XCTAssertTrue(result.rows.isEmpty)
        XCTAssertTrue(result.hasMore, "a deadline-limited scan must not claim to have examined the retained history")
        XCTAssertTrue(result.outputTruncated)
        XCTAssertFalse(result.pending)
        XCTAssertNotNil(result.state.filterEvaluationLimits)
        XCTAssertNotEqual(result.cursor, first.cursor, "a bounded scan still advances past examined rows")
        XCTAssertLessThan(elapsed, 0.4, "row-level regex limits must not multiply the caller's timeout")
    }

    private func makePaneWithAdversarialRows() -> (DeviceLogPaneViewController, BufferedDeviceLogSource) {
        let deviceID = UUID().uuidString
        let pane = DeviceLogPaneViewController(owningSessionID: UUID().uuidString,
                                               preferredMachineID: deviceID, stream: .regular)
        pane.loadView()
        let machine = DeviceLogSourceOption.Machine(id: deviceID, title: "Regex fixture", isSimulator: true)
        pane.installSourcesForTesting([.init(machine: machine, title: "System log", kind: .simulator(udid: deviceID))])
        let source = BufferedDeviceLogSource()
        pane.sourceFactory = { _, _, _ in source }
        pane.startCapture(discover: false)
        // The failure occurs inside the expression's inspected prefix, so this exercises regex
        // backtracking and its progress callback rather than merely the input truncation limit.
        let text = String(repeating: "a", count: 4_095) + "!"
        let fixture = (0..<1_024).map { _ in
            DeviceLogRow(time: "09:41:00", level: "Info", process: "Fixture", subsystem: nil,
                         message: text, deviceID: deviceID, source: .system, rawLine: text)
        }
        pane.installRowsForTesting(fixture)
        return (pane, source)
    }

    private func configureAdversarialFilter(on pane: DeviceLogPaneViewController, showingContext: Bool) async throws {
        var configuration = DeviceLogPanelConfiguration()
        configuration.text = "^(a+)+$"
        configuration.textMode = .regex
        configuration.showContext = showingContext
        _ = try await pane.configurePanel(configuration)
    }
}
