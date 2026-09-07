import Foundation
import SwiftTerm

/// Renders a terminal's visible screen as a self-contained repaint — real terminal output, not
/// plain text — so a session that was already running when capture began still has something
/// valid to seed `RemoteRingBuffer` with.
///
/// `Terminal.getBufferAsData` cannot do this job, and seeding the ring with it was the bug behind
/// the scrambled first paint in the browser:
///
/// - It joins rows with a bare line feed. A terminal that is not in new-line mode moves the
///   cursor *down* on LF and leaves the column where it was, so every row started where the
///   previous row ended and the screen came out as a staircase that wrapped around the right
///   edge.
/// - It renders every unwritten or erased cell as U+0000, because SwiftTerm's blank `CharData`
///   carries `code == 0` and `getCharacter()` maps that straight to a NUL scalar. A client
///   discards NUL without advancing the cursor, so the gaps a TUI leaves between words collapse
///   and the text runs together.
/// - It walks the whole scrollback and drops every attribute, so the seed was a large colourless
///   dump that the ring then truncated mid-line.
///
/// The repaint states the ground it needs and no more: buffer, charset designation, attributes,
/// screen contents, cursor. Scrolling margins (DECSTBM) and origin mode (DECOM) are deliberately
/// *not* restated, so a seed that follows a cut stream inherits whatever the cut head armed.
/// That is the safer residual: those two describe the region the live output still being
/// streamed is aimed at, and resetting them would misplace everything that arrives after the
/// seed in order to tidy what came before it.
///
/// A pure function over a copied terminal snapshot, so the byte stream is unit-tested directly
/// without exposing SwiftTerm's mutable parser storage.
enum RemoteScreenSeed {

    // MARK: - Constants

    private enum Sequence {
        static let enterAlternateBuffer = "\u{1b}[?1049h"
        /// Designates ASCII into G0. See `repaint`.
        static let selectAsciiG0 = "\u{1b}(B"
        static let clearScreen = "\u{1b}[H\u{1b}[2J"
        static let resetAttributes = "\u{1b}[0m"
        static let hideCursor = "\u{1b}[?25l"
        static let rowSeparator = "\r\n"
        static let blankCell: Character = " "
    }

    /// SGR parameters, named so the encoder reads as the spec does.
    private enum Sgr {
        static let reset = 0
        static let bold = 1
        static let dim = 2
        static let italic = 3
        static let underline = 4
        static let blink = 5
        static let inverse = 7
        static let invisible = 8
        static let crossedOut = 9

        static let foregroundBase = 30
        static let backgroundBase = 40
        static let brightForegroundBase = 90
        static let brightBackgroundBase = 100
        static let extendedForeground = 38
        static let extendedBackground = 48
        static let paletteSelector = 5
        static let trueColorSelector = 2

        /// Codes 0...7 are the plain ANSI colours; 8...15 repeat them as the bright set.
        static let brightPaletteStart: UInt8 = 8
        static let namedPaletteEnd: UInt8 = 16
    }

    /// A cell whose width is greater than one is followed by placeholder stubs that the client
    /// must not be sent — the wide glyph advances the cursor across them by itself.
    private static let singleCellAdvance = 1

    // MARK: - Public Methods

    /// The repaint for a `.liveScreen` snapshot, ready to be replayed into a fresh client.
    /// A scrolled viewport cannot be replayed: its rows disagree with the live cursor and with
    /// the cursor-addressed PTY output that follows this seed.
    static func repaint(of terminal: TerminalViewStateSnapshot) -> Data {
        var out = ""

        // The client starts on the normal buffer. A session already running an alt-screen TUI
        // needs that switch replayed first or its repaint lands in the wrong buffer.
        if terminal.isAlternateBuffer {
            out += Sequence.enterAlternateBuffer
        }
        // Designate ASCII into G0 before writing a single glyph. A seed can follow an arbitrary
        // cut of the raw stream, and an ncurses program draws its borders by leaving G0 on the
        // DEC line-drawing set for the length of the burst; CAN returns the parser to ground but
        // resets no designation, so a repaint sent under a live line-drawing G0 spells every
        // letter of itself as a box glyph.
        //
        // Erasing does not clear SGR, and the client may hold a colour from a truncated earlier
        // seed. Rows are rendered assuming they begin on default attributes, so say so.
        out += Sequence.selectAsciiG0 + Sequence.clearScreen + Sequence.resetAttributes

        for (row, line) in terminal.visibleRows.enumerated() {
            if row > 0 {
                out += Sequence.rowSeparator
            }
            out += render(line.cells, cols: terminal.dimensions.cols)
        }

        let cursor = terminal.cursor
        out += cursorPosition(column: cursor.col, row: cursor.row)
        if !terminal.cursorHidden {
            return Data(out.utf8)
        }
        return Data((out + Sequence.hideCursor).utf8)
    }

