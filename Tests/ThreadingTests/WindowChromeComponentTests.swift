import AppKit
import XCTest
@testable import Threading

/// The app-drawn window chrome as components: the band that carries a takeover window's title
/// and gestures, the three buttons that are its working parts, and the host that collapses all
/// of it to nothing in native dress.
@MainActor
final class WindowChromeComponentTests: XCTestCase {

    private enum Render {
        static var directory: URL {
            if let override = ProcessInfo.processInfo.environment["THREADING_RENDER_OUT"] {
                return URL(fileURLWithPath: override)
            }
            return URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("ThreadingRenders", isDirectory: true)
        }
    }

    override func tearDown() {
        AppThemePalette.set(.system)
        super.tearDown()
    }

    // MARK: - Fixtures

    private func fixtureStyle(
        glyphs: WindowChromeStyle.TitleBar.ButtonGlyphStyle = .squares
    ) -> WindowChromeAppearance.Resolved {
        WindowChromeAppearance.resolved(from: fixtureChrome(glyphs: glyphs))
    }

    private func fixtureChrome(
        glyphs: WindowChromeStyle.TitleBar.ButtonGlyphStyle = .squares
    ) -> WindowChromeStyle {
        WindowChromeStyle(
            titleBar: .init(
                activeGradient: .init(stops: [
                    .init(color: NSColor(hex: "#000080")!, position: 0),
                    .init(color: NSColor(hex: "#1084D0")!, position: 1)
                ], angleDegrees: 90),
                ink: .white,
                buttonGlyphStyle: glyphs
            ),
            frame: .init(width: 4)
        )
    }

    /// Records the operations instead of running them. A real `zoom()` on a frameless,
    /// unshown fixture window spawns AppKit's `_NSWindowTransformAnimation`, which outlives
    /// the window a test drops moments later and segfaults in whichever later test pumps the
    /// run loop — found as a crash in `ToastTests`, two suites away. The contract under test
    /// is "the control asks its window", and this window answers exactly that question.
    private final class OperationRecordingWindow: NSWindow {
        var zoomCount = 0
        var miniaturizeCount = 0

        override var canBecomeKey: Bool { true }
        override func zoom(_ sender: Any?) { zoomCount += 1 }
        override func miniaturize(_ sender: Any?) { miniaturizeCount += 1 }
    }

    private func makeWindow() -> OperationRecordingWindow {
        let window = OperationRecordingWindow(
            contentRect: NSRect(x: 80, y: 80, width: 480, height: 320),
            styleMask: WindowChromeCoordinator.takeoverMask,
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = NSView()
        return window
    }

    private func press(_ button: WindowChromeButton) {
        _ = button.performPrimaryAction()
    }

    // MARK: - Button State

    func testTheZoomButtonAsksItsWindowToZoom() {
        let window = makeWindow()
        let button = WindowChromeButton(role: .zoom)
        window.contentView?.addSubview(button)

        press(button)

        XCTAssertEqual(window.zoomCount, 1, "the zoom button performs the window's own zoom")
    }

    func testTheZoomButtonBecomesRestoreForAZoomedWindow() {
        let button = WindowChromeButton(role: .zoom)
        button.fixtureIsZoomed = true

        XCTAssertTrue(button.displaysRestore)
        XCTAssertEqual(button.accessibilityLabel(), L10n.string("Restore"))

        button.fixtureIsZoomed = false
        XCTAssertFalse(button.displaysRestore)
        XCTAssertEqual(button.accessibilityLabel(), L10n.string("Zoom"))
    }

    func testTheMinimizeButtonAsksItsWindowToMiniaturize() {
        let window = makeWindow()
        let button = WindowChromeButton(role: .minimize)
        window.contentView?.addSubview(button)

        press(button)

        XCTAssertEqual(window.miniaturizeCount, 1)
    }

    /// Asserted through a refusing delegate rather than a real close: closing a key-capable
    /// window queues AppKit's terminate-after-last-window-closed decision against the test
    /// host, which then exits inside whichever later test pumps the run loop (the CLAUDE.md
    /// trap). The button's contract is exactly "ask `windowShouldClose`, honour the answer" —
    /// so the refusal *is* the assertion.
    func testTheCloseButtonAsksTheDelegateAndHonoursARefusal() {
        final class Doorman: NSObject, NSWindowDelegate {
            var asked = false
            func windowShouldClose(_ sender: NSWindow) -> Bool {
                asked = true
                return false
            }
        }

        let window = makeWindow()
        let doorman = Doorman()
        window.delegate = doorman
        defer { window.delegate = nil }
        let button = WindowChromeButton(role: .close)
        window.contentView?.addSubview(button)

        var closed = false
        let token = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: window,
            queue: nil
        ) { _ in closed = true }
        defer { NotificationCenter.default.removeObserver(token) }

        press(button)

        XCTAssertTrue(doorman.asked, "the close button asks the window's own delegate")
        XCTAssertFalse(closed, "a refused close must not close")
    }

