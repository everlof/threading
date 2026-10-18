import AppKit
import Darwin
import XCTest
import ThreadingDesignKit
@testable import DeviceLogsPlugin

/// Replays a captured `pymobiledevice3 syslog live --format json` stream through each stage the
/// pane runs, and reports CPU time as a share of the capture's own wall time.
///
/// A real capture rather than generated rows, because the cost lives in the shape: a phone's mix of
/// levels, message lengths, labels and timestamps. Capture one with
/// `PYMOBILEDEVICE3_UDID=<udid> pymobiledevice3 --no-color syslog live --native --format json > f`,
/// then `THREADING_DEVICE_LOG_REPLAY=f swift test --package-path Plugins/DeviceLogsPlugin
/// --filter DeviceLogReplayCostTests`. The capture holds a device's real log and stays local.
@MainActor
final class DeviceLogReplayCostTests: XCTestCase {
    private func capture() throws -> (lines: [ArraySlice<UInt8>], seconds: Double) {
        guard let path = ProcessInfo.processInfo.environment["THREADING_DEVICE_LOG_REPLAY"] else {
            throw XCTSkip("Opt-in replay of a captured device log stream")
        }
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        let all = [UInt8](data).split(separator: 0x0A)
        let decoded = all.compactMap { DeviceLogDecoding.pymobiledevice3($0) }.compactMap(\.timestamp)
        let seconds = try XCTUnwrap(decoded.max()).timeIntervalSince(try XCTUnwrap(decoded.min()))
        // What a reader asked for a level would have delivered over the same wall time.
        let level = Int(ProcessInfo.processInfo.environment["THREADING_DEVICE_LOG_REPLAY_CAPTURE_SEVERITY"] ?? "") ?? 0
        let lines = all.filter { (DeviceLogDecoding.pymobiledevice3($0)?.severity ?? 0) >= level }
        print("DEVICE_LOG_REPLAY capture severity >= \(level): \(lines.count) of \(all.count) rows")
        return (lines, seconds)
    }

