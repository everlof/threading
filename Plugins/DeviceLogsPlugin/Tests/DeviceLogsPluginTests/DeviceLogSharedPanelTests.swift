import AppKit
import XCTest
@testable import DeviceLogsPlugin

@MainActor
final class DeviceLogSharedPanelTests: XCTestCase {
    private let bundleID = "com.example.chameleon"

    private func row(_ text: String, level: String = "Info", process: String = "Ananke", pid: Int = 42,
                     subsystem: String = "AirLab", category: String = "Bluetooth") -> DeviceLogRow {
        .init(time: "09:41:00", level: level, process: process, subsystem: subsystem, message: text,
              deviceID: "phone", bundleID: bundleID, pid: pid, category: category,
              source: .system, rawLine: text)
    }

    private func pane() -> DeviceLogPaneViewController {
        let pane = DeviceLogPaneViewController(owningSessionID: UUID().uuidString, stream: .regular)
        pane.loadView()
        let phone = DeviceLogSourceOption.Machine(id: "phone", title: "David's 16 Pro", isSimulator: false)
        pane.installSourcesForTesting([
            .init(machine: phone, title: "Chameleon", kind: .app(deviceID: phone.id, bundleID: bundleID, appName: "Chameleon")),
        ])
        return pane
    }

    func testSharedScenarioAndManualEditChangeTheNextRead() async throws {
        let pane = pane()
        pane.installRowsForTesting([row("AirLab TX NS"), row("AirLab RX ANCS CP"), row("AirLab TX DS"), row("Other", subsystem: "Other")])
        var configuration = DeviceLogPanelConfiguration()
        configuration.deviceID = "phone"
        configuration.bundleID = bundleID
        configuration.process = "Ananke"
        configuration.text = "AirLab"
        configuration.levels = []
        let state = try await pane.configurePanel(configuration, expectedRevision: pane.panelState().revision)
        let first = try await pane.readPanel(expectedRevision: state.revision)
        XCTAssertEqual(first.rows.map(\.message), ["AirLab TX NS", "AirLab RX ANCS CP", "AirLab TX DS"])
        XCTAssertEqual(first.state.filter.textMode, .literal)
        XCTAssertEqual(first.state.deviceName, "David's 16 Pro")
        pane.simulateUserFilterEditForTesting("ANCS")
        let next = try await pane.readPanel()
        XCTAssertEqual(next.rows.map(\.message), ["AirLab RX ANCS CP"])
        XCTAssertGreaterThan(next.state.revision, first.state.revision)
        do {
            _ = try await pane.configurePanel(configuration, expectedRevision: first.state.revision)
            XCTFail("stale configuration must not overwrite manual edits")
        } catch let error as DeviceLogPanelError { XCTAssertEqual(error.code, "stale_revision") }
        XCTAssertEqual(pane.panelState().filter.text, "ANCS")
    }

    func testLiteralRegexAndIndependentPredicatesHaveOneMeaningForReadsAndUI() async throws {
        let pane = pane()
        pane.installRowsForTesting([
            row("Air.Lab TX", level: "Info"), row("AirXLab RX", level: "Error"),
            row("Air.Lab wrong subsystem", subsystem: "Other"),
            row("Air.Lab wrong category", category: "Other"), row("Air.Lab debug", level: "Debug"),
        ])
        var configuration = DeviceLogPanelConfiguration()
        configuration.text = "Air.Lab"
        configuration.subsystem = "AirLab"
        configuration.category = "Bluetooth"
        configuration.levels = ["info", "error"]
        _ = try await pane.configurePanel(configuration)
        let literal = try await pane.readPanel()
        XCTAssertEqual(literal.rows.map(\.message), ["Air.Lab TX"])
        configuration.textMode = .regex
        _ = try await pane.configurePanel(configuration)
        let regex = try await pane.readPanel()
        XCTAssertEqual(regex.rows.map(\.message), ["Air.Lab TX", "AirXLab RX"])
        let revision = pane.panelState().revision
        configuration.text = "["
        do {
            _ = try await pane.configurePanel(configuration, expectedRevision: revision)
            XCTFail("invalid expression must fail")
        } catch let error as DeviceLogPanelError { XCTAssertEqual(error.code, "invalid_regex") }
        XCTAssertEqual(pane.panelState().revision, revision)
        XCTAssertEqual(pane.panelState().filter.text, "Air.Lab")
    }

