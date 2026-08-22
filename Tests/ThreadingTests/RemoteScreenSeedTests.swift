import XCTest
import SwiftTerm
@testable import Threading

/// The bytes a joining remote client is sent to reproduce a screen that was already on the Mac.
///
/// The seed used to be `Terminal.getBufferAsData()`, which is plain text: rows joined by a bare
/// line feed, and every blank cell rendered as U+0000. A client that is not in new-line mode
/// leaves the column alone on LF and discards NUL without advancing, so the browser drew the
/// screen as a staircase of run-together words. These assert on the byte stream because the byte
/// stream is the whole contract.
@MainActor
final class RemoteScreenSeedTests: XCTestCase {

    // MARK: - Harness

    private func makeTerminal(cols: Int = 20, rows: Int = 5) -> TerminalView {
        TerminalView(
            frame: .zero,
            options: TerminalOptions(cols: cols, rows: rows, scrollback: 200))
    }

    private func seed(_ terminal: TerminalView) -> String {
        String(
            decoding: RemoteScreenSeed.repaint(of: terminal.terminalStateSnapshot()),
            as: UTF8.self)
    }

    /// The printable text of the seed, with every escape sequence removed, so a test can talk
    /// about what lands on screen without restating the encoding.
    private func visibleText(_ seed: String) -> String {
        var out = ""
        var rest = Substring(seed)
        while let escape = rest.firstIndex(of: "\u{1b}") {
            out += rest[rest.startIndex..<escape]
            // Every sequence this seed emits — CSI, and the `ESC ( B` charset designation —
            // ends on its first alphabetic byte.
            guard let final = rest[escape...].firstIndex(where: { $0.isLetter }) else {
                return out
            }
            rest = rest[rest.index(after: final)...]
        }
        return out + rest
    }

    // MARK: - Row Separation

    func testRowsAreJoinedWithCarriageReturnAndLineFeed() {
        let terminal = makeTerminal()
        terminal.feed(text: "alpha\r\nbeta\r\ngamma")

        let bytes = seed(terminal)

        XCTAssertTrue(bytes.contains("alpha\r\nbeta"), "rows must be separated by CRLF")
        XCTAssertFalse(
            bytes.contains("alpha\nbeta"),
            "a bare LF leaves the column where it was, which staircases the screen"
        )
    }

    func testEveryLineFeedCarriesACarriageReturn() {
        let terminal = makeTerminal()
        terminal.feed(text: "one\r\ntwo\r\nthree\r\nfour")

        let bytes = Array(RemoteScreenSeed.repaint(of: terminal.terminalStateSnapshot()))
        let lineFeeds = bytes.enumerated().filter { $0.element == UInt8(ascii: "\n") }

        XCTAssertFalse(lineFeeds.isEmpty, "a multi-row screen should emit line feeds")
        for (index, _) in lineFeeds {
            XCTAssertTrue(
                index > 0 && bytes[index - 1] == UInt8(ascii: "\r"),
                "the line feed at \(index) is not preceded by a carriage return"
            )
        }
    }

    // MARK: - Blank Cells

    func testBlankCellsBecomeSpacesRatherThanNul() {
        let terminal = makeTerminal()
        // Write, then jump forward and write again — the skipped cells are never touched, which
        // is exactly how a TUI leaves gaps between words.
        terminal.feed(text: "left\u{1b}[12Gright")

        let bytes = RemoteScreenSeed.repaint(of: terminal.terminalStateSnapshot())

        XCTAssertFalse(bytes.contains(0), "a NUL is dropped by the client, collapsing the gap")
        XCTAssertTrue(
            visibleText(seed(terminal)).hasPrefix("left       right"),
            "the gap between the runs must survive as spaces"
        )
    }

    func testErasedCellsBecomeSpacesRatherThanNul() {
        let terminal = makeTerminal()
        terminal.feed(text: "abcdefgh\r")
        // Erase from the cursor to the end of the line, then reach past the erased region.
        terminal.feed(text: "ab\u{1b}[K\u{1b}[7Gz")

        XCTAssertFalse(
            RemoteScreenSeed.repaint(of: terminal.terminalStateSnapshot()).contains(0),
            "erased cells carry code 0 and must not reach the client as NUL"
        )
        XCTAssertTrue(
            visibleText(seed(terminal)).hasPrefix("ab    z"),
            "the erased span must survive as spaces"
        )
    }

    // MARK: - Scope

    func testOnlyTheVisibleScreenIsSeeded() {
        let terminal = makeTerminal(cols: 20, rows: 3)
        terminal.feed(text: "scrolled-away\r\n")
        terminal.feed(text: "one\r\ntwo\r\nthree\r\nfour")

        let text = visibleText(seed(terminal))

        XCTAssertFalse(
            text.contains("scrolled-away"),
            "the seed is the visible screen, not the whole scrollback"
        )
        XCTAssertTrue(text.contains("four"), "the live screen must be present")
    }

