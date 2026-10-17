import AppKit
import XCTest
@testable import Threading

@MainActor
final class RemoteHostAvailabilityTests: HostedStoreTestCase {
    func testWindowsNeedsItsOwnMatchingBootTaskEvenWithEnabledLinuxServices() throws {
        let output = AvailabilityRunner.windows
        XCTAssertEqual(try XCTUnwrap(RemoteHostAvailabilityProbe.parse(output)).startup, .automatic)
        for changed in [
            output.replacingOccurrences(of: "taskDistro=Ubuntu-24.04", with: "taskDistro=Other"),
            output.replacingOccurrences(of: "taskUser=threading", with: "taskUser=other"),
            output.replacingOccurrences(of: "taskStartup=automatic", with: "taskStartup=unknown"),
            output.replacingOccurrences(of: "taskScript=/home/threading/", with: "taskScript=/home/other/")
        ] {
            XCTAssertEqual(try XCTUnwrap(RemoteHostAvailabilityProbe.parse(changed)).startup, .unknown)
        }
        XCTAssertEqual(try XCTUnwrap(RemoteHostAvailabilityProbe.parse(
            output.replacingOccurrences(of: "taskStartup=automatic", with: "taskStartup=manual"))).startup, .manual)
        XCTAssertEqual(try XCTUnwrap(RemoteHostAvailabilityProbe.parse(
            output.replacingOccurrences(of: "linger=yes", with: "linger=no"))).startup, .manual)
    }

    func testStartupAndSleepAreIndependentAndMissingTimersAreNotZero() throws {
        let facts = try XCTUnwrap(RemoteHostAvailabilityProbe.parse(AvailabilityRunner.windows))
        XCTAssertEqual(facts.startup, .automatic)
        XCTAssertEqual(facts.sleep, .maySleep)
        let noTimers = AvailabilityRunner.windows.replacingOccurrences(of: "sleepDC=7200", with: "sleepDC=")
        XCTAssertEqual(try XCTUnwrap(RemoteHostAvailabilityProbe.parse(noTimers)).sleep, .unknown)
        let disabled = AvailabilityRunner.windows.replacingOccurrences(of: "7200", with: "0")
        XCTAssertEqual(try XCTUnwrap(RemoteHostAvailabilityProbe.parse(disabled)).sleep, .idleDisabled)
        XCTAssertNil(RemoteHostAvailabilityProbe.parse("permission denied"))
        XCTAssertNil(RemoteHostAvailabilityProbe.parse(String(repeating: "a", count: 8193)))
        XCTAssertEqual(try XCTUnwrap(RemoteHostAvailabilityProbe.parse(AvailabilityRunner.linux)).startup, .manual)
        XCTAssertEqual(try XCTUnwrap(RemoteHostAvailabilityProbe.parse(
            AvailabilityRunner.linux.replacingOccurrences(of: "disabled", with: "enabled"))).startup, .automatic)
    }

    func testChecksCoalesceAndAFailureKeepsThePreviousReadingLabelled() async throws {
        let runner = AvailabilityRunner(blocked: true)
        let coordinator = RemoteExecutionHosts(runner: runner)
        let host = RemoteHostDestination(alias: "windows", configFile: nil)
        for _ in 0..<50 { coordinator.checkAvailability(for: host) }
        runner.release()
        try await wait(coordinator, for: host)
        XCTAssertEqual(runner.count, 1)
        let previous = coordinator.availability(for: host)
        XCTAssertEqual(previous.facts.startup, .automatic)
        runner.fail = true
        coordinator.checkAvailability(for: host)
        runner.release()
        try await wait(coordinator, for: host)
        let failed = coordinator.availability(for: host)
        XCTAssertTrue(failed.failed)
        XCTAssertEqual(failed.facts, previous.facts)
        XCTAssertEqual(failed.checkedAt, previous.checkedAt)
        XCTAssertTrue(RemoteHostAvailabilityPresentation.freshness(failed).contains("Last known"))
    }