    func testDataAppendDoesNotInvalidateConfigurationButPIDRestartDoes() async throws {
        let pane = pane()
        let source = BufferedDeviceLogSource()
        pane.sourceFactory = { _, _, _ in source }
        pane.startCapture(discover: false)
        defer { pane.stopCapture() }
        var configuration = DeviceLogPanelConfiguration()
        configuration.bundleID = bundleID
        _ = try await pane.configurePanel(configuration)
        source.enqueue([row("first")]); pane.drain()
        let revision = pane.panelState().revision
        source.enqueue([row("second")]); pane.drain()
        XCTAssertEqual(pane.panelState().revision, revision)
        source.enqueue([row("after restart", pid: 99)]); pane.drain()
        XCTAssertGreaterThan(pane.panelState().revision, revision)
        XCTAssertEqual(pane.panelState().selectedPID, 99)
        XCTAssertEqual(pane.panelState().filter.bundleID, bundleID)
        let page = try await pane.readPanel()
        XCTAssertEqual(page.rows.map(\.message), ["first", "second", "after restart"])
    }

    func testCursorLimitReadNeverScrollsAndRevealUsesExactStableIDs() async throws {
        let pane = pane()
        let rows = (0..<100).map { row("line \($0)") }
        pane.installRowsForTesting(rows)
        let initialOrigin = pane.scrollOriginForTesting
        let first = try await pane.readPanel(limit: 2)
        XCTAssertEqual(first.rows.map(\.id), rows.prefix(2).map(\.id))
        XCTAssertTrue(first.hasMore)
        let next = try await pane.readPanel(cursor: first.cursor, limit: 2)
        XCTAssertEqual(next.rows.map(\.id), rows[2..<4].map(\.id))
        XCTAssertEqual(pane.scrollOriginForTesting, initialOrigin)
        XCTAssertTrue(pane.selectedRowIDsForTesting.isEmpty)
        let revealed = try await pane.revealPanel(rowID: rows[70].id, throughRowID: rows[72].id)
        XCTAssertEqual(pane.selectedRowIDsForTesting, rows[70...72].map(\.id))
        XCTAssertFalse(revealed.following)
        pane.installRowsForTesting([row("replacement")])
        do { _ = try await pane.revealPanel(rowID: rows[70].id); XCTFail("retired identity must not reveal another row") }
        catch let error as DeviceLogPanelError { XCTAssertEqual(error.code, "row_unavailable") }
        do { _ = try await pane.readPanel(limit: 201); XCTFail("oversized read must fail") }
        catch let error as DeviceLogPanelError { XCTAssertEqual(error.code, "invalid_limit") }
    }

    func testWaitMatchesNewRowsAndReportsFilterChanges() async throws {
        let pane = pane()
        let source = BufferedDeviceLogSource()
        pane.sourceFactory = { _, _, _ in source }
        pane.startCapture(discover: false)
        defer { pane.stopCapture() }
        var configuration = DeviceLogPanelConfiguration()
        configuration.text = "ANCS"
        _ = try await pane.configurePanel(configuration)
        let initial = try await pane.readPanel()
        let waiting = Task { try await pane.waitPanel(cursor: initial.cursor, timeout: 1) }
        try await Task.sleep(for: .milliseconds(70))
        source.enqueue([row("AirLab RX ANCS CP")]); pane.drain()
        let result = try await waiting.value
        XCTAssertEqual(result.rows.map(\.message), ["AirLab RX ANCS CP"])
        XCTAssertFalse(result.timedOut)
        let changing = Task { try await pane.waitPanel(cursor: result.cursor, timeout: 1) }
        try await Task.sleep(for: .milliseconds(70))
        pane.simulateUserFilterEditForTesting("TX")
        let changed = try await changing.value
        XCTAssertTrue(changed.changed)
        XCTAssertEqual(changed.changeReason, "configuration_changed")
        XCTAssertEqual(changed.state.filter.text, "TX")
    }