    func testADisabledButtonRefusesActivation() {
        let window = makeWindow()
        let button = WindowChromeButton(role: .zoom)
        window.contentView?.addSubview(button)
        button.isEnabled = false

        XCTAssertFalse(button.performPrimaryAction())
        XCTAssertEqual(window.zoomCount, 0)
    }

    // MARK: - Accessibility

    func testAccessibilityContract() {
        let window = makeWindow()
        let button = WindowChromeButton(role: .zoom)
        window.contentView?.addSubview(button)

        XCTAssertEqual(button.accessibilityRole(), .button)
        XCTAssertEqual(button.accessibilityLabel(), L10n.string("Zoom"))
        XCTAssertTrue(button.isAccessibilityElement())

        XCTAssertTrue(button.accessibilityPerformPress())
        XCTAssertEqual(window.zoomCount, 1, "the accessibility press is the real press")
    }

    // MARK: - Band Behaviour

    /// Pushed, not observed: the window controller's `updateWindowTitle` calls the host's
    /// `setTitle` beside setting `window.title`, so the two never disagree — and the band
    /// holds no observation that would unregister against a deallocating window.
    func testTheBandShowsThePushedTitle() {
        let band = WindowTitleBandView()

        band.setTitle("Threading — retro")

        XCTAssertEqual(band.displayedTitle, "Threading — retro")
    }

    func testPlatinumSplitsItsWindowBoxesAndDropsTheApplicationIcon() throws {
        let band = WindowTitleBandView()
        band.fixtureStyle = WindowChromeAppearance.resolved(
            from: try XCTUnwrap(AppThemeStyles.platinum.variant(.light)?.chrome)
        )

        XCTAssertEqual(band.leadingWindowButtonRoles, [.close])
        XCTAssertEqual(band.trailingWindowButtonRoles, [.minimize, .zoom])
        XCTAssertFalse(band.showsApplicationIcon)
    }

    func testBeOSUsesARealLeadingTitleTabAndOnlyItsTwoWindowBoxes() throws {
        let band = WindowTitleBandView()
        band.frame = NSRect(x: 0, y: 0, width: 480, height: 28)
        band.fixtureStyle = WindowChromeAppearance.resolved(
            from: try XCTUnwrap(AppThemeStyles.beOS.variant(.light)?.chrome)
        )
        band.layoutSubtreeIfNeeded()

        XCTAssertEqual(band.leadingWindowButtonRoles, [.close])
        XCTAssertEqual(band.trailingWindowButtonRoles, [.zoom])
        XCTAssertFalse(band.showsApplicationIcon)
        XCTAssertEqual(band.occupiedTitleWidth, 210, accuracy: 0.5)
        XCTAssertLessThan(band.occupiedTitleWidth, band.bounds.width,
                          "BeOS needs a title tab, not a yellow full-width title bar")
    }