    func testSeedClearsTheScreenAndHomesTheCursorFirst() {
        let terminal = makeTerminal()
        terminal.feed(text: "hello")

        XCTAssertTrue(
            seed(terminal).hasPrefix("\u{1b}(B\u{1b}[H\u{1b}[2J"),
            "a client may already hold a previous screen; the seed must start from a clear one"
        )
    }

    /// A seed can follow an arbitrary cut of the raw stream, and CAN resets no charset
    /// designation — so a repaint sent while G0 still holds the DEC line-drawing set an ncurses
    /// border left armed would spell every letter of itself as a box glyph.
    func testSeedDesignatesAsciiBeforeWritingAnyGlyph() throws {
        let terminal = makeTerminal()
        terminal.feed(text: "hello")

        let bytes = seed(terminal)
        let charset = try XCTUnwrap(bytes.range(of: "\u{1b}(B"))
        let firstGlyph = try XCTUnwrap(bytes.range(of: "hello"))

        XCTAssertTrue(
            charset.upperBound <= firstGlyph.lowerBound,
            "ASCII must be designated into G0 ahead of the repaint's own text"
        )
    }

    /// The margins and origin mode a cut head armed describe where the live output that follows
    /// the seed is aimed, so the seed leaves both alone rather than tidying them away.
    func testSeedRestatesNeitherScrollingMarginsNorOriginMode() {
        let terminal = makeTerminal()
        terminal.feed(text: "hello")

        let bytes = seed(terminal)

        XCTAssertFalse(bytes.contains("\u{1b}[r"), "DECSTBM must not be reset by the repaint")
        XCTAssertFalse(bytes.contains("\u{1b}[?6l"), "DECOM must not be reset by the repaint")
    }

    func testAlternateBufferIsEnteredBeforeTheRepaint() {
        let terminal = makeTerminal()
        terminal.feed(text: "\u{1b}[?1049h")
        terminal.feed(text: "in-alt")

        XCTAssertTrue(
            seed(terminal).hasPrefix("\u{1b}[?1049h"),
            "a repaint for an alt-screen TUI must not land on the normal buffer"
        )
    }

    // MARK: - Attributes

    func testColoursSurviveAsSgr() {
        let terminal = makeTerminal()
        terminal.feed(text: "\u{1b}[31mred\u{1b}[0m plain")

        let bytes = seed(terminal)

        XCTAssertTrue(bytes.contains("\u{1b}[0;31mred"), "an ANSI colour must be re-emitted")
        XCTAssertTrue(visibleText(bytes).hasPrefix("red plain"))
    }

    func testTrueColourSurvivesAsSgr() {
        let terminal = makeTerminal()
        terminal.feed(text: "\u{1b}[38;2;10;20;30mrgb")

        XCTAssertTrue(
            seed(terminal).contains("\u{1b}[0;38;2;10;20;30mrgb"),
            "24-bit colour must not be flattened away"
        )
    }

    func testBoldSurvivesAsSgr() {
        let terminal = makeTerminal()
        terminal.feed(text: "\u{1b}[1mbold")

        XCTAssertTrue(seed(terminal).contains("\u{1b}[0;1mbold"))
    }

    func testAttributesAreResetAtTheEndOfARow() {
        let terminal = makeTerminal()
        terminal.feed(text: "\u{1b}[41mred-bg\r\nnext")

        let rows = seed(terminal).components(separatedBy: "\r\n")

        XCTAssertTrue(
            rows.first?.hasSuffix("\u{1b}[0m") == true,
            "a coloured run must not bleed into the following row"
        )
    }

    // MARK: - Wide Glyphs

    func testDoubleWidthGlyphDoesNotGainATrailingSpace() {
        let terminal = makeTerminal()
        // A wide glyph occupies two cells: the character, then a blank placeholder stub. Sending
        // the stub as a space would shift the rest of the row right by one column.
        terminal.feed(text: "日本語ok")

        XCTAssertTrue(
            visibleText(seed(terminal)).hasPrefix("日本語ok"),
            "the placeholder cells of a wide glyph must not be emitted"
        )
    }

    // MARK: - Cursor

    func testCursorIsPlacedWhereTheTerminalLeftIt() {
        let terminal = makeTerminal()
        terminal.feed(text: "one\r\ntwo")

        let cursor = terminal.terminalStateSnapshot().cursor

        XCTAssertTrue(
            seed(terminal).hasSuffix("\u{1b}[\(cursor.row + 1);\(cursor.col + 1)H"),
            "the client must resume typing where the Mac's cursor actually is"
        )
    }

    func testHiddenCursorStaysHidden() {
        let terminal = makeTerminal()
        terminal.feed(text: "\u{1b}[?25lquiet")

        XCTAssertTrue(
            seed(terminal).hasSuffix("\u{1b}[?25l"),
            "a TUI that hid the cursor should not get a blinking block in the browser"
        )
    }
}
