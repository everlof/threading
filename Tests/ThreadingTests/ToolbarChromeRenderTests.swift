import AppKit
import XCTest
@testable import Threading

/// Draws the window's chrome vocabulary — the page tab, the toolbar's actions, the display
/// pane's tab strip — and writes each story out as an image.
///
/// It exists because the thing being checked is a *relationship*, and no assertion states it:
/// whether a tab in the toolbar and a tab in the pane read as the same idea, and whether the
/// actions beside them share that silhouette. Those were three shapes in one strip — a pill, a
/// rounded rect and a row of circles — which is visible in a picture and in nothing else.
///
/// Both appearances and backdrop extremes are rendered. Toolbar overlays ink themselves against
/// the terminal (see `BackdropOverlay`), while pane controls use chrome ink, so the paired matrix
/// checks the right contrast contract for each kind of component.
@MainActor
final class ToolbarChromeRenderTests: XCTestCase {

    // MARK: - Configuration

    private enum Render {
        static var directory: URL {
            if let override = ProcessInfo.processInfo.environment["THREADING_RENDER_OUT"] {
                return URL(fileURLWithPath: override)
            }
            return URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("ThreadingRenders", isDirectory: true)
        }

        /// A near-black terminal and a paper-white one in their matching system appearances.
        static let backdrops: [
            (name: String, colour: NSColor, appearance: NSAppearance.Name)
        ] = [
            ("dark", NSColor(hex: "#0B0B0F")!, .darkAqua),
            ("light", NSColor(hex: "#FAFAF7")!, .aqua)
        ]
    }

    // MARK: - Stories

    func testRendersTheChromeStorybook() throws {
        var written = 0

        written += try write(story: "01-toolbar") { Self.toolbarStrip() }
        written += try write(story: "02-pane-tabs") { Self.paneTabStrip() }
        written += try write(story: "03-drawer-seam") { Self.drawerSeam() }
        written += try write(story: "04-pane-header-hover") { Self.paneHeaderRow() }

        XCTAssertEqual(written, 8, "Every story should render on both backdrops")
        print("Rendered toolbar chrome storybook to \(Render.directory.path)")
    }

    /// The live browser's actual chrome component at the widths and states that previously made
    /// it fail: the 260pt pane minimum, a private tab, a pop-up, loading, and every agent testing
    /// condition active. System gets both appearances; the two most geometrically opinionated
    /// stock styles ensure this is app chrome rather than a system control row in themed paint.
    func testRendersBrowserChromeMatrix() throws {
        let themes: [(name: String, theme: AppTheme, appearance: NSAppearance.Name)] = [
            ("system-light", .system, .aqua),
            ("system-dark", .system, .darkAqua),
            ("swiss-minimalist", AppThemeStyles.swissMinimalist, .aqua),
            ("cyberpunk", AppThemeStyles.cyberpunk, .darkAqua)
        ]
        let stories: [BrowserChromeStory] = [
            BrowserChromeStory(
                name: "compact-default",
                width: 260,
                context: .shared
            ) {
                $0.addressField.stringValue = "https://example.test/dashboard"
                $0.setNavigationState(canGoBack: true, canGoForward: false, popupDepth: 0)
            },
            BrowserChromeStory(
                name: "compact-loading",
                width: 260,
                context: .shared
            ) {
                $0.addressField.stringValue = "https://example.test/stream"
                $0.setNavigationState(canGoBack: true, canGoForward: false, popupDepth: 0)
                $0.setLoading(true)
            },
            BrowserChromeStory(
                name: "medium-private",
                width: 380,
                context: .private
            ) {
                $0.addressField.stringValue = "https://accounts.example.test/sign-in"
                $0.setNavigationState(canGoBack: true, canGoForward: true, popupDepth: 0)
                $0.setPasswordFieldFocused(true)
            },
            BrowserChromeStory(
                name: "medium-popup",
                width: 380,
                context: .shared
            ) {
                $0.addressField.stringValue = "https://accounts.example.test/authorize"
                $0.setNavigationState(canGoBack: true, canGoForward: false, popupDepth: 1)
            },
            BrowserChromeStory(
                name: "wide-test-conditions",
                width: 620,
                context: .private
            ) {
                $0.addressField.stringValue = "https://example.test/responsive"
                $0.setNavigationState(canGoBack: true, canGoForward: true, popupDepth: 0)
                $0.setActiveTestConditionCount(4)
                $0.setPasswordFieldFocused(true)
            },
            BrowserChromeStory(
                name: "wide-annotating",
                width: 760,
                context: .shared
            ) {
                $0.addressField.stringValue = "https://example.test/review"
                $0.setNavigationState(canGoBack: true, canGoForward: true, popupDepth: 0)
                $0.setAnnotating(true)
            }
        ]

        let originalTheme = AppThemePalette.current
        defer { AppThemePalette.set(originalTheme) }

        try FileManager.default.createDirectory(
            at: Render.directory,
            withIntermediateDirectories: true
        )

        var written = 0
        for theme in themes {
            AppThemePalette.set(theme.theme)
            let appearance = try XCTUnwrap(NSAppearance(named: theme.appearance))
            for story in stories {
                let data = try XCTUnwrap(
                    browserChromePNG(story: story, theme: theme.theme, appearance: appearance),
                    "Failed to render \(story.name) under \(theme.name)"
                )
                try data.write(
                    to: Render.directory.appendingPathComponent(
                        "browser-chrome-\(story.name)-\(theme.name).png"
                    )
                )
                written += 1
            }
        }

        XCTAssertEqual(written, 24)
        print("Rendered browser chrome matrix to \(Render.directory.path)")
    }