    func testTheWindowsSetupInstallerShipsInTheApp() throws {
        let file = try XCTUnwrap(RemoteHostWindowsSetup.resourceURL)
        let script = try String(contentsOf: file, encoding: .utf8)
        XCTAssertTrue(script.contains("-LogonType S4U"))
        XCTAssertTrue(script.contains("-ExecutionTimeLimit ([TimeSpan]::Zero)"))
    }

    func testTheProjectWarningUsesTheHostFactsAndClearsWhenTheyChange() throws {
        var project = Project(name: "Windows", folderURL: URL(fileURLWithPath: "/tmp/windows"))
        let host = ProjectExecutionHost(destination: "windows", remoteDirectory: "/home/threading/projects")
        project.executionHost = host
        let row = ProjectRowView(customizationLookup: { _ in .empty })
        var check = RemoteHostAvailabilityCheck(facts: .init(startup: .manual))
        row.configure(with: project, executionHost: host.destination, hostAvailability: check)
        let mark = try XCTUnwrap(descendants(row).first { $0.accessibilityIdentifier() == RemoteExecutionHostMark.projectMarkIdentifier })
        XCTAssertTrue(mark.accessibilityLabel()?.contains("manual startup") == true)
        check.facts.startup = .automatic
        row.refreshRemoteHostAvailability(for: host.sshDestination, check: check)
        XCTAssertEqual(mark.accessibilityLabel(), RemoteExecutionHostMark.runsOn(host.destination))
        XCTAssertTrue(mark.accessibilityHelp()?.contains("Autostart: Configured") == true)
    }

