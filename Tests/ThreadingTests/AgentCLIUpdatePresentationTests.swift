import AppKit
import Foundation
import XCTest
@testable import Threading

@MainActor
final class AgentCLIUpdatePresentationTests: XCTestCase {

    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUp() {
        super.setUp()
        suiteName = "AgentCLIUpdatePresentationTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    func testToastPresentsAComparisonAndRunsOnlyFromItsAction() throws {
        let updates = fixtureUpdates()
        var requested: [AgentCLIUpdate]?

        let request = AgentCLIUpdateToast.request(for: updates) { requested = $0 }

        XCTAssertEqual(request.message, "2 agent tool updates are available")
        XCTAssertNil(request.detail)
        XCTAssertEqual(request.comparison, ToastComparison(
            currentTitle: "Now",
            targetTitle: "Latest",
            rows: [
                ToastComparisonRow(
                    label: "Claude Code",
                    currentValue: "2.1.220",
                    targetValue: "2.1.237"
                ),
                ToastComparisonRow(
                    label: "Codex",
                    currentValue: "0.145.0",
                    targetValue: "0.148.0"
                )
            ]
        ))
        XCTAssertEqual(request.actionTitle, "Update All")
        XCTAssertEqual(request.dwell, ToastDefaults.unattendedDwell)
        XCTAssertEqual(request.identifier, AgentCLIUpdateToast.identifier)
        XCTAssertNil(requested, "constructing the notice must not start an updater")

        try XCTUnwrap(request.action)()
        XCTAssertEqual(requested, updates)
    }

    func testUpdatePlanRunsEveryProviderInOneVisibleShellSequence() throws {
        let updates = [
            AgentCLIUpdate(
                id: "first",
                displayName: "First Tool",
                installedVersion: "1.0.0",
                latestVersion: "2.0.0",
                updateCommand: "printf first; exit 7"
            ),
            AgentCLIUpdate(
                id: "second",
                displayName: "Second Tool",
                installedVersion: "3.0.0",
                latestVersion: "4.0.0",
                updateCommand: "printf second"
            )
        ]
        let plan = AgentCLIUpdateExecutionPlan(updates: updates)
        let script = AgentCLIUpdateShellCommand.script(for: updates)

        XCTAssertTrue(script.contains("'/bin/sh' '-l' '-c' 'printf first; exit 7'"))
        XCTAssertTrue(script.contains("'/bin/sh' '-l' '-c' 'printf second'"))
        XCTAssertTrue(plan.shellSource.hasPrefix("'/bin/sh' '-l' '-c' "))

        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", plan.shellSource]
        process.standardOutput = output
        process.standardError = output
        try process.run()
        process.waitUntilExit()

        let text = String(
            decoding: output.fileHandleForReading.readDataToEndOfFile(),
            as: UTF8.self
        )
        XCTAssertEqual(process.terminationStatus, 0)
        XCTAssertTrue(text.contains("First Tool updater finished with exit code 7"))
        XCTAssertTrue(text.contains("Second Tool updater finished with exit code 0"))
        XCTAssertTrue(text.contains("first"))
        XCTAssertTrue(text.contains("second"), "the first updater's exit stopped the second")
    }

    func testScheduleIsDailyAndRecoversFromAClockCorrection() {
        let now = Date(timeIntervalSince1970: 1_000_000)

        XCTAssertFalse(AgentCLIUpdateSchedule.shouldCheck(
            enabled: false,
            lastAttempt: nil,
            now: now
        ))
        XCTAssertTrue(AgentCLIUpdateSchedule.shouldCheck(
            enabled: true,
            lastAttempt: nil,
            now: now
        ))
        XCTAssertFalse(AgentCLIUpdateSchedule.shouldCheck(
            enabled: true,
            lastAttempt: now.addingTimeInterval(-60),
            now: now
        ))
        XCTAssertTrue(AgentCLIUpdateSchedule.shouldCheck(
            enabled: true,
            lastAttempt: now.addingTimeInterval(-AgentCLIUpdateSchedule.interval),
            now: now
        ))
        XCTAssertTrue(AgentCLIUpdateSchedule.shouldCheck(
            enabled: true,
            lastAttempt: now.addingTimeInterval(60),
            now: now
        ))
    }

    func testCoordinatorDefersUntilPresentationIsVisibleAndDeduplicatesTheReceipt() async {
        let updates = fixtureUpdates()
        let report = AgentCLIUpdateReport(
            installed: [],
            updates: updates,
            failures: [],
            checkedSourceCount: updates.count,
            missingCount: 0
        )
        var canPresent = false
        var presentations: [[AgentCLIUpdate]] = []
        let coordinator = AgentCLIUpdateCoordinator(
            defaults: defaults,
            automaticChecksEnabled: { true },
            check: { report },
            canPresent: { canPresent },
            present: { presentations.append($0) },
            now: { Date(timeIntervalSince1970: 1_000_000) },
            notificationCenter: NotificationCenter()
        )

        coordinator.start()
        for _ in 0..<20 { await Task.yield() }
        XCTAssertTrue(presentations.isEmpty)

        canPresent = true
        coordinator.presentationMayBeReady()
        XCTAssertEqual(presentations, [updates])
        XCTAssertEqual(
            defaults.string(forKey: AgentCLIUpdateSchedule.lastNotificationKey),
            AgentCLIUpdateSchedule.fingerprint(for: updates)
        )

        coordinator.presentationMayBeReady()
        XCTAssertEqual(presentations.count, 1)
    }

    private func fixtureUpdates() -> [AgentCLIUpdate] {
        [
            AgentCLIUpdate(
                id: "claude",
                displayName: "Claude Code",
                installedVersion: "2.1.220",
                latestVersion: "2.1.237",
                updateCommand: "claude update"
            ),
            AgentCLIUpdate(
                id: "codex",
                displayName: "Codex",
                installedVersion: "0.145.0",
                latestVersion: "0.148.0",
                updateCommand: "codex update"
            )
        ]
    }
}
