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
        suiteName = "AgentCLIUpdatePresentationTests"
        defaults = UserDefaults(suiteName: suiteName)
        defaults.removePersistentDomain(forName: suiteName)
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

        // The plan's own shells are login shells, which is the point of it — so this runs them
        // against a scratch home rather than the developer's. A profile that prints a banner,
        // asks a question or takes its time would otherwise decide whether this test passes,
        // and one that blocks on input would hang the suite outright. Hence the deadline too.
        let home = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("AgentCLIUpdatePlan-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }

        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", plan.shellSource]
        process.environment = ["HOME": home.path, "ENV": "", "PATH": "/usr/bin:/bin"]
        process.standardOutput = output
        process.standardError = output
        process.standardInput = FileHandle.nullDevice

        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }
        try process.run()
        let text = String(
            decoding: output.fileHandleForReading.readDataToEndOfFile(),
            as: UTF8.self
        )
        guard exited.wait(timeout: .now() + Self.planDeadline) == .success else {
            process.terminate()
            return XCTFail("the update plan did not finish within \(Self.planDeadline)s")
        }

        XCTAssertEqual(process.terminationStatus, 0)
        XCTAssertTrue(text.contains("First Tool updater finished with exit code 7"))
        XCTAssertTrue(text.contains("Second Tool updater finished with exit code 0"))
        XCTAssertTrue(text.contains("first"))
        XCTAssertTrue(text.contains("second"), "the first updater's exit stopped the second")
    }

    func testAFullPlanBypassesTheCompleteTTYInputLimitAndLeavesAnInteractiveShell() {
        let plan = AgentCLIUpdateExecutionPlan(
            updates: AgentCLIUpdateCatalog.all.map { definition in
                AgentCLIUpdate(
                    id: definition.id,
                    displayName: definition.displayName,
                    installedVersion: "2026.08.11-e8db854",
                    latestVersion: "2026.08.19-aabbccd",
                    updateCommand: "/usr/bin/printf 'ran-\(definition.id)\\n'"
                )
            }
        )
        let source = plan.shellSource

        let longestLine = source.split(separator: "\n", omittingEmptySubsequences: false)
            .map(\.utf8.count)
            .max() ?? 0
        XCTAssertGreaterThan(
            source.utf8.count,
            Self.terminalInputQueueLimit,
            "the fixture must cover the aggregate queue limit that broke Update All"
        )
        XCTAssertLessThan(longestLine, Self.terminalCanonicalLineLimit)
        XCTAssertEqual(source.filter { $0 == "'" }.count % 2, 0, "quoting must balance")

        var profile = TerminalProfile.default
        profile.shellPath = "/bin/sh"
        profile.shellArguments = []
        let session = TerminalSession(
            profile: profile,
            frame: NSRect(x: 0, y: 0, width: 800, height: 500)
        )
        var output = Data()
        session.onRawOutput = { output.append($0) }
        session.startShell(
            initialDirectory: FileManager.default.temporaryDirectory,
            running: plan.shellCommand
        )
        defer { session.terminate() }

        XCTAssertTrue(
            waitForTerminalText("Agent tool update run finished.") {
                String(decoding: output, as: UTF8.self)
            },
            String(decoding: output, as: UTF8.self)
        )
        let completedText = String(decoding: output, as: UTF8.self)
        for definition in AgentCLIUpdateCatalog.all {
            XCTAssertTrue(completedText.contains("ran-\(definition.id)"), completedText)
        }

        session.insertText("/usr/bin/printf '\\nTHREADING_SHELL_READY\\n'\n")
        XCTAssertTrue(
            waitForTerminalOccurrences("THREADING_SHELL_READY", count: 2) {
                String(decoding: output, as: UTF8.self)
            },
            "the configured shell echoed the command but did not execute it"
        )
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
        XCTAssertLessThan(
            AgentCLIUpdateSchedule.pollInterval,
            AgentCLIUpdateSchedule.interval,
            "the tick has to be finer than the interval it is meant to notice"
        )
    }

    func testCoordinatorDefersUntilPresentationIsVisibleAndRecordsOnlyAStartedRun() async {
        var canPresent = false
        var presentations: [[AgentCLIUpdate]] = []
        var starts: [@MainActor () -> Void] = []
        let updates = fixtureUpdates()
        let coordinator = makeCoordinator(
            updates: updates,
            canPresent: { canPresent },
            present: { presented, didStart in
                presentations.append(presented)
                starts.append(didStart)
            }
        )

        coordinator.start()
        await settle()
        XCTAssertTrue(presentations.isEmpty)

        canPresent = true
        coordinator.presentationMayBeReady()
        XCTAssertEqual(presentations, [updates])
        XCTAssertNil(
            defaults.string(forKey: AgentCLIUpdateSchedule.lastNotificationKey),
            "showing a band is not the user answering it"
        )

        coordinator.presentationMayBeReady()
        XCTAssertEqual(presentations.count, 1)

        starts[0]()
        XCTAssertEqual(
            defaults.string(forKey: AgentCLIUpdateSchedule.lastNotificationKey),
            AgentCLIUpdateSchedule.fingerprint(for: updates)
        )
    }

    func testAReceiptNobodySawComesBackAndOneThatWasActedOnDoesNot() async {
        var clock = Date(timeIntervalSince1970: 1_000_000)
        var presentations: [[AgentCLIUpdate]] = []
        var starts: [@MainActor () -> Void] = []
        let coordinator = makeCoordinator(
            updates: fixtureUpdates(),
            canPresent: { true },
            present: { presented, didStart in
                presentations.append(presented)
                starts.append(didStart)
            },
            now: { clock }
        )

        // Day one: the band dwells its fourteen seconds behind another window and goes away.
        coordinator.start()
        await settle()
        XCTAssertEqual(presentations.count, 1)

        // A poll inside the interval is not a second check.
        coordinator.checkIfDue()
        await settle()
        XCTAssertEqual(presentations.count, 1)

        // Day two, same versions: the same news is worth saying again, because it was never heard.
        clock = clock.addingTimeInterval(AgentCLIUpdateSchedule.interval)
        coordinator.checkIfDue()
        await settle()
        XCTAssertEqual(presentations.count, 2)

        // Now it is heard, and acted on.
        starts[1]()
        clock = clock.addingTimeInterval(AgentCLIUpdateSchedule.interval)
        coordinator.checkIfDue()
        await settle()
        XCTAssertEqual(presentations.count, 2, "an answered receipt does not come back")
    }

    func testTheDaysAttemptIsSpentOnTheAnswerRatherThanTheIntent() async {
        let center = NotificationCenter()
        var enabled = true
        var presentations: [[AgentCLIUpdate]] = []
        let coordinator = makeCoordinator(
            updates: fixtureUpdates(),
            automaticChecksEnabled: { enabled },
            canPresent: { true },
            present: { presented, _ in presentations.append(presented) },
            notificationCenter: center
        )

        coordinator.start()
        XCTAssertNil(
            defaults.object(forKey: AgentCLIUpdateSchedule.lastAttemptKey),
            "an attempt that has not run yet cannot have been spent"
        )

        // Off cancels the check that just started; on asks for it again, seconds later.
        enabled = false
        center.post(AppSettingsDidChange())
        enabled = true
        center.post(AppSettingsDidChange())
        await settle()

        XCTAssertEqual(presentations.count, 1, "turning the setting back on must do something")
        XCTAssertNotNil(defaults.object(forKey: AgentCLIUpdateSchedule.lastAttemptKey))
    }

    func testAnUnrelatedSettingChangeDoesNotDropTheBandOverTheSettingsPane() async {
        let center = NotificationCenter()
        var canPresent = false
        var presentations: [[AgentCLIUpdate]] = []
        let coordinator = makeCoordinator(
            updates: fixtureUpdates(),
            canPresent: { canPresent },
            present: { presented, _ in presentations.append(presented) },
            notificationCenter: center
        )

        coordinator.start()
        await settle()
        XCTAssertTrue(presentations.isEmpty)

        // Settings is open inside the visible window, and the user flips the idle-sleep switch.
        canPresent = true
        center.post(AppSettingsDidChange())
        await settle()
        XCTAssertTrue(
            presentations.isEmpty,
            "a held receipt waits for the window and the activation, not for any setting"
        )

        coordinator.presentationMayBeReady()
        XCTAssertEqual(presentations.count, 1)
    }

    // MARK: - Helpers

    private static let planDeadline: TimeInterval = 30
    /// `{MAX_INPUT}` on this platform: the aggregate terminal input queue, not one line.
    private static let terminalInputQueueLimit = 1_024
    /// `MAX_CANON` on this platform: a longer line is discarded whole by the line discipline.
    private static let terminalCanonicalLineLimit = 1_024

    private func waitForTerminalText(
        _ expected: String,
        timeout: TimeInterval = 10,
        output: () -> String
    ) -> Bool {
        waitForTerminalOccurrences(expected, count: 1, timeout: timeout, output: output)
    }

    private func waitForTerminalOccurrences(
        _ expected: String,
        count: Int,
        timeout: TimeInterval = 10,
        output: () -> String
    ) -> Bool {
        func occurrenceCount() -> Int {
            output().components(separatedBy: expected).count - 1
        }
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if occurrenceCount() >= count { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        } while Date() < deadline
        return occurrenceCount() >= count
    }

    private func makeCoordinator(
        updates: [AgentCLIUpdate],
        automaticChecksEnabled: @escaping @MainActor () -> Bool = { true },
        canPresent: @escaping @MainActor () -> Bool,
        present: @escaping AgentCLIUpdateCoordinator.Present,
        now: @escaping @MainActor () -> Date = { Date(timeIntervalSince1970: 1_000_000) },
        notificationCenter: NotificationCenter = NotificationCenter()
    ) -> AgentCLIUpdateCoordinator {
        let report = AgentCLIUpdateReport(
            installed: [],
            updates: updates,
            failures: [],
            checkedSourceCount: updates.count,
            missingCount: 0
        )
        return AgentCLIUpdateCoordinator(
            defaults: defaults,
            automaticChecksEnabled: automaticChecksEnabled,
            check: { report },
            canPresent: canPresent,
            present: present,
            now: now,
            notificationCenter: notificationCenter
        )
    }

    private func settle() async {
        for _ in 0..<20 { await Task.yield() }
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
