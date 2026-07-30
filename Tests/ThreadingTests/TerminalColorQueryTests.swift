import AppKit
import SwiftTerm
import XCTest
@testable import Threading

/// What the terminal answers when the program running in it asks what colour it is.
///
/// Claude Code's `"theme": "auto"` — the default — is not "follow macOS". It sends
/// `OSC 11 ; ? ST`, reads the terminal's own background out of the reply, and falls back to its
/// **dark** palette when nothing answers. Threading answered nothing, so every agent in every
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

    // MARK: - What the Session States Up Front

    /// The query is a handshake, and a handshake can be missed. `COLORFGBG` is the same fact
    /// stated in the environment, where nothing can race it — and it is the fallback Claude
    /// Code's `"theme": "auto"` reads when its own `OSC 11` question goes unanswered in time.
    ///
    /// Only the background half is ever read: `15` is a light slot, `0` a dark one.
    func testALightPaletteStatesALightBackgroundInTheEnvironment() {
        let palette = AppThemeStyles.bauhaus.terminalPalette

        XCTAssertFalse(palette.hasDarkBackground, "Bauhaus is warm paper")
        XCTAssertEqual(palette.colorFGBG, "0;15")
        XCTAssertEqual(
            environment(for: palette)[EnvironmentKeys.colorFGBG],
            "0;15",
            "an agent launched here would have assumed a dark terminal"
        )
    }

    func testADarkPaletteStatesADarkBackgroundInTheEnvironment() {
        let palette = AppThemeStyles.artDeco.terminalPalette

        XCTAssertTrue(palette.hasDarkBackground, "Art Deco is midnight lacquer")
        XCTAssertEqual(palette.colorFGBG, "15;0")
        XCTAssertEqual(environment(for: palette)[EnvironmentKeys.colorFGBG], "15;0")
    }

    /// Threading is launched by launchd and inherits its environment, so a `COLORFGBG` left over
    /// from a terminal the app was started from describes *that* terminal. Two sessions side by
    /// side need not agree either, which is why this is written from the session's own profile
    /// on every launch rather than read or defaulted.
    func testTheSessionOverwritesAnInheritedValue() {
        setenv(EnvironmentKeys.colorFGBG, "12;3", 1)
        defer { unsetenv(EnvironmentKeys.colorFGBG) }

        XCTAssertEqual(
            environment(for: AppThemeStyles.bauhaus.terminalPalette)[EnvironmentKeys.colorFGBG],
            "0;15"
        )
    }

    // MARK: - What the Session Announces Later

    /// The two answers above are both given **once, at startup** — and a theme switched under
    /// a running agent reaches neither. Claude Code keeps whatever it heard, so repainting the
    /// terminal moves nothing on its side: an agent that heard "ink" keeps drawing near-white
    /// text onto what is now paper. That is the white-on-white diff, surviving a correct
    /// handshake and a correct environment.
    ///
    /// It does subscribe to colour-scheme reports (`DECSET 2031`) at startup, and the report —
    /// `CSI ? 997 ; 1|2 n` — is a *prompt to re-ask*, not the news itself: on hearing it the
    /// agent sends a fresh `OSC 11 ; ?` and adopts that answer. (Which is why feeding the
    /// report alone, without changing the answer behind it, once read as "not wired up".) So a
    /// switch must land palette-first, report-second, and the whole exchange is pinned here:
    /// announce, re-ask, new answer.
    func testAThemeSwitchUnderASubscribedChildIsAnnounced() {
        let (session, sent) = makeSession(theme: AppThemeStyles.bauhaus.terminalPalette)

        // The child subscribes the way Claude Code does in its first bytes.
        session.terminalView.getTerminal().feed(text: "\u{1b}[?2031h")

        var profile = TerminalProfile.default
        profile.theme = AppThemeStyles.artDeco.terminalPalette
        session.updateProfile(profile)

        XCTAssertEqual(
            sent.text,
            "\u{1b}[?997;1n",
            "paper to lacquer went unannounced, or announced as the wrong page"
        )
    }

    func testTheReAskAfterASwitchHearsTheNewPage() {
        let (session, sent) = makeSession(theme: AppThemeStyles.bauhaus.terminalPalette)
        session.terminalView.getTerminal().feed(text: "\u{1b}[?2031h")

        var profile = TerminalProfile.default
        profile.theme = AppThemeStyles.artDeco.terminalPalette
        session.updateProfile(profile)
        sent.bytes.removeAll()

        // The agent's move after hearing the report.
        session.terminalView.getTerminal().feed(text: "\u{1b}]11;?\u{7}")

        let background = terminalColor(profile.theme.background)
        let xcolor = String(
            format: "rgb:%04x/%04x/%04x", background.red, background.green, background.blue
        )
        XCTAssertEqual(
            sent.text,
            "\u{1b}]11;\(xcolor)\u{1b}\\",
            "the re-ask was answered with the palette the terminal just left"
        )
    }

    func testAnUnsubscribedChildHearsNoReport() {
        let (session, sent) = makeSession(theme: AppThemeStyles.bauhaus.terminalPalette)

        var profile = TerminalProfile.default
        profile.theme = AppThemeStyles.artDeco.terminalPalette
        session.updateProfile(profile)

        XCTAssertEqual(sent.text, "", "a program that never asked was interrupted anyway")
    }

    /// `applyProfile` also runs for font changes and re-applies of the same theme; only an
    /// actual change of page is worth an announcement, because only then does the re-ask hear
    /// anything new.
    func testReapplyingTheSamePageAnnouncesNothing() {
        let (session, sent) = makeSession(theme: AppThemeStyles.bauhaus.terminalPalette)
        session.terminalView.getTerminal().feed(text: "\u{1b}[?2031h")

        var profile = TerminalProfile.default
        profile.theme = AppThemeStyles.bauhaus.terminalPalette
        profile.fontSize += 1
        session.updateProfile(profile)

        XCTAssertEqual(sent.text, "", "a font tweak read as the page turning")
    }

    func testTheSubscriptionCanBeWithdrawn() {
        let (session, sent) = makeSession(theme: AppThemeStyles.bauhaus.terminalPalette)
        session.terminalView.getTerminal().feed(text: "\u{1b}[?2031h\u{1b}[?2031l")

        var profile = TerminalProfile.default
        profile.theme = AppThemeStyles.artDeco.terminalPalette
        session.updateProfile(profile)

        XCTAssertEqual(sent.text, "")
    }

    /// Collects what the session sends upstream, where both reports and replies go.
    private final class SentBytes {
        var bytes: [UInt8] = []
        var text: String { String(decoding: bytes, as: UTF8.self) }
    }

    private func makeSession(theme: TerminalTheme) -> (TerminalSession, SentBytes) {
        var profile = TerminalProfile.default
        profile.theme = theme

        let session = TerminalSession(
            profile: profile,
            frame: NSRect(x: 0, y: 0, width: 400, height: 300)
        )
        let sent = SentBytes()
        session.terminalView.onInputBytes = { sent.bytes.append(contentsOf: $0) }
        return (session, sent)
    }

    /// What a session hands its child, as a dictionary.
    private func environment(for palette: TerminalTheme) -> [String: String] {
        var profile = TerminalProfile.default
        profile.theme = palette

        let session = TerminalSession(
            profile: profile,
            frame: NSRect(x: 0, y: 0, width: 400, height: 300)
        )

        return session.buildEnvironment().reduce(into: [:]) { entries, entry in
            guard let split = entry.firstIndex(of: "=") else { return }
            entries[String(entry[entry.startIndex..<split])] = String(entry[entry.index(after: split)...])
        }
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