    func testEmptyUnavailableWaitAndPauseAreTruthful() async throws {
        let empty = DeviceLogPaneViewController(owningSessionID: UUID().uuidString)
        empty.loadView()
        XCTAssertEqual(empty.panelState().captureState, "unavailable")
        let result = try await empty.waitPanel(timeout: 0.1)
        XCTAssertEqual(result.rows.count, 0)
        XCTAssertFalse(result.timedOut)
        var config = DeviceLogPanelConfiguration()
        config.paused = true
        let paused = try await empty.configurePanel(config)
        XCTAssertTrue(paused.paused)
        XCTAssertEqual(paused.captureState, "paused")
    }

    func testSparseReadHasBoundedScanAndLargeRowsHaveBoundedOutput() async throws {
        let pane = pane()
        pane.installRowsForTesting((0..<25_000).map { row($0 == 24_999 ? "needle" : "routine") })
        var config = DeviceLogPanelConfiguration()
        config.text = "needle"
        _ = try await pane.configurePanel(config)
        let first = try await pane.readPanel(limit: 1)
        XCTAssertTrue(first.rows.isEmpty)
        XCTAssertTrue(first.hasMore)
        let second = try await pane.readPanel(cursor: first.cursor, limit: 1)
        XCTAssertTrue(second.rows.isEmpty)
        let third = try await pane.readPanel(cursor: second.cursor, limit: 1)
        XCTAssertEqual(third.rows.map(\.message), ["needle"])
        pane.installRowsForTesting((0..<50).map { _ in row(String(repeating: "large", count: 5_000)) })
        config.text = ""
        _ = try await pane.configurePanel(config)
        let bounded = try await pane.readPanel(limit: 50)
        XCTAssertLessThan(bounded.rows.count, 50)
        XCTAssertTrue(bounded.outputTruncated)
        XCTAssertTrue(bounded.hasMore)
        XCTAssertTrue(bounded.rows.allSatisfy { $0.message.utf8.count <= 8_195 && $0.truncated })
    }

    func testFullRingSparseReadStress() async throws {
        guard ProcessInfo.processInfo.environment["THREADING_DEVICE_LOG_SHARED_STRESS"] == "1" else { throw XCTSkip("opt-in full-ring query workload") }
        let pane = pane()
        pane.installRowsForTesting((0..<50_000).map { row($0 % 9_999 == 0 ? "AirLab ANCS \($0)" : "routine \($0)") })
        var config = DeviceLogPanelConfiguration()
        config.text = "ANCS"
        let start = DispatchTime.now().uptimeNanoseconds
        _ = try await pane.configurePanel(config)
        var cursor: String?
        var count = 0
        var scans = 0
        repeat {
            let page = try await pane.readPanel(cursor: cursor, limit: 2)
            XCTAssertLessThanOrEqual(page.count, 2)
            count += page.count; scans += 1; cursor = page.cursor
            if !page.hasMore { break }
        } while scans < 20
        XCTAssertEqual(count, 6)
        XCTAssertEqual(pane.panelState().retainedCount, 50_000)
        let elapsed = Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
        print("Shared device-log full ring: \(scans) bounded pages, \(count) matches, \(elapsed) ms")
    }
    func testExactWarningLevelDoesNotIncludeNotice() async throws {
        let pane = pane()
        pane.installRowsForTesting([row("warning", level: "Warning"), row("notice", level: "Notice"), row("default", level: "Default")])
        var config = DeviceLogPanelConfiguration()
        config.levels = ["warning"]
        _ = try await pane.configurePanel(config)
        let warnings = try await pane.readPanel()
        XCTAssertEqual(warnings.rows.map(\.message), ["warning"])
        config.levels = ["notice"]
        _ = try await pane.configurePanel(config)
        let notices = try await pane.readPanel()
        XCTAssertEqual(notices.rows.map(\.message), ["notice", "default"])
    }

