import XCTest
import SwiftTerm
@testable import Threading

/// Reading a terminal's recent text must cost what arrived, not what the session has ever printed.
///
/// The attachment observer polls a live terminal every couple of seconds. Its only bound was a
/// 256 KB cap on the *returned* text, which cannot bound the *read*: a blank row costs one
/// separator byte, and real scrollback is mostly blank and short rows, so the budget was never
/// spent and the walk reached row zero every time. A day-old window with 24 sessions was
/// translating its entire scrollback to strings about six times a second on the thread that draws,
/// to hand back a few tens of kilobytes it had already seen.
///
/// The rows above the screen cannot change, so re-reading them buys nothing. These pin that the
/// window is bounded by new output, and that the two things which *can* still change — the screen
/// itself, and a buffer that was reset underneath the cursor — are not skipped with it.
final class TerminalIncrementalScanTests: XCTestCase {

    // MARK: - Harness

    private final class Silent: TerminalDelegate {
        func send(source: Terminal, data: ArraySlice<UInt8>) {}
    }

    private var delegate = Silent()
    private let budget = 256 * 1024

    private func makeTerminal(cols: Int = 40, rows: Int = 5) -> Terminal {
        delegate = Silent()
        return Terminal(
            delegate: delegate,
            options: TerminalOptions(cols: cols, rows: rows, scrollback: 2_000)
        )
    }

    private func feedLines(_ terminal: Terminal, _ range: ClosedRange<Int>) {
        for index in range {
            terminal.feed(text: "line-\(index)\r\n")
        }
    }

    // MARK: - Reading only what arrived

    func testAReadWithNoCursorReturnsTheWholeBoundedWindow() {
        let terminal = makeTerminal()
        feedLines(terminal, 1...300)

        let read = terminal.getRecentLogicalBufferText(
            maximumUTF8Bytes: budget,
            sinceAbsoluteRow: 0
        )

        XCTAssertTrue(read.text.contains("line-1\n"), "the oldest retained row is still included")
        XCTAssertTrue(read.text.contains("line-300"), "the newest row is included")
        XCTAssertEqual(
            read.text,
            terminal.getRecentLogicalBufferText(maximumUTF8Bytes: budget),
            "the cursorless form is the unchanged whole-window read"
        )
    }

    func testReadingAgainSkipsTheScrollbackAlreadyRead() {
        let terminal = makeTerminal()
        feedLines(terminal, 1...300)
        let first = terminal.getRecentLogicalBufferText(maximumUTF8Bytes: budget, sinceAbsoluteRow: 0)
        XCTAssertTrue(first.text.contains("line-100"))

        feedLines(terminal, 301...301)
        let second = terminal.getRecentLogicalBufferText(
            maximumUTF8Bytes: budget,
            sinceAbsoluteRow: first.nextAbsoluteRow
        )

        XCTAssertTrue(second.text.contains("line-301"), "new output is read")
        XCTAssertFalse(
            second.text.contains("line-100"),
            "scrollback that was already read is not translated again"
        )
        XCTAssertLessThanOrEqual(
            second.text.split(separator: "\n", omittingEmptySubsequences: false).count,
            8,
            "the second read is bounded by the screen plus what arrived, not by scrollback depth"
        )
    }

    /// A full-screen agent TUI repaints rows in place without scrolling, so the screen is the one
    /// region that can change without producing a new row. Skipping it would make the incremental
    /// read faster and wrong.
    func testTheCurrentScreenIsAlwaysReadAgain() {
        let terminal = makeTerminal()
        feedLines(terminal, 1...300)
        let first = terminal.getRecentLogicalBufferText(maximumUTF8Bytes: budget, sinceAbsoluteRow: 0)

        // Repaint the top of the screen in place: home the cursor, overwrite, no new rows.
        terminal.feed(text: "\u{1b}[H/tmp/painted-in-place.png")
        let second = terminal.getRecentLogicalBufferText(
            maximumUTF8Bytes: budget,
            sinceAbsoluteRow: first.nextAbsoluteRow
        )

        XCTAssertTrue(
            second.text.contains("/tmp/painted-in-place.png"),
            "a path repainted onto the existing screen is still seen"
        )
    }

    func testACursorPastTheBufferReadsTheWholeWindowAgain() {
        let terminal = makeTerminal()
        feedLines(terminal, 1...300)

        // What a caller holds after the buffer is cleared or switched underneath it.
        let read = terminal.getRecentLogicalBufferText(
            maximumUTF8Bytes: budget,
            sinceAbsoluteRow: 10_000_000
        )

        XCTAssertTrue(
            read.text.contains("line-1\n"),
            "a stale cursor falls back to the whole window rather than reading nothing"
        )
    }

    func testTheCursorAdvancesWithProducedRows() {
        let terminal = makeTerminal()
        feedLines(terminal, 1...10)
        let first = terminal.getRecentLogicalBufferText(maximumUTF8Bytes: budget, sinceAbsoluteRow: 0)

        feedLines(terminal, 11...13)
        let second = terminal.getRecentLogicalBufferText(
            maximumUTF8Bytes: budget,
            sinceAbsoluteRow: first.nextAbsoluteRow
        )

        XCTAssertEqual(
            second.nextAbsoluteRow - first.nextAbsoluteRow,
            3,
            "three printed lines advance the cursor by three rows"
        )
    }

