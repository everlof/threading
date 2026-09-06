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
                executable: "false",
                versionArguments: [],
                comparison: .semantic,
                installedVersion: "1.0.0",
                latestVersion: "2.0.0",
                updateArguments: []
            ),
            AgentCLIUpdate(
                id: "second",
                displayName: "Second Tool",
                executable: "echo",
                versionArguments: ["4.0.0"],
                comparison: .semantic,
                installedVersion: "3.0.0",
                latestVersion: "4.0.0",
                updateArguments: ["second"]
            )
        ]
        let items: [AgentCLIUpdateExecutionItem] = [
            .ready(
                update: updates[0],
                resolved: ResolvedAgentCLI(
                    executablePath: "/usr/bin/false",
                    effectivePATH: "/usr/bin:/bin",
                    version: "1.0.0"
                )
            ),
            .ready(
                update: updates[1],
                resolved: ResolvedAgentCLI(
                    executablePath: "/bin/echo",
                    effectivePATH: "/usr/bin:/bin",
                    version: "3.0.0"
                )
            )
        ]
        let plan = AgentCLIUpdateExecutionPlan(items: items)
        let script = AgentCLIUpdateShellCommand.script(for: items)

        XCTAssertTrue(script.contains("'/usr/bin/env' 'PATH=/usr/bin:/bin' '/usr/bin/false'"))
        XCTAssertTrue(script.contains("'/usr/bin/env' 'PATH=/usr/bin:/bin' '/bin/echo' 'second'"))
        XCTAssertTrue(plan.shellSource.hasPrefix("'/bin/sh' '-c' "))
        XCTAssertFalse(plan.shellSource.contains("'-l'"))

        // The runner is deliberately a clean non-login shell: provider paths and the PATH needed
        // by their interpreters were resolved before this terminal began.
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
        XCTAssertTrue(text.contains("First Tool updater failed with exit code 1"))
        XCTAssertTrue(text.contains("Second Tool updated from 3.0.0 to 4.0.0"))
        XCTAssertTrue(text.contains("second"), "the first updater's exit stopped the second")
        XCTAssertTrue(text.contains("1 updated, 0 changed, 0 skipped, 1 failed"))
    }

    func testPreflightReResolvesAndSkipsAToolUpdatedSinceTheNotice() async {
        let update = fixtureUpdates()[0]
        let plan = await AgentCLIUpdateExecutionPlan.prepare(updates: [update]) { _ in
            .success(ResolvedAgentCLI(
                executablePath: "/fresh/bin/claude",
                effectivePATH: "/fresh/bin:/usr/bin:/bin",
                version: update.latestVersion
            ))
        }

        XCTAssertEqual(plan.items, [
            .alreadyCurrent(
                update: update,
                resolved: ResolvedAgentCLI(
                    executablePath: "/fresh/bin/claude",
                    effectivePATH: "/fresh/bin:/usr/bin:/bin",
                    version: update.latestVersion
                )
            )
        ])
    }

    func testResolvedPATHRunsAnEnvShebangFromASparseGUIEnvironment() throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("AgentCLIUpdatePATH-\(UUID().uuidString)", isDirectory: true)
        let bin = home.appendingPathComponent("bin", isDirectory: true)
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }

        let interpreter = bin.appendingPathComponent("fixture-shell")
        try FileManager.default.createSymbolicLink(
            at: interpreter,
            withDestinationURL: URL(fileURLWithPath: "/bin/sh")
        )
        let versionFile = home.appendingPathComponent("version")
        try Data("1.0.0\n".utf8).write(to: versionFile)
        let executable = bin.appendingPathComponent("fixture-agent")
        let source = """
        #!/usr/bin/env fixture-shell
        if [ "$1" = "update" ]; then
            /usr/bin/printf '2.0.0\\n' > "$HOME/version"
        else
            /bin/cat "$HOME/version"
        fi
        """
        try Data(source.utf8).write(to: executable)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: executable.path
        )

        let update = AgentCLIUpdate(
            id: "fixture",
            displayName: "Fixture Tool",
            executable: "fixture-agent",
            versionArguments: ["--version"],
            comparison: .semantic,
            installedVersion: "1.0.0",
            latestVersion: "2.0.0",
            updateArguments: ["update"]
        )
        let plan = AgentCLIUpdateExecutionPlan(items: [
            .ready(
                update: update,
                resolved: ResolvedAgentCLI(
                    executablePath: executable.path,
                    effectivePATH: "\(bin.path):/usr/bin:/bin",
                    version: "1.0.0"
                )
            )
        ])

        let result = try BoundedChildProcess.run(
            executable: "/bin/sh",
            arguments: ["-c", plan.shellSource],
            environment: [
                "HOME": home.path,
                "PATH": "/usr/bin:/bin"
            ],
            timeout: Self.planDeadline,
            maximumOutputBytes: 64 * 1_024
        )
        let text = String(decoding: result.output, as: UTF8.self)

        XCTAssertEqual(result.termination, .exited(0))
        XCTAssertTrue(text.contains("Fixture Tool updated from 1.0.0 to 2.0.0"), text)
        XCTAssertTrue(text.contains("1 updated, 0 changed, 0 skipped, 0 failed"), text)
    }

    func testAZeroExitWithoutAVersionChangeIsReportedAsAFailure() throws {
        let update = AgentCLIUpdate(
            id: "unchanged",
            displayName: "Unchanged Tool",
            executable: "echo",
            versionArguments: ["1.0.0"],
            comparison: .semantic,
            installedVersion: "1.0.0",
            latestVersion: "2.0.0",
            updateArguments: ["provider updater exited zero"]
        )
        let plan = AgentCLIUpdateExecutionPlan(items: [
            .ready(
                update: update,
                resolved: ResolvedAgentCLI(
                    executablePath: "/bin/echo",
                    effectivePATH: "/usr/bin:/bin",
                    version: "1.0.0"
                )
            )
        ])

        let result = try BoundedChildProcess.run(
            executable: "/bin/sh",
            arguments: ["-c", plan.shellSource],
            timeout: Self.planDeadline,
            maximumOutputBytes: 64 * 1_024
        )
        let text = String(decoding: result.output, as: UTF8.self)

        XCTAssertEqual(result.termination, .exited(0))
        XCTAssertTrue(text.contains("provider updater exited zero"), text)
        XCTAssertTrue(text.contains("version remains 1.0.0"), text)
        XCTAssertTrue(text.contains("0 updated, 0 changed, 0 skipped, 1 failed"), text)
    }

    func testAFullPlanBypassesTheCompleteTTYInputLimitAndLeavesAnInteractiveShell() {
        let plan = AgentCLIUpdateExecutionPlan(
            items: AgentCLIUpdateCatalog.all.map { definition in
                let update = AgentCLIUpdate(
                    id: definition.id,
                    displayName: definition.displayName,
                    executable: definition.executable,
                    versionArguments: ["2026.08.19-aabbccd"],
                    comparison: definition.comparison,
                    installedVersion: "2026.08.11-e8db854",
                    latestVersion: "2026.08.19-aabbccd",
                    updateArguments: ["ran-\(definition.id)"]
                )
                return .ready(
                    update: update,
                    resolved: ResolvedAgentCLI(
                        executablePath: "/bin/echo",
                        effectivePATH: "/usr/bin:/bin",
                        version: update.installedVersion
                    )
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
            waitForTerminalText("Agent tool update run finished:") {
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
                executable: "claude",
                versionArguments: ["--version"],
                comparison: .semantic,
                installedVersion: "2.1.220",
                latestVersion: "2.1.237",
                updateArguments: ["update"]
            ),
            AgentCLIUpdate(
                id: "codex",
                displayName: "Codex",
                executable: "codex",
                versionArguments: ["--version"],
                comparison: .semantic,
                installedVersion: "0.145.0",
                latestVersion: "0.148.0",
                updateArguments: ["update"]
            )
        ]
    }
}
