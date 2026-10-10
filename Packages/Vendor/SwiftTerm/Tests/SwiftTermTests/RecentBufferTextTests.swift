#if os(macOS)
import Foundation
import XCTest

@testable import SwiftTerm

final class RecentBufferTextTests: XCTestCase {
    private let queue = DispatchQueue(label: "SwiftTerm.RecentBufferTextTests")

    private func terminal(
        cols: Int = 80,
        rows: Int = 24,
        scrollback: Int = 100
    ) -> Terminal {
        HeadlessTerminal(
            queue: queue,
            options: TerminalOptions(cols: cols, rows: rows, scrollback: scrollback)
        ) { _ in }.terminal
    }

    private func feedLines(_ terminal: Terminal, _ range: ClosedRange<Int>) {
        for index in range {
            terminal.feed(text: "line-\(index)\r\n")
        }
    }

    func testJoinsSoftWrapsAndPreservesHardBreaks() {
        let terminal = terminal(cols: 12, rows: 8)
        let path = "/tmp/a-very-long-render-name.png"
        terminal.feed(text: path + "\r\nnext")

        let text = terminal.getRecentLogicalBufferText(maximumUTF8Bytes: 4_096)

        XCTAssertTrue(text.contains(path))
        XCTAssertTrue(text.contains("\nnext"))
    }

    func testOmitsAnOversizedPartialLogicalLine() {
        let terminal = terminal(cols: 8, rows: 6)
        terminal.feed(text: "/tmp/this-logical-line-is-larger-than-the-budget.png")

        let text = terminal.getRecentLogicalBufferText(maximumUTF8Bytes: 16)

        XCTAssertLessThanOrEqual(text.utf8.count, 16)
        XCTAssertFalse(text.contains(".png"))
        XCTAssertFalse(text.contains("budget"))
    }

    func testIncrementalReadSkipsStableScrollback() {
        let terminal = terminal(cols: 40, rows: 5, scrollback: 2_000)
        feedLines(terminal, 1...300)
        let first = terminal.getRecentLogicalBufferText(
            maximumUTF8Bytes: 256 * 1024,
            sinceAbsoluteRow: 0)

        feedLines(terminal, 301...301)
        let second = terminal.getRecentLogicalBufferText(
            maximumUTF8Bytes: 256 * 1024,
            sinceAbsoluteRow: first.nextAbsoluteRow)

        XCTAssertTrue(second.text.contains("line-301"))
        XCTAssertFalse(second.text.contains("line-100"))
        XCTAssertLessThanOrEqual(
            second.text.split(separator: "\n", omittingEmptySubsequences: false).count,
            8)
    }

    func testIncrementalReadAlwaysIncludesCurrentScreen() {
        let terminal = terminal(cols: 40, rows: 5, scrollback: 2_000)
        feedLines(terminal, 1...300)
        let first = terminal.getRecentLogicalBufferText(
            maximumUTF8Bytes: 256 * 1024,
            sinceAbsoluteRow: 0)

        terminal.feed(text: "\u{1b}[H/tmp/painted-in-place.png")
        let second = terminal.getRecentLogicalBufferText(
            maximumUTF8Bytes: 256 * 1024,
            sinceAbsoluteRow: first.nextAbsoluteRow)

        XCTAssertTrue(second.text.contains("/tmp/painted-in-place.png"))
    }

    func testCursorPastCurrentBufferReadsTheRetainedWindow() {
        let terminal = terminal(cols: 40, rows: 5, scrollback: 2_000)
        feedLines(terminal, 1...300)

        let read = terminal.getRecentLogicalBufferText(
            maximumUTF8Bytes: 256 * 1024,
            sinceAbsoluteRow: 10_000_000)

        XCTAssertTrue(read.text.contains("line-1\n"))
    }

    func testCursorAdvancesByProducedRows() {
        let terminal = terminal(cols: 40, rows: 5, scrollback: 2_000)
        feedLines(terminal, 1...10)
        let first = terminal.getRecentLogicalBufferText(
            maximumUTF8Bytes: 256 * 1024,
            sinceAbsoluteRow: 0)

        feedLines(terminal, 11...13)
        let second = terminal.getRecentLogicalBufferText(
            maximumUTF8Bytes: 256 * 1024,
            sinceAbsoluteRow: first.nextAbsoluteRow)

        XCTAssertEqual(second.nextAbsoluteRow - first.nextAbsoluteRow, 3)
    }

    func testSnapshotPreservesTextAcrossMutationAndArenaReplacement() {
        let terminal = terminal(cols: 24, rows: 10)
        terminal.feed(text: "e\u{301} 👩🏽‍💻 中 /tmp/wrapped-image.png\r\n\u{1b}[44mcolored\u{1b}[0m")
        let expected = terminal.getRecentLogicalBufferText(maximumUTF8Bytes: 4_096, sinceAbsoluteRow: 0)
        let snapshot = terminal.recentBufferTextSnapshot(
            maximumUTF8Bytes: 4_096, sinceAbsoluteRow: 0, kind: .active)

        terminal.feed(text: "\u{1b}cnew buffer")

        XCTAssertEqual(snapshot.text(maximumUTF8Bytes: 4_096), expected)
    }