    func testContextReadSharesThePanelsProjectionAndMarksMatches() async throws {
        let pane = pane()
        pane.installRowsForTesting((0..<10).map { row($0 == 5 ? "needle" : "routine \($0)") })
        var config = DeviceLogPanelConfiguration()
        config.text = "needle"
        config.showContext = true
        _ = try await pane.configurePanel(config)
        for _ in 0..<200 where pane.isProjectingForTesting { try await Task.sleep(for: .milliseconds(5)) }
        let page = try await pane.readPanel()
        XCTAssertEqual(page.rows.map(\.message), pane.visibleRowsForTools(limit: 50).map(\.message))
        XCTAssertEqual(page.rows.count, 5)
        XCTAssertEqual(page.rows.filter(\.isMatch).map(\.message), ["needle"])
    }

    func testFilteredRevealRefusesWithoutChangingSelection() async throws {
        let pane = pane()
        let fixture = [row("needle"), row("excluded")]
        pane.installRowsForTesting(fixture)
        var config = DeviceLogPanelConfiguration()
        config.text = "needle"
        _ = try await pane.configurePanel(config)
        for _ in 0..<200 where pane.isProjectingForTesting { try await Task.sleep(for: .milliseconds(5)) }
        do { _ = try await pane.revealPanel(rowID: fixture[1].id); XCTFail("filter must be respected") }
        catch let error as DeviceLogPanelError { XCTAssertEqual(error.code, "row_filtered") }
        XCTAssertTrue(pane.selectedRowIDsForTesting.isEmpty)
        let page = try await pane.readPanel()
        XCTAssertEqual(page.rows.map(\.id), [fixture[0].id])
    }

    func testReconnectReportsGenerationAndRetainedHistoryGap() async throws {
        let pane = pane()
        let source = BufferedDeviceLogSource()
        pane.sourceFactory = { _, _, _ in source }
        pane.startCapture(discover: false)
        defer { pane.stopCapture() }
        source.enqueue([row("retained")]); pane.drain()
        let before = try await pane.readPanel()
        pane.stopCapture()
        pane.startCapture(discover: false)
        let changed = try await pane.waitPanel(cursor: before.cursor, timeout: 0.1)
        XCTAssertTrue(changed.changed)
        XCTAssertEqual(changed.changeReason, "capture_restarted")
        XCTAssertGreaterThan(changed.state.sourceGeneration, before.state.sourceGeneration)
        XCTAssertTrue(changed.state.historyHasGap)
        XCTAssertEqual(changed.state.retainedCount, 1)
        XCTAssertEqual(changed.state.revision, before.state.revision)
    }

    func testBytePressureEvictsRowsAndDisclosesTheBound() {
        let pane = pane()
        let large = String(repeating: "x", count: 1_024 * 1_024)
        pane.installRowsForTesting((0..<100).map { _ in row(large) })
        let state = pane.panelState()
        XCTAssertLessThan(state.retainedCount, 100)
        XCTAssertGreaterThan(state.ringDropped, 0)
        XCTAssertLessThanOrEqual(state.retainedBytes, state.ringByteCapacity)
        XCTAssertEqual(state.ringByteCapacity, 128 * 1_024 * 1_024)
    }

