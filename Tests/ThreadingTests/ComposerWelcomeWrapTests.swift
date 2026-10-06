import AppKit
import XCTest
@testable import Threading

/// A theme's greeting may run to 160 characters, and the composer's hero wraps it: to the pane
/// between its side margins, never wider than a reading measure, at most three lines for the
/// greeting and two for the caption. Pinned here: the wrapped lines fit that measure in a narrow
/// and a wide pane, the hero still hides when the pane is too short for its *wrapped* height,
/// the manager's brief keeps its own three lines, and the composer itself — light and dark,
/// narrow and wide — rendered to `THREADING_RENDER_OUT` as `composer-welcome-wrap-*.png`.
@MainActor
final class ComposerWelcomeWrapTests: HostedStoreTestCase {

    private enum Fixture {
        static let narrow = NSSize(width: 480, height: 640)
        static let wide = NSSize(width: 1280, height: 640)

        static let greeting = "Wake up, {user}. The Matrix has you, and so does a build queue "
            + "with eleven red jobs and a review nobody has read since Thursday."
        static let caption = "{working} sessions are working and {waiting} are waiting on you, "
            + "so start with the one that has been waiting the longest."
        static let shortGreeting = "Evening, {user}."

        static let ellipsis = "\u{2026}"
    }

    override func setUp() async throws {
        try await super.setUp()
        // Lines land at once rather than morphing, so a test reads what is up.
        Design.Motion.reduceMotionOverrideForTesting = true
    }

    /// The theme goes back to the one the app launches into. Synchronous, like the welcome
    /// tests beside it, so the hosted store's own asynchronous teardown runs after it.
    override func tearDown() {
        MainActor.assumeIsolated {
            AppThemeLibrary.apply(AppThemeLibrary.defaultTheme)
            Design.Motion.reduceMotionOverrideForTesting = nil
        }
        super.tearDown()
    }

    // MARK: - Measure

    /// In a narrow pane the greeting wraps to the room between the margins and stops at three
    /// lines, the last one truncated; in a wide one it wraps to the reading measure instead of
    /// running across the pane, and the whole sentence fits. Either way every line fits the
    /// measure, the block stays inside the pane's margins, and it stays centred over the box.
    func testALongThemedGreetingWrapsToTheHerosMeasure() throws {
        AppThemeLibrary.apply(try longWelcomeTheme())

        for size in [Fixture.narrow, Fixture.wide] {
            let composer = makeComposer()
            let host = host(composer, size: size)
            composer.show(projectID: nil)
            host.layoutSubtreeIfNeeded()

            let measure = min(
                size.width - Design.Spacing.pane * 2,
                ComposerDefaults.heroMeasure
            )
            let greeting = try greeting(in: composer)
            let caption = try caption(in: composer)
            XCTAssertEqual(greeting.wrapWidth, measure.rounded(.down), "\(size)")
            XCTAssertEqual(caption.wrapWidth, measure.rounded(.down), "\(size)")
            XCTAssertTrue(greeting.stringValue.hasPrefix("Wake up, Ada."), greeting.stringValue)

            let lines = greeting.presentedLines
            XCTAssertGreaterThan(lines.count, 1, "\(size): \(lines)")
            XCTAssertLessThanOrEqual(lines.count, ComposerDefaults.greetingMaximumLines)
            XCTAssertLessThanOrEqual(
                caption.presentedLines.count,
                ComposerDefaults.captionMaximumLines
            )
            for block in [greeting, caption] {
                for line in drawnLines(of: block) {
                    XCTAssertLessThanOrEqual(
                        line.naturalWidth(of: line.stringValue),
                        measure,
                        "\(size): '\(line.stringValue)' is wider than the hero's measure"
                    )
                    XCTAssertGreaterThanOrEqual(
                        line.bounds.width,
                        line.naturalWidth(of: line.stringValue),
                        "\(size): '\(line.stringValue)' is drawn truncated by its own block"
                    )
                }
                let frame = composer.view.convert(block.bounds, from: block)
                XCTAssertGreaterThanOrEqual(frame.minX, Design.Spacing.pane - 0.5, "\(size)")
                XCTAssertLessThanOrEqual(
                    frame.maxX,
                    composer.view.bounds.maxX - Design.Spacing.pane + 0.5,
                    "\(size)"
                )
                XCTAssertEqual(frame.midX, composer.view.bounds.midX, accuracy: 0.5, "\(size)")
            }
            XCTAssertEqual(
                greeting.frame.height,
                CGFloat(lines.count) * Design.Typography.lineHeight(
                    of: try XCTUnwrap(greeting.appliedRoleFont)
                ),
                accuracy: 1,
                "\(size): the block is not as tall as the lines it wrapped to"
            )

            if size == Fixture.narrow {
                XCTAssertEqual(lines.count, ComposerDefaults.greetingMaximumLines, "\(lines)")
                XCTAssertTrue(lines.last?.hasSuffix(Fixture.ellipsis) ?? false, "\(lines)")
            } else {
                XCTAssertFalse(
                    lines.contains { $0.hasSuffix(Fixture.ellipsis) },
                    "the reading measure had room for the whole greeting: \(lines)"
                )
                XCTAssertEqual(
                    lines.joined(separator: " "),
                    greeting.stringValue,
                    "a wrapped greeting lost words"
                )
            }
        }
    }