    func testRendersBrowserResponsiveReviewMatrix() throws {
        let themes: [(name: String, theme: AppTheme, appearance: NSAppearance.Name)] = [
            ("system-light", .system, .aqua),
            ("system-dark", .system, .darkAqua),
            ("swiss-minimalist", AppThemeStyles.swissMinimalist, .aqua),
            ("cyberpunk", AppThemeStyles.cyberpunk, .darkAqua)
        ]
        let widths: [(name: String, value: CGFloat)] = [
            ("wide", 760),
            ("compact", 430)
        ]

        let originalTheme = AppThemePalette.current
        defer { AppThemePalette.set(originalTheme) }
        try FileManager.default.createDirectory(
            at: Render.directory,
            withIntermediateDirectories: true
        )

        var written = 0
        for theme in themes {
            AppThemePalette.set(theme.theme)
            let appearance = try XCTUnwrap(NSAppearance(named: theme.appearance))
            for width in widths {
                let data = try XCTUnwrap(
                    browserResponsiveReviewPNG(
                        width: width.value,
                        theme: theme.theme,
                        appearance: appearance
                    )
                )
                try data.write(
                    to: Render.directory.appendingPathComponent(
                        "browser-responsive-review-\(width.name)-\(theme.name).png"
                    )
                )
                written += 1
            }
        }

        XCTAssertEqual(written, 8)
        print("Rendered browser responsive review matrix to \(Render.directory.path)")
    }

