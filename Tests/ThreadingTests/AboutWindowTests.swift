import AppKit
import XCTest
@testable import Threading

/// The window that replaced `orderFrontStandardAboutPanel`.
///
/// The claims worth pinning are the ones a picture cannot make: that the surface is app-owned all
/// the way down (the audit), that the readings on it are the ones `BuildDetails` took rather than a
/// second transcription of the bundle, and that Escape closes it. What it *looks* like is reviewed
/// from the renders at the bottom, under System plus deliberately different authored themes —
/// including one whose whole point is that it draws nothing like the system's About panel.
@MainActor
final class AboutWindowTests: XCTestCase {

    private enum Render {

        static var directory: URL {
            // Empty, not absent, is the case worth guarding: the test plan forwards this as
            // `$(THREADING_RENDER_OUT)`, which expands to the empty string when nothing set it —
            // and an empty path is the volume root, which is read-only.
            if let override = ProcessInfo.processInfo.environment["THREADING_RENDER_OUT"],
               !override.isEmpty {
                return URL(fileURLWithPath: override)
            }
            return URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("ThreadingRenders", isDirectory: true)
        }

        /// System in both appearances, plus the styles that stress glow, a hard-edged construction
        /// and a square print one — the three ways the brand plate and its rule can go wrong.
        static var fixtures: [(name: String, theme: AppTheme, appearance: NSAppearance.Name)] {
            [
                ("system-light", .system, .aqua),
                ("system-dark", .system, .darkAqua),
                ("threading", AppThemeStyles.threading, .darkAqua),
                ("cyberpunk", AppThemeStyles.cyberpunk, .darkAqua),
                ("neo-brutalism", AppThemeStyles.neoBrutalism, .aqua),
                ("swiss", AppThemeStyles.swissMinimalist, .aqua)
            ]
        }
    }

    // MARK: - Content

    func testTheWindowNamesTheAppAndStatesEveryReadingItWasGiven() throws {
        let details = fixture()
        let controller = AboutViewController(details: details)
        let root = laidOut(controller.view)
        let shown = Set(labels(in: root).map(\.stringValue))

        XCTAssertTrue(shown.contains(AppInfo.name), "the window does not say which app it is about")
        XCTAssertTrue(shown.contains("1.4.0 (212)"), "the version pair is not on the window")
        for entry in details.entries {
            XCTAssertTrue(shown.contains(entry.label), "no label for \(entry.label)")
            XCTAssertTrue(shown.contains(entry.value), "no reading for \(entry.label)")
        }
        withExtendedLifetime(root) {}
    }

    /// The mark beside the version is the sidebar's own, so the abbreviation means the same thing
    /// in both places and carries the same Help Tag.
    func testTheVersionWearsTheSameChannelMarkAsTheSidebar() throws {
        let controller = AboutViewController(details: fixture())
        let root = laidOut(controller.view)
        let badge = try XCTUnwrap(
            labels(in: root).first { $0.accessibilityIdentifier() == "sidebar.buildChannel" },
            "the About window shows no channel mark on a dev build"
        )

        XCTAssertEqual(badge.stringValue, BuildChannelBadge.title(for: .dev))
        XCTAssertEqual(badge.toolTip, fixture().helpTag)
        withExtendedLifetime(root) {}
    }

    /// A release build wears no mark, here for the same reason it wears none in the footer: the
    /// mark exists to flag the exception. The version pair still stands.
    func testAReleaseBuildShowsTheVersionWithNoChannelMark() throws {
        let controller = AboutViewController(details: fixture(channel: .release))
        let root = laidOut(controller.view)

        XCTAssertNil(labels(in: root).first { $0.accessibilityIdentifier() == "sidebar.buildChannel" })
        XCTAssertTrue(labels(in: root).map(\.stringValue).contains("1.4.0 (212)"))
        withExtendedLifetime(root) {}
    }

