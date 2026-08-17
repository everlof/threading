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
@MainActor
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

    // MARK: - Faint Text

    /// Claude Code marks its composer's proposed text — the `Try "…"` hint, autosuggestions —
    /// with bare SGR 2 (faint) over the *default* foreground, no colour of its own (measured
    /// against 2.0.61 and 2.1.220 in a bare PTY). No palette can therefore distinguish a
    /// suggestion from typed text; only the renderer's faint handling can, which is why this
    /// asserts on drawn pixels end to end — parser flag, attribute cache, and the glyph pass
    /// each held half of a fix that no other assertion would notice regressing.
    @MainActor
    func testFaintTextDrawsDimmerThanTypedText() throws {
        let view = TerminalView(frame: NSRect(x: 0, y: 0, width: 240, height: 80))
        // Stated rather than defaulted, so ink intensity below is simply the sampled
        // channel maximum over a black ground — no colour-space arithmetic against
        // whatever the platform default happens to be.
        view.nativeBackgroundColor = NSColor(srgbRed: 0, green: 0, blue: 0, alpha: 1)
        view.nativeForegroundColor = NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 1)
        view.getTerminal().feed(text: "AAAA\r\n\u{1b}[2mAAAA")

        let rep = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: rep)

        // The strongest ink per pixel row — glyph strokes peak at the text colour whatever
        // the antialiasing does at the edges.
        var rowPeaks: [Int: CGFloat] = [:]
        for y in 0..<rep.pixelsHigh {
            for x in 0..<rep.pixelsWide {
                guard let colour = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else {
                    continue
                }
                let deviation = max(
                    colour.redComponent,
                    max(colour.greenComponent, colour.blueComponent)
                )
                rowPeaks[y] = max(rowPeaks[y] ?? 0, deviation)
            }
        }

        // Two bands of ink, top to bottom: the typed row, then the faint row.
        var bands: [CGFloat] = []
        var current: CGFloat?
        for y in 0..<rep.pixelsHigh {
            if let peak = rowPeaks[y], peak > 0.05 {
                current = max(current ?? 0, peak)
            } else if let finished = current {
                bands.append(finished)
                current = nil
            }
        }
        if let finished = current { bands.append(finished) }

        XCTAssertEqual(bands.count, 2, "expected a typed row and a faint row, got \(bands)")
        let typed = bands[0]
        let faint = bands[1]
        XCTAssertGreaterThan(typed, 0.8, "the typed row did not draw at full strength")
        XCTAssertLessThan(
            faint,
            typed * 0.7,
            "a proposed suggestion is indistinguishable from text the user typed"
        )
        XCTAssertGreaterThan(
            faint,
            typed * 0.25,
            "faint means dimmer, not gone"
        )
    }

    // MARK: - Invisible Explicit Colours

    /// The reported bug's exact semantics: SGR 97 resolves to palette index 15, and System's
    /// light terminal palette states that index and its background as the same white.
    func testAVisibleBrightWhiteRunOnWhiteReportsItsFinalCollisionOnce() throws {
        let view = TerminalView(frame: NSRect(x: 0, y: 0, width: 420, height: 100))
        view.installColors(TerminalTheme.systemLight.asSwiftTermColors())
        view.nativeForegroundColor = TerminalTheme.systemLight.foreground
        view.nativeBackgroundColor = TerminalTheme.systemLight.background

        var conflicts: [TerminalTextColorConflict] = []
        view.onLowContrastText = { conflicts.append($0) }
        view.getTerminal().feed(text: "\u{1b}[97m[last: 12s] git:main")

        let rep = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: rep)
        view.cacheDisplay(in: view.bounds, to: rep)

        XCTAssertEqual(conflicts.count, 1, "one visible colour pair warned once per palette")
        let conflict = try XCTUnwrap(conflicts.first)
        XCTAssertEqual(conflict.foregroundSource, .ansi256(index: 15))
        XCTAssertEqual(conflict.backgroundSource, .defaultBackground)
        XCTAssertEqual(conflict.foreground, .init(red: 255, green: 255, blue: 255))
        XCTAssertEqual(conflict.background, .init(red: 255, green: 255, blue: 255))
        XCTAssertEqual(conflict.contrastRatio, 1, accuracy: 0.001)
        XCTAssertEqual(
            conflict.sample, "[last: 12s] git:main",
            "the run that went missing is the one thing the reader can look for"
        )
    }

    /// The quoted evidence is program output, and is treated as such: control characters never
    /// reach the band as chrome, whitespace collapses, and a run as wide as the terminal is cut
    /// to a few words with the cut declared rather than silently made.
    func testTheQuotedRunIsSanitizedAndBounded() throws {
        let view = TerminalView(frame: NSRect(x: 0, y: 0, width: 900, height: 100))
        view.installColors(TerminalTheme.systemLight.asSwiftTermColors())
        view.nativeForegroundColor = TerminalTheme.systemLight.foreground
        view.nativeBackgroundColor = TerminalTheme.systemLight.background

        var conflicts: [TerminalTextColorConflict] = []
        view.onLowContrastText = { conflicts.append($0) }
        view.getTerminal().feed(
            text: "\u{1b}[97m   compiling\u{200b}   every single one of the workspace targets now"
        )

        let rep = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: rep)

        let sample = try XCTUnwrap(conflicts.first?.sample)
        XCTAssertTrue(sample.hasPrefix("compiling every"), "got \(sample)")
        XCTAssertFalse(sample.unicodeScalars.contains { $0 == "\u{200b}" })
        XCTAssertLessThanOrEqual(
            sample.count,
            TerminalContrastSample.characterLimit + 1,
            "a full-width run reached the band whole"
        )
        XCTAssertEqual(sample.last, TerminalContrastSample.ellipsis)
    }

    /// One collision, however many unreadable words it printed. The quote makes each report
    /// distinct without making it a new finding — the pair is still what was wrong.
    func testASecondUnreadableRunInTheSamePairIsStillOneCollision() throws {
        let view = TerminalView(frame: NSRect(x: 0, y: 0, width: 420, height: 100))
        view.installColors(TerminalTheme.systemLight.asSwiftTermColors())
        view.nativeForegroundColor = TerminalTheme.systemLight.foreground
        view.nativeBackgroundColor = TerminalTheme.systemLight.background

        var conflicts: [TerminalTextColorConflict] = []
        view.onLowContrastText = { conflicts.append($0) }
        view.getTerminal().feed(text: "\u{1b}[97mfirst hidden line\r\nsecond hidden line")

        let rep = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: rep)

        XCTAssertEqual(conflicts.count, 1)
        XCTAssertEqual(conflicts.first?.sample, "first hidden line")
    }

    /// What the pane actually says. The sentence names the run when there is one to name, and
    /// falls back to the colours alone rather than quoting an empty string.
    func testTheExplanationQuotesTheRunWhenTheRendererCouldCaptureOne() {
        let base = TerminalTextColorConflict(
            foregroundSource: .trueColor(red: 0x50, green: 0x50, blue: 0x50),
            backgroundSource: .trueColor(red: 0x46, green: 0x46, blue: 0x46),
            foreground: .init(red: 0x50, green: 0x50, blue: 0x50),
            background: .init(red: 0x46, green: 0x46, blue: 0x46),
            contrastRatio: 1.17,
            sample: "esc to interrupt"
        )
        let quoted = TerminalTextVisibilityIssue(
            identity: .ephemeral(UUID()),
            themeID: "system-dark",
            conflict: base
        )
        let bare = TerminalTextVisibilityIssue(
            identity: quoted.identity,
            themeID: quoted.themeID,
            conflict: TerminalTextColorConflict(
                foregroundSource: base.foregroundSource,
                backgroundSource: base.backgroundSource,
                foreground: base.foreground,
                background: base.background,
                contrastRatio: base.contrastRatio
            )
        )

        XCTAssertTrue(quoted.detail.contains("“esc to interrupt”"), quoted.detail)
        for detail in [quoted.detail, bare.detail] {
            XCTAssertTrue(detail.contains("#505050"), detail)
            XCTAssertTrue(detail.contains("#464646"), detail)
            XCTAssertTrue(detail.contains("1.17:1"), detail)
            XCTAssertTrue(detail.contains("ANSI 39"), detail)
        }
        XCTAssertFalse(bare.detail.contains("“"), bare.detail)

        // A quote is not a new context: the same pair under the same theme stays one dismissal.
        XCTAssertEqual(quoted.signature, bare.signature)
    }

    /// Spaces, ornament, deliberate SGR concealment and default text are not evidence that a
    /// program accidentally selected unreadable ink.
    func testTheVisibilityHeuristicRejectsNoiseAndIntentionalConcealment() throws {
        let view = TerminalView(frame: NSRect(x: 0, y: 0, width: 420, height: 140))
        view.installColors(TerminalTheme.systemLight.asSwiftTermColors())
        view.nativeForegroundColor = TerminalTheme.systemLight.foreground
        view.nativeBackgroundColor = TerminalTheme.systemLight.background

        var conflicts: [TerminalTextColorConflict] = []
        view.onLowContrastText = { conflicts.append($0) }
        view.getTerminal().feed(
            text: "plain text\r\n\u{1b}[97m   \r\n---\r\n\u{1b}[8mlong hidden value"
        )

        let rep = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: rep)

        XCTAssertEqual(conflicts, [])
    }

    func testDismissalIsExactDurableAndBounded() {
        let suite = "TerminalTextVisibilityDismissals.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let dismissals = TerminalTextVisibilityDismissals(defaults: defaults)

        let base = TerminalTextVisibilityIssue(
            identity: .ephemeral(UUID()),
            themeID: "system-light",
            conflict: TerminalTextColorConflict(
                foregroundSource: .ansi256(index: 15),
                backgroundSource: .defaultBackground,
                foreground: .init(red: 255, green: 255, blue: 255),
                background: .init(red: 255, green: 255, blue: 255),
                contrastRatio: 1
            )
        )
        dismissals.dismiss(base)

        XCTAssertTrue(dismissals.contains(base))
        XCTAssertTrue(dismissals.contains(.init(
            identity: .ephemeral(UUID()),
            themeID: base.themeID,
            conflict: base.conflict
        )), "the same exact collision should not nag in every terminal")
        XCTAssertFalse(dismissals.contains(.init(
            identity: base.identity,
            themeID: "another-theme",
            conflict: base.conflict
        )), "a theme change is a new colour context")

        for index in 0..<(TerminalTextVisibilityDismissals.maximumCount + 8) {
            dismissals.dismiss(.init(
                identity: .ephemeral(UUID()),
                themeID: "theme-\(index)",
                conflict: base.conflict
            ))
        }
        XCTAssertEqual(
            defaults.stringArray(forKey: "dismissedTerminalTextVisibilityIssues")?.count,
            TerminalTextVisibilityDismissals.maximumCount
        )
    }

    /// The old palette's diagnosis cannot survive a profile refresh. If the new palette still
    /// collides, SwiftTerm reports it again after drawing; if it fixed the pair, nothing stale
    /// remains for the pane to show.
    func testAProfileRefreshInvalidatesThePreviousVisibilityFinding() {
        let identity = TerminalInstanceIdentity.ephemeral(UUID())
        let session = TerminalSession(profile: .default, identity: identity)
        var invalidated: [TerminalInstanceIdentity] = []
        let observer = NotificationCenter.default.observe(
            TerminalTextVisibilityIssuesInvalidated.self
        ) { event in
            invalidated.append(event.identity)
        }
        defer { NotificationCenter.default.removeObserver(observer) }

        session.increaseFontSize()

        XCTAssertEqual(invalidated, [identity])
    }

    /// A renderer callback deliberately leaves the draw pass before posting its app event. If a
    /// theme lands during that one-turn handoff, the finding belongs to the page just left and
    /// must not repopulate the notice after invalidation.
    func testAProfileRefreshDiscardsAnOldPaletteFindingAlreadyQueuedForDelivery() async {
        let session = TerminalSession(profile: .default)
        var detected: [TerminalTextVisibilityIssue] = []
        let observer = NotificationCenter.default.observe(
            TerminalTextVisibilityIssueDetected.self
        ) { event in
            detected.append(event.issue)
        }
        defer { NotificationCenter.default.removeObserver(observer) }

        session.terminalView.onLowContrastText?(TerminalTextColorConflict(
            foregroundSource: .ansi256(index: 15),
            backgroundSource: .defaultBackground,
            foreground: .init(red: 255, green: 255, blue: 255),
            background: .init(red: 255, green: 255, blue: 255),
            contrastRatio: 1
        ))
        session.increaseFontSize()

        let queueDrained = expectation(description: "queued renderer delivery drained")
        DispatchQueue.main.async { queueDrained.fulfill() }
        await fulfillment(of: [queueDrained], timeout: 1)
        XCTAssertEqual(detected, [])
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

    // MARK: - What the Session Refuses to Pass On

    /// `NO_COLOR` describes a *stream*, and the stream a session hands its child is a PTY that
    /// Threading paints — so an inherited one is always a statement about somewhere else. It
    /// arrives whenever the app is opened from a pipe or from another agent's tool call, both of
    /// which set it alongside `TERM=dumb`; the app already restates `TERM`, so the claim outlived
    /// everything that made it true and nothing contradicted it.
    ///
    /// The visible cost is not colour but *rank*. Claude Code marks its composer's proposed text
    /// with bare SGR 2 (faint) and nothing else, so under `NO_COLOR` a suggestion reaches the
    /// terminal at exactly the strength of text the user typed — which is
    /// `testFaintTextDrawsDimmerThanTypedText`'s bug arriving from the far side, where no
    /// renderer fix can reach it.
    func testAnInheritedNoColourIsNotPassedOn() {
        setenv(EnvironmentKeys.noColor, "1", 1)
        defer { unsetenv(EnvironmentKeys.noColor) }

        XCTAssertNil(
            environment(for: AppThemeStyles.artDeco.terminalPalette)[EnvironmentKeys.noColor],
            "every agent in every session would draw its own chrome unstyled"
        )
    }

    /// `CLICOLOR`/`FORCE_COLOR` mean "off" only when spelled `0`. That spelling goes the same
    /// way as `NO_COLOR`; any other value is the user asking *for* colour and is theirs to keep.
    func testOnlyTheOffSpellingOfAColourVetoIsDropped() {
        setenv("CLICOLOR", "0", 1)
        setenv("FORCE_COLOR", "3", 1)
        defer {
            unsetenv("CLICOLOR")
            unsetenv("FORCE_COLOR")
        }

        let env = environment(for: AppThemeStyles.artDeco.terminalPalette)
        XCTAssertNil(env["CLICOLOR"])
        XCTAssertEqual(env["FORCE_COLOR"], "3", "a request for colour was read as a veto")
    }

    /// A pager set to something that does not page says the same thing `NO_COLOR` does, and it
    /// is equally untrue of a PTY. Only that spelling goes: a real pager is a choice.
    func testAPagerThatCannotPageIsNotPassedOn() {
        setenv("GIT_PAGER", "cat", 1)
        setenv("PAGER", "less -R", 1)
        defer {
            unsetenv("GIT_PAGER")
            unsetenv("PAGER")
        }

        let env = environment(for: AppThemeStyles.artDeco.terminalPalette)
        XCTAssertNil(env["GIT_PAGER"])
        XCTAssertEqual(env["PAGER"], "less -R", "the user's own pager was thrown away")
    }

    /// The headless path has no PTY, so there the same claims are simply true — a stream
    /// nothing is watching should not be paged into, whoever said so.
    func testTheHeadlessPathKeepsTheClaimsThatAreTrueOfIt() {
        setenv("GIT_PAGER", "cat", 1)
        setenv(EnvironmentKeys.noColor, "1", 1)
        defer {
            unsetenv("GIT_PAGER")
            unsetenv(EnvironmentKeys.noColor)
        }

        let env = AgentEnvironment.launchEnvironment()
        XCTAssertEqual(env["GIT_PAGER"], "cat")
        XCTAssertEqual(env[EnvironmentKeys.noColor], "1")
    }

    // MARK: - What the Launcher Was Running Inside

    /// `open` forwards its caller's environment through LaunchServices, so a Threading opened
    /// from an agent's tool call inherits that run's whole posture — and hands it on. The
    /// sandbox is the sharp end: a Codex session launched here was told its network was
    /// disabled by a sandbox that had already ended.
    ///
    /// Listed by family rather than one variable at a time because the gap is silent —
    /// `CODEX_THREAD` was covered and `CODEX_CI` beside it was not.
    func testARunnersOwnPostureIsNotPassedOn() {
        let inherited = [
            "CODEX_SANDBOX_NETWORK_DISABLED": "1",
            "CODEX_PERMISSION_PROFILE": ":workspace",
            "CODEX_CI": "1",
            "CODEX_SHELL": "1",
            "CODEX_THREAD_ID": "019fcb4a-0dd6-7461-87bb-bbb390c848d7",
            "CLAUDE_CODE_SESSION_ID": "b6a0b082-a6fe-4d90-85d6-2ece300c8b41",
            "CLAUDECODE": "1",
            "AI_AGENT": "claude-code_2-1-221_agent"
        ]
        for (key, value) in inherited { setenv(key, value, 1) }
        defer { for key in inherited.keys { unsetenv(key) } }

        let env = environment(for: AppThemeStyles.artDeco.terminalPalette)
        for key in inherited.keys {
            XCTAssertNil(env[key], "\(key) followed its runner into a session it says nothing about")
        }
    }

    /// The exception, and the reason the rule is not simply "drop the whole family": these name
    /// where a login's config lives, which is how a session reaches an account other than the
    /// default. Read from `AgentKind`, so a new runtime arrives already covered.
    func testWhereAnAccountLivesSurvivesTheSameFilter() {
        for key in AgentEnvironment.accountConfigKeys {
            setenv(key, "/tmp/config-\(key)", 1)
        }
        defer { for key in AgentEnvironment.accountConfigKeys { unsetenv(key) } }

        let env = environment(for: AppThemeStyles.artDeco.terminalPalette)
        for key in AgentEnvironment.accountConfigKeys {
            XCTAssertEqual(
                env[key],
                "/tmp/config-\(key)",
                "every session would have been stranded on the default login"
            )
        }
        // One key per runtime that *has* one. Cursor does not: its login is in the system
        // keychain, and pointing either `CURSOR_DATA_DIR` or `XDG_CONFIG_HOME` somewhere else
        // still reports it authenticated — so there is no name here for a launch to set, and an
        // invented one would be an inert exception in the filter above.
        XCTAssertEqual(
            AgentEnvironment.accountConfigKeys.count,
            AgentKind.allCases.filter { $0.accountEnvironmentKey != nil }.count,
            "a runtime that names a config directory has to be exempt from the filter"
        )
        XCTAssertTrue(
            AgentKind.allCases.contains { $0.accountEnvironmentKey == nil },
            "if every runtime names one, this test has stopped covering the optional case"
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

    // MARK: - What the Session Installs

    /// The palette's bold text has to reach the renderer, and a screenshot would not say when
    /// it does not: the view falls back to the foreground whenever this is nil, which is
    /// exactly how every palette drew before the role existed. So the wire is asserted rather
    /// than looked at.
    func testApplyingAProfileInstallsThePalettesBoldText() {
        let (session, _) = makeSession(theme: .ocean)

        XCTAssertEqual(
            session.terminalView.nativeBoldForegroundColor?.hexString,
            TerminalTheme.ocean.boldForeground.hexString
        )
        XCTAssertNotEqual(
            session.terminalView.nativeBoldForegroundColor?.hexString,
            TerminalTheme.ocean.foreground.hexString,
            "the fixture palette has to state a bold colour of its own to prove anything"
        )
    }

    /// And it follows a theme change, including onto a palette that draws its headings in the
    /// body's own ink — the state the property must be *put back into*, not merely left in.
    func testSwitchingToAPaletteWhoseBoldIsItsBodyMovesTheViewToThatColour() {
        let (session, _) = makeSession(theme: .ocean)

        var flat = TerminalTheme.basic
        flat.boldForeground = flat.foreground
        var profile = TerminalProfile.default
        profile.theme = flat
        session.updateProfile(profile)

        XCTAssertEqual(
            session.terminalView.nativeBoldForegroundColor?.hexString,
            flat.foreground.hexString
        )
    }

    // MARK: - The Program That Only Re-Reads on Focus

    /// Codex does not implement `DECSET 2031`, so the announcement above reaches it not at all.
    /// It re-reads `OSC 10/11` when it is told focus was gained instead, which makes a focus
    /// report the only prompt it can hear. Measured in a bare PTY: 0.146.0 answers one with a
    /// fresh colour query and repaints; 0.147.0 removed that path. Filed as openai/codex#18942
    /// and openai/codex#38575, and **this whole section goes away when they are answered.**
    func testAProgramThatOnlyRereadsOnFocusIsPromptedByASwitch() {
        let (session, sent) = makeSession(theme: AppThemeStyles.bauhaus.terminalPalette)
        // Focus reports the way Codex asks for them, and no 2031 subscription at all.
        session.terminalView.getTerminal().feed(text: "\u{1b}[?1004h")
        session.terminalView.hasFocus = true

        var profile = TerminalProfile.default
        profile.theme = AppThemeStyles.artDeco.terminalPalette
        session.updateProfile(profile)

        XCTAssertEqual(
            sent.text,
            "\u{1b}[I",
            "the one prompt this program can hear was not sent"
        )
    }

    /// The prompt is a focus report, so it must not reach a program that never asked for focus
    /// reports: to that one the same bytes are keystrokes.
    func testAProgramThatNeverAskedForFocusReportsIsNotPrompted() {
        let (session, sent) = makeSession(theme: AppThemeStyles.bauhaus.terminalPalette)
        session.terminalView.hasFocus = true

        var profile = TerminalProfile.default
        profile.theme = AppThemeStyles.artDeco.terminalPalette
        session.updateProfile(profile)

        XCTAssertEqual(sent.text, "", "a program that never opted in was sent input")
    }

    func testAReapplyOfTheSamePagePromptsNoReread() {
        let (session, sent) = makeSession(theme: AppThemeStyles.bauhaus.terminalPalette)
        session.terminalView.getTerminal().feed(text: "\u{1b}[?1004h")
        session.terminalView.hasFocus = true

        var profile = TerminalProfile.default
        profile.theme = AppThemeStyles.bauhaus.terminalPalette
        profile.fontSize += 1
        session.updateProfile(profile)

        XCTAssertEqual(sent.text, "", "a font tweak read as the page turning")
    }

    /// A focus report is a statement about where the user is looking, so it may only be sent
    /// when it is true. A theme that moves behind the app — macOS going dark at sunset under an
    /// adaptive theme — must therefore wait rather than lie, and SwiftTerm reports focus from
    /// the responder hooks alone, so a window becoming key again emits nothing by itself.
    func testTheFocusPromptWaitsForTheTerminalToBeLookedAtAgain() async {
        let (session, sent) = makeSession(theme: AppThemeStyles.bauhaus.terminalPalette)
        session.terminalView.getTerminal().feed(text: "\u{1b}[?1004h")
        session.terminalView.hasFocus = false

        var profile = TerminalProfile.default
        profile.theme = AppThemeStyles.artDeco.terminalPalette
        session.updateProfile(profile)

        XCTAssertEqual(sent.text, "", "an unfocused terminal claimed the user was looking at it")

        session.terminalView.hasFocus = true
        postKeyWindow()

        let delivered = await promptDelivered(to: sent)
        XCTAssertEqual(
            delivered,
            "\u{1b}[I",
            "the carried prompt never arrived, so the palette stayed stale"
        )
    }

    /// One switch is one prompt. Coming back to the window later is not itself news.
    func testTheCarriedPromptIsSentOnceAndNotOnEveryReturn() async {
        let (session, sent) = makeSession(theme: AppThemeStyles.bauhaus.terminalPalette)
        session.terminalView.getTerminal().feed(text: "\u{1b}[?1004h")
        session.terminalView.hasFocus = false

        var profile = TerminalProfile.default
        profile.theme = AppThemeStyles.artDeco.terminalPalette
        session.updateProfile(profile)

        session.terminalView.hasFocus = true
        postKeyWindow()

        let delivered = await promptDelivered(to: sent)
        XCTAssertEqual(delivered, "\u{1b}[I", "nothing was carried, so this proves nothing below")
        sent.bytes.removeAll()

        postKeyWindow()
        await settleMainQueue()

        XCTAssertEqual(sent.text, "", "every window activation turned into a synthetic focus")
    }

    /// A session applies its palette once on the way up, where the background moves off
    /// SwiftTerm's own default and there is no program yet to prompt. Arming there would leave
    /// every session holding a prompt it spends on the first window activation, for a switch
    /// that never happened.
    func testAFreshSessionCarriesNoPromptForItsOwnFirstPalette() async {
        let (session, sent) = makeSession(theme: AppThemeStyles.bauhaus.terminalPalette)
        session.terminalView.getTerminal().feed(text: "\u{1b}[?1004h")
        session.terminalView.hasFocus = true

        postKeyWindow()
        await settleMainQueue()

        XCTAssertEqual(sent.text, "", "a session prompted a re-read of the palette it started on")
    }

    /// Says a window became key, *naming one*.
    ///
    /// AppKit never posts this with no object, and its own machinery is entitled to assume one.
    /// Broadcasting it with `nil` reached whatever was live in a full run and aborted the test
    /// host inside the next async teardown, while passing for this class on its own — the shape
    /// of a fixture that only misbehaves once the process has a window in it. The window is
    /// never ordered on screen and is held for the length of the post, which is all the
    /// notification needs it for.
    private func postKeyWindow() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 100, height: 100),
            styleMask: [.titled],
            backing: .buffered,
            defer: true
        )
        NotificationCenter.default.post(name: NSWindow.didBecomeKeyNotification, object: window)
        withExtendedLifetime(window) {}
    }

    /// The observer runs on the main queue, so a post is not yet a delivery — and under a full
    /// run that queue has other work in front of it, which is what made waiting exactly one turn
    /// pass alone and fail in the suite. Waits for the prompt itself rather than for a turn.
    private func promptDelivered(to sent: SentBytes) async -> String {
        for _ in 0..<20 {
            if !sent.bytes.isEmpty { break }
            await drainMainQueue()
        }
        return sent.text
    }

    /// Absence cannot be waited for, so give the queue several turns before believing it.
    private func settleMainQueue() async {
        for _ in 0..<3 {
            await drainMainQueue()
        }
    }

    private func drainMainQueue() async {
        let drained = expectation(description: "main queue drained")
        OperationQueue.main.addOperation { drained.fulfill() }
        await fulfillment(of: [drained], timeout: 1)
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