    func testBrowserChromeProtectsTheAddressAtMinimumWidth() {
        let bar = BrowserChromeBar(contextKind: .shared)
        bar.frame = NSRect(x: 0, y: 0, width: 260, height: 40)
        bar.setNavigationState(canGoBack: true, canGoForward: false, popupDepth: 0)
        bar.setActiveTestConditionCount(4)
        bar.layoutSubtreeIfNeeded()

        XCTAssertTrue(bar.forwardButton.isHidden, "an inert Forward should yield first")
        XCTAssertTrue(bar.testConditionsButton.isHidden)
        XCTAssertEqual(
            bar.overflowButton.title,
            "4",
            "active conditions should fold into Browser Options before the address gives up space"
        )
        XCTAssertGreaterThanOrEqual(bar.addressField.frame.width, 72)

        bar.setNavigationState(canGoBack: true, canGoForward: true, popupDepth: 0)
        bar.layoutSubtreeIfNeeded()
        XCTAssertFalse(bar.forwardButton.isHidden, "usable navigation must never disappear")

        bar.frame.size.width = 620
        bar.updateResponsiveLayout()
        bar.layoutSubtreeIfNeeded()
        XCTAssertEqual(bar.testConditionsButton.title, "4")
        XCTAssertFalse(bar.testConditionsButton.isHidden)
        XCTAssertEqual(bar.overflowButton.title, "")

        let crowded = BrowserChromeBar(contextKind: .private)
        crowded.frame = NSRect(x: 0, y: 0, width: 260, height: 40)
        crowded.setNavigationState(canGoBack: true, canGoForward: true, popupDepth: 1)
        crowded.setActiveTestConditionCount(4)
        crowded.layoutSubtreeIfNeeded()

        XCTAssertTrue(crowded.isReloadFolded)
        XCTAssertFalse(crowded.closePopupButton.isHidden)
        XCTAssertGreaterThanOrEqual(
            crowded.addressField.frame.width,
            72,
            "private + pop-up + emulation should still preserve a usable address"
        )

        let password = BrowserChromeBar(contextKind: .shared)
        password.frame = NSRect(x: 0, y: 0, width: 260, height: 40)
        password.setPasswordFieldFocused(true)
        password.layoutSubtreeIfNeeded()
        XCTAssertFalse(password.passwordInputButton.isHidden)
        XCTAssertEqual(password.passwordInputButton.title, "")
        XCTAssertGreaterThanOrEqual(
            password.addressField.frame.width,
            72,
            "private input state should not consume the address at minimum width"
        )

        password.frame.size.width = 620
        password.updateResponsiveLayout()
        password.layoutSubtreeIfNeeded()
        XCTAssertEqual(password.passwordInputButton.title, "Private Input")

        password.setPasswordFieldFocused(false)
        XCTAssertTrue(password.passwordInputButton.isHidden)
    }

    /// The claim the storybook is there to protect.
    ///
    /// It used to compare two classes' heights, fonts and radii — a test that could only ever
    /// catch drift *after* it was written, and that passed for a long while over two tabs which
    /// visibly differed in hover, close button and click behaviour, none of which it measured.
    /// There is one class now, so the property worth pinning is that: the toolbar's page tab and
    /// the pane's tab are the same type, differing only in the ground they ink from.
    func testTheTwoTabSurfacesAreOneComponent() {
        let paneTab = ThemedTabItemView(
            title: "Info",
            symbolName: "info.circle",
            placement: .horizontal,
            showsClose: true,
            inkSource: .chrome
        )
        paneTab.isSelected = true

        let pageTab = Self.pageTab(title: "Info", symbolName: "info.circle")

        XCTAssertEqual(
            paneTab.intrinsicContentSize,
            pageTab.intrinsicContentSize,
            "two tabs with the same content measured differently"
        )
        XCTAssertEqual(paneTab.inkSource, .chrome)
        XCTAssertEqual(
            pageTab.inkSource,
            .backdrop,
            "the toolbar floats over the terminal's palette, not the chrome's"
        )
    }

    /// The behaviour a shared constants enum could never have delivered, and the reason this is
    /// one class: a tab is clickable, wherever it is drawn.
    func testThePageTabIsSelectableAndReachableFromTheKeyboard() {
        var reveals = 0
        let pageTab = Self.pageTab(title: "sonda", symbolName: "folder")
        pageTab.onSelect = { reveals += 1 }

        XCTAssertTrue(pageTab.performPrimaryAction())
        XCTAssertEqual(reveals, 1)

        XCTAssertEqual(pageTab.accessibilityRole(), .radioButton)
        XCTAssertEqual(pageTab.accessibilityTitle(), "sonda")
        XCTAssertTrue(pageTab.accessibilityPerformPress())
        XCTAssertEqual(reveals, 2, "the page tab is not reachable through accessibility")
    }

    /// A rename morphs; a change of page does not. The tab decides from the identity it is
    /// handed, which is what stops the toolbar animating between two unrelated pages.
    func testOnlyARenameOfTheSamePageIsAnimated() {
        let sessionA = UUID()
        let tab = Self.pageTab(title: "First", symbolName: "folder")

        tab.update(title: "First", symbolName: "folder", showsClose: true, identity: sessionA)
        tab.update(title: "Renamed", symbolName: "folder", showsClose: true, identity: sessionA)
        XCTAssertEqual(tab.title, "Renamed")

        tab.update(title: "Another page", symbolName: "folder", showsClose: true, identity: UUID())
        XCTAssertEqual(tab.title, "Another page")
    }

