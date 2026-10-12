import AppKit
import XCTest
import ThreadingDesignKit
@testable import DeviceLogsPlugin

@MainActor
final class DeviceLogStreamingPerformanceTests: XCTestCase {
    func testVisibleUSBStreamIncludesLayoutAndDisplay() throws {
        guard ProcessInfo.processInfo.environment["THREADING_DEVICE_LOG_RENDER_STRESS"] == "1" else {
            throw XCTSkip("Opt-in onscreen log streaming workload")
        }
        let reader = BufferedDeviceLogSource()
        let pane = DeviceLogPaneViewController(owningSessionID: UUID().uuidString, stream: .regular)
        pane.captureManagedByWorkspace = true
        pane.sourceFactory = { _, _, _ in reader }
        let phone = DeviceLogSourceOption.Machine(id: "stream-stress", title: "Stress iPhone", isSimulator: false)
        _ = pane.view
        pane.acceptSources([.init(machine: phone, title: "System log (USB)", kind: .device(udid: phone.id, overNetwork: false))])
        pane.startCapture(discover: false)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 760),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentViewController = pane
        window.setContentSize(NSSize(width: 1000, height: 760))
        window.orderFront(nil)
        defer { pane.stopCapture(); window.orderOut(nil); window.contentViewController = nil }

        let batch = (0..<1_000).map { index in
            DeviceLogRow(time: "12:34:56.123456", level: "Info", process: "process-\(index % 40)",
                         subsystem: "com.example.usb", message: "event \(index) " + String(repeating: "payload ", count: 128))
        }
        func paint() {
            window.contentView?.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
            CATransaction.flush()
        }
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        paint()
        func descendants(_ view: NSView) -> [NSView] { view.subviews.flatMap { [$0] + descendants($0) } }
        let table = try XCTUnwrap(descendants(pane.view).first { $0 is NSTableView } as? NSTableView)
        XCTAssertGreaterThan(table.visibleRect.height, 300)
        var drains: [Double] = []
        var ticks: [Double] = []
        for iteration in 0..<80 {
            reader.enqueue(batch)
            let start = CFAbsoluteTimeGetCurrent()
            pane.drain()
            let drained = CFAbsoluteTimeGetCurrent()
            paint()
            if iteration >= 50 {
                drains.append((drained - start) * 1000)
                ticks.append((CFAbsoluteTimeGetCurrent() - start) * 1000)
            }
            // Match the production 100 ms cadence. Running faster after the fix otherwise
            // benchmarks compositor/recorder backpressure rather than a phone's live tail.
            let remaining = max(0, 0.1 - (CFAbsoluteTimeGetCurrent() - start))
            RunLoop.main.run(until: Date().addingTimeInterval(remaining))
        }
        drains.sort(); ticks.sort()
        XCTAssertEqual(pane.focusSummary.total, DeviceLogLimits.ringCapacity)
        let visible = table.rows(in: table.visibleRect)
        XCTAssertGreaterThan(visible.length, 20)
        XCTAssertNotNil(table.view(atColumn: 0, row: visible.location, makeIfNecessary: false))
        XCTAssertEqual(NSMaxRange(visible), table.numberOfRows, "A rolling ring must keep following the tail")
        XCTAssertLessThan(ticks[ticks.count / 2], 60, "Visible streaming must not rebuild the table every tick")
        let liveCells = descendants(table).filter { $0 is ThemedTableTextCell }.count
        XCTAssertLessThan(liveCells, 500, "Cell residency must stay proportional to the viewport")
        print("USB_VISIBLE_STRESS table=\(table.frame) visible=\(visible) last=\(table.numberOfRows - 1) cells=\(liveCells)")
        print("USB_VISIBLE_STRESS drain median=\(drains[drains.count / 2])ms max=\(drains.last!)ms; drain+layout+display median=\(ticks[ticks.count / 2])ms max=\(ticks.last!)ms")
    }
}