    func testOpenStepBookendsMiniaturizeAndCloseInItsHistoricalOrder() throws {
        let band = WindowTitleBandView()
        band.fixtureStyle = WindowChromeAppearance.resolved(
            from: try XCTUnwrap(AppThemeStyles.openStep.variant(.light)?.chrome)
        )

        XCTAssertEqual(band.leadingWindowButtonRoles, [.minimize])
        XCTAssertEqual(band.trailingWindowButtonRoles, [.close])
        XCTAssertFalse(band.showsApplicationIcon)
    }

    func testABandDoubleClickPerformsTheChosenAction() throws {
        let window = makeWindow()
        let band = WindowTitleBandView()
        band.frame = NSRect(x: 0, y: 292, width: 480, height: 28)
        window.contentView?.addSubview(band)
        band.doubleClickAction = { .zoom }

        let event = try XCTUnwrap(NSEvent.mouseEvent(
            with: .leftMouseDown,
            location: NSPoint(x: 240, y: 306),
            modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: 0,
            clickCount: 2,
            pressure: 1
        ))
        band.mouseDown(with: event)

        XCTAssertEqual(window.zoomCount, 1, "a band double-click performs the zoom")
    }

    // MARK: - Gallery

    func testGalleryTellsTheirStories() {
        for name in [
            "WindowTitleBandView", "WindowChromeButton", "WindowCommandBandView",
            "WindowChromeFrameView"
        ] {
            XCTAssertTrue(
                ComponentGalleryViewController.componentNames.contains(name),
                "A design-system component without a gallery story is invisible to review"
            )
        }
    }

    // MARK: - Host

    /// In native dress the chrome host must be geometrically invisible: the band hidden at
    /// zero height, the command band hidden too, no frame inset, the workspace filling the root exactly.
    func testTheHostCollapsesToNothingInNativeDress() {
        let workspace = NSViewController()
        workspace.view = NSView()
        let host = WindowChromeHostViewController(workspace: workspace)
        host.view.frame = NSRect(x: 0, y: 0, width: 600, height: 400)
        host.view.layoutSubtreeIfNeeded()

        XCTAssertTrue(host.bandView.isHidden)
        XCTAssertEqual(host.bandView.frame.height, 0)
        XCTAssertTrue(host.commandBandView.isHidden)
        XCTAssertEqual(host.commandBandView.frame.height, 0)
        XCTAssertEqual(workspace.view.frame, host.view.bounds)
    }

    func testTheHostDressesForTakeoverAndUndressesAgain() throws {
        let takeover = try AppThemeEditing.assemble(
            id: AppThemeID("custom-window-chrome-component-tests"),
            name: "Component Fixture",
            mode: AppThemeStyles.cyberpunk.availableVariants[0] == .dark ? .dark : .light,
            summary: nil,
            variants: [
                AppThemeStyles.cyberpunk.availableVariants[0]: AppThemeEditing.makeVariant(
                    named: "Component Fixture",
                    from: AppThemeStyles.cyberpunk,
                    kind: AppThemeStyles.cyberpunk.availableVariants[0],
                    chrome: .set(fixtureChrome())
                )
            ]
        )
        AppThemePalette.set(takeover)

        let workspace = NSViewController()
        workspace.view = NSView()
        let host = WindowChromeHostViewController(workspace: workspace)
        host.view.frame = NSRect(x: 0, y: 0, width: 600, height: 400)
        host.setTakeoverActive(true)
        host.view.layoutSubtreeIfNeeded()

        XCTAssertFalse(host.bandView.isHidden)
        XCTAssertFalse(host.commandBandView.isHidden)
        XCTAssertEqual(
            host.bandView.frame.height,
            WindowChromeStyleLimits.defaultBandHeight
        )
        XCTAssertEqual(host.commandBandView.frame.height, WindowCommandBandView.bandHeight)
        XCTAssertEqual(workspace.view.frame.maxY, host.commandBandView.frame.minY)
        XCTAssertEqual(workspace.view.frame.minX, 4, "the frame's width insets the workspace")
        XCTAssertEqual(
            host.view.bounds.maxY - host.bandView.frame.maxY,
            4,
            "the frame's width seats the band below the top edge"
        )

        host.setTakeoverActive(false)
        host.view.layoutSubtreeIfNeeded()
        XCTAssertTrue(host.bandView.isHidden)
        XCTAssertTrue(host.commandBandView.isHidden)
        XCTAssertEqual(workspace.view.frame, host.view.bounds)
    }

