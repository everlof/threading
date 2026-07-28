import AppKit
import SwiftTerm
import XCTest
@testable import Skalman

/// What the terminal answers when the program running in it asks what colour it is.
///
/// Claude Code's `"theme": "auto"` — the default — is not "follow macOS". It sends
/// `OSC 11 ; ? ST`, reads the terminal's own background out of the reply, and falls back to its
/// **dark** palette when nothing answers. Skalman answered nothing, so every agent in every
/// session painted dark-theme ink: on a light terminal theme (Bauhaus is paper) a diff's
/// unchanged lines arrived as near-white text on cream, and the washes behind its changed lines
/// were Claude's near-black slabs.
///
/// The reply is a contract with a program that is already running, so these assert on the exact
/// bytes rather than on any state the app can read back.
final class TerminalColorQueryTests: XCTestCase {

    // MARK: - Harness

    /// Captures what the terminal sends upstream, which is where a reply goes.
    private final class Recorder: TerminalDelegate {
        var written: [UInt8] = []

        func send(source: Terminal, data: ArraySlice<UInt8>) {
            written.append(contentsOf: data)
        }

        var text: String { String(decoding: written, as: UTF8.self) }
    }

    /// A terminal wearing a light palette, which is the case the fallback gets wrong.
    private func makeTerminal() -> (Terminal, Recorder) {
        let recorder = Recorder()
        let terminal = Terminal(delegate: recorder)
        terminal.foregroundColor = Color(red: 0x1717, green: 0x1717, blue: 0x1717)
        terminal.backgroundColor = Color(red: 0xF4F4, green: 0xEBEB, blue: 0xDDDD)
        terminal.cursorColor = Color(red: 0xD6D6, green: 0x2828, blue: 0x2828)
        recorder.written.removeAll()
        return (terminal, recorder)
    }

    // MARK: - Answering a Query

    func testBackgroundQueryIsAnswered() {
        let (terminal, recorder) = makeTerminal()

        terminal.feed(text: "\u{1b}]11;?\u{7}")

        XCTAssertEqual(
            recorder.text,
            "\u{1b}]11;rgb:f4f4/ebeb/dddd\u{1b}\\",
            "the terminal did not tell the program what colour it is"
        )
    }

    func testForegroundQueryIsAnswered() {
        let (terminal, recorder) = makeTerminal()

        terminal.feed(text: "\u{1b}]10;?\u{7}")

        XCTAssertEqual(recorder.text, "\u{1b}]10;rgb:1717/1717/1717\u{1b}\\")
    }

    /// The reply names the colour that was asked about: 10 foreground, 11 background, 12 cursor.
    /// A cursor query answered as `11` tells the asker the *page* is the cursor's colour.
    func testCursorQueryIsAnsweredAsTheCursor() {
        let (terminal, recorder) = makeTerminal()

        terminal.feed(text: "\u{1b}]12;?\u{7}")

        XCTAssertEqual(recorder.text, "\u{1b}]12;rgb:d6d6/2828/2828\u{1b}\\")
    }

    /// xterm's own multi-parameter form: each further parameter names the next colour along.
    /// This is what the `startAt` offset exists for, and reading it as an index into the
    /// parameters instead is what silently dropped every single-parameter OSC 11.
    func testOneQueryCanAskAboutSeveralColoursAtOnce() {
        let (terminal, recorder) = makeTerminal()

        terminal.feed(text: "\u{1b}]10;?;?;?\u{7}")

        XCTAssertEqual(
            recorder.text,
            "\u{1b}]10;rgb:1717/1717/1717\u{1b}\\"
                + "\u{1b}]11;rgb:f4f4/ebeb/dddd\u{1b}\\"
                + "\u{1b}]12;rgb:d6d6/2828/2828\u{1b}\\"
        )
    }

    // MARK: - Setting a Colour

    func testTheProgramCanSetTheBackground() {
        let (terminal, _) = makeTerminal()

        terminal.feed(text: "\u{1b}]11;#102030\u{7}")

        XCTAssertEqual(terminal.backgroundColor, Color(red: 0x1010, green: 0x2020, blue: 0x3030))
    }

    func testSettingTheForegroundSpillsIntoTheBackgroundAndCursor() {
        let (terminal, _) = makeTerminal()

        terminal.feed(text: "\u{1b}]10;#ffffff;#000000;#ff0000\u{7}")

        XCTAssertEqual(terminal.foregroundColor, Color(red: 0xFFFF, green: 0xFFFF, blue: 0xFFFF))
        XCTAssertEqual(terminal.backgroundColor, Color(red: 0x0000, green: 0x0000, blue: 0x0000))
        XCTAssertEqual(terminal.cursorColor, Color(red: 0xFFFF, green: 0x0000, blue: 0x0000))
    }

    // MARK: - What the Session Reports

    /// The answer has to be the palette the user is actually looking at, not SwiftTerm's default
    /// black — the agent asks once, at startup, and keeps whatever it heard for the whole
    /// session.
    func testTheSessionAnswersWithItsOwnThemesBackground() throws {
        var profile = TerminalProfile.default
        profile.theme = AppThemeStyles.bauhaus.terminalPalette

        let session = TerminalSession(
            profile: profile,
            frame: NSRect(x: 0, y: 0, width: 400, height: 300)
        )

        XCTAssertEqual(
            session.terminalView.getTerminal().backgroundColor,
            terminalColor(profile.theme.background),
            "the terminal would have reported a background nobody can see"
        )
    }

    /// SwiftTerm's own conversion, which is internal to the package.
    private func terminalColor(_ color: NSColor) -> Color {
        let srgb = color.usingColorSpace(.sRGB) ?? color
        return Color(
            red: UInt16(srgb.redComponent * 65535),
            green: UInt16(srgb.greenComponent * 65535),
            blue: UInt16(srgb.blueComponent * 65535)
        )
    }
}