    /// Narrowing the pane re-wraps the greeting, and widening it gives the lines back.
    func testResizingThePaneRewrapsTheGreeting() throws {
        AppThemeLibrary.apply(try longWelcomeTheme())
        let composer = makeComposer()
        let host = host(composer, size: Fixture.wide)
        composer.show(projectID: nil)
        host.layoutSubtreeIfNeeded()
        let greeting = try greeting(in: composer)
        let wide = greeting.presentedLines

        host.setFrameSize(Fixture.narrow)
        host.layoutSubtreeIfNeeded()
        XCTAssertNotEqual(greeting.presentedLines, wide)
        XCTAssertEqual(greeting.wrapWidth, Fixture.narrow.width - Design.Spacing.pane * 2)

        host.setFrameSize(Fixture.wide)
        host.layoutSubtreeIfNeeded()
        XCTAssertEqual(greeting.presentedLines, wide)
    }

    // MARK: - Hiding

    /// The hero hides on the height of the lines it *wrapped* to. Grown from too short to tall,
    /// a composer whose greeting wraps to three lines shows its hero later than one whose
    /// greeting is a single line under the same caption — a greeting judged on one truncated
    /// line would show at the same height — and wherever it does show, it floats clear of the
    /// box with every one of those lines laid out.
    func testTheHeroHidesOnTheHeightOfItsWrappedLines() throws {
        let heights = Array(stride(from: CGFloat(300), through: 700, by: 10))

        AppThemeLibrary.apply(try longWelcomeTheme())
        let long = try visibility(
            across: heights,
            expectingLines: ComposerDefaults.greetingMaximumLines
        )

        AppThemeLibrary.apply(try longWelcomeTheme(greeting: Fixture.shortGreeting))
        let short = try visibility(across: heights, expectingLines: 1)

        let firstLong = try XCTUnwrap(long.firstIndex(of: true), "the tall pane never floated it")
        let firstShort = try XCTUnwrap(short.firstIndex(of: true))
        XCTAssertGreaterThan(
            firstLong,
            firstShort,
            "a three-line hero was judged on the room a one-line hero needs"
        )
        XCTAssertFalse(long[firstLong...].contains(false), "the hero flickered as the pane grew")
    }

    // MARK: - The brief

    /// The manager's brief keeps its three authored lines, even under a measure narrow enough
    /// that the greeting's wrapping would re-break them — and the chat's greeting wraps again on
    /// return.
    func testTheManagersBriefKeepsItsOwnLines() throws {
        AppThemeLibrary.apply(try longWelcomeTheme())
        let composer = makeComposer()
        let host = host(composer, size: Fixture.narrow)
        composer.show(projectID: nil)
        host.layoutSubtreeIfNeeded()
        let greeting = try greeting(in: composer)
        let wrapped = greeting.presentedLines
        XCTAssertEqual(wrapped.count, ComposerDefaults.greetingMaximumLines)

        let brief = ComposerDefaults.managerGreeting.components(separatedBy: "\n")
        composer.presetManagerRole()
        host.layoutSubtreeIfNeeded()
        XCTAssertEqual(greeting.wrapping, .none)
        XCTAssertEqual(greeting.presentedLines, brief)

        // A measure narrower than every line of the brief — what a pane too narrow for the
        // column would state — still leaves the brief its own three lines.
        greeting.wrapWidth = ComposerDefaults.heroMarkSide
        XCTAssertEqual(greeting.presentedLines, brief)

        composer.selectedRole = .chat
        composer.refreshChips()
        host.layoutSubtreeIfNeeded()
        XCTAssertEqual(greeting.wrapping, .words(maximumLines: ComposerDefaults.greetingMaximumLines))
        XCTAssertEqual(greeting.presentedLines, wrapped)
    }