    // MARK: - Renders

    /// System plus two deliberately different themes, light and dark: the band with its
    /// square-plate buttons over its own gradient, active and inactive, plus the bare-glyph
    /// style. Balance and legibility are judged by looking, the render-suite rule.
    func testRendersUnderSystemAndTwoStyledThemes() throws {
        let directory = Render.directory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        // The takeover themes join the usual pair because their material reaches these
        // components: Windows has square plates, Platinum split inset boxes, and BeOS a tab.
        let styled = [
            "Cyberpunk", "Swiss Minimalist", "Mac OS 9 Platinum", "BeOS R5", "Windows 98"
        ].map { name in
            AppThemeLibrary.stock.first { $0.name == name }
        }
        let themes = try [AppTheme.system] + styled.map { try XCTUnwrap($0) }

        var written = 0
        for theme in themes {
            AppThemePalette.set(theme)
            for (suffix, appearanceName) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
                let appearance = try XCTUnwrap(NSAppearance(named: appearanceName))
                var data: Data?
                appearance.performAsCurrentDrawingAppearance {
                    data = strip(appearance: appearance, theme: theme)
                }
                let url = directory.appendingPathComponent(
                    "window-chrome-\(theme.id.rawValue)-\(suffix).png"
                )
                try XCTUnwrap(data, "Failed to render \(theme.name) \(suffix)").write(to: url)
                written += 1
            }
        }
        print("Rendered \(written) window-chrome strips to \(directory.path)")
        XCTAssertEqual(written, themes.count * 2)
    }

    /// The whole takeover window as one picture: the real `MainWindowController` dressed by
    /// the stock takeover themes, drawn unshown. In takeover the app draws every pixel of
    /// the frame, so the content render *is* the window — the one picture that shows band,
    /// buttons, frame, bevels and panes as one thing, which no per-component strip can.
    func testRendersTheWholeTakeoverWindow() throws {
        let directory = Render.directory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { AppThemePalette.set(.system) }

        // The native half first, as the comparison's "before". Its traffic lights and
        // toolbar are AppKit's own chrome outside the content, so this is the workspace
        // alone — the takeover half is the one where the content *is* the whole window.
        for (theme, name) in [
            (AppTheme.system, "window-chrome-native-window"),
            (AppThemeStyles.platinum, "window-chrome-platinum-window"),
            (AppThemeStyles.beOS, "window-chrome-beos-window"),
            (AppThemeStyles.openStep, "window-chrome-openstep-window"),
            (AppThemeStyles.win98, "window-chrome-takeover-window")
        ] {
            AppThemePalette.set(theme)
            let controller = MainWindowController()
            let window = try XCTUnwrap(controller.window)
            window.setContentSize(NSSize(width: 1_100, height: 700))
            let content = try XCTUnwrap(window.contentView)
            content.layoutSubtreeIfNeeded()

            // The hero form: an unshown window is never key, so the band would render its
            // inactive gray without the fixture saying otherwise.
            firstBand(in: content)?.fixtureIsKey = true

            let rep = try XCTUnwrap(content.bitmapImageRepForCachingDisplay(in: content.bounds))
            content.cacheDisplay(in: content.bounds, to: rep)
            let png = try XCTUnwrap(rep.representation(using: .png, properties: [:]))
            let url = directory.appendingPathComponent("\(name).png")
            try png.write(to: url)
            print("Rendered \(name) to \(url.path)")
        }
    }

    func testRendersOpenStepLeadingStippledScroller() throws {
        let directory = Render.directory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        AppThemePalette.set(AppThemeStyles.openStep)

        let scroll = ThemedScrollView(frame: NSRect(x: 0, y: 0, width: 180, height: 280))
        scroll.surfaceRole = .sidebarNavigator
        scroll.scrollerStyle = .legacy
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = false

        let document = NSView(frame: NSRect(x: 0, y: 0, width: 160, height: 760))
        document.wantsLayer = true
        document.layer?.backgroundColor = Design.Surface.elevated.cgColor
        for index in 0..<18 {
            let label = NSTextField(labelWithString: index.isMultiple(of: 3)
                ? "Workspace \(index / 3 + 1)"
                : "  Session \(index + 1)")
            label.font = Design.Typography.body()
            label.textColor = Design.Text.label
            label.frame = NSRect(x: 12, y: 720 - CGFloat(index * 36), width: 132, height: 20)
            document.addSubview(label)
        }
        scroll.documentView = document
        scroll.layoutSubtreeIfNeeded()
        let scroller = try XCTUnwrap(scroll.verticalScroller)
        scroller.isEnabled = true
        scroller.doubleValue = 0.28
        scroller.knobProportion = 0.30

        let rep = try XCTUnwrap(scroll.bitmapImageRepForCachingDisplay(in: scroll.bounds))
        scroll.cacheDisplay(in: scroll.bounds, to: rep)
        let png = try XCTUnwrap(rep.representation(using: .png, properties: [:]))
        let url = directory.appendingPathComponent("openstep-leading-scroller.png")
        try png.write(to: url)
        print("Rendered OPENSTEP scroller to \(url.path)")
    }

    private func firstBand(in view: NSView) -> WindowTitleBandView? {
        if let band = view as? WindowTitleBandView { return band }
        for subview in view.subviews {
            if let band = firstBand(in: subview) { return band }
        }
        return nil
    }

    private func strip(appearance: NSAppearance, theme: AppTheme) -> Data? {
        let squares = fixtureStyle(glyphs: .squares)
        let band = WindowTitleBandView()
        band.fixtureStyle = squares

        let plain = fixtureStyle(glyphs: .plain)
        let plainButtons = NSStackView(
            views: [WindowChromeButton.Role.minimize, .zoom, .close].map { role in
                let button = WindowChromeButton(role: role)
                button.fixtureStyle = plain
                return button
            }
        )
        plainButtons.orientation = .horizontal
        plainButtons.spacing = Design.Spacing.hairline

        let host = NSView(frame: NSRect(x: 0, y: 0, width: 460, height: 76))
        host.appearance = appearance
        band.translatesAutoresizingMaskIntoConstraints = false
        plainButtons.translatesAutoresizingMaskIntoConstraints = false
        host.addSubview(band)
        host.addSubview(plainButtons)
        NSLayoutConstraint.activate([
            band.topAnchor.constraint(equalTo: host.topAnchor, constant: Design.Spacing.small),
            band.leadingAnchor.constraint(
                equalTo: host.leadingAnchor, constant: Design.Spacing.small
            ),
            band.widthAnchor.constraint(equalToConstant: 420),
            band.heightAnchor.constraint(equalToConstant: squares.bandHeight),
            plainButtons.topAnchor.constraint(
                equalTo: band.bottomAnchor, constant: Design.Spacing.small
            ),
            plainButtons.leadingAnchor.constraint(equalTo: band.leadingAnchor)
        ])
        host.layoutSubtreeIfNeeded()

        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return nil }
        host.wantsLayer = true
        host.layer?.backgroundColor = theme.resolved(.ground, appearance: appearance).cgColor
        host.cacheDisplay(in: host.bounds, to: rep)
        return rep.representation(using: .png, properties: [:])
    }
}