    func testGraphemeSnapshotOwnsValuesAcrossArenaBlocksAndRetirement() {
        let snapshot: [[UInt32]?] = {
            let arena = CellArena()
            for count in 1...300 {
                _ = arena.intern(grapheme: [0x65] + Array(repeating: 0x301, count: count))
            }
            return arena.textGraphemeSnapshot()
        }()
        XCTAssertEqual(snapshot.count, 301)
        XCTAssertNil(snapshot[0])
        for count in 1...300 {
            XCTAssertEqual(snapshot[count], [0x65] + Array(repeating: 0x301, count: count))
        }
    }

    func testSnapshotMatchesSynchronousReadForEveryByteBudget() {
        let terminal = terminal(cols: 12, rows: 20)
        terminal.feed(text: "first\r\n/tmp/long-wrapped-image.png\r\ne\u{301} 👩🏽‍💻 中\r\nlast")
        let snapshot = terminal.recentBufferTextSnapshot(
            maximumUTF8Bytes: 4_096, sinceAbsoluteRow: 0, kind: .active)
        for budget in 0...150 {
            XCTAssertEqual(snapshot.text(maximumUTF8Bytes: budget),
                terminal.getRecentLogicalBufferText(maximumUTF8Bytes: budget, sinceAbsoluteRow: 0),
                "byte budget \(budget)")
        }
    }

    func testSnapshotMatchesAfterEraseInsertDeleteAndResize() {
        let terminal = terminal(cols: 20, rows: 6)
        for control in ["before 中 e\u{301}", "\u{1b}[H\u{1b}[2@x", "\u{1b}[3P",
                        "\u{1b}[44m\u{1b}[K", "\u{1b}[2;1H👩🏽‍💻 tail", "\u{1b}[1K",
                        "\u{1b}[3;1Hnext\u{1b}[2X", "\u{1b}[2J", "after"] {
            terminal.feed(text: control)
            let snapshot = terminal.recentBufferTextSnapshot(
                maximumUTF8Bytes: 4_096, sinceAbsoluteRow: 0, kind: .active)
            XCTAssertEqual(snapshot.text(maximumUTF8Bytes: 4_096),
                terminal.getRecentLogicalBufferText(maximumUTF8Bytes: 4_096, sinceAbsoluteRow: 0))
        }
        terminal.resize(cols: 8, rows: 10)
        let snapshot = terminal.recentBufferTextSnapshot(
            maximumUTF8Bytes: 4_096, sinceAbsoluteRow: 0, kind: .active)
        XCTAssertEqual(snapshot.text(maximumUTF8Bytes: 4_096),
            terminal.getRecentLogicalBufferText(maximumUTF8Bytes: 4_096, sinceAbsoluteRow: 0))
    }

    func testSnapshotBoundsSparseRowsAndDenseCellsBeforeTranslation() {
        let terminal = terminal(cols: 120, rows: 50, scrollback: 10_000)
        terminal.feed(text: String(repeating: "\r\n", count: 9_000))
        let sparse = terminal.recentBufferTextSnapshot(
            maximumUTF8Bytes: 256 * 1024, sinceAbsoluteRow: 0, kind: .active)
        XCTAssertEqual(sparse.rowsNewestFirst.count, RecentBufferTextSnapshot.maximumRows)

        terminal.feed(text: String(repeating: String(repeating: "x", count: 120) + "\r\n", count: 3_000))
        let dense = terminal.recentBufferTextSnapshot(
            maximumUTF8Bytes: 256 * 1024, sinceAbsoluteRow: 0, kind: .active)
        XCTAssertLessThanOrEqual(dense.rowsNewestFirst.reduce(0) { $0 + $1.cells.count },
                                 RecentBufferTextSnapshot.maximumCells)
        XCTAssertLessThan(dense.rowsNewestFirst.count, RecentBufferTextSnapshot.maximumRows)
    }

    func testSnapshotOmitsLogicalLineCutByCaptureBudget() {
        let terminal = terminal(cols: 120, rows: 50, scrollback: 4_000)
        terminal.feed(text: "/tmp/" + String(repeating: "x", count: 300_000) + ".png")
        let snapshot = terminal.recentBufferTextSnapshot(
            maximumUTF8Bytes: 256 * 1024, sinceAbsoluteRow: 0, kind: .active)
        XCTAssertFalse(snapshot.text(maximumUTF8Bytes: 256 * 1024).text.contains(".png"))
    }

    @MainActor
    func testViewReaderRetainsIncrementalScreenAndResetSemantics() {
        let view = TerminalView(frame: .zero, font: nil,
            options: TerminalOptions(cols: 40, rows: 5, scrollback: 2_000))
        for index in 1...300 { view.feed(text: "line-\(index)\r\n") }
        let first = view.recentLogicalBufferText(maximumUTF8Bytes: 256 * 1024)
        view.feed(text: "\u{1b}[H/tmp/repainted.png")
        let repaint = view.recentLogicalBufferText(
            maximumUTF8Bytes: 256 * 1024, sinceAbsoluteRow: first.nextAbsoluteRow)
        XCTAssertTrue(repaint.text.contains("/tmp/repainted.png"))
        XCTAssertFalse(repaint.text.contains("line-100"))
        let resetCursor = view.recentLogicalBufferText(
            maximumUTF8Bytes: 256 * 1024, sinceAbsoluteRow: Int.max)
        XCTAssertTrue(resetCursor.text.contains("line-100"))
    }