    func testLiveWindowsAvailabilityIsReadWithoutChangingTheHost() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let alias = environment["THREADING_REMOTE_HOST_DESTINATION"] else { throw XCTSkip("Opt-in read-only host check") }
        let destination = RemoteHostDestination(alias: alias, configFile: environment["THREADING_REMOTE_HOST_SSH_CONFIG"])
        let result = try await Task.detached {
            try SystemSSHCommandRunner().run(on: destination, command: "sh -s",
                input: .data(Data(RemoteHostAvailabilityProbe.script.utf8)), extraOptions: [], timeout: RemoteHostAvailabilityProbe.timeout)
        }.value
        XCTAssertTrue(result.succeeded, result.output)
        let facts = try XCTUnwrap(RemoteHostAvailabilityProbe.parse(result.output), result.output)
        XCTAssertEqual(facts.platform, .wsl)
        XCTAssertEqual(facts.startup, .automatic, result.output)
        XCTAssertEqual(facts.sleep, .maySleep, result.output)
    }

    func testAThousandHostsKeepOnlyViewportRowsAndRefreshOneHost() async throws {
        guard ProcessInfo.processInfo.environment["THREADING_REMOTE_HOST_STRESS"] == "1" else {
            throw XCTSkip("Opt-in 1,000-host viewport fixture")
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        struct Fixture: Encodable { let hosts: [RemoteHostRecord] }
        let records = (0..<1000).map { RemoteHostRecord(label: String(format: "Host %04d", $0), destination: "host-\($0)") }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(Fixture(hosts: records)).write(to: root.appendingPathComponent(RemoteHostStoreDefaults.fileName))
        let coordinator = RemoteExecutionHosts(runner: AvailabilityRunner())
        let page = RemoteHostsPreferencesViewController(store: RemoteHostStore(directory: root), coordinator: coordinator)
        let shell = makeMainWindowController(initialFramePlan: .useDefaultFrame)
        let window = try XCTUnwrap(shell.window)
        defer { window.orderOut(nil) }
        window.setContentSize(NSSize(width: 1280, height: 820))
        shell.showSettingsPage(id: SettingsPages.remoteHostsID)
        shell.containerViewController.install(settings: page, repaint: false)
        page.viewWillAppear()
        let pane = try XCTUnwrap(window.contentView)
        pane.layoutSubtreeIfNeeded()
        let bitmap = try XCTUnwrap(pane.bitmapImageRepForCachingDisplay(in: pane.bounds))
        pane.cacheDisplay(in: pane.bounds, to: bitmap)
        let table = try XCTUnwrap(descendants(page.view).compactMap { $0 as? ThemedGroupedTableView }.first)
        XCTAssertEqual(table.numberOfRows, 1001)
        XCTAssertGreaterThan(table.visibleRect.height, 100)
        let before = visibleHostLabels(in: table)
        XCTAssertNotNil(before[1], "the host being refreshed must be in the viewport")
        XCTAssertGreaterThan(before.count, 1)
        XCTAssertLessThan(before.count, 30)
        let updated = expectation(description: "availability delivered to the mounted page")
        let events = AppEventObservations()
        defer { events.removeAll() }
        var received = false
        events.observe(RemoteHostAvailabilityDidChange.self) { event in
            guard !received, event.coordinator == ObjectIdentifier(coordinator),
                  coordinator.availability(for: event.destination).checkedAt != nil else { return }
            received = true
            updated.fulfill()
        }
        coordinator.checkAvailability(for: records[0].sshDestination)
        await fulfillment(of: [updated], timeout: 3)
        page.view.layoutSubtreeIfNeeded()
        let startup = descendants(page.view).first { $0.accessibilityIdentifier() == "settings.remote-hosts.startup.0" } as? NSTextField
        XCTAssertEqual(startup?.stringValue, "Autostart: Configured")
        let after = visibleHostLabels(in: table)
        XCTAssertNotNil(after[1])
        XCTAssertLessThan(after.count, 30)
        let commonRows = before.keys.filter { $0 != 1 && after[$0] != nil }
        XCTAssertFalse(commonRows.isEmpty)
        for row in commonRows {
            XCTAssertEqual(after[row], before[row], "a status update rebuilt an unrelated row")
        }
    }

    func testRendersAvailabilityInTheShippingSettingsCanvas() async throws {
        let oldTheme = AppThemeLibrary.current
        let palette = AppThemePalette.current
        defer { AppThemeLibrary.installResolved(oldTheme); AppThemePalette.set(palette) }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let triggers = TriggerStore(url: root.appendingPathComponent("triggers.db"))
        addTeardownBlock { await triggers.close(); try? FileManager.default.removeItem(at: root) }
        let store = RemoteHostStore(directory: root)
        let runner = AvailabilityRunner()
        let coordinator = RemoteExecutionHosts(runner: runner, availabilityClock: { Date(timeIntervalSince1970: 1792059000) })
        for (name, alias) in [("Windows PC", "windows"), ("Build server", "linux"), ("New host", "unknown")] {
            let record = RemoteHostRecord(label: name, destination: alias)
            XCTAssertEqual(store.add(record), .applied)
            if alias != "unknown" {
                coordinator.checkAvailability(for: record.sshDestination)
                try await wait(coordinator, for: record.sshDestination)
            }
        }
        let folder = root.appendingPathComponent("Windows workspace", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let project = try XCTUnwrap(ProjectStore.shared.addProject(folderURL: folder))
        let host = ProjectExecutionHost(destination: "windows", remoteDirectory: "/home/threading/projects")
        XCTAssertEqual(ProjectStore.shared.setExecutionHost(host, forProjectID: project.id), .applied)
        let shell = makeMainWindowController(initialFramePlan: .useDefaultFrame, triggerStore: triggers)
        let window = try XCTUnwrap(shell.window)
        defer { window.orderOut(nil) }
        window.setContentSize(NSSize(width: 1280, height: 820))
        let content = try XCTUnwrap(window.contentView)
        let output = URL(fileURLWithPath: ProcessInfo.processInfo.environment["THREADING_RENDER_OUT"] ?? NSTemporaryDirectory())
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        AppThemeLibrary.installResolved(.system)
        window.appearance = NSAppearance(named: .darkAqua)
        shell.sidebarViewController.mountInitialTreeIfNeeded()
        AppThemeRefresh.repaint(content)
        content.layoutSubtreeIfNeeded()
        let projectRows = descendants(shell.sidebarViewController.view).compactMap { $0 as? ProjectRowView }
        for row in projectRows {
            row.refreshRemoteHostAvailability(for: host.sshDestination, check: coordinator.availability(for: host.sshDestination))
        }
        XCTAssertTrue(descendants(shell.sidebarViewController.view).contains {
            $0.accessibilityLabel()?.contains("can sleep while remote work") == true
        }, "the warning must be mounted in the shipping outline")
        try capture(content, to: output.appendingPathComponent("remote-host-availability-sidebar.png"))
        shell.showSettingsPage(id: SettingsPages.remoteHostsID)
        let page = RemoteHostsPreferencesViewController(store: store, coordinator: coordinator)
        shell.containerViewController.install(settings: page, repaint: false)
        page.viewWillAppear()
        for (name, theme, appearance) in [
            ("light", AppTheme.system, NSAppearance.Name.aqua), ("dark", AppTheme.system, .darkAqua),
            ("cyberpunk", AppThemeStyles.cyberpunk, .darkAqua), ("swiss", AppThemeStyles.swissMinimalist, .aqua)
        ] {
            AppThemeLibrary.installResolved(theme)
            window.appearance = NSAppearance(named: appearance)
            AppThemeRefresh.repaint(content)
            content.layoutSubtreeIfNeeded()
            content.layoutSubtreeIfNeeded()
            XCTAssertEqual(ThemeBoundaryAudit.violations(in: page.view), [])
            let labels = descendants(page.view).compactMap { $0 as? NSTextField }.map(\.stringValue)
            XCTAssertTrue(labels.contains("Autostart: Manual start required"))
            XCTAssertTrue(labels.contains("Sleep: Automatic sleep enabled"))
            try capture(content, to: output.appendingPathComponent("remote-host-availability-\(name).png"))
        }
    }

    private func capture(_ content: NSView, to destination: URL) throws {
        content.layoutSubtreeIfNeeded()
        let bitmap = try XCTUnwrap(content.bitmapImageRepForCachingDisplay(in: content.bounds))
        content.cacheDisplay(in: content.bounds, to: bitmap)
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: destination)
    }

    private func visibleHostLabels(in table: NSTableView) -> [Int: ObjectIdentifier] {
        var result: [Int: ObjectIdentifier] = [:]
        table.enumerateAvailableRowViews { row, index in
            guard let label = descendants(row).first(where: {
                $0.accessibilityIdentifier().hasPrefix("settings.remote-hosts.startup.")
            }) else { return }
            result[index] = ObjectIdentifier(label)
        }
        return result
    }

    private func wait(_ coordinator: RemoteExecutionHosts, for destination: RemoteHostDestination) async throws {
        let deadline = Date().addingTimeInterval(3)
        while coordinator.availability(for: destination).isChecking, Date() < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertFalse(coordinator.availability(for: destination).isChecking)
    }

    private func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
}

