import AppKit
import SwiftTerm
import XCTest
@testable import Threading

/// Draws the notice band at a pane's width and writes each state out as an image — System light
/// and dark plus the two deliberately different stock themes, per the component contract in
/// `docs/THEME_BOUNDARY.md`.
///
/// `PaneNoticeTests` pins the arithmetic; these pin what the arithmetic is for. The band's whole
/// job is to be read once and then answered, and the things that would stop it doing that — a
/// warning mark that disappears into the ground it is drawn on, a sentence that meets the button
/// answering it, a second row of chrome that reads as furniture rather than as news — are visible
/// in a picture and in no assertion anyone would have written.
@MainActor
final class PaneNoticeRenderTests: XCTestCase {

    // MARK: - Configuration

    private enum Render {
        static var directory: URL {
            if let override = ProcessInfo.processInfo.environment["THREADING_RENDER_OUT"],
               !override.isEmpty {
                return URL(fileURLWithPath: override)
            }
            return URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("ThreadingRenders", isDirectory: true)
        }

        static let appearances: [(name: String, appearance: NSAppearance.Name)] = [
            ("light", .aqua),
            ("dark", .darkAqua)
        ]

        static let themes: [(name: String, theme: AppTheme)] = [
            ("system", .system),
            ("cyberpunk", AppThemeStyles.cyberpunk),
            ("swiss", AppThemeStyles.swissMinimalist)
        ]

        /// A conversation pane at a width the window opens near.
        static let paneWidth: CGFloat = 760
        /// Narrow enough that the sentence has to give way, which is the state the band is most
        /// likely to be wrong in.
        static let narrowPaneWidth: CGFloat = 360
    }

    override func tearDown() {
        AppThemePalette.set(.system)
        super.tearDown()
    }

    // MARK: - Stories

    /// The band exactly as `MainWindowController.presentUncleanExitNotice` puts it up when macOS
    /// filed a report: the sentence, Restore, Show Crash Report, private reporting, and the way
    /// out.
    func testRendersTheUncleanExitNoticeStorybook() throws {
        try writeStorybook(named: "notice-unclean") {
            PaneNoticeView(
                tone: .attention,
                message: L10n.string(
                    "Threading quit unexpectedly last time. Its open session and browser windows "
                        + "were not reopened."
                ),
                actions: [
                    PaneNoticeAction(title: L10n.string("Restore")) {},
                    PaneNoticeAction(
                        title: L10n.string("Send to Developer"),
                        emphasis: .secondary
                    ) {},
                    PaneNoticeAction(
                        title: L10n.string("Show Crash Report"),
                        emphasis: .tertiary
                    ) {}
                ],
                onDismiss: {}
            )
        }
    }

    /// A kill, a power cut, or a report the system has not filed: the same band with nothing to
    /// reveal, which must not leave a gap where the second button was.
    func testRendersTheUncleanExitNoticeWithNoReportToPointAt() throws {
        try writeStorybook(named: "notice-unclean-noreport") {
            PaneNoticeView(
                tone: .attention,
                message: L10n.string(
                    "Threading quit unexpectedly last time. Its open session and browser windows "
                        + "were not reopened."
                ),
                actions: [
                    PaneNoticeAction(title: L10n.string("Restore")) {},
                    PaneNoticeAction(
                        title: L10n.string("Send to Developer"),
                        emphasis: .secondary
                    ) {}
                ],
                onDismiss: {}
            )
        }
    }

    /// The launch band the background host puts up: agents kept working while Threading was
    /// closed, and one of them has not been taken back yet.
    ///
    /// The informational tone is the point of the picture. Nothing went wrong — this is the
    /// feature working — so the band has to read as news rather than as a warning, while still
    /// carrying an answer somebody is meant to press.
    func testRendersTheBackgroundHostLaunchBand() throws {
        let notice = PTYHostLaunchNotice.keptRunning(count: 3, pending: 1)
        try writeStorybook(named: "notice-ptyhost-kept") {
            PaneNoticeView(
                tone: notice.isAttention ? .attention : .informational,
                message: notice.message,
                actions: [PaneNoticeAction(title: notice.actionTitle ?? "") {}],
                onDismiss: {}
            )
        }
    }

    /// The other half of the same surface: a restarted daemon could not account for a session,
    /// which is the one thing about the background host that *did* go wrong.
    ///
    /// Drawn beside the band above deliberately: the two say almost the same sentence and have to
    /// be tellable apart at a glance, which is what the tone and the mark are for.
    func testRendersTheBackgroundHostLostBand() throws {
        let notice = PTYHostLaunchNotice.lost([SessionID(), SessionID()])
        try writeStorybook(named: "notice-ptyhost-lost") {
            PaneNoticeView(
                tone: notice.isAttention ? .attention : .informational,
                message: notice.message,
                actions: [PaneNoticeAction(title: notice.actionTitle ?? "") {}],
                onDismiss: {}
            )
        }
    }