    func testProcessCatalogSelectsExactPIDAndRestoresStableExecutableAfterRestart() async throws {
        let pane = pane()
        let phone = DeviceLogSourceOption.Machine(id: "phone", title: "David's 16 Pro", isSimulator: false)
        func option(_ pid: Int, path: String) -> DeviceLogSourceOption {
            .init(machine: phone, title: "Ananke (PID \(pid))", kind: .device(udid: phone.id, overNetwork: false),
                  processIdentity: .init(name: "Ananke", executablePath: path, pid: pid))
        }
        let a = option(41, path: "/Applications/A/Ananke")
        let b = option(42, path: "/Applications/B/Ananke")
        pane.installSourcesForTesting([a, b])
        let source = BufferedDeviceLogSource()
        var startedPID: Int?
        pane.sourceFactory = { option, _, _ in startedPID = option.processIdentity?.pid; return source }
        pane.startCapture(discover: false)
        defer { pane.stopCapture() }
        var config = DeviceLogPanelConfiguration()
        config.process = "Ananke"
        config.pid = 42
        _ = try await pane.configurePanel(config)
        XCTAssertEqual(startedPID, 42)
        config.pid = 0
        config.source = b.title
        _ = try await pane.configurePanel(config)
        let restarted = option(84, path: "/Applications/B/Ananke")
        pane.acceptSources([a, restarted])
        XCTAssertEqual(pane.panelState().source, restarted.title)
        XCTAssertEqual(pane.panelState().selectedPID, 84)
    }

    func testScopedDescriptorAvailabilityClearsOnReaderRestartAndRetainsDrops() async throws {
        let pane = pane()
        let source = BufferedDeviceLogSource()
        pane.sourceFactory = { _, _, _ in source }
        pane.startCapture(discover: false)
        defer { pane.stopCapture() }
        var config = DeviceLogPanelConfiguration()
        config.bundleID = bundleID
        config.process = "Ananke"
        _ = try await pane.configurePanel(config)
        source.enqueue([.init(time: "", level: "Info", process: "Ananke", subsystem: nil, message: "descriptor",
                              bundleID: bundleID, pid: 42, source: .stdout)])
        pane.drain()
        XCTAssertTrue(pane.panelState().availableSources.contains("stdout"))
        XCTAssertFalse(pane.panelState().unavailableSources.contains("stdout"))
        source.enqueue(Array(repeating: row("overflow"), count: BufferedDeviceLogSource.handoffCapacity + 1))
        pane.drain()
        let dropped = pane.panelState().handoffDropped
        XCTAssertGreaterThan(dropped, 0)
        pane.stopCapture()
        pane.startCapture(discover: false)
        XCTAssertFalse(pane.panelState().availableSources.contains("stdout"))
        XCTAssertTrue(pane.panelState().unavailableSources.contains("stdout"))
        XCTAssertEqual(pane.panelState().handoffDropped, dropped)
        XCTAssertTrue(pane.panelState().historyHasGap)
    }

    func testControllerRecreationRestoresBundleIdentityAfterAppRename() {
        let deviceID = UUID().uuidString
        let phone = DeviceLogSourceOption.Machine(id: deviceID, title: "Fixture phone", isSimulator: false)
        func app(_ name: String, bundle: String) -> DeviceLogSourceOption {
            .init(machine: phone, title: name, kind: .app(deviceID: deviceID, bundleID: bundle, appName: name))
        }
        let first = DeviceLogPaneViewController(owningSessionID: UUID().uuidString, preferredMachineID: deviceID, stream: .regular)
        first.loadView()
        first.sourceFactory = { _, _, _ in BufferedDeviceLogSource() }
        first.installSourcesForTesting([app("First", bundle: "example.a"), app("Old Name", bundle: "example.b")])
        first.startCapture(discover: false)
        first.selectAppForTesting(bundleID: "example.b")
        first.stopCapture()
        let recreated = DeviceLogPaneViewController(owningSessionID: UUID().uuidString, preferredMachineID: deviceID, stream: .regular)
        recreated.loadView()
        recreated.installSourcesForTesting([app("First", bundle: "example.a"), app("New Name", bundle: "example.b")])
        XCTAssertEqual(recreated.panelState().source, "New Name")
    }

    func testQuietSelectedRowsUseTransportEvidenceAndReconnectStartsFresh() async throws {
        let pane = pane()
        let source = BufferedDeviceLogSource()
        pane.sourceFactory = { _, _, _ in source }
        pane.startCapture(discover: false)
        defer { pane.stopCapture() }
        source.markTransportActivity()
        XCTAssertEqual(pane.panelState().captureState, "awaiting_matches")
        source.enqueue([row("live")]); pane.drain()
        XCTAssertEqual(pane.panelState().captureState, "live")
        pane.stopCapture()
        pane.startCapture(discover: false)
        XCTAssertEqual(pane.panelState().captureState, "starting")
        XCTAssertEqual(pane.panelState().retainedCount, 1)
    }