private final class AvailabilityRunner: RemoteHostCommandRunning, @unchecked Sendable {
    private let lock = NSLock()
    private var calls = 0
    private var failing = false
    private let gate: DispatchSemaphore?
    init(blocked: Bool = false) { gate = blocked ? DispatchSemaphore(value: 0) : nil }
    func release() { gate?.signal() }
    var count: Int { lock.lock(); defer { lock.unlock() }; return calls }
    var fail: Bool {
        get { lock.lock(); defer { lock.unlock() }; return failing }
        set { lock.lock(); defer { lock.unlock() }; failing = newValue }
    }
    func run(on destination: RemoteHostDestination, command: String, input: RemoteHostCommandInput,
             extraOptions: [String], timeout: TimeInterval) throws -> RemoteHostCommandResult {
        lock.lock(); calls += 1; let failed = failing; lock.unlock()
        if let gate { _ = gate.wait(timeout: .now() + 3) }
        return .init(output: destination.alias == "linux" ? Self.linux : Self.windows, termination: .exited(failed ? 1 : 0))
    }
    static let linux = "availability=1\nplatform=linux\nlinger=yes\nservices=disabled\nssh=enabled"
    static let windows = #"""
        availability=1
        platform=wsl
        home=/home/threading
        user=threading
        linger=yes
        services=enabled
        ssh=enabled
        wslRoot=\\wsl.localhost\Ubuntu-24.04\
        taskDistro=Ubuntu-24.04
        taskUser=threading
        taskScript=/home/threading/.local/lib/threading/wsl-startup/keep-running.sh
        taskStartup=automatic
        sleepAC=0
        sleepDC=7200
        hibernateAC=0
        hibernateDC=0
        """#
}