    /// The quieter tone, where the mark is the secondary ink rather than the warning one — the
    /// pair of images is how the two are checked for being tellable apart.
    func testRendersTheInformationalTone() throws {
        try writeStorybook(named: "notice-informational") {
            PaneNoticeView(
                tone: .informational,
                message: "This conversation was imported and is read only.",
                actions: [],
                onDismiss: {}
            )
        }
    }

    /// The band in a pane too narrow for both halves, where the sentence wraps and then
    /// truncates rather than taking room from the control that answers it.
    func testRendersTheNoticeInAPaneTooNarrowForBothHalves() throws {
        try writeStorybook(named: "notice-narrow", width: Render.narrowPaneWidth) {
            PaneNoticeView(
                tone: .attention,
                message: L10n.string(
                    "Threading quit unexpectedly last time. Its open session and browser windows "
                        + "were not reopened."
                ),
                actions: [PaneNoticeAction(title: L10n.string("Restore")) {}],
                onDismiss: {}
            )
        }
    }

    /// The reported failure in context: System Light's ANSI bright white and terminal
    /// background are both #FFFFFF. The blank inside the prompt is intentional evidence in the
    /// picture; the band above it has to explain that evidence without pretending the emulator
    /// may rewrite a program's colour choice.
    func testRendersTheTerminalTextVisibilityWarningInItsPane() throws {
        let directory = Render.directory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { AppThemePalette.set(.system) }

        let issue = TerminalTextVisibilityIssue(
            identity: .ephemeral(UUID()),
            themeID: TerminalTheme.systemLight.id.rawValue,
            conflict: TerminalTextColorConflict(
                foregroundSource: .ansi256(index: 15),
                backgroundSource: .defaultBackground,
                foreground: .init(red: 255, green: 255, blue: 255),
                background: .init(red: 255, green: 255, blue: 255),
                contrastRatio: 1,
                sample: "[last: 23s]"
            )
        )

        var written = 0
        for (themeName, theme) in Render.themes {
            AppThemePalette.set(theme)
            for (appearanceName, appearanceID) in Render.appearances {
                let data = try XCTUnwrap(
                    terminalVisibilityImage(appearance: appearanceID, issue: issue),
                    "Failed to render the terminal warning under \(themeName) in \(appearanceName)"
                )
                try data.write(
                    to: directory.appendingPathComponent(
                        "notice-terminal-text-visibility-\(themeName)-\(appearanceName).png"
                    )
                )
                written += 1
            }
        }

        XCTAssertEqual(written, Render.themes.count * Render.appearances.count)
        print("Rendered terminal text visibility storybook to \(directory.path)")
    }

    /// The pair from the field report, which is the harder case to draw: two 24-bit greys four
    /// steps apart. The sentence can only spell them out as two different hex values; the
    /// specimen is where they are visibly one field, and the quoted run is what the reader can
    /// go and look for in the terminal below.
    func testRendersTheNearCollapsedColourPairStorybook() throws {
        let issue = TerminalTextVisibilityIssue(
            identity: .ephemeral(UUID()),
            themeID: TerminalTheme.systemDark.id.rawValue,
            conflict: TerminalTextColorConflict(
                foregroundSource: .trueColor(red: 0x50, green: 0x50, blue: 0x50),
                backgroundSource: .trueColor(red: 0x46, green: 0x46, blue: 0x46),
                foreground: .init(red: 0x50, green: 0x50, blue: 0x50),
                background: .init(red: 0x46, green: 0x46, blue: 0x46),
                contrastRatio: 1.17,
                sample: "esc to interrupt"
            )
        )

        try writeStorybook(named: "notice-color-pair") {
            PaneNoticeView(
                tone: .attention,
                title: issue.title,
                message: issue.detail,
                accessory: ColorPairSpecimenView(
                    ink: issue.foregroundColor,
                    ground: issue.backgroundColor,
                    caption: L10n.string("As drawn"),
                    accessibilityLabel: issue.specimenLabel
                ),
                actions: [PaneNoticeAction(title: L10n.string("Change Theme…")) {}],
                onDismiss: {}
            )
        }
    }

    // MARK: - Helpers

    private func writeStorybook(
        named name: String,
        width: CGFloat = Render.paneWidth,
        build: @escaping @MainActor () -> PaneNoticeView
    ) throws {
        let directory = Render.directory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        defer { AppThemePalette.set(.system) }

        var written = 0
        for (themeName, theme) in Render.themes {
            AppThemePalette.set(theme)
            for (appearanceName, appearanceID) in Render.appearances {
                let data = try XCTUnwrap(
                    noticeImage(appearance: appearanceID, width: width, build: build),
                    "Failed to render \(name) under \(themeName) in \(appearanceName)"
                )
                try data.write(
                    to: directory.appendingPathComponent(
                        "\(name)-\(themeName)-\(appearanceName).png"
                    )
                )
                written += 1
            }
        }

        XCTAssertEqual(written, Render.themes.count * Render.appearances.count)
        print("Rendered \(name) storybook to \(directory.path)")
    }