    // MARK: - Private Methods

    /// One row, trimmed of its trailing blanks and emitted as runs of equal attributes.
    ///
    /// Every row starts and ends on default attributes — `repaint` resets before the first one
    /// and this resets after any row that set something — so a plain row costs no escape bytes
    /// at all and a coloured run cannot bleed into the row below.
    private static func render(_ line: [TerminalVisibleCellSnapshot], cols: Int) -> String {
        let end = min(trimmedLength(of: line), min(line.count, cols))
        guard end > 0 else { return "" }

        var out = ""
        var inEffect = Sequence.resetAttributes
        var runAttribute: Attribute?
        var column = 0

        while column < end {
            let cell = line[column]
            // Encode once per run of equal attributes, not once per cell — a full-size grid is
            // nearly forty thousand cells and this runs on the main actor.
            if cell.attribute != runAttribute {
                runAttribute = cell.attribute
                let wanted = sgr(for: cell.attribute)
                if wanted != inEffect {
                    out += wanted
                    inEffect = wanted
                }
            }
            out.append(printable(cell))
            column += advance(past: cell)
        }

        if inEffect != Sequence.resetAttributes {
            out += Sequence.resetAttributes
        }
        return out
    }

    /// The character to send for a cell: a blank cell holds `code == 0`, which is a NUL scalar
    /// rather than a space, and a client would drop it without advancing the cursor.
    private static func printable(_ cell: TerminalVisibleCellSnapshot) -> Character {
        let character = cell.character
        if character.unicodeScalars.first?.value == 0 {
            return Sequence.blankCell
        }
        return character
    }

    /// How many cells a glyph owns. A double-width glyph is stored with a blank placeholder in
    /// the following cell; sending that placeholder as a space would shift the rest of the row.
    private static func advance(past cell: TerminalVisibleCellSnapshot) -> Int {
        max(cell.width, singleCellAdvance)
    }

    private static func trimmedLength(of line: [TerminalVisibleCellSnapshot]) -> Int {
        var end = line.count
        while end > 0 {
            let cell = line[end - 1]
            if cell.character.unicodeScalars.first?.value != 0, cell.character != " " {
                break
            }
            end -= 1
        }
        return end
    }

    private static func cursorPosition(column: Int, row: Int) -> String {
        // CUP is one-based, and the terminal tracks the cursor from zero.
        "\u{1b}[\(row + 1);\(column + 1)H"
    }

    /// A full SGR reset plus this attribute, so every run stands on its own and a truncated ring
    /// cannot leave the client wearing a colour it never saw set.
    private static func sgr(for attribute: Attribute) -> String {
        var parameters = [Sgr.reset]

        let styles: [(CharacterStyle, Int)] = [
            (.bold, Sgr.bold),
            (.dim, Sgr.dim),
            (.italic, Sgr.italic),
            (.underline, Sgr.underline),
            (.blink, Sgr.blink),
            (.inverse, Sgr.inverse),
            (.invisible, Sgr.invisible),
            (.crossedOut, Sgr.crossedOut),
        ]
        for (style, code) in styles where attribute.style.contains(style) {
            parameters.append(code)
        }

        parameters += colorParameters(
            attribute.fg,
            base: Sgr.foregroundBase,
            brightBase: Sgr.brightForegroundBase,
            extended: Sgr.extendedForeground
        )
        parameters += colorParameters(
            attribute.bg,
            base: Sgr.backgroundBase,
            brightBase: Sgr.brightBackgroundBase,
            extended: Sgr.extendedBackground
        )

        return "\u{1b}[" + parameters.map(String.init).joined(separator: ";") + "m"
    }

    /// The default colours need no parameters — the leading reset already selected them.
    private static func colorParameters(
        _ color: Attribute.Color,
        base: Int,
        brightBase: Int,
        extended: Int
    ) -> [Int] {
        switch color {
        case .defaultColor, .defaultInvertedColor:
            return []
        case .ansi256(let code) where code < Sgr.brightPaletteStart:
            return [base + Int(code)]
        case .ansi256(let code) where code < Sgr.namedPaletteEnd:
            return [brightBase + Int(code - Sgr.brightPaletteStart)]
        case .ansi256(let code):
            return [extended, Sgr.paletteSelector, Int(code)]
        case .trueColor(let red, let green, let blue):
            return [extended, Sgr.trueColorSelector, Int(red), Int(green), Int(blue)]
        }
    }
}