    @MainActor
    func testTheViewReaderCanTranslateOnAWorker() async {
        let view = TerminalView(frame: .zero)
        view.feed(text: "wrote /tmp/worker-read.png\r\n")
        let read = view.recentLogicalBufferReader(maximumUTF8Bytes: budget)

        let result = await Task.detached { read(0) }.value

        XCTAssertTrue(result.text.contains("/tmp/worker-read.png"))
        XCTAssertEqual(
            result,
            view.recentLogicalBufferText(maximumUTF8Bytes: budget),
            "the worker reader must use the same synchronized terminal state as the view API"
        )
    }

    // MARK: - Stress

    /// The read the attachment stress target never covered.
    ///
    /// `SessionAttachmentStoreTests.testStressAttachmentScanWhenEnabled` hands the detector a
    /// ready-made `String`, so every measurement of this feature began *after* the expensive part
    /// and the whole-scrollback walk was invisible to it. This sweeps the read itself across
    /// scrollback depths, with the sparse, mostly-blank rows a real agent session leaves behind.
    func testStressTerminalBufferReadWhenEnabled() throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["THREADING_TERMINAL_READ_STRESS"] == "1",
            "Set THREADING_TERMINAL_READ_STRESS=1 to run the terminal buffer-read sweep."
        )

        let depth = ProcessInfo.processInfo.environment["THREADING_TERMINAL_READ_STRESS_ROWS"]
            .flatMap(Int.init)
            .flatMap { $0 > 0 ? $0 : nil }
            ?? 3_500
        let repeats = 20

        let terminal = Terminal(
            delegate: delegate,
            options: TerminalOptions(cols: 120, rows: 50, scrollback: depth + 200)
        )
        // What a Claude Code session actually leaves in scrollback: mostly blank and short rows,
        // an occasional path. Blank rows are the whole problem, because they cost one byte of the
        // budget and a full row of translation.
        for index in 1...depth {
            switch index % 7 {
            case 0: terminal.feed(text: "\r\n")
            case 3: terminal.feed(text: "  · wrote /tmp/artifact-\(index).png\r\n")
            default: terminal.feed(text: "  step \(index) ok\r\n")
            }
        }

        func median(_ values: [UInt64]) -> UInt64 {
            let sorted = values.sorted()
            return sorted[sorted.count / 2]
        }

        var wholeWindow: [UInt64] = []
        var incremental: [UInt64] = []
        var bytesWhole = 0
        var bytesIncremental = 0
        var cursor = 0

        for _ in 0..<repeats {
            let started = DispatchTime.now().uptimeNanoseconds
            let full = terminal.getRecentLogicalBufferText(
                maximumUTF8Bytes: SessionAttachmentDefaults.maximumTerminalScanBytes,
                sinceAbsoluteRow: 0
            )
            wholeWindow.append(DispatchTime.now().uptimeNanoseconds - started)
            bytesWhole = full.text.utf8.count

            // One repaint's worth of new output, then the read a polling observer now makes.
            terminal.feed(text: "  · wrote /tmp/fresh.png\r\n")
            let incrementalStarted = DispatchTime.now().uptimeNanoseconds
            let next = terminal.getRecentLogicalBufferText(
                maximumUTF8Bytes: SessionAttachmentDefaults.maximumTerminalScanBytes,
                sinceAbsoluteRow: cursor == 0 ? full.nextAbsoluteRow : cursor
            )
            incremental.append(DispatchTime.now().uptimeNanoseconds - incrementalStarted)
            bytesIncremental = next.text.utf8.count
            cursor = next.nextAbsoluteRow
        }

        let whole = median(wholeWindow)
        let partial = median(incremental)
        print(
            "THREADING_PERF terminal-buffer-read "
                + "scrollback_rows=\(depth) repeats=\(repeats) "
                + "whole_window_ms=\(Self.milliseconds(whole)) "
                + "incremental_ms=\(Self.milliseconds(partial)) "
                + "whole_window_kb=\(bytesWhole / 1024) "
                + "incremental_kb=\(bytesIncremental / 1024) "
                + "speedup=\(String(format: "%.1fx", Double(whole) / Double(max(partial, 1))))"
        )

        XCTAssertLessThan(
            partial,
            whole,
            "an incremental read of one repaint must cost less than the whole window"
        )
    }

    private static func milliseconds(_ nanoseconds: UInt64) -> String {
        String(format: "%.3f", Double(nanoseconds) / 1_000_000)
    }

    // MARK: - The observer's half of the contract

    private final class CursorProbe: @unchecked Sendable {
        private let lock = NSLock()
        private var seen: [Int] = []
        private var mainThreadReads: [Bool] = []
        private let pauseFirstRead: Bool
        private let firstReadGate = DispatchSemaphore(value: 0)

        init(pauseFirstRead: Bool = false) {
            self.pauseFirstRead = pauseFirstRead
        }

        var reads: [Int] { lock.withLock { seen } }
        var readWasOnMainThread: [Bool] { lock.withLock { mainThreadReads } }

        func read(since: Int) -> TerminalScanRead {
            let isFirst = lock.withLock {
                seen.append(since)
                mainThreadReads.append(Thread.isMainThread)
                return seen.count == 1
            }
            if pauseFirstRead && isFirst { firstReadGate.wait() }
            return TerminalScanRead(text: "", nextAbsoluteRow: since + 7)
        }

        func releaseFirstRead() { firstReadGate.signal() }
    }

    @MainActor
    private final class AdmissionGate {
        private(set) var entered = false
        private var continuation: CheckedContinuation<Void, Never>?

        func hold() async {
            entered = true
            await withCheckedContinuation { continuation = $0 }
        }

        func release() {
            continuation?.resume()
            continuation = nil
        }
    }

    @MainActor
    private func makeObserver(
        enabled: @escaping () -> Bool,
        probe: CursorProbe
    ) -> TerminalAttachmentObserver {
        let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        return TerminalAttachmentObserver(
            sessionID: SessionID(),
            projectRoot: { root },
            currentDirectory: { root },
            text: { since in probe.read(since: since) },
            isEnabled: enabled,
            record: { _, _, _, _ in .empty }
        )
    }

    /// Waits for the detached resolution to return to the main actor, which is when a scan's
    /// result is either applied or dropped.
    @MainActor
    private func settle(_ observer: TerminalAttachmentObserver) async {
        let deadline = Date().addingTimeInterval(5)
        while observer.isScanInFlight, Date() < deadline {
            try? await Task.sleep(nanoseconds: 2_000_000)
        }
    }

    @MainActor
    func testTheObserverFeedsItsCursorBackToTheTerminal() async {
        let probe = CursorProbe()
        let observer = makeObserver(enabled: { true }, probe: probe)

        observer.scanNow()
        await settle(observer)
        observer.scanNow()
        await settle(observer)
        observer.scanNow()
        await settle(observer)

        XCTAssertEqual(
            probe.reads,
            [0, 7, 14],
            "each applied scan resumes from where the previous read stopped"
        )
        XCTAssertEqual(
            probe.readWasOnMainThread,
            [false, false, false],
            "translating terminal rows must not block the main thread"
        )
    }

    /// The cursor is the only thing standing between "read once" and "never read". A scan that
    /// loses a race to a newer generation is dropped, so the rows it read must still be waiting
    /// for the scan that replaces it.
    @MainActor
    func testAScanThatIsSupersededDoesNotCarryItsRowsAway() async {
        let probe = CursorProbe(pauseFirstRead: true)
        let observer = makeObserver(enabled: { true }, probe: probe)

        observer.scanNow()
        let deadline = Date().addingTimeInterval(2)
        while probe.reads.isEmpty, Date() < deadline {
            try? await Task.sleep(nanoseconds: 2_000_000)
        }
        XCTAssertEqual(probe.reads, [0], "the first read must be in flight before it is replaced")
        observer.scanNow()
        probe.releaseFirstRead()
        await settle(observer)

        XCTAssertEqual(
            probe.reads,
            [0, 0],
            "the superseded scan's rows are read again rather than skipped"
        )
        XCTAssertEqual(observer.lastScanMetrics?.wasUnchanged, false)
    }

    @MainActor
    func testSupersedingAdmissionRetainsTheUnreadCursorAndFingerprint() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("attachment-admission-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("artifact.png")
        try Data("png".utf8).write(to: file)

        let buffer = TerminalScanTextBuffer(text: "wrote \(file.path)", nextAbsoluteRow: 7)
        let gate = AdmissionGate()
        var admissions = 0
        let observer = TerminalAttachmentObserver(
            sessionID: SessionID(),
            projectRoot: { root },
            currentDirectory: { root },
            text: { since in buffer.read(since: since) },
            record: { _, _, _, _ in
                admissions += 1
                if admissions == 1 { await gate.hold() }
                return .empty
            }
        )

        observer.scanNow()
        let deadline = Date().addingTimeInterval(5)
        while !gate.entered, Date() < deadline {
            try? await Task.sleep(nanoseconds: 2_000_000)
        }
        XCTAssertTrue(gate.entered, "the first scan must reach admission before replacement")
        observer.scanNow()
        gate.release()
        await settle(observer)

        XCTAssertEqual(buffer.reads, [0, 0], "the replacement must reread the uncommitted rows")
        XCTAssertEqual(admissions, 2, "the replacement must resolve the same path again")
        XCTAssertEqual(observer.lastScanMetrics?.wasUnchanged, false)
    }

    @MainActor
    func testTurningDetectionOffForgetsTheCursor() async {
        var enabled = true
        let probe = CursorProbe()
        let observer = makeObserver(enabled: { enabled }, probe: probe)

        observer.scanNow()
        await settle(observer)
        enabled = false
        observer.scanNow()
        await settle(observer)
        enabled = true
        observer.scanNow()
        await settle(observer)

        XCTAssertEqual(
            probe.reads,
            [0, 0],
            "a disabled observer reads nothing, and the next enabled scan starts from the whole window"
        )
    }
}