    // MARK: - Renders

    /// The long themed greeting and caption in a narrow and a wide pane, light and dark, over a
    /// wash with both veils, so the picture shows the wrap, the cap's ellipsis, the reading
    /// measure in a wide pane and the hero's veil covering every wrapped line.
    func testRendersALongThemedGreetingInANarrowAndAWidePane() throws {
        let directory = ThemeWelcomeFixtures.renderDirectory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        AppThemeLibrary.apply(try longWelcomeTheme(dressed: true))

        var written = 0
        for (label, size) in [("narrow", Fixture.narrow), ("wide", Fixture.wide)] {
            for (suffix, appearanceName) in [
                ("light", NSAppearance.Name.aqua),
                ("dark", NSAppearance.Name.darkAqua)
            ] {
                let appearance = try XCTUnwrap(NSAppearance(named: appearanceName))
                let composer = makeComposer()
                let renderHost = host(composer, size: size)
                renderHost.appearance = appearance
                AppThemeRefresh.repaint(renderHost)
                composer.show(projectID: nil)

                var data: Data?
                appearance.performAsCurrentDrawingAppearance {
                    renderHost.layoutSubtreeIfNeeded()
                    composer.view.layoutSubtreeIfNeeded()
                    guard let rep = renderHost.bitmapImageRepForCachingDisplay(
                        in: renderHost.bounds
                    ) else { return }
                    renderHost.wantsLayer = true
                    renderHost.layer?.backgroundColor = AppThemePalette.current
                        .resolved(.ground, appearance: appearance).cgColor
                    renderHost.cacheDisplay(in: renderHost.bounds, to: rep)
                    data = rep.representation(using: .png, properties: [:])
                }

                let greeting = try greeting(in: composer)
                XCTAssertFalse(greeting.isHiddenOrHasHiddenAncestor, "\(label) \(suffix)")
                XCTAssertGreaterThan(greeting.presentedLines.count, 1, "\(label) \(suffix)")
                // The veil behind the hero is told the frame of the wrapped hero.
                let hero = try XCTUnwrap(greeting.superview)
                let scrim = try XCTUnwrap(
                    composer.view.subviews.compactMap { $0 as? ThemeWelcomeScrimView }.first
                )
                let heroFrame = scrim.convert(hero.bounds, from: hero)
                XCTAssertEqual(scrim.heroRegion.height, heroFrame.height, accuracy: 0.5)
                XCTAssertEqual(scrim.heroRegion.minY, heroFrame.minY, accuracy: 0.5)

                try XCTUnwrap(data, "\(label) \(suffix)").write(to: directory.appendingPathComponent(
                    "composer-welcome-wrap-\(label)-\(suffix).png"
                ))
                written += 1
            }
        }
        print("Rendered \(written) wrapped welcomes to \(directory.path)")
        XCTAssertEqual(written, 4)
    }

    // MARK: - Fixtures

    private var longWelcomeStyle: ThemeWelcome.TextStyle {
        ThemeWelcome.TextStyle(scale: 1.3, weight: .bold, ink: .role(.accent), typeface: .rounded)
    }

