#if os(macOS)
import Foundation
import XCTest

@testable import SwiftTerm

final class EmbeddingIntegrationTests: XCTestCase {
    private let queue = DispatchQueue(label: "SwiftTerm.EmbeddingIntegrationTests")

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

    func testResizeDoesNotMaterializeEmptyScrollbackCapacity() {
        let terminal = terminal(rows: 24, scrollback: 10_000)
        let allocatedBefore = terminal.normalBuffer.lines.getArray().compactMap { $0 }.count

        terminal.resize(cols: 120, rows: 24)

        XCTAssertEqual(terminal.normalBuffer.lines.count, 24)
        XCTAssertEqual(
            terminal.normalBuffer.lines.getArray().compactMap { $0 }.count,
            allocatedBefore)
    }

    func testFunctionalKeyAPIUsesLiveTerminalKeyboardModes() {
        let terminal = terminal()

        XCTAssertEqual(terminal.encodedFunctionalKey(.up), Array("\u{1b}[A".utf8))
        terminal.feed(text: "\u{1b}[?1h")
        XCTAssertEqual(terminal.encodedFunctionalKey(.up), Array("\u{1b}OA".utf8))

        terminal.feed(text: "\u{1b}[>1u")
        XCTAssertEqual(
            terminal.encodedFunctionalKey(.tab, modifiers: [.ctrl]),
            Array("\u{1b}[9;5u".utf8))
    }

    func testRecentLogicalBufferJoinsWrapsAndPreservesHardBreaks() {
        let terminal = terminal(cols: 12, rows: 8)
        let path = "/tmp/a-very-long-render-name.png"
        terminal.feed(text: path + "\r\nnext")

        let text = terminal.getRecentLogicalBufferText(maximumUTF8Bytes: 4_096)

        XCTAssertTrue(text.contains(path))
        XCTAssertTrue(text.contains("\nnext"))
    }

    func testRecentLogicalBufferOmitsOversizedPartialLine() {
        let terminal = terminal(cols: 8, rows: 6)
        terminal.feed(text: "/tmp/this-logical-line-is-larger-than-the-budget.png")

        let text = terminal.getRecentLogicalBufferText(maximumUTF8Bytes: 16)

        XCTAssertLessThanOrEqual(text.utf8.count, 16)
        XCTAssertFalse(text.contains(".png"))
        XCTAssertFalse(text.contains("budget"))
    }

    func testIncrementalRecentBufferSkipsStableScrollback() {
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

    func testIncrementalRecentBufferAlwaysRereadsCurrentScreen() {
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

    func testIncrementalRecentBufferRejectsCursorPastResetBuffer() {
        let terminal = terminal(cols: 40, rows: 5, scrollback: 2_000)
        feedLines(terminal, 1...300)

        let read = terminal.getRecentLogicalBufferText(
            maximumUTF8Bytes: 256 * 1024,
            sinceAbsoluteRow: 10_000_000)

        XCTAssertTrue(read.text.contains("line-1\n"))
    }

    func testIncrementalRecentBufferCursorAdvancesWithProducedRows() {
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

    func testMouseProtocolIsPublicContract() {
        let delegate = CapturingTerminalDelegate()
        let terminal = Terminal(
            delegate: delegate,
            options: TerminalOptions(cols: 80, rows: 24))

        terminal.feed(text: "\u{1b}[?1006h")
        XCTAssertEqual(terminal.mouseProtocol, .sgr)
    }

    func testDiagnosticsAreStructuredAndRateLimited() {
        let events = DiagnosticEvents()
        SwiftTermDiagnostics.installHandler { events.append($0) }
        addTeardownBlock { SwiftTermDiagnostics.removeHandler() }

        SwiftTermDiagnostics.emit(.error, .ptyWriteFailed, facts: ["errno": 5])
        SwiftTermDiagnostics.emit(.error, .ptyWriteFailed, facts: ["errno": 6])
        SwiftTermDiagnostics.emit(.fault, .bufferWidthInvariant, facts: ["columns": 80])

        XCTAssertEqual(events.snapshot.map(\.code), [.ptyWriteFailed, .bufferWidthInvariant])
        XCTAssertEqual(events.snapshot.first?.facts, ["errno": 5])
    }
}

private final class CapturingTerminalDelegate: TerminalDelegate {
    var data: [UInt8] = []
    var text: String { String(decoding: data, as: UTF8.self) }

    func send(source: Terminal, data: ArraySlice<UInt8>) {
        self.data.append(contentsOf: data)
    }
}

private final class DiagnosticEvents: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [SwiftTermDiagnosticEvent] = []

    func append(_ event: SwiftTermDiagnosticEvent) {
        lock.lock()
        storage.append(event)
        lock.unlock()
    }

    var snapshot: [SwiftTermDiagnosticEvent] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }
}
#endif