    /// The readings can be dragged across and copied into a bug report, which is the only reason
    /// anybody selects a version number. The labels beside them are not selectable — nothing is
    /// gained by selecting the word "System".
    func testTheReadingsAreSelectableSoTheyCanBeCopiedIntoAReport() throws {
        let details = fixture()
        let controller = AboutViewController(details: details)
        let root = laidOut(controller.view)
        let selectable = Set(labels(in: root).filter(\.isSelectable).map(\.stringValue))

        XCTAssertTrue(selectable.contains("1.4.0 (212)"))
        for entry in details.entries {
            XCTAssertTrue(selectable.contains(entry.value), "\(entry.label)'s reading cannot be copied")
            XCTAssertFalse(selectable.contains(entry.label), "\(entry.label) is selectable for no reason")
        }
        withExtendedLifetime(root) {}
    }

    /// Found in a render, not in an assertion: the ground carries the theme's backdrop pattern, and
    /// Neo Brutalism's dot field landed inside the glyphs of the 11pt spec sheet drawn straight onto
    /// it. So the readings sit on a panel, and the only reading left on the patterned ground — the
    /// version pair — is body-sized rather than detail-sized.
    func testTheReadingsSitOnAPanelRatherThanOnTheThemesBackdrop() throws {
        let details = fixture()
        let controller = AboutViewController(details: details)
        let root = laidOut(controller.view)

        let grid = try XCTUnwrap(descendants(of: root, type: NSGridView.self).first)
        let card = try XCTUnwrap(
            grid.superview as? ThemedSurfaceView,
            "the readings are drawn straight onto the window's ground again"
        )
        XCTAssertFalse(
            card === controller.view,
            "the readings' 'card' is the patterned ground itself"
        )
        XCTAssertNotNil(
            card.appliedSurfaceRadius,
            "the card wears no applied surface, so it is a container rather than a panel"
        )

        let version = try XCTUnwrap(
            labels(in: root).first { $0.stringValue == details.versionSummary }
        )
        XCTAssertFalse(
            version.isDescendant(of: card),
            "the version moved onto the card; this claim is about the one line that did not"
        )
        XCTAssertGreaterThan(
            version.font?.pointSize ?? 0,
            Design.Typography.detail().pointSize,
            "the version pair is back at detail size on top of a dot pattern"
        )
        withExtendedLifetime(root) {}
    }

    /// The mark is the brand, not a control: the window's accessible name is the window's, and the
    /// artwork announces nothing of its own.
    func testTheMarkIsDecorativeAndTheDetailsAreFindable() throws {
        let controller = AboutViewController(details: fixture())
        let root = laidOut(controller.view)
        let mark = try XCTUnwrap(descendants(of: root, type: ThreadingMarkView.self).first)

        XCTAssertFalse(mark.isAccessibilityElement())
        XCTAssertNotNil(
            descendants(of: root, type: NSView.self)
                .first { $0.accessibilityIdentifier() == "about.buildDetails" }
        )
        withExtendedLifetime(root) {}
    }

    // MARK: - Window

    func testTheWindowIsAppOwnedAllTheWayDownAndKeepsItsChromeOutOfTheWay() throws {
        let controller = AboutWindowController()
        let window = try XCTUnwrap(controller.window)
        window.contentView?.layoutSubtreeIfNeeded()

        XCTAssertTrue(window.styleMask.contains(.fullSizeContentView))
        XCTAssertTrue(window.titlebarAppearsTransparent)
        XCTAssertEqual(window.titleVisibility, .hidden)
        XCTAssertFalse(
            window.styleMask.contains(.resizable),
            "the panel states a fixed set of readings and has no second size worth having"
        )
        // The title is hidden but not absent: it is the window's accessible name and its row in
        // the Window menu.
        XCTAssertTrue(window.title.contains(AppInfo.name))

        let content = try XCTUnwrap(controller.contentViewController?.view)
        XCTAssertEqual(ThemeBoundaryAudit.violations(in: content), [])
    }