    /// The band's exact position in the pane: under the header strip, above the content, drawn on
    /// the pane's own ground so the hairline it folds on is visible against what it separates.
    private func noticeImage(
        appearance name: NSAppearance.Name,
        width: CGFloat,
        build: @escaping @MainActor () -> PaneNoticeView
    ) -> Data? {
        let appearance = NSAppearance(named: name)

        var data: Data?
        let render: @MainActor () -> Void = {
            let notice = build()

            let host = ThemedSurfaceView()
            host.frame = NSRect(
                x: 0,
                y: 0,
                width: width,
                height: PaneNoticeDefaults.bandHeight * 2
            )
            host.applySurface(fill: Design.Surface.ground, radius: .fixed(0))
            // Without this the offscreen draw comes out blank: `cacheDisplay` resolves dynamic
            // colours against the host's appearance, and a host with none has nothing to resolve.
            host.appearance = appearance
            host.addSubview(notice)

            NSLayoutConstraint.activate([
                host.widthAnchor.constraint(equalToConstant: width),
                host.heightAnchor.constraint(
                    equalToConstant: PaneNoticeDefaults.bandHeight * 2
                ),
                notice.leadingAnchor.constraint(equalTo: host.leadingAnchor),
                notice.trailingAnchor.constraint(equalTo: host.trailingAnchor),
                notice.topAnchor.constraint(equalTo: host.topAnchor)
            ])
            AppThemeRefresh.repaint(host)
            host.layoutSubtreeIfNeeded()

            guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return }
            host.cacheDisplay(in: host.bounds, to: rep)
            data = rep.representation(using: .png, properties: [:])
        }

        if let appearance {
            appearance.performAsCurrentDrawingAppearance {
                MainActor.assumeIsolated(render)
            }
        }
        return data
    }

    /// Uses a real SwiftTerm view, not a painted stand-in, so the storybook preserves the exact
    /// invisible run that caused the notice: `[last: 23s]` exists between `$` and `master`, but
    /// ANSI bright white makes it white on the System Light palette's white background.
    private func terminalVisibilityImage(
        appearance name: NSAppearance.Name,
        issue: TerminalTextVisibilityIssue
    ) -> Data? {
        let appearance = NSAppearance(named: name)

        var data: Data?
        let render: @MainActor () -> Void = {
            let notice = PaneNoticeView(
                tone: .attention,
                title: issue.title,
                message: issue.detail,
                accessory: ColorPairSpecimenView(
                    ink: issue.foregroundColor,
                    ground: issue.backgroundColor,
                    caption: L10n.string("As drawn"),
                    accessibilityLabel: issue.specimenLabel
                ),
                actions: [PaneNoticeAction(title: L10n.string("Change Theme…")) {}],
                onDismiss: {}
            )
            let terminal = TerminalView(frame: .zero)
            terminal.translatesAutoresizingMaskIntoConstraints = false
            terminal.font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
            terminal.installColors(TerminalTheme.systemLight.asSwiftTermColors())
            terminal.nativeForegroundColor = TerminalTheme.systemLight.foreground
            terminal.nativeBackgroundColor = TerminalTheme.systemLight.background
            terminal.feed(
                text: "\r\n$ \u{1b}[97m[last: 23s]\u{1b}[0m  "
                    + "\u{1b}[33mmaster\u{1b}[0m  "
                    + "\u{1b}[34m~/repo/AnotherTerminal\u{1b}[0m\r\n$ "
            )

            let host = ThemedSurfaceView()
            host.frame = NSRect(x: 0, y: 0, width: Render.paneWidth, height: 280)
            host.applySurface(fill: Design.Surface.ground, radius: .fixed(0))
            host.appearance = appearance
            host.addSubview(notice)
            host.addSubview(terminal)

            NSLayoutConstraint.activate([
                host.widthAnchor.constraint(equalToConstant: Render.paneWidth),
                host.heightAnchor.constraint(equalToConstant: 280),
                notice.leadingAnchor.constraint(equalTo: host.leadingAnchor),
                notice.trailingAnchor.constraint(equalTo: host.trailingAnchor),
                notice.topAnchor.constraint(equalTo: host.topAnchor),
                terminal.leadingAnchor.constraint(equalTo: host.leadingAnchor),
                terminal.trailingAnchor.constraint(equalTo: host.trailingAnchor),
                terminal.topAnchor.constraint(equalTo: notice.bottomAnchor),
                terminal.bottomAnchor.constraint(equalTo: host.bottomAnchor)
            ])
            AppThemeRefresh.repaint(host)
            host.layoutSubtreeIfNeeded()

            guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return }
            host.cacheDisplay(in: host.bounds, to: rep)
            data = rep.representation(using: .png, properties: [:])
        }

        if let appearance {
            appearance.performAsCurrentDrawingAppearance {
                MainActor.assumeIsolated(render)
            }
        }
        return data
    }
}