    private static func threadCPU() -> Double { Double(clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID)) / 1e9 }

    private static func processCPU() -> Double {
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        func seconds(_ value: timeval) -> Double { Double(value.tv_sec) + Double(value.tv_usec) / 1e6 }
        return seconds(usage.ru_utime) + seconds(usage.ru_stime)
    }

    private static func report(_ stage: String, cpu: Double, over seconds: Double) {
        print(String(format: "DEVICE_LOG_REPLAY %@ cpu=%.3fs share=%.1f%% of one core", stage, cpu, cpu / seconds * 100))
    }

    func testStageCosts() throws {
        let (lines, seconds) = try capture()
        print("DEVICE_LOG_REPLAY rows=\(lines.count) seconds=\(seconds) rate=\(Int(Double(lines.count) / seconds))/s")

        var start = Self.threadCPU()
        let rows = lines.compactMap { DeviceLogDecoding.pymobiledevice3($0) }
        Self.report("decode", cpu: Self.threadCPU() - start, over: seconds)

        let stamps = rows.map { $0.time }
        start = Self.threadCPU()
        var parsed = 0
        for line in lines {
            guard let object = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any] else { continue }
            if object["timestamp"] is String { parsed += 1 }
        }
        Self.report("decode.json-only", cpu: Self.threadCPU() - start, over: seconds)
        start = Self.threadCPU()
        for line in lines {
            guard let object = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
                  let raw = object["timestamp"] as? String else { continue }
            _ = DeviceLogDecoding.instant(in: raw)
        }
        Self.report("decode.json+instant", cpu: Self.threadCPU() - start, over: seconds)
        XCTAssertEqual(stamps.count, rows.count)

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("DeviceLogReplay-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try DeviceLogStore(url: directory.appendingPathComponent("replay.sqlite"))
        let perTick = max(1, Int(Double(rows.count) / seconds / 10))
        start = Self.threadCPU()
        for batch in stride(from: 0, to: rows.count, by: perTick) {
            _ = try store.append(Array(rows[batch..<min(rows.count, batch + perTick)]))
        }
        Self.report("record", cpu: Self.threadCPU() - start, over: seconds)
        XCTAssertEqual(try store.count(), rows.count)
    }

    /// The pane as it ships: onscreen, following, Info and above, draining every 100 ms.
    func testVisiblePaneCost() throws { try measurePane(paused: false) }

    /// The same stream while the reader has scrolled up to read. Nothing they see changes.
    func testPausedPaneCost() throws { try measurePane(paused: true) }

    private func measurePane(paused: Bool) throws {
        let (lines, seconds) = try capture()
        let rows = lines.compactMap { DeviceLogDecoding.pymobiledevice3($0) }
        let perTick = max(1, Int(Double(rows.count) / seconds / 10))

        let reader = BufferedDeviceLogSource()
        let pane = DeviceLogPaneViewController(owningSessionID: UUID().uuidString, stream: .regular)
        pane.captureManagedByWorkspace = true
        pane.sourceFactory = { _, _, _ in reader }
        let phone = DeviceLogSourceOption.Machine(id: "replay", title: "Replay iPhone", isSimulator: false)
        _ = pane.view
        pane.acceptSources([.init(machine: phone, title: "System log (USB)", kind: .device(udid: phone.id, overNetwork: false))])
        pane.startCapture(discover: false)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1400, height: 1000),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentViewController = pane
        window.setContentSize(NSSize(width: 1400, height: 1000))
        window.orderFront(nil)
        defer { pane.stopCapture(); window.orderOut(nil); window.contentViewController = nil }

        // Fill the ring first so the measured ticks run at the steady state a user sees.
        var cursor = 0
        while pane.focusSummary.total < DeviceLogLimits.ringCapacity {
            reader.enqueue(Array(rows[cursor..<min(rows.count, cursor + perTick * 10)]))
            pane.drain()
            cursor = (cursor + perTick * 10) % max(1, rows.count - perTick * 10)
        }
        func descendants(_ view: NSView) -> [NSView] { view.subviews.flatMap { [$0] + descendants($0) } }
        let table = try XCTUnwrap(descendants(pane.view).first { $0 is NSTableView } as? NSTableView)
        // The fill's large batches project on a worker, and the recorder is still writing them;
        // both land before measuring, or the first test run pays for the fill.
        let recorded = expectation(description: "recorder caught up")
        pane.recorder?.read({ _ in }) { _ in recorded.fulfill() }
        wait(for: [recorded], timeout: 120)
        RunLoop.main.run(until: Date().addingTimeInterval(1))
        if paused {
            // A few screens above the tail, so 100 ticks of head trimming never reach the lines
            // being read: those are evicted only when the ring turns over.
            table.scrollRowToVisible(table.numberOfRows - 300)
            RunLoop.main.run(until: Date().addingTimeInterval(0.2))
            XCTAssertLessThan(NSMaxRange(table.rows(in: table.visibleRect)), table.numberOfRows - 200)
        }
        func firstVisibleMessage() -> String? {
            let first = table.rows(in: table.visibleRect).location
            return (table.view(atColumn: 4, row: first, makeIfNecessary: false) as? ThemedTableTextCell)?.label.stringValue
        }
        let readingBefore = firstVisibleMessage()
        var seenCells = Set(descendants(table).compactMap { $0 as? ThemedTableTextCell }.map(ObjectIdentifier.init))
        var createdCells = 0
        var countChanges = 0
        var diagnosticsCPU = 0.0

        let ticks = Int(ProcessInfo.processInfo.environment["THREADING_DEVICE_LOG_REPLAY_TICKS"] ?? "") ?? 100
        var mainCPU = 0.0
        let processStart = Self.processCPU()
        let mainStart = Self.threadCPU()
        for _ in 0..<ticks {
            let tickStart = CFAbsoluteTimeGetCurrent()
            reader.enqueue(Array(rows[cursor..<min(rows.count, cursor + perTick)]))
            cursor = (cursor + perTick) % max(1, rows.count - perTick)
            // The production timer drains; the run loop then lays out, displays and commits.
            let before = Self.threadCPU()
            let countBefore = table.numberOfRows
            pane.drain()
            mainCPU += Self.threadCPU() - before
            RunLoop.main.run(until: Date(timeIntervalSinceReferenceDate: tickStart + 0.1))
            let diagnosticsStart = Self.threadCPU()
            if table.numberOfRows != countBefore { countChanges += 1 }
            for cell in descendants(table) where cell is ThemedTableTextCell {
                if seenCells.insert(ObjectIdentifier(cell)).inserted { createdCells += 1 }
            }
            diagnosticsCPU += Self.threadCPU() - diagnosticsStart
        }
        if paused {
            XCTAssertEqual(firstVisibleMessage(), readingBefore, "A paused reader keeps the same lines on screen")
            XCTAssertEqual(createdCells, 0, "Nothing a paused reader can see is rebuilt")
            XCTAssertLessThan(NSMaxRange(table.rows(in: table.visibleRect)), table.numberOfRows - 100)
        } else {
            XCTAssertEqual(NSMaxRange(table.rows(in: table.visibleRect)), table.numberOfRows)
        }
        let wall = Double(ticks) * 0.1
        let process = Self.processCPU() - processStart
        let mainTotal = Self.threadCPU() - mainStart - diagnosticsCPU
        print("DEVICE_LOG_REPLAY \(paused ? "paused" : "following") ticks=\(ticks) rowCountChanged=\(countChanges) newCells=\(createdCells) visibleRows=\(table.rows(in: table.visibleRect).length)")
        Self.report("pane.drain(main)", cpu: mainCPU, over: wall)
        Self.report("pane.main-thread(total)", cpu: mainTotal, over: wall)
        Self.report("pane.other-threads", cpu: process - mainTotal, over: wall)
        Self.report("pane.process(total)", cpu: process, over: wall)
    }
}