    private static func pageTab(title: String, symbolName: String) -> ThemedTabItemView {
        let tab = ThemedTabItemView(
            title: title,
            symbolName: symbolName,
            placement: .horizontal,
            showsClose: true,
            inkSource: .backdrop
        )
        tab.isSelected = true
        return tab
    }

    // MARK: - Content

    /// The trailing half of the window's toolbar: the active page, then what acts on it.
    private static func toolbarStrip() -> NSView {
        let pageTab = pageTab(
            title: "hi ❤️ nice",
            symbolName: "chevron.left.forwardslash.chevron.right"
        )
        pageTab.widthAnchor.constraint(equalToConstant: 190).isActive = true

        let newSession = ThemedIconButton(symbolName: "plus", accessibility: "New session")

        // The way out to another app, drawn beside the actions it must *not* read as one of:
        // it is the only control in this strip carrying colour, because the one question it
        // answers at a glance is which app the press sends you to. Finder's icon stands in
        // because every Mac has it — on a real strip this is VS Code, Xcode or Zed.
        let openIn = ThemedIconButton(
            symbolName: OpenInToolbarDefaults.fallbackSymbol,
            accessibility: "Open in Finder"
        )
        if let finder = ExternalApps.app(id: ExternalApps.finderID),
           let icon = ExternalAppLauncher.shared.icon(for: finder) {
            openIn.setImage(icon, accessibility: "Open in Finder")
        }
        let openInGroup = ToolbarButtonGroupView(buttons: [
            openIn,
            ThemedIconButton(symbolName: DesignSymbols.chevron, accessibility: "Choose an app")
        ])

        let actions = ToolbarButtonGroupView(buttons: [
            ThemedIconButton(symbolName: "ellipsis", accessibility: "Session options"),
            ThemedIconButton(symbolName: "terminal", accessibility: "Show as Claude Code UI"),
            ThemedIconButton(
                symbolName: "rectangle.bottomthird.inset.filled",
                accessibility: "Shell drawer"
            ),
            selected(ThemedIconButton(symbolName: "sidebar.trailing", accessibility: "Panel"))
        ])

        return strip([pageTab, newSession, openInGroup, actions], spacing: Design.Spacing.medium)
    }

    /// The pane's header row as it is drawn: the tabs and the `+` that adds one, with both of
    /// the row's small hover surfaces raised so their silhouettes can be compared. They came
    /// from one radius token and drew as a rounded square and a *disc* — see
    /// `Design.Radius.control(fitting:)`.
    private static func paneHeaderRow() -> NSView {
        let close = ThemedButton(
            symbol: "xmark",
            accessibility: "Close tab",
            target: nil,
            action: nil
        )
        close.hoverFill = Design.Surface.controlHover
        close.widthAnchor.constraint(equalToConstant: Design.Size.tabCloseTarget).isActive = true
        close.heightAnchor.constraint(equalToConstant: Design.Size.tabCloseTarget).isActive = true

        let add = ThemedButton(symbol: "plus", accessibility: "New tab", target: nil, action: nil)
        add.widthAnchor.constraint(equalToConstant: DisplayPaneDefaults.buttonSize).isActive = true
        add.heightAnchor.constraint(equalToConstant: DisplayPaneDefaults.buttonSize).isActive = true

        // Both raised, because the hover surface *is* what is being compared: at rest a plain
        // button draws nothing and the two silhouettes cannot be told apart.
        [close, add].forEach { $0.mouseEntered(with: hoverEvent()) }

        return strip([close, add], spacing: Design.Spacing.large)
    }

    /// The display pane's own strip: one selected surface, one not.
    private static func paneTabStrip() -> NSView {
        let info = ThemedTabItemView(
            title: "Info",
            symbolName: "info.circle",
            placement: .horizontal,
            showsClose: true,
            inkSource: .chrome
        )
        info.isSelected = true

        let browser = ThemedTabItemView(
            title: "Browser",
            symbolName: "globe",
            placement: .horizontal,
            showsClose: true,
            inkSource: .chrome
        )

        return strip([info, browser], spacing: Design.Spacing.tight)
    }

    /// The seam between a conversation and the shell under it, which was invisible.
    private static func drawerSeam() -> NSView {
        let divider = ShellDrawerDivider()
        divider.translatesAutoresizingMaskIntoConstraints = false
        divider.heightAnchor.constraint(
            equalToConstant: ShellDrawerDefaults.dividerHeight
        ).isActive = true
        divider.widthAnchor.constraint(equalToConstant: 260).isActive = true

        return strip([divider], spacing: 0)
    }