    @MainActor
    func testStressSynchronizedReaderWhenEnabled() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["SWIFTTERM_READ_STRESS"] == "1")
        let view = TerminalView(frame: .zero, font: nil,
            options: TerminalOptions(cols: 120, rows: 50, scrollback: 10_200))
        for index in 0..<10_000 {
            view.feed(text: index % 7 == 0 ? "\r\n" : "step \(index) /tmp/output.png\r\n")
        }
        let reader = view.recentLogicalBufferReader(maximumUTF8Bytes: 256 * 1024)
        var cursor = 0
        for phase in ["cold", "screen", "screen"] {
            let since = cursor
            let started = DispatchTime.now().uptimeNanoseconds
            let result = await Task.detached { reader(since) }.value
            let elapsed = Double(DispatchTime.now().uptimeNanoseconds - started) / 1_000_000
            cursor = result.nextAbsoluteRow
            XCTAssertTrue(result.text.contains("/tmp/output.png"))
            print("TERMINAL_READ phase=\(phase) ms=\(elapsed) bytes=\(result.text.utf8.count)")
        }
        for _ in 0..<3 {
            let started = DispatchTime.now().uptimeNanoseconds
            let snapshot = view.withTerminal { terminal in
                terminal.recentBufferTextSnapshot(
                    maximumUTF8Bytes: 256 * 1024, sinceAbsoluteRow: 0, kind: .active)
            }
            let captured = DispatchTime.now().uptimeNanoseconds
            let result = await Task.detached { snapshot.text(maximumUTF8Bytes: 256 * 1024) }.value
            let finished = DispatchTime.now().uptimeNanoseconds
            XCTAssertTrue(result.text.contains("/tmp/output.png"))
            print("TERMINAL_CAPTURE lock_ms=\(Double(captured - started) / 1_000_000) translate_ms=\(Double(finished - captured) / 1_000_000)")
        }
    }

    @MainActor
    func testStressMatchedLockCostWhenEnabled() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["SWIFTTERM_READ_STRESS"] == "1")
        for shape in ["sparse", "dense", "graphemes"] {
            let view = TerminalView(frame: .zero, font: nil,
                options: TerminalOptions(cols: 120, rows: 50, scrollback: 4_000))
            let line: String
            switch shape {
            case "dense": line = String(repeating: "x", count: 110)
            case "graphemes":
                line = (0..<110).map { "e" + String(Unicode.Scalar(0x0300 + $0)!) }.joined()
            default: line = "step /tmp/output.png"
            }
            for _ in 0..<(shape == "sparse" ? 3_500 : 2_000) { view.feed(text: line + "\r\n") }
            for _ in 0..<3 {
                let started = DispatchTime.now().uptimeNanoseconds
                let before = view.withTerminal {
                    $0.getRecentLogicalBufferText(maximumUTF8Bytes: 256 * 1024, sinceAbsoluteRow: 0)
                }
                let beforeEnd = DispatchTime.now().uptimeNanoseconds
                let snapshot = view.withTerminal {
                    $0.recentBufferTextSnapshot(maximumUTF8Bytes: 256 * 1024, sinceAbsoluteRow: 0, kind: .active)
                }
                let captured = DispatchTime.now().uptimeNanoseconds
                let after = await Task.detached { snapshot.text(maximumUTF8Bytes: 256 * 1024) }.value
                let finished = DispatchTime.now().uptimeNanoseconds
                XCTAssertEqual(after, before, "the matched case must preserve every byte and the cursor")
                print("TERMINAL_MATCHED shape=\(shape) before_lock_ms=\(Double(beforeEnd - started) / 1_000_000) after_lock_ms=\(Double(captured - beforeEnd) / 1_000_000) translate_ms=\(Double(finished - captured) / 1_000_000)")
            }
        }
    }

    func testStressFullGraphemeTableWhenEnabled() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["SWIFTTERM_READ_STRESS"] == "1")
        let arena = CellArena()
        for identifier in 0..<Int(UInt16.max) {
            let marks = (0..<16).map { UInt32(0x300 + ((identifier >> $0) & 1)) }
            XCTAssertNotNil(arena.intern(grapheme: [0x65] + marks))
        }
        for _ in 0..<3 {
            let started = DispatchTime.now().uptimeNanoseconds
            let snapshot = arena.textGraphemeSnapshot()
            let elapsed = Double(DispatchTime.now().uptimeNanoseconds - started) / 1_000_000
            XCTAssertEqual(snapshot.count, Int(UInt16.max) + 1)
            XCTAssertEqual(snapshot[Int(UInt16.max)]?.count, 17)
            print("TERMINAL_GRAPHEME_TABLE entries=65535 copy_ms=\(elapsed)")
        }
    }
}
#endif