@MainActor
final class DeviceLogStreamingTests: XCTestCase {
    private func withPane(_ body: @MainActor (DeviceLogPaneViewController, BufferedDeviceLogSource, NSTableView) async throws -> Void) async throws {
        let reader = BufferedDeviceLogSource()
        let pane = DeviceLogPaneViewController(owningSessionID: UUID().uuidString, stream: .regular)
        pane.captureManagedByWorkspace = true
        pane.sourceFactory = { _, _, _ in reader }
        _ = pane.view
        let phone = DeviceLogSourceOption.Machine(id: "stream-fixture", title: "Test iPhone", isSimulator: false)
        pane.acceptSources([.init(machine: phone, title: "System log (USB)", kind: .device(udid: phone.id, overNetwork: false))])
        pane.startCapture(discover: false)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 760),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentViewController = pane
        window.setContentSize(NSSize(width: 1000, height: 760))
        defer { pane.stopCapture(); window.contentViewController = nil }
        window.contentView?.layoutSubtreeIfNeeded()
        func descendants(_ view: NSView) -> [NSView] { view.subviews.flatMap { [$0] + descendants($0) } }
        let table = try XCTUnwrap(descendants(pane.view).first { $0 is NSTableView } as? NSTableView)
        pane.installRowsForTesting((0..<DeviceLogLimits.ringCapacity).map { row("line \($0)") })
        table.scrollRowToVisible(table.numberOfRows - 1)
        window.contentView?.layoutSubtreeIfNeeded()
        try await body(pane, reader, table)
    }

    private func row(_ message: String) -> DeviceLogRow {
        .init(time: "12:34:56", level: "Info", process: "Test", subsystem: nil, message: message)
    }

    func testFullRingUpdatesTheTailWithoutReplacingItsCellOrLabel() async throws {
        try await withPane { pane, reader, table in
            let last = table.numberOfRows - 1
            let cell = try XCTUnwrap(table.view(atColumn: 4, row: last, makeIfNecessary: true) as? ThemedTableTextCell)
            let label = cell.label
            table.selectRowIndexes(IndexSet(integer: last), byExtendingSelection: false)
            reader.enqueue([row("new tail")])
            pane.drain()
            table.layoutSubtreeIfNeeded()
            XCTAssertTrue(table.view(atColumn: 4, row: last, makeIfNecessary: false) === cell)
            XCTAssertTrue(cell.label === label)
            XCTAssertEqual(label.stringValue, "new tail")
            XCTAssertEqual(table.selectedRow, last - 1, "Selection follows the line, not its old row number")
            XCTAssertEqual(NSMaxRange(table.rows(in: table.visibleRect)), table.numberOfRows)
        }
    }

    func testPausedViewportAndSelectionStayOnTheSameLinesWhenTheRingTrims() async throws {
        try await withPane { pane, reader, table in
            table.scrollRowToVisible(25_000)
            table.layoutSubtreeIfNeeded()
            let first = table.rows(in: table.visibleRect).location
            let before = try XCTUnwrap(table.view(atColumn: 4, row: first, makeIfNecessary: true) as? ThemedTableTextCell).label.stringValue
            table.selectRowIndexes(IndexSet(integer: first + 3), byExtendingSelection: false)
            reader.enqueue((0..<300).map { row("new \($0)") })
            pane.drain()
            table.layoutSubtreeIfNeeded()
            let after = table.rows(in: table.visibleRect).location
            XCTAssertEqual(after, first - 300)
            XCTAssertEqual(table.selectedRow, first + 3 - 300)
            XCTAssertEqual(try XCTUnwrap(table.view(atColumn: 4, row: after, makeIfNecessary: true) as? ThemedTableTextCell).label.stringValue, before)
        }
    }

    func testContextProjectionKeepsItsSnapshotAndSelectedLineWhileCaptureRolls() async throws {
        try await withPane { pane, reader, table in
            pane.applyFocus(pattern: "line 499", minimumSeverity: 0)
            table.scrollRowToVisible(table.numberOfRows - 1)
            table.selectRowIndexes(IndexSet(integer: table.numberOfRows - 1), byExtendingSelection: false)
            let before = pane.visibleRowsForTools(limit: 200).map(\.message)
            reader.enqueue((0..<300).map { row("new \($0)") })
            pane.drain()
            XCTAssertTrue(pane.isProjectingForTesting)
            XCTAssertEqual(pane.visibleRowsForTools(limit: 200).map(\.message), before,
                           "Displayed entries must still address their original snapshot during a background scan")
            for _ in 0..<200 where pane.isProjectingForTesting { try await Task.sleep(nanoseconds: 10_000_000) }
            XCTAssertFalse(pane.isProjectingForTesting)
            XCTAssertEqual(pane.visibleRowsForTools(limit: 200).last?.message, "new 1", "The match keeps exactly two context lines")
            let selected = try XCTUnwrap(table.view(atColumn: 4, row: table.selectedRow, makeIfNecessary: true) as? ThemedTableTextCell)
            XCTAssertEqual(selected.label.stringValue, "line 49999")
        }
    }

    func testLargeFilteredBurstProjectsOffMainWithoutRepointingExistingRows() async throws {
        try await withPane { pane, reader, _ in
            pane.simulateUserFilterEditForTesting("line 499")
            for _ in 0..<200 where pane.isProjectingForTesting { try await Task.sleep(nanoseconds: 10_000_000) }
            XCTAssertFalse(pane.isProjectingForTesting)
            let before = pane.visibleRowsForTools(limit: 200).map(\.message)
            reader.enqueue((0..<5_000).map { row("new \($0) " + String(repeating: "payload ", count: 128)) })
            pane.drain()
            XCTAssertTrue(pane.isProjectingForTesting, "A backlog must not put thousands of text scans on the main actor")
            XCTAssertEqual(pane.visibleRowsForTools(limit: 200).map(\.message), before)
            for _ in 0..<400 where pane.isProjectingForTesting { try await Task.sleep(nanoseconds: 10_000_000) }
            XCTAssertFalse(pane.isProjectingForTesting)
            XCTAssertEqual(pane.visibleRowsForTools(limit: 200).last?.message, "line 49999")
        }
    }

    func testReturningFromTheOtherLogTabKeepsTheSelectedLineAfterCaptureRolls() async throws {
        try await withPane { pane, reader, table in
            table.selectRowIndexes(IndexSet(integer: table.numberOfRows - 1), byExtendingSelection: false)
            pane.setRowsPresented(false)
            let updates = pane.presentationUpdateCount
            reader.enqueue((0..<300).map { row("new \($0)") })
            pane.drain()
            XCTAssertEqual(pane.presentationUpdateCount, updates)
            XCTAssertFalse(pane.isProjectingForTesting)
            pane.setRowsPresented(true)
            XCTAssertEqual(pane.visibleRowsForTools(limit: 1).last?.message, "line 49999")
            for _ in 0..<200 where pane.isProjectingForTesting { try await Task.sleep(nanoseconds: 10_000_000) }
            XCTAssertFalse(pane.isProjectingForTesting)
            let selected = try XCTUnwrap(table.view(atColumn: 4, row: table.selectedRow, makeIfNecessary: true) as? ThemedTableTextCell)
            XCTAssertEqual(selected.label.stringValue, "line 49999")
            XCTAssertEqual(pane.visibleRowsForTools(limit: 1).last?.message, "new 299")
        }
    }
}
