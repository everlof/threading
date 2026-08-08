import AppKit
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
            if let override = ProcessInfo.processInfo.environment["THREADING_RENDER_OUT"] {
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
    /// filed a report: the sentence, Restore, Show Crash Report, and the way out.
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
                actions: [PaneNoticeAction(title: L10n.string("Restore")) {}],
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
}