    private static func hoverEvent() -> NSEvent {
        NSEvent.enterExitEvent(
            with: .mouseEntered,
            location: .zero,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            eventNumber: 0,
            trackingNumber: 0,
            userData: nil
        )!
    }

    private static func selected(_ button: ThemedIconButton) -> ThemedIconButton {
        button.isSelected = true
        return button
    }

    private static func strip(_ views: [NSView], spacing: CGFloat) -> NSView {
        let stack = NSStackView(views: views)
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = spacing
        stack.edgeInsets = NSEdgeInsets(
            top: Design.Spacing.inset,
            left: Design.Spacing.inset,
            bottom: Design.Spacing.inset,
            right: Design.Spacing.inset
        )
        return stack
    }

    // MARK: - Browser Chrome Harness

    private struct BrowserChromeStory {
        let name: String
        let width: CGFloat
        let context: BrowserContextKind
        let configure: (BrowserChromeBar) -> Void
    }

    private func browserChromePNG(
        story: BrowserChromeStory,
        theme: AppTheme,
        appearance: NSAppearance
    ) -> Data? {
        var data: Data?
        appearance.performAsCurrentDrawingAppearance {
            let height: CGFloat = 42
            let root = NSView(
                frame: NSRect(x: 0, y: 0, width: story.width, height: height)
            )
            root.wantsLayer = true
            root.layer?.backgroundColor = theme.resolved(
                .ground,
                appearance: appearance
            ).cgColor
            root.appearance = appearance

            let chrome = BrowserChromeBar(contextKind: story.context)
            story.configure(chrome)
            root.addSubview(chrome)
            NSLayoutConstraint.activate([
                chrome.topAnchor.constraint(equalTo: root.topAnchor),
                chrome.bottomAnchor.constraint(equalTo: root.bottomAnchor),
                chrome.leadingAnchor.constraint(equalTo: root.leadingAnchor),
                chrome.trailingAnchor.constraint(equalTo: root.trailingAnchor)
            ])

            let window = NSWindow(
                contentRect: root.bounds,
                styleMask: [.borderless],
                backing: .buffered,
                defer: false
            )
            window.isReleasedWhenClosed = false
            window.appearance = appearance
            window.contentView = root

            AppThemeRefresh.repaint(root)
            root.layoutSubtreeIfNeeded()
            chrome.updateResponsiveLayout()
            root.layoutSubtreeIfNeeded()

            if let rep = root.bitmapImageRepForCachingDisplay(in: root.bounds) {
                root.cacheDisplay(in: root.bounds, to: rep)
                data = rep.representation(using: .png, properties: [:])
            }
            window.close()
        }
        return data
    }