    func testClearFilterChangesTheReadersCaptureLevelAsWellAsTheUI() async throws {
        let pane = pane()
        let source = BufferedDeviceLogSource()
        pane.sourceFactory = { _, _, _ in source }
        pane.startCapture(discover: false)
        defer { pane.stopCapture() }
        XCTAssertEqual(pane.captureSeverityForTesting, 1)
        var config = DeviceLogPanelConfiguration()
        config.clearFilter = true
        let state = try await pane.configurePanel(config)
        XCTAssertEqual(state.filter.minimumSeverity, 0)
        XCTAssertEqual(state.captureMinimumSeverity, 0)
        XCTAssertEqual(pane.captureSeverityForTesting, 0)
        source.enqueue([row("debug now admitted", level: "Debug")]); pane.drain()
        let page = try await pane.readPanel()
        XCTAssertEqual(page.rows.map(\.message), ["debug now admitted"])
    }

    func testContextTailWaitCanBeAheadOfCompletedProjection() async throws {
        let pane = pane()
        let source = BufferedDeviceLogSource()
        pane.sourceFactory = { _, _, _ in source }
        pane.startCapture(discover: false)
        defer { pane.stopCapture() }
        source.enqueue([row("needle")]); pane.drain()
        var config = DeviceLogPanelConfiguration()
        config.text = "needle"
        config.showContext = true
        _ = try await pane.configurePanel(config)
        for _ in 0..<200 where pane.isProjectingForTesting { try await Task.sleep(for: .milliseconds(5)) }
        source.enqueue((0..<10_000).map { row("needle \($0)") }); pane.drain()
        // This internally minted tail cursor can be newer than the visible completed snapshot.
        let page = try await pane.waitPanel(timeout: 0.02)
        XCTAssertTrue(page.rows.isEmpty)
        XCTAssertTrue(page.timedOut || page.pending)
        XCTAssertFalse(page.cursor.isEmpty)
    }

    func testNarrowConsoleKeepsItsMessageColumnVisibleInARealScrollHost() async throws {
        let pane = pane()
        pane.installRowsForTesting([row("AirLab RX ANCS CP")])
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 420, height: 480),
                              styleMask: .borderless, backing: .buffered, defer: false)
        let host = NSView(frame: NSRect(x: 0, y: 0, width: 420, height: 480))
        window.contentView = host
        pane.view.translatesAutoresizingMaskIntoConstraints = false
        host.addSubview(pane.view)
        NSLayoutConstraint.activate([
            pane.view.leadingAnchor.constraint(equalTo: host.leadingAnchor),
            pane.view.trailingAnchor.constraint(equalTo: host.trailingAnchor),
            pane.view.topAnchor.constraint(equalTo: host.topAnchor),
            pane.view.bottomAnchor.constraint(equalTo: host.bottomAnchor),
        ])
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(20))
        host.layoutSubtreeIfNeeded()
        func descendants(_ view: NSView) -> [NSView] { view.subviews.flatMap { [$0] + descendants($0) } }
        let table = try XCTUnwrap(descendants(host).compactMap { $0 as? NSTableView }.first)
        let message = table.column(withIdentifier: NSUserInterfaceItemIdentifier("message"))
        XCTAssertGreaterThanOrEqual(message, 0)
        let messageRect = table.convert(table.rect(ofColumn: message), to: pane.view)
        XCTAssertGreaterThan(messageRect.intersection(pane.view.bounds).width, 180,
                             "pane=\(pane.view.bounds) table=\(table.frame) clip=\(String(describing: table.enclosingScrollView?.contentView.bounds))")
        XCTAssertTrue(table.tableColumn(withIdentifier: NSUserInterfaceItemIdentifier("process"))?.isHidden == true)
    }

}