    /// It sizes itself to its content rather than to a width somebody typed, and stays wide enough
    /// to read in a locale with longer labels than English's.
    func testTheWindowSizesItselfToItsContent() throws {
        let controller = AboutWindowController()
        let window = try XCTUnwrap(controller.window)
        let content = try XCTUnwrap(window.contentView)
        content.layoutSubtreeIfNeeded()

        let expected = AboutWindowDefaults.minimumContentWidth + Design.Spacing.pane * 2
        XCTAssertGreaterThanOrEqual(content.bounds.width, expected)
        XCTAssertGreaterThan(content.bounds.height, AboutWindowDefaults.plateSide)
        XCTAssertFalse(
            descendants(of: content, type: NSView.self).contains { $0.frame.width > content.bounds.width + 1 },
            "something on the About window is wider than the window"
        )
    }

    /// Escape closes it, like every other transient surface in the app. Asserted through the
    /// responder call AppKit actually makes, on an **unshown** window: `close()` posts the
    /// notification either way, so proving the key is wired needs no window on screen. The window
    /// is not released when closed, which is what makes closing it here safe rather than a race
    /// with whatever AppKit still has autoreleased.
    func testEscapeClosesTheWindow() throws {
        let controller = AboutWindowController()
        let window = try XCTUnwrap(controller.window)
        XCTAssertFalse(window.isReleasedWhenClosed)

        let closed = expectation(
            forNotification: NSWindow.willCloseNotification,
            object: window,
            handler: nil
        )
        controller.cancelOperation(nil)

        wait(for: [closed], timeout: 1)
        XCTAssertFalse(window.isVisible)
    }

    // MARK: - Images

    func testRendersTheAboutWindowAcrossThemes() throws {
        let directory = Render.directory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { AppThemePalette.set(.system) }

        var written = 0
        for fixture in Render.fixtures {
            AppThemePalette.set(fixture.theme)

            let controller = AboutViewController(details: self.fixture())
            let root = controller.view
            let appearance = try XCTUnwrap(NSAppearance(named: fixture.appearance))
            root.appearance = appearance
            let host = laidOut(root)
            AppThemeRefresh.repaint(host)
            host.layoutSubtreeIfNeeded()

            var data: Data?
            appearance.performAsCurrentDrawingAppearance {
                data = self.png(of: host)
            }
            let url = directory.appendingPathComponent("about-\(fixture.name).png")
            try XCTUnwrap(data, "no render for \(fixture.name)").write(to: url)
            XCTAssertEqual(ThemeBoundaryAudit.violations(in: host), [])
            written += 1
        }

        print("Rendered \(written) About windows to \(directory.path)")
        XCTAssertEqual(written, Render.fixtures.count)
    }

    // MARK: - Helpers

    private func fixture(channel: BuildChannel = .dev) -> BuildDetails {
        BuildDetails(
            channel: channel,
            versionSummary: "1.4.0 (212)",
            configuration: "Debug",
            built: "17 Aug 2026 at 10:12",
            system: "macOS 26.1",
            architecture: "arm64"
        )
    }

    /// The About window's content sizes itself, so the fixture states no width of its own — it
    /// wraps the view at its fitting size, which is the geometry the real window gets.
    private func laidOut(_ view: NSView) -> NSView {
        view.translatesAutoresizingMaskIntoConstraints = false
        let size = view.fittingSize
        let host = NSView(frame: NSRect(origin: .zero, size: size))
        host.addSubview(view)
        NSLayoutConstraint.activate([
            view.topAnchor.constraint(equalTo: host.topAnchor),
            view.leadingAnchor.constraint(equalTo: host.leadingAnchor),
            view.trailingAnchor.constraint(equalTo: host.trailingAnchor),
            view.bottomAnchor.constraint(equalTo: host.bottomAnchor)
        ])
        host.layoutSubtreeIfNeeded()
        return host
    }

    private func labels(in root: NSView) -> [NSTextField] {
        descendants(of: root, type: NSTextField.self)
    }

    private func descendants<T: NSView>(of root: NSView, type: T.Type) -> [T] {
        var found: [T] = []
        for view in root.subviews {
            if let match = view as? T { found.append(match) }
            found += descendants(of: view, type: type)
        }
        return found
    }

    private func png(of host: NSView) -> Data? {
        guard host.bounds.height > 1,
              let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return nil }
        host.cacheDisplay(in: host.bounds, to: rep)
        return rep.representation(using: .png, properties: [:])
    }
}