    private func browserResponsiveReviewPNG(
        width: CGFloat,
        theme: AppTheme,
        appearance: NSAppearance
    ) -> Data? {
        var data: Data?
        appearance.performAsCurrentDrawingAppearance {
            let height: CGFloat = 420
            let chromeHeight: CGFloat = 42
            let toolbarHeight: CGFloat = 40
            let root = NSView(frame: NSRect(x: 0, y: 0, width: width, height: height))
            root.wantsLayer = true
            root.layer?.backgroundColor = theme.resolved(
                .ground,
                appearance: appearance
            ).cgColor
            root.appearance = appearance

            let page = NSView(
                frame: NSRect(
                    x: 0,
                    y: 0,
                    width: width,
                    height: height - chromeHeight - toolbarHeight
                )
            )
            page.wantsLayer = true
            page.layer?.backgroundColor = theme.resolved(
                .surface,
                appearance: appearance
            ).cgColor

            let overlay = BrowserAnnotationOverlay(frame: page.bounds)
            overlay.markers = [
                BrowserAnnotationMarker(id: 1, point: CGPoint(x: width * 0.35, y: 120)),
                BrowserAnnotationMarker(id: 2, point: CGPoint(x: width * 0.68, y: 220))
            ]
            overlay.isAnnotating = true
            // The component under the pointer, as the browser reports it while aiming a pin.
            overlay.hoveredTarget = BrowserAnnotationTarget(
                rect: CGRect(x: width * 0.10, y: 262, width: width * 0.45, height: 44),
                label: "button \u{201C}Continue with another provider\u{201D}"
            )

            let toolbar = BrowserDeviceToolbar(
                frame: NSRect(
                    x: 0,
                    y: page.frame.maxY,
                    width: width,
                    height: toolbarHeight
                )
            )
            toolbar.translatesAutoresizingMaskIntoConstraints = true
            toolbar.setViewport(
                CGSize(width: 390, height: 844),
                preset: nil
            )

            let chrome = BrowserChromeBar(contextKind: .shared)
            chrome.translatesAutoresizingMaskIntoConstraints = true
            chrome.frame = NSRect(
                x: 0,
                y: toolbar.frame.maxY,
                width: width,
                height: chromeHeight
            )
            chrome.addressField.stringValue = "localhost:3000/docs"
            chrome.setNavigationState(canGoBack: true, canGoForward: false, popupDepth: 0)
            chrome.setAnnotating(true)

            root.addSubview(page)
            root.addSubview(overlay)
            root.addSubview(toolbar)
            root.addSubview(chrome)

            let window = NSWindow(
                contentRect: root.bounds,
                styleMask: [.borderless],
                backing: .buffered,
                defer: false
            )
            window.isReleasedWhenClosed = false
            window.appearance = appearance
            window.contentView = root

            AppThemeRefresh.repaint(root)
            toolbar.needsLayout = true
            toolbar.layoutSubtreeIfNeeded()
            chrome.needsLayout = true
            chrome.updateResponsiveLayout()
            chrome.layoutSubtreeIfNeeded()
            overlay.needsDisplay = true
            root.layoutSubtreeIfNeeded()

            if let rep = root.bitmapImageRepForCachingDisplay(in: root.bounds) {
                root.cacheDisplay(in: root.bounds, to: rep)
                data = rep.representation(using: .png, properties: [:])
            }
            window.close()
        }
        return data
    }

    // MARK: - Harness

    /// Rendered inside a real window, not from a detached view: `BackdropOverlay` inks itself when
    /// it moves to one, so a view drawn without a window would report only what `draw(_:)` reads
    /// directly and leave every label at its default colour.
    private func write(story: String, make: @escaping () -> NSView) throws -> Int {
        let directory = Render.directory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let originalBackdrop = WindowBackdrop.ground
        defer { WindowBackdrop.set(originalBackdrop) }

        var written = 0
        for backdrop in Render.backdrops {
            let appearance = try XCTUnwrap(NSAppearance(named: backdrop.appearance))
            WindowBackdrop.set(.terminal(backdrop.colour))

            let content = make()
            content.translatesAutoresizingMaskIntoConstraints = false

            let host = NSView()
            host.wantsLayer = true
            host.addSubview(content)
            NSLayoutConstraint.activate([
                content.topAnchor.constraint(equalTo: host.topAnchor),
                content.bottomAnchor.constraint(equalTo: host.bottomAnchor),
                content.leadingAnchor.constraint(equalTo: host.leadingAnchor),
                content.trailingAnchor.constraint(equalTo: host.trailingAnchor)
            ])

            let window = NSWindow(
                contentRect: NSRect(origin: .zero, size: NSSize(width: 520, height: 80)),
                styleMask: [.borderless],
                backing: .buffered,
                defer: false
            )
            window.isReleasedWhenClosed = false
            window.appearance = appearance
            host.appearance = appearance
            window.contentView = host
            host.frame = NSRect(origin: .zero, size: host.fittingSize)
            host.layer?.backgroundColor = backdrop.colour.cgColor
            AppThemeRefresh.repaint(host)
            host.layoutSubtreeIfNeeded()

            guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else {
                XCTFail("Failed to make a bitmap for \(story) on \(backdrop.name)")
                continue
            }
            host.cacheDisplay(in: host.bounds, to: rep)

            let data = try XCTUnwrap(
                rep.representation(using: .png, properties: [:]),
                "Failed to render \(story) on \(backdrop.name)"
            )
            try data.write(
                to: directory.appendingPathComponent("chrome-\(story)-\(backdrop.name).png")
            )
            window.close()
            written += 1
        }
        return written
    }
}