    /// The long greeting and caption — the kind of line a theme may now write — optionally over
    /// a wash with both veils.
    private func longWelcomeTheme(
        greeting: String = Fixture.greeting,
        dressed: Bool = false
    ) throws -> AppTheme {
        let dark = NSAppearance(named: .darkAqua) ?? NSAppearance.currentDrawing()
        let deep = AppThemeStyles.threading.resolved(.accent, appearance: dark)
        return try ThemeWelcomeFixtures.theme(ThemeWelcome(
            backdrop: dressed ? ThemeBackdrop(gradient: ThemeBackdrop.Gradient(
                stops: [
                    .init(color: Design.Surface.ground, position: 0),
                    .init(color: deep.withAlphaComponent(0.55), position: 1)
                ],
                angleDegrees: 165
            )) : nil,
            greeting: ThemeWelcome.Wording(
                lines: [.init(text: greeting)],
                style: longWelcomeStyle
            ),
            caption: ThemeWelcome.Wording(
                lines: [.init(text: Fixture.caption)],
                style: ThemeWelcome.TextStyle(ink: .role(.secondaryLabel))
            ),
            scrim: dressed ? ThemeWelcome.Scrim(hero: 0.55, prompt: 0.7) : nil
        ))
    }

    /// Whether the hero floats at each of `heights` in a 480-point pane, grown from the first.
    /// Wherever it does, it is checked for what the decision promised: every wrapped line laid
    /// out, and clear of the column by at least half the clearance on its lower side.
    private func visibility(
        across heights: [CGFloat],
        expectingLines lines: Int
    ) throws -> [Bool] {
        let composer = makeComposer()
        let host = host(composer, size: NSSize(width: Fixture.narrow.width, height: heights[0]))
        composer.show(projectID: nil)
        let greeting = try greeting(in: composer)
        let hero = try XCTUnwrap(greeting.superview)
        let box = composer.promptHandoffView
        let column = try XCTUnwrap(
            composer.view.subviews.first { box.isDescendant(of: $0) && $0 !== hero }
        )

        return heights.map { height in
            host.setFrameSize(NSSize(width: Fixture.narrow.width, height: height))
            host.layoutSubtreeIfNeeded()
            let shown = !hero.isHiddenOrHasHiddenAncestor
            guard shown else { return false }
            XCTAssertEqual(greeting.presentedLines.count, lines, "\(height)")
            XCTAssertEqual(
                hero.frame.height,
                hero.fittingSize.height,
                accuracy: 0.5,
                "\(height): the hero is laid out at a different height than it was judged on"
            )
            XCTAssertGreaterThanOrEqual(
                hero.frame.minY - column.frame.maxY,
                ComposerDefaults.heroMinimumClearance / 2 - 0.5,
                "\(height): the hero crowds the box"
            )
            return true
        }
    }

    private func makeComposer() -> SessionComposerViewController {
        SessionComposerViewController(
            newSessionAccountHandle: { _ in .standard },
            welcomeEnvironment: ThemeWelcomeFixtures.Clock().environment()
        )
    }

    private func host(_ composer: SessionComposerViewController, size: NSSize) -> NSView {
        let host = NSView(frame: NSRect(origin: .zero, size: size))
        let view = composer.view
        view.translatesAutoresizingMaskIntoConstraints = false
        host.addSubview(view)
        NSLayoutConstraint.activate([
            view.topAnchor.constraint(equalTo: host.topAnchor),
            view.bottomAnchor.constraint(equalTo: host.bottomAnchor),
            view.leadingAnchor.constraint(equalTo: host.leadingAnchor),
            view.trailingAnchor.constraint(equalTo: host.trailingAnchor)
        ])
        return host
    }

    private func greeting(
        in composer: SessionComposerViewController
    ) throws -> MorphingMultilineTitleLabel {
        try XCTUnwrap(
            descendants(of: composer.view)
                .compactMap { $0 as? MorphingMultilineTitleLabel }
                .first { $0.accessibilityIdentifier() != "composer.session-start.caption" }
        )
    }

    private func caption(
        in composer: SessionComposerViewController
    ) throws -> MorphingMultilineTitleLabel {
        try XCTUnwrap(
            descendants(of: composer.view)
                .compactMap { $0 as? MorphingMultilineTitleLabel }
                .first { $0.accessibilityIdentifier() == "composer.session-start.caption" }
        )
    }

    /// The line labels a block is laying out.
    private func drawnLines(of block: MorphingMultilineTitleLabel) -> [MorphingTitleLabel] {
        descendants(of: block)
            .compactMap { $0 as? MorphingTitleLabel }
            .filter { !$0.isHiddenOrHasHiddenAncestor }
    }

    private func descendants(of view: NSView) -> [NSView] {
        view.subviews + view.subviews.flatMap { descendants(of: $0) }
    }
}
