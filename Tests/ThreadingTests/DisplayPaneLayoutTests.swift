import AppKit
import XCTest
@preconcurrency import WebKit
@testable import Threading

/// What the display panel lets the window do, and how the picture inside it is reached.
///
/// The first two parts of this file are the same bug seen twice: the panel is a *panel*, and it
/// had been quietly deciding things that belong to the window and to the user — how small the
/// window may be, and whether the image in it can be opened properly. The last part is where a
/// shown picture now *arrives*: the Attachments list rather than a tab of its own.
@MainActor
final class DisplayPaneLayoutTests: HostedStoreTestCase {

    func testDisplayImagePixelGateBoundsDimensionsAndDecodedMemoryWithoutOverflow() {
        XCTAssertTrue(DisplayImageSafety.accepts(width: 1_440, height: 20_000))
        XCTAssertFalse(DisplayImageSafety.accepts(width: 0, height: 100))
        XCTAssertFalse(DisplayImageSafety.accepts(
            width: MCPDefaults.maximumImagePixelDimension + 1,
            height: 1
        ))
        XCTAssertFalse(DisplayImageSafety.accepts(width: 10_000, height: 10_000))
        XCTAssertFalse(DisplayImageSafety.accepts(width: Int.max, height: Int.max))
    }

    // MARK: - Fixtures

    /// A picture with a file behind it, since inspection and file actions need one that exists.
    private func imageOnDisk(
        size: NSSize,
        name: String = "shot.png"
    ) throws -> (content: DisplayContent, url: URL) {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("threading-pane-\(UUID().uuidString)-\(name)")
        let image = NSImage(size: size)
        image.lockFocus()
        NSColor.systemTeal.setFill()
        NSRect(origin: .zero, size: size).fill()
        image.unlockFocus()

        let bitmap = try XCTUnwrap(image.representations.first as? NSBitmapImageRep
            ?? NSBitmapImageRep(data: image.tiffRepresentation ?? Data()))
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: url)

        return (
            DisplayContent(body: .image(image, url: url), title: nil, subtitle: name),
            url
        )
    }

    private func filledImage(size: NSSize, color: NSColor) -> NSImage {
        let image = NSImage(size: size)
        image.lockFocus()
        color.setFill()
        NSRect(origin: .zero, size: size).fill()
        image.unlockFocus()
        return image
    }

    /// What the view actually paints, away from its own edges — the hover's accent stroke and the
    /// focus ring both live there, and neither is what these assertions are about.
    private func centrePixel(of view: NSView) throws -> NSColor {
        let rep = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: rep)
        let pixel = try XCTUnwrap(rep.colorAt(x: rep.pixelsWide / 2, y: rep.pixelsHigh / 2))
        return try XCTUnwrap(pixel.usingColorSpace(.sRGB))
    }

    /// How far apart two colours are across their channels. A wash that only shifts a hue and one
    /// that replaces the pixel outright are the same "different colour" until the size of the
    /// move is the thing being measured.
    private func distance(from: NSColor, to: NSColor) -> CGFloat {
        let red = from.redComponent - to.redComponent
        let green = from.greenComponent - to.greenComponent
        let blue = from.blueComponent - to.blueComponent
        return sqrt(red * red + green * green + blue * blue)
    }

    /// A role at full strength — what the pixel would have become had the fill covered it.
    private func opaque(_ color: NSColor) throws -> NSColor {
        try XCTUnwrap(color.usingColorSpace(.sRGB)).withAlphaComponent(1)
    }

    private func crossingEvent(_ type: NSEvent.EventType) throws -> NSEvent {
        try XCTUnwrap(
            NSEvent.enterExitEvent(
                with: type,
                location: .zero,
                modifierFlags: [],
                timestamp: 0,
                windowNumber: 0,
                context: nil,
                eventNumber: 0,
                trackingNumber: 0,
                userData: nil
            )
        )
    }

    private func paneShowing(_ content: DisplayContent) -> DisplayPaneController {
        let pane = DisplayPaneController()
        let sessionID = SessionID()
        pane.showSession(sessionID)
        pane.addContentTab(content, for: sessionID)
        pane.view.layoutSubtreeIfNeeded()
        return pane
    }

    /// An empty pane and an image tab have no reason to launch WebKit. The shared document
    /// renderer is mounted only when HTML becomes the selected content.
    func testDocumentRendererIsLazyUntilHTMLContentIsShown() {
        let pane = DisplayPaneController()
        pane.view.frame = NSRect(x: 0, y: 0, width: 420, height: 700)
        let sessionID = SessionID()
        pane.showSession(sessionID)
        pane.view.layoutSubtreeIfNeeded()

        XCTAssertTrue(descendants(of: pane.view).compactMap { $0 as? WKWebView }.isEmpty)

        pane.addContentTab(
            DisplayContent(
                body: .image(
                    filledImage(size: NSSize(width: 20, height: 20), color: .systemTeal),
                    url: URL(fileURLWithPath: "/tmp/lazy-display-pane-image.png")
                ),
                title: "Image",
                subtitle: "Image"
            ),
            for: sessionID
        )
        XCTAssertTrue(descendants(of: pane.view).compactMap { $0 as? WKWebView }.isEmpty)

        pane.addContentTab(
            DisplayContent(
                body: .html("<p>Document</p>"),
                title: "Document",
                subtitle: "Document"
            ),
            for: sessionID
        )
        XCTAssertEqual(descendants(of: pane.view).compactMap { $0 as? WKWebView }.count, 1)
    }

    // MARK: - The Picture Does Not Size the Pane

    /// `NSImageView` reports the picture's own dimensions as its intrinsic content size, so the
    /// pane it sits in inherits an opinion about how wide it should be from whatever the agent
    /// happened to screenshot. Stating no intrinsic size removes the opinion rather than
    /// out-prioritising it — the difference being that a floored priority is still *in* the
    /// layout, and still what `fittingSize` answers.
    func testTheImageLendsThePaneNoWidthOfItsOwn() throws {
        let tiny = paneShowing(try imageOnDisk(size: NSSize(width: 8, height: 8)).content)
        let huge = paneShowing(try imageOnDisk(size: NSSize(width: 1320, height: 1100)).content)

        XCTAssertEqual(
            tiny.view.fittingSize.width,
            huge.view.fittingSize.width,
            "a 1320pt-wide screenshot asked the panel to be wider than an 8pt one"
        )
    }

    /// The caption is the same claim in words. It is held off the leading edge with a `>=`, which
    /// reads as "shrink me first" and is not what an `NSTextField` does: its compression
    /// resistance charged the pane the whole file name, and a pane's width is the window's
    /// minimum. It already truncates in the middle — this is only what makes it do so before the
    /// window is made to grow instead.
    func testTheCaptionLendsThePaneNoWidthOfItsOwn() throws {
        let short = paneShowing(
            try imageOnDisk(size: NSSize(width: 40, height: 40), name: "a.png").content
        )
        let long = paneShowing(
            try imageOnDisk(
                size: NSSize(width: 40, height: 40),
                name: String(repeating: "a-rather-long-", count: 8) + "name.png"
            ).content
        )

        XCTAssertEqual(
            short.view.fittingSize.width,
            long.view.fittingSize.width,
            "a long file name asked the panel — and so the window — to be wider"
        )
    }

    func testThePreviewStatesNoIntrinsicSize() {
        let preview = ThemedImagePreview()
        preview.image = NSImage(size: NSSize(width: 900, height: 600))

        XCTAssertEqual(preview.intrinsicContentSize.width, NSView.noIntrinsicMetric)
        XCTAssertEqual(preview.intrinsicContentSize.height, NSView.noIntrinsicMetric)
    }

    /// Scaled down to fit, never up, centred across the width and pinned to the top.
    func testTheImageFitsWithoutBeingBlownUp() {
        let bounds = NSRect(x: 0, y: 0, width: 200, height: 400)

        let wide = ThemedImagePreview.fittedRect(
            for: NSSize(width: 1000, height: 500),
            in: bounds
        )
        XCTAssertEqual(wide.width, 200, "a wide image should fill the width")
        XCTAssertEqual(wide.height, 100)
        XCTAssertEqual(wide.maxY, bounds.maxY, "the picture should hang from the top edge")

        let small = ThemedImagePreview.fittedRect(for: NSSize(width: 20, height: 10), in: bounds)
        XCTAssertEqual(small.size, NSSize(width: 20, height: 10), "a small image was blown up")
        XCTAssertEqual(small.midX, bounds.midX, "a small image should be centred across")

        XCTAssertEqual(
            ThemedImagePreview.fittedRect(for: .zero, in: bounds),
            .zero,
            "an image with no size should draw nothing rather than divide by it"
        )
    }

    // MARK: - The Panel Does Not Size the Window

    /// A split item's `minimumThickness` is a **required** constraint, so a pane minimum is
    /// also a window minimum — and `display_image` opens this panel, which once meant showing a
    /// picture quietly took 200pt off how small the window was allowed to be.
    ///
    /// Inspect the property that creates that required constraint. `NSView.fittingSize` is not
    /// a proxy for it: the split item's non-required holding constraint deliberately carries
    /// the *current* divider width into fitting-size calculation. This test used to pass only
    /// because it measured before the asynchronous width restoration completed; moving that
    /// restoration into the reveal correctly made the race deterministic and exposed the bad
    /// measurement. The next test owns the separate claim that the panel opens wide enough.
    func testThePanelHardFloorCostsOnlyItsOwnChrome() throws {
        let controller = makeMainWindowController()
        let item = try XCTUnwrap(controller.splitViewController.splitViewItems.last)

        XCTAssertEqual(item.minimumThickness, DisplayPaneDefaults.slimmestWidth)
        XCTAssertLessThan(
            item.minimumThickness,
            DisplayPaneDefaults.minWidth,
            "the panel's required floor is its readable opening width rather than its chrome"
        )
    }

    // MARK: - The Panel Opens Wide Enough to Read

    /// A required width constraint, laid out and then released, holds the pane for exactly as
    /// long as it is active — the split view keeps positioning its items with its own constraint
    /// at `holdingPriority`, whose constant is still the thickness the pane had. So the reveal
    /// measured 372 while the constraint was up and **48** on the next layout pass: the panel's
    /// chrome floor, which is where `display_image` opened it.
    ///
    /// Driven through the divider, so the width becomes the split view's own answer and survives
    /// the passes that follow.
    func testThePanelOpensAtTheWidthItRemembersRatherThanItsChromeFloor() throws {
        let previous = DisplayPaneWidth.stored
        let previousSidebar = SidebarWidth.stored
        defer {
            DisplayPaneWidth.stored = previous
            if let previousSidebar {
                SidebarWidth.record(previousSidebar)
            } else {
                SidebarWidth.reset()
            }
        }
        // The hosted-test preference suite survives test processes. A width left by an
        // unrelated sidebar test can legitimately leave the terminal too little room for a
        // 420pt panel, turning this into an order-dependent test of AppKit's clamping instead
        // of the remembered-width contract named here.
        SidebarWidth.reset()
        DisplayPaneWidth.stored = 420

        let controller = makeMainWindowController()
        let window = try XCTUnwrap(controller.window)
        window.setContentSize(NSSize(width: 1400, height: 800))

        controller.setDisplayPaneVisible(true)
        window.layoutIfNeeded()
        settle()
        window.layoutIfNeeded()

        XCTAssertEqual(
            controller.displayPaneController.view.bounds.width, 420, accuracy: 1,
            "the panel opened at \(controller.displayPaneController.view.bounds.width)"
        )
    }

    // MARK: - The Corner Between the Two Seams

    /// The attachments fold runs edge to edge, so its leading end lands on the window's own split
    /// seam — but that is four constraints and three levels of hosting away from where either
    /// component is tested, and a component asserted outside the container it ships in can pass
    /// while being unusable. So the claim is made *in the window*: the corner exists there, and
    /// what it holds is the panel's divider.
    func testTheAttachmentsFoldsCornerHoldsTheWindowsOwnSeam() throws {
        let previousWidth = DisplayPaneWidth.stored
        let previousSidebar = SidebarWidth.stored
        defer {
            DisplayPaneWidth.stored = previousWidth
            if let previousSidebar { SidebarWidth.record(previousSidebar) } else { SidebarWidth.reset() }
        }
        SidebarWidth.reset()
        DisplayPaneWidth.stored = 420

        let fixture = try projectAndSession()
        defer { fixture.tearDown() }
        SessionAttachmentStore.shared.record(
            declared: try writePNG(in: fixture.folder, named: "chart.png", color: .systemBlue),
            sessionID: fixture.sessionID,
            projectRoot: fixture.folder,
            origin: .agent
        )

        let controller = makeMainWindowController()
        let window = try XCTUnwrap(controller.window)
        window.setContentSize(NSSize(width: 1400, height: 800))
        controller.setDisplayPaneVisible(true)
        window.layoutIfNeeded()
        settle()
        window.layoutIfNeeded()

        controller.displayPaneController.showSession(fixture.sessionID)
        let attachments = try XCTUnwrap(
            controller.displayPaneController.activateAttachments(for: fixture.sessionID),
            "the panel opened no Attachments tab"
        )
        window.layoutIfNeeded()

        let fold = try XCTUnwrap(
            descendants(of: attachments.view).compactMap { $0 as? PaneFoldDivider }.first,
            "the attachments pane grew no fold"
        )
        let split = try XCTUnwrap(controller.splitViewController.splitView as? ThemedSplitView)
        let panel = controller.displayPaneController.view.bounds.width

        let corner = NSPoint(x: fold.bounds.minX + 2, y: fold.bounds.midY)
        XCTAssertEqual(
            fold.cornerSide(at: corner),
            .leading,
            "the fold's leading end does not reach the panel's own edge in the window"
        )
        XCTAssertNil(
            fold.cornerSide(at: NSPoint(x: fold.bounds.midX, y: fold.bounds.midY)),
            "the middle of the fold claimed the panel's divider"
        )

        fold.mouseDown(with: try XCTUnwrap(NSEvent.mouseEvent(
            with: .leftMouseDown,
            location: fold.convert(corner, to: nil),
            modifierFlags: [],
            timestamp: 0,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: 0,
            clickCount: 1,
            pressure: 1
        )))
        split.moveHeldSeam(by: -60)
        window.layoutIfNeeded()

        XCTAssertEqual(
            controller.displayPaneController.view.bounds.width,
            panel + 60,
            accuracy: 1,
            "the corner did not widen the panel it stands in the edge of"
        )
    }

    /// The panel is written to on every divider move, and the test bundle is hosted in the app —
    /// so this has to be the *scratch* suite, or a fixture window's idea of how wide the panel is
    /// lands in the preferences of the app the developer is running. That is not hypothetical:
    /// it is how a real machine came to have the 48pt floor saved as its panel width.
    func testTheRememberedWidthIsNotWrittenToTheDevelopersOwnPreferences() {
        XCTAssertTrue(PreferenceStore.isRedirected, "a hosted test is writing the real defaults")

        let previous = DisplayPaneWidth.stored
        defer { DisplayPaneWidth.stored = previous }
        DisplayPaneWidth.stored = 517

        XCTAssertEqual(DisplayPaneWidth.stored, 517)
        XCTAssertNotEqual(
            UserDefaults.standard.double(forKey: "ThreadingDisplayPaneWidth"), 517,
            "the panel's width went into the real preferences"
        )
    }

    /// A width nobody chose is not restored: below the panel's own `minWidth` the stored value
    /// is read as absent, so a sliver recorded by a layout — the bug above — cannot become the
    /// width every later reveal opens at.
    func testASliverIsNeverRestoredAsAChosenWidth() {
        let previous = DisplayPaneWidth.stored
        defer { DisplayPaneWidth.stored = previous }

        DisplayPaneWidth.stored = DisplayPaneDefaults.slimmestWidth
        XCTAssertEqual(DisplayPaneWidth.stored, DisplayPaneDefaults.defaultWidth)
        XCTAssertGreaterThanOrEqual(
            DisplayPaneWidth.opening(in: 1400), DisplayPaneDefaults.defaultWidth
        )
    }

    /// With no width ever chosen, the panel takes a share of the window rather than one fixed
    /// number — floored so it stays legible on a small window, capped so it shares a large one.
    func testAFirstOpenScalesWithTheWindow() {
        let previous = DisplayPaneWidth.stored
        defer { DisplayPaneWidth.stored = previous }
        DisplayPaneWidth.stored = 0

        XCTAssertEqual(DisplayPaneWidth.opening(in: 900), DisplayPaneDefaults.defaultWidth)
        XCTAssertEqual(
            DisplayPaneWidth.opening(in: 1600),
            1600 * DisplayPaneDefaults.openingFraction,
            accuracy: 0.5
        )
        XCTAssertEqual(DisplayPaneWidth.opening(in: 4000), DisplayPaneDefaults.widestOpening)
        XCTAssertEqual(DisplayPaneWidth.opening(in: 0), DisplayPaneDefaults.defaultWidth)
    }

    /// The reveal restores the width two run-loop turns later; ours queue behind both.
    private func settle() {
        let settled = expectation(description: "the panel settled")
        DispatchQueue.main.async {
            DispatchQueue.main.async { DispatchQueue.main.async { settled.fulfill() } }
        }
        wait(for: [settled], timeout: 2)
    }

    // MARK: - The User Sizes the Panel, Not Its Tabs

    /// `NSSplitViewController` holds a divider where it was dragged with a constraint at the
    /// item's holding priority — `DisplayPaneDefaults.holdingPriority`, 260. Anything inside a
    /// pane that resists being *stretched* above that priority is therefore the pane's maximum
    /// width, and the panel's tab strip hugged its tabs at `.defaultHigh`: the divider stopped a
    /// few points past the `+` and the panel could be dragged narrower but never wider — with the
    /// wall moving as the page renamed itself, since a longer title bought a wider panel.
    ///
    /// Driven at the divider's own priority rather than through a required width, which would
    /// out-rank the bug and pass with it in place.
    func testTheDividerCanTakeThePanelPastItsTabs() throws {
        let (content, url) = try imageOnDisk(size: NSSize(width: 40, height: 40))
        defer { try? FileManager.default.removeItem(at: url) }

        let pane = paneShowing(content)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1000, height: 600),
            styleMask: [.titled, .resizable],
            backing: .buffered,
            defer: false
        )
        let host = try XCTUnwrap(window.contentView)
        pane.view.translatesAutoresizingMaskIntoConstraints = false
        host.addSubview(pane.view)

        let requested: CGFloat = 700
        let divider = pane.view.widthAnchor.constraint(equalToConstant: requested)
        divider.priority = DisplayPaneDefaults.holdingPriority

        NSLayoutConstraint.activate([
            pane.view.topAnchor.constraint(equalTo: host.topAnchor),
            pane.view.bottomAnchor.constraint(equalTo: host.bottomAnchor),
            pane.view.trailingAnchor.constraint(equalTo: host.trailingAnchor),
            pane.view.leadingAnchor.constraint(greaterThanOrEqualTo: host.leadingAnchor),
            divider
        ])
        host.layoutSubtreeIfNeeded()

        XCTAssertEqual(
            pane.view.frame.width,
            requested,
            accuracy: 1,
            "the panel stopped at its tabs' own width instead of where the divider was put"
        )
    }

    /// The strip's default hugging is right for the drawer — whose `+` sits after the tabs and
    /// has to follow them — and wrong for the panel, whose `+` is pinned to the pane's trailing
    /// edge. Both halves are asserted because either mistake is silent: too high and the host
    /// cannot be grown, too low and the control after the strip drifts away from the tabs.
    func testTheStripOnlyOutranksADividerWhereItsHostFollowsItsTabs() {
        let strip = ThemedTabStripView(inkSource: .chrome)

        XCTAssertEqual(
            strip.contentHuggingPriority(for: .horizontal),
            .defaultHigh,
            "a host that places a control after the tabs needs the strip to hug them"
        )

        strip.fillsHostWidth = true

        XCTAssertLessThan(
            strip.contentHuggingPriority(for: .horizontal).rawValue,
            DisplayPaneDefaults.holdingPriority.rawValue,
            "a stretched strip still outranked the divider that places its pane"
        )
    }

    // MARK: - The Panel's Own Toggle

    /// Pressing the toggle in the panel's corner shuts the panel — the same collapse the
    /// session header's copy of it and **View ▸ Display Panel** perform, through the one route
    /// the window already exposes for the last tab closing.
    func testTheCornerToggleCollapsesThePanel() throws {
        let controller = makeMainWindowController()
        let window = try XCTUnwrap(controller.window)
        window.setContentSize(NSSize(width: 1400, height: 800))

        controller.setDisplayPaneVisible(true)
        window.layoutIfNeeded()
        settle()

        let item = try XCTUnwrap(controller.splitViewController.splitViewItems.last)
        XCTAssertFalse(item.isCollapsed, "the panel never opened, so nothing was closed")

        let toggle = try XCTUnwrap(
            descendant(
                in: item.viewController.view,
                accessibilityTitle: DisplayPanelToggle.accessibility
            ),
            "the panel's header has no toggle in its corner"
        )
        XCTAssertTrue(toggle.accessibilityPerformPress())
        settle()

        XCTAssertTrue(item.isCollapsed, "the corner toggle did not shut the panel")
    }

    /// **One toggle, and it does not move — the same view, in both homes.** The control that
    /// opens the panel sits at the trailing end of the session header's group; the panel opens
    /// *underneath* it and the panel's own corner holds it from then on, at the same point in
    /// the window, so the switch is never offered twice and never leaves the corner.
    ///
    /// This is what the corner used to get wrong twice over. It held an ✕ — a different control,
    /// saying "close" where the toolbar said "toggle" — which left the toggle itself a pane's
    /// width to the left of where the eye had just been. Its replacement was a *second* toggle
    /// that appeared as the group's hid, and that cost the gesture: AppKit sends every click
    /// after the first of a chain to the view that took the first one, so the toggle answered
    /// one press and then nothing until the pointer moved. Hence the identity assertions here.
    func testThePanelsToggleKeepsItsPlaceWhenThePanelOpensUnderIt() throws {
        let controller = makeMainWindowController()
        let window = try XCTUnwrap(controller.window)
        window.setContentSize(NSSize(width: 1400, height: 800))
        window.layoutIfNeeded()
        settle()

        let item = try XCTUnwrap(controller.splitViewController.splitViewItems.last)
        XCTAssertTrue(item.isCollapsed, "the fixture opened with the panel already showing")

        let content = try XCTUnwrap(window.contentView)
        let inHeader = try XCTUnwrap(
            descendant(in: content, accessibilityTitle: DisplayPanelToggle.accessibility),
            "the session header has no display-panel toggle"
        )
        XCTAssertFalse(inHeader.isHidden, "the only toggle was hidden while the panel was shut")
        let shutFrame = inHeader.convert(inHeader.bounds, to: nil)

        controller.setDisplayPaneVisible(true)
        window.layoutIfNeeded()
        settle()

        let inCorner = try XCTUnwrap(
            descendant(
                in: item.viewController.view,
                accessibilityTitle: DisplayPanelToggle.accessibility
            ),
            "the open panel's corner has no toggle"
        )
        XCTAssertTrue(
            inCorner === inHeader,
            "the corner drew a second toggle instead of taking the one that was already there"
        )
        XCTAssertEqual(
            descendants(in: content, accessibilityTitle: DisplayPanelToggle.accessibility).count,
            1,
            "the window offers the same switch twice"
        )
        let openFrame = inCorner.convert(inCorner.bounds, to: nil)

        XCTAssertEqual(
            openFrame.midX, shutFrame.midX, accuracy: 0.5,
            "the toggle moved sideways as the panel arrived under it"
        )
        XCTAssertEqual(
            openFrame.midY, shutFrame.midY, accuracy: 0.5,
            "the two headers' toggles sit on different lines"
        )
        XCTAssertEqual(
            openFrame.size, shutFrame.size,
            "the corner drew the same control at a different size"
        )

        controller.setDisplayPaneVisible(false)
        window.layoutIfNeeded()
        settle()
        XCTAssertFalse(
            inHeader.isHidden,
            "shutting the panel took the toggle away with it"
        )
        XCTAssertEqual(
            inHeader.convert(inHeader.bounds, to: nil).origin,
            shutFrame.origin,
            "the toggle came home to a different place than it left from"
        )
    }

    /// The tabs are not thrown away with the pane. The toggle hides the panel; reopening it
    /// finds the same surfaces waiting, exactly as a dormant session's scrollback is.
    ///
    /// Driven through the window because the corner holds the *window's* one toggle: a pane
    /// standing on its own has the slot it moves into and nothing in it.
    func testTheCornerToggleKeepsTheTabsItHides() throws {
        let controller = makeMainWindowController()
        let window = try XCTUnwrap(controller.window)
        window.setContentSize(NSSize(width: 1400, height: 800))
        let pane = controller.displayPaneController
        let sessionID = SessionID()
        pane.showSession(sessionID)
        pane.addContentTab(
            DisplayContent(
                body: .html("<p>Kept while hidden</p>"),
                title: "Fixture",
                subtitle: "Fixture document"
            ),
            for: sessionID
        )
        controller.setDisplayPaneVisible(true)
        window.layoutIfNeeded()
        settle()

        let item = try XCTUnwrap(controller.splitViewController.splitViewItems.last)
        let toggle = try XCTUnwrap(
            descendant(
                in: item.viewController.view,
                accessibilityTitle: DisplayPanelToggle.accessibility
            ),
            "the open panel's corner has no toggle"
        )
        XCTAssertTrue(toggle.accessibilityPerformPress())
        settle()

        XCTAssertTrue(item.isCollapsed, "the corner toggle did not shut the panel")
        XCTAssertTrue(pane.hasContent(for: sessionID), "hiding the panel discarded its tabs")
    }

    /// The global theme document takes the row from the controls that act on *this chat's* tabs.
    /// The toggle is not one of them: it acts on the pane, and the pane is on screen either way.
    func testTheToggleStaysWhileTheGlobalDocumentTakesTheRow() throws {
        let pane = DisplayPaneController()
        pane.view.frame = NSRect(x: 0, y: 0, width: 420, height: 700)
        let sessionID = SessionID()
        pane.showSession(sessionID)
        pane.showCurrentTheme()
        pane.view.layoutSubtreeIfNeeded()

        let newTab = try XCTUnwrap(
            descendant(in: pane.view, accessibilityTitle: L10n.string("New tab"))
        )
        // The corner itself, since the toggle standing in it belongs to the window: a pane in a
        // fixture has the slot and no window to have put a toggle in it.
        let corner = pane.panelToggleSlot

        XCTAssertTrue(newTab.isHidden, "the chat-scoped + remained beside Current Theme")
        XCTAssertFalse(corner.isHidden, "the way out of the panel went with the chat's controls")
        let taken = corner.convert(corner.bounds, to: pane.view)

        pane.showSessionTabs(sessionID)
        pane.view.layoutSubtreeIfNeeded()
        XCTAssertFalse(newTab.isHidden)
        XCTAssertFalse(corner.isHidden)
        XCTAssertEqual(
            corner.convert(corner.bounds, to: pane.view),
            taken,
            "the corner moved as the row changed hands"
        )
    }

    /// The floor is the row's two trailing controls and the margin around them, so at
    /// `slimmestWidth` both are still whole and inside the pane.
    ///
    /// The tab strip is what yields: its trailing constraint sits just below required precisely
    /// so this width closes it to nothing instead of asking it for a negative one and having
    /// AppKit break a constraint to grant it.
    func testBothTrailingControlsFitThePanesFloor() throws {
        let pane = DisplayPaneController()
        pane.view.frame = NSRect(
            x: 0, y: 0,
            width: DisplayPaneDefaults.slimmestWidth,
            height: 400
        )
        pane.showSession(SessionID())
        pane.view.layoutSubtreeIfNeeded()

        let newTab = try XCTUnwrap(
            descendant(in: pane.view, accessibilityTitle: L10n.string("New tab"))
        )

        for control in [newTab, pane.panelToggleSlot] {
            let frame = control.convert(control.bounds, to: pane.view)
            XCTAssertEqual(
                frame.width, Design.Size.toolbarButtonWidth, accuracy: 0.5,
                "a trailing control was squeezed out of shape at the pane's floor"
            )
            XCTAssertGreaterThanOrEqual(
                frame.minX, 0,
                "a trailing control hung over the pane's leading edge at its floor"
            )
            XCTAssertLessThanOrEqual(frame.maxX, pane.view.bounds.width)
        }
        XCTAssertFalse(
            pane.view.hasAmbiguousLayout,
            "the header row has no single answer at the pane's floor"
        )
    }

    // MARK: - The Current Theme Is Global

    /// The inspector occupies the panel beside a chat, but belongs to neither that chat nor the
    /// one selected next. It therefore stays visible across selection and leaves both persisted
    /// tab lists untouched; an explicit per-session surface command is what takes the panel back.
    func testCurrentThemeSurvivesSessionSelectionWithoutJoiningEitherTabList() {
        let pane = DisplayPaneController()
        pane.view.frame = NSRect(x: 0, y: 0, width: 420, height: 700)
        let first = SessionID()
        let second = SessionID()

        pane.showSession(first)
        pane.showCurrentTheme()
        pane.view.layoutSubtreeIfNeeded()

        XCTAssertTrue(pane.isShowingCurrentTheme)
        XCTAssertEqual(pane.currentSessionID, first)
        XCTAssertFalse(pane.hasContent(for: first), "the global inspector became a chat tab")
        XCTAssertNotNil(
            descendant(in: pane.view, accessibilityIdentifier: "current-theme"),
            "the live theme document was not installed into the panel"
        )
        let newTab = descendant(in: pane.view, accessibilityTitle: L10n.string("New tab"))
        XCTAssertTrue(newTab?.isHidden == true, "the chat-scoped + remained beside Current Theme")

        pane.showSession(second)
        XCTAssertTrue(pane.isShowingCurrentTheme, "changing chats closed the global document")
        XCTAssertEqual(pane.currentSessionID, second)
        XCTAssertFalse(pane.hasContent(for: second), "selection copied the inspector into a chat")

        pane.showSessionTabs(second)
        XCTAssertFalse(pane.isShowingCurrentTheme)
        XCTAssertFalse(newTab?.isHidden == true, "leaving Current Theme did not restore the +")
    }

    /// The door belongs beside the room it opens. The sidebar showed none of this document and
    /// carried a permanent row to it anyway; the panel that *does* show it carries the way in.
    ///
    /// It is still not one of the chat's surfaces — choosing it takes the whole panel and joins
    /// no tab list — so it sits behind its own separator, below them, and follows the same Tools
    /// switch as **View ▸ Current Theme**.
    func testTheNewTabMenuOffersTheGlobalDocumentBelowTheChatsOwnSurfaces() throws {
        let settings = AppSettings.shared
        let previous = settings.disabledToolGroupIDs
        defer { settings.disabledToolGroupIDs = previous }
        settings.setToolGroup(MCPToolCatalog.appearance.id, enabled: true)

        let pane = DisplayPaneController()
        pane.view.frame = NSRect(x: 0, y: 0, width: 420, height: 700)
        let sessionID = SessionID()
        pane.showSession(sessionID)

        let entries = pane.newTabEntries(for: sessionID)
        let theme = try XCTUnwrap(
            entries.firstIndex { $0.itemTitle == L10n.string("Current Theme") },
            "the panel's + offers no way into the app-wide theme document"
        )
        let review = try XCTUnwrap(entries.firstIndex { $0.itemTitle == "Review" })
        XCTAssertGreaterThan(theme, review, "the global document led the chat's own surfaces")
        XCTAssertEqual(
            entries[review].item?.shortcut,
            ShortcutOverrideStore.shared.shortcut(forID: AppCommands.ID.review)
        )
        XCTAssertEqual(
            entries[theme].item?.shortcut,
            ShortcutOverrideStore.shared.shortcut(forID: AppCommands.ID.currentTheme)
        )
        guard case .separator = entries[theme - 1] else {
            return XCTFail("Current Theme reads as another of this chat's tabs")
        }

        try XCTUnwrap(entries[theme].item).onChoose?()
        XCTAssertTrue(pane.isShowingCurrentTheme, "the entry did not open the document")
        XCTAssertFalse(pane.hasContent(for: sessionID), "the global document became a chat tab")

        settings.setToolGroup(MCPToolCatalog.appearance.id, enabled: false)
        XCTAssertNil(
            pane.newTabEntries(for: sessionID).firstIndex {
                $0.itemTitle == L10n.string("Current Theme")
            },
            "the + kept a door to a document no enabled tool can edit"
        )
    }

    /// Activity and Info are destinations inside one durable surface, not two singleton tabs
    /// that spend the narrow strip naming the same session twice.
    func testTheNewTabMenuOffersOneOverviewInsteadOfActivityAndInfo() {
        let pane = DisplayPaneController()
        let entries = pane.newTabEntries(for: SessionID())
        let titles = entries.compactMap(\.itemTitle)

        XCTAssertEqual(titles.filter { $0 == L10n.string("Overview") }.count, 1)
        XCTAssertFalse(titles.contains(L10n.string("Activity")))
        XCTAssertFalse(titles.contains(L10n.string("Info")))
    }

    /// The old commands remain useful anchors, but both focus a section of the same tab. The
    /// selected section is written through the old persisted kind so layouts stay compatible
    /// with builds from before the merge.
    func testActivityAndInfoCommandsFocusOnePersistedOverview() throws {
        let fixture = try projectAndSession()
        defer { fixture.tearDown() }
        let pane = DisplayPaneController()

        XCTAssertNotNil(pane.activateFiles(for: fixture.sessionID))
        var tabs = pane.tabs(for: fixture.sessionID)
        XCTAssertEqual(tabs.count, 1)
        XCTAssertEqual(tabs.first?.title, L10n.string("Overview"))
        XCTAssertEqual(tabs.first?.overview?.selectedSection, .activity)
        XCTAssertEqual(
            DisplayPaneStore.shared.loadLayout(for: fixture.sessionID)?.panelTabs.first?.kind,
            .files
        )

        let originalID = tabs.first?.id
        XCTAssertNotNil(pane.activateInfo(for: fixture.sessionID))
        tabs = pane.tabs(for: fixture.sessionID)
        XCTAssertEqual(tabs.count, 1)
        XCTAssertEqual(tabs.first?.id, originalID)
        XCTAssertEqual(tabs.first?.overview?.selectedSection, .info)
        XCTAssertEqual(
            DisplayPaneStore.shared.loadLayout(for: fixture.sessionID)?.panelTabs.first?.kind,
            .info
        )
    }

    /// Layouts written before Overview can legitimately contain both old singleton tabs. The
    /// selected one supplies the section, identity and strip position; the duplicate disappears.
    func testRestoreMergesLegacyActivityAndInfoTabsIntoTheSelectedOverview() throws {
        let fixture = try projectAndSession()
        defer { fixture.tearDown() }
        let activityID = UUID()
        let infoID = UUID()
        DisplayPaneStore.shared.saveLayout(
            tabs: [
                PersistedTab(
                    id: activityID.uuidString, kind: .files, title: nil,
                    subtitle: "", url: nil, html: nil, cacheFile: nil
                ),
                PersistedTab(
                    id: infoID.uuidString, kind: .info, title: nil,
                    subtitle: "", url: nil, html: nil, cacheFile: nil
                ),
            ],
            activeID: infoID.uuidString,
            for: fixture.sessionID
        )

        let pane = DisplayPaneController()
        let tabs = pane.tabs(for: fixture.sessionID)

        XCTAssertEqual(tabs.count, 1)
        XCTAssertEqual(tabs.first?.id, infoID)
        XCTAssertEqual(tabs.first?.overview?.selectedSection, .info)
        XCTAssertEqual(pane.activeTabID(for: fixture.sessionID), infoID)
        XCTAssertEqual(
            DisplayPaneStore.shared.loadLayout(for: fixture.sessionID)?.panelTabs.map(\.id),
            [infoID.uuidString],
            "the in-memory merge left the legacy duplicate on disk"
        )
    }

    /// Pressing the panel toggle should reveal something useful, but a look is not a decision to
    /// restore that surface forever. The fallback therefore appears in the strip and nowhere in
    /// the persisted or agent-facing tab lists.
    func testAnEmptyPanelShowsANonPersistedOverviewWhenOpenedByHand() throws {
        let fixture = try projectAndSession()
        defer { fixture.tearDown() }
        let pane = DisplayPaneController()

        pane.showSessionWithDefaultOverview(fixture.sessionID)
        pane.view.frame = NSRect(x: 0, y: 0, width: 420, height: 700)
        pane.view.layoutSubtreeIfNeeded()

        XCTAssertFalse(pane.hasContent(for: fixture.sessionID))
        XCTAssertTrue(pane.tabs(for: fixture.sessionID).isEmpty)
        XCTAssertNil(DisplayPaneStore.shared.loadLayout(for: fixture.sessionID))
        XCTAssertNotNil(descendant(
            in: pane.view,
            accessibilityIdentifier: "session-overview"
        ))
        let infoSegment = try XCTUnwrap(descendant(
            in: pane.view,
            accessibilityIdentifier: "session-overview.section.info"
        ))
        XCTAssertEqual(infoSegment.accessibilityValue() as? NSNumber, 1)

        pane.showSession(fixture.sessionID)
        pane.view.layoutSubtreeIfNeeded()
        XCTAssertNil(
            descendant(in: pane.view, accessibilityIdentifier: "session-overview"),
            "ordinary session selection retained the manual-open fallback"
        )
    }

    func testWindowCommandTogglesTheInspectorWithoutOpeningSettings() throws {
        let settings = AppSettings.shared
        let previous = settings.disabledToolGroupIDs
        defer { settings.disabledToolGroupIDs = previous }
        settings.setToolGroup(MCPToolCatalog.appearance.id, enabled: true)

        let controller = makeMainWindowController()
        let container = try XCTUnwrap(
            controller.splitViewController.splitViewItems[1].viewController
                as? TerminalContainerViewController
        )

        controller.toggleCurrentTheme()
        XCTAssertTrue(controller.isCurrentThemeVisible)
        XCTAssertFalse(container.isShowingSettings, "the inspector took the old Settings route")

        controller.toggleCurrentTheme()
        XCTAssertFalse(controller.isCurrentThemeVisible)
    }

    private func descendant(in view: NSView, accessibilityIdentifier: String) -> NSView? {
        if view.accessibilityIdentifier() == accessibilityIdentifier { return view }
        return view.subviews.lazy.compactMap {
            self.descendant(in: $0, accessibilityIdentifier: accessibilityIdentifier)
        }.first
    }

    private func descendant(in view: NSView, accessibilityLabel: String) -> NSView? {
        if view.accessibilityLabel() == accessibilityLabel { return view }
        return view.subviews.lazy.compactMap {
            self.descendant(in: $0, accessibilityLabel: accessibilityLabel)
        }.first
    }

    /// `ThemedIconButton` names itself through `setAccessibilityTitle`, which is what a button
    /// with no visible text is supposed to carry — matching one by label finds nothing at all.
    private func descendant(in view: NSView, accessibilityTitle: String) -> NSView? {
        if view.accessibilityTitle() == accessibilityTitle { return view }
        return view.subviews.lazy.compactMap {
            self.descendant(in: $0, accessibilityTitle: accessibilityTitle)
        }.first
    }

    /// Every one of them, for the questions that are about *how many* — a control the window
    /// offers twice is the shape of bug this pane has had before.
    private func descendants(in view: NSView, accessibilityTitle: String) -> [NSView] {
        (view.accessibilityTitle() == accessibilityTitle ? [view] : [])
            + view.subviews.flatMap { descendants(in: $0, accessibilityTitle: accessibilityTitle) }
    }

    // MARK: - The Compare Tab Follows the Pane

    /// The compare canvas's height is a function of the width it is given, and it was read
    /// **once** — from `view.bounds.width` while the body was being built, before the pane had
    /// been laid out at all on a first show. The box then kept that height for the rest of its
    /// life: dragging the divider refitted the images inside a canvas that never moved, which
    /// is the compare tab reading as a fixed-size thing in a resizable pane.
    func testTheCompareCanvasFollowsThePanesWidth() throws {
        let old = try imageOnDisk(size: NSSize(width: 400, height: 200), name: "old.png")
        let new = try imageOnDisk(size: NSSize(width: 400, height: 200), name: "new.png")
        defer {
            try? FileManager.default.removeItem(at: old.url)
            try? FileManager.default.removeItem(at: new.url)
        }

        let controller = CompareViewController(
            sessionID: SessionID(),
            oldPath: old.url.path,
            newPath: new.url.path,
            oldTitle: nil,
            newTitle: nil,
            mode: .wipeHorizontal
        )

        let host = NSView(frame: NSRect(x: 0, y: 0, width: 600, height: 500))
        host.addSubview(controller.view)
        controller.view.frame = host.bounds
        controller.view.autoresizingMask = [.width, .height]

        let loaded = expectation(description: "compare read both files")
        controller.onLoadingChange = { isLoading in
            if !isLoading { loaded.fulfill() }
        }
        controller.refresh(force: true)
        wait(for: [loaded], timeout: 10)

        controller.view.layoutSubtreeIfNeeded()
        let wide = try XCTUnwrap(Self.compareCanvas(in: controller.view)).frame.height

        host.setFrameSize(NSSize(width: 260, height: 500))
        controller.view.layoutSubtreeIfNeeded()
        let narrow = try XCTUnwrap(Self.compareCanvas(in: controller.view)).frame.height

        XCTAssertLessThan(
            narrow,
            wide,
            "the canvas kept its first height while the pane around it changed width"
        )
    }

    private static func compareCanvas(in view: NSView) -> ImageCompareView? {
        if let found = view as? ImageCompareView { return found }
        for subview in view.subviews {
            if let found = compareCanvas(in: subview) { return found }
        }
        return nil
    }

    // MARK: - Reaching the Picture

    func testTheMenuLeadsWithInspectionAndKeepsSystemQuickLookAsFallback() throws {
        let (content, url) = try imageOnDisk(size: NSSize(width: 40, height: 40))
        defer { try? FileManager.default.removeItem(at: url) }

        let titles = paneShowing(content).makeContentEntries().compactMap { $0.item?.title }

        XCTAssertEqual(
            titles.first,
            L10n.string("Inspect"),
            "the in-window inspector should lead because it keeps the user in Threading"
        )
        XCTAssertEqual(titles.last, L10n.string("Open in System Quick Look"))
    }

    /// Neither inspector can show a file that has since been deleted, so both routes are left
    /// out rather than offered and then refused.
    func testTheMenuDropsPreviewRoutesWhenTheFileIsGone() throws {
        let (content, url) = try imageOnDisk(size: NSSize(width: 40, height: 40))
        try FileManager.default.removeItem(at: url)

        let titles = paneShowing(content).makeContentEntries().compactMap { $0.item?.title }

        XCTAssertFalse(titles.contains(L10n.string("Inspect")))
        XCTAssertFalse(titles.contains(L10n.string("Open in System Quick Look")))
        XCTAssertTrue(titles.contains(L10n.string("Copy Image")), "the rest should still be there")
    }

    /// Focus, a key, a pointer and an accessibility action all reach the same place. Asserted
    /// through the *refusal* path — a file that is not there — because the success path opens a
    /// real system window, which is the one thing a test in `fast` must not do.
    func testEveryRouteToInspectionRefusesTogetherWhenThereIsNoFile() {
        let preview = ThemedImagePreview()
        preview.image = NSImage(size: NSSize(width: 40, height: 40))
        preview.fileURL = URL(fileURLWithPath: "/nowhere/threading-missing.png")

        XCTAssertFalse(preview.performPrimaryAction())
        XCTAssertFalse(preview.accessibilityPerformPress())
        XCTAssertFalse(
            preview.acceptsFirstResponder,
            "a picture with nothing to open should stay out of the key loop"
        )
        XCTAssertNil(preview.toolTip)
    }

    func testAPictureWithAFileIsFocusableAndSaysSo() throws {
        let (_, url) = try imageOnDisk(size: NSSize(width: 40, height: 40))
        defer { try? FileManager.default.removeItem(at: url) }

        let preview = ThemedImagePreview()
        preview.image = NSImage(size: NSSize(width: 40, height: 40))
        preview.fileURL = url

        XCTAssertTrue(preview.acceptsFirstResponder)
        XCTAssertNotNil(preview.toolTip, "the gesture has to be advertised somewhere")
        XCTAssertEqual(preview.accessibilityRole(), .image)
        XCTAssertEqual(preview.accessibilityLabel(), url.lastPathComponent)
        XCTAssertNotNil(preview.accessibilityHelp())
    }

    /// Clearing the picture clears the file with it, so a pane switched to another tab cannot
    /// keep the previous image previewable behind an empty view.
    func testClearingThePictureClearsTheFile() throws {
        let (_, url) = try imageOnDisk(size: NSSize(width: 40, height: 40))
        defer { try? FileManager.default.removeItem(at: url) }

        let preview = ThemedImagePreview()
        preview.image = NSImage(size: NSSize(width: 40, height: 40))
        preview.fileURL = url
        preview.image = nil

        XCTAssertNil(preview.fileURL)
        XCTAssertFalse(preview.performPrimaryAction())
    }

    /// **The wash a hover brings must not be a lid.** This one fill is drawn *over* its content
    /// rather than under it, and `Design.Surface.controlHover` — the role every other hover in the
    /// app reaches for — is opaque under System and under half the stock themes. Pointing at an
    /// attachment replaced the whole picture with a flat rectangle.
    ///
    /// Read off the drawn pixels and over every stock theme, because what broke is one theme's
    /// alpha: the same code is correct under a theme that happens to ship a translucent hover, so
    /// no single-theme assertion would have seen it.
    func testHoveringAPictureTintsItRatherThanCoveringIt() throws {
        let original = AppThemePalette.current
        defer { AppThemePalette.set(original) }

        let preview = ThemedImagePreview(frame: NSRect(x: 0, y: 0, width: 80, height: 60))
        preview.image = filledImage(size: NSSize(width: 80, height: 60), color: .systemTeal)

        for theme in AppThemeLibrary.stock {
            AppThemePalette.set(theme)

            let resting = try centrePixel(of: preview)
            preview.mouseEntered(with: try crossingEvent(.mouseEntered))
            let hovered = try centrePixel(of: preview)
            preview.mouseExited(with: try crossingEvent(.mouseExited))

            // The alpha itself is pinned by the test below. What is asserted here is what the
            // *eye* gets: the pixel under the pointer still belongs to the picture. Stated as a
            // comparison rather than as a bound on how far it moved, because the move is not
            // linear in the alpha — the blend happens in the bitmap's own space and comes back
            // through sRGB's gamma, so "shifted by at most 0.16" is true of neither channel.
            let lid = try opaque(Design.Surface.controlHover)
            XCTAssertLessThan(
                distance(from: hovered, to: resting),
                distance(from: hovered, to: lid) / 2,
                "\(theme.name) covered the picture instead of tinting it"
            )
        }
    }

    /// The other half of the same rule, stated where the decision lives: the wash is translucent
    /// under *every* theme, including ones whose `controlHover` is not. Asserted against the role
    /// it is derived from, because "most themes ship an opaque hover" is exactly the fact that
    /// made drawing `controlHover` over a picture look fine on the theme it was written under.
    func testTheImageHoverWashIsTranslucentUnderEveryThemeWhoseHoverIsNot() throws {
        let original = AppThemePalette.current
        defer { AppThemePalette.set(original) }

        var opaqueHovers = 0
        for theme in AppThemeLibrary.stock {
            AppThemePalette.set(theme)

            let wash = try XCTUnwrap(Design.Surface.imageHoverWash.usingColorSpace(.sRGB))
            XCTAssertEqual(
                wash.alphaComponent,
                Design.Opacity.imageHoverWash,
                accuracy: 0.001,
                "\(theme.name) let a theme's own alpha decide how much of the picture is covered"
            )

            let hover = try XCTUnwrap(Design.Surface.controlHover.usingColorSpace(.sRGB))
            if hover.alphaComponent > 0.99 { opaqueHovers += 1 }
        }

        XCTAssertGreaterThan(
            opaqueHovers,
            0,
            "the wash is only worth deriving because some themes hover opaquely — if none do, "
                + "this test has stopped covering anything"
        )
    }

    func testCanPreviewOnlyAcceptsAFileThatExists() throws {
        let (_, url) = try imageOnDisk(size: NSSize(width: 10, height: 10))

        XCTAssertTrue(QuickLookPresenter.canPreview(url))
        XCTAssertFalse(QuickLookPresenter.canPreview(nil))
        XCTAssertFalse(QuickLookPresenter.canPreview(URL(string: "https://example.com/a.png")))

        try FileManager.default.removeItem(at: url)
        XCTAssertFalse(QuickLookPresenter.canPreview(url), "a deleted file is not previewable")
    }

    // MARK: - A Shown Image Is a Row, Not a Tab

    /// `display_image` used to spend a tab per picture, so a session that showed six charts grew
    /// six `photo` chips whose titles truncated to nothing — while the store had already recorded
    /// every one of them into the Attachments list. The panel was stating one fact twice. The
    /// list is the chronology now; the tab is gone.
    func testAShownImageJoinsTheListInsteadOfSpendingATab() throws {
        let fixture = try projectSession()
        defer { fixture.tearDown() }
        let png = try writePNG(in: fixture.folder, named: "chart.png", color: .systemRed)

        let result = fixture.coordinator.handle(
            .displayImage(.init(path: png.path, title: nil)), for: fixture.sessionID
        )
        XCTAssertFalse(result.isError, result.text)
        XCTAssertTrue(result.text.contains("Attachments"), result.text)

        let tabs = fixture.pane.tabs(for: fixture.sessionID)
        XCTAssertEqual(tabs.count, 1, "a shown image opened a tab of its own")
        XCTAssertNil(tabs.first?.content, "the picture is still a content tab")
        let attachments = try XCTUnwrap(tabs.first?.attachments, "no Attachments tab was opened")
        XCTAssertEqual(
            fixture.pane.activeTabID(for: fixture.sessionID),
            tabs.first?.id,
            "the list was opened without being brought to the front"
        )

        // The row it asked for, selected — and previewed, since the preview follows selection.
        let table = try attachmentsTable(in: attachments.view)
        XCTAssertEqual(table.numberOfRows, 1)
        XCTAssertEqual(table.selectedRow, 0, "the shown image is not the selected row")
        XCTAssertEqual(try preview(in: attachments.view).fileURL?.lastPathComponent, "chart.png")
    }

    /// Display is an immutable capture: a regenerated chart keeps both versions, and the pane
    /// lands on the newest captured bytes rather than whichever source path now contains.
    func testShowingTheSameImageTwiceKeepsBothCapturesAndSelectsTheNewest() throws {
        let fixture = try projectSession()
        defer { fixture.tearDown() }
        let first = try writePNG(in: fixture.folder, named: "one.png", color: .systemRed)
        let second = try writePNG(in: fixture.folder, named: "two.png", color: .systemBlue)

        _ = fixture.coordinator.handle(
            .displayImage(.init(path: first.path, title: nil)), for: fixture.sessionID
        )
        _ = fixture.coordinator.handle(
            .displayImage(.init(path: second.path, title: nil)), for: fixture.sessionID
        )
        _ = fixture.coordinator.handle(
            .displayImage(.init(path: first.path, title: nil)), for: fixture.sessionID
        )

        let tabs = fixture.pane.tabs(for: fixture.sessionID)
        XCTAssertEqual(tabs.count, 1, "three images grew more than the one list")
        let attachments = try XCTUnwrap(tabs.first?.attachments)
        let table = try attachmentsTable(in: attachments.view)
        XCTAssertEqual(table.numberOfRows, 3, "an immutable display capture was deduplicated")
        XCTAssertEqual(table.selectedRow, 0, "the newest capture was not selected")
        XCTAssertEqual(
            try preview(in: attachments.view).fileURL?.lastPathComponent,
            "one.png",
            "the image shown again is not the one being previewed"
        )

        let recorded = SessionAttachmentStore.shared.attachments(for: fixture.sessionID)
        XCTAssertEqual(Set(recorded.map(\.id)).count, 3)
        let firstCaptures = recorded.filter { $0.sourcePath == first.path }
        XCTAssertEqual(firstCaptures.count, 2)
        XCTAssertEqual(
            Set(firstCaptures.map { $0.url.standardizedFileURL.path }).count,
            2,
            "two display moments still point at one mutable set of bytes"
        )
    }

    /// The filter is a convenience; being asked to show a picture is an instruction. A pane
    /// filtered to *You* would otherwise answer `display_image` with the list it already had.
    func testShowingAnImageTheFilterWouldHideResetsTheFilter() throws {
        let fixture = try projectSession()
        defer { fixture.tearDown() }

        // One of each side, so the filter control is offered at all.
        let mine = try writePNG(in: fixture.folder, named: "mine.png", color: .systemGreen)
        SessionAttachmentStore.shared.record(
            declared: mine,
            sessionID: fixture.sessionID,
            projectRoot: fixture.folder,
            origin: .user
        )
        let theirs = try writePNG(in: fixture.folder, named: "theirs.png", color: .systemRed)
        SessionAttachmentStore.shared.record(
            declared: theirs,
            sessionID: fixture.sessionID,
            projectRoot: fixture.folder,
            origin: .agent
        )

        let attachments = try XCTUnwrap(
            fixture.pane.activateAttachments(for: fixture.sessionID)
        )
        fixture.pane.view.layoutSubtreeIfNeeded()
        let filter = try XCTUnwrap(
            descendants(of: attachments.view).compactMap { $0 as? ThemedSegmentedControl }.first,
            "the pane offered no filter for a list with both sides in it"
        )
        let user = try XCTUnwrap(AttachmentFilter.allCases.firstIndex(of: .user))
        filter.selectedIndex = user
        filter.onSelect?(user)
        XCTAssertEqual(try attachmentsTable(in: attachments.view).numberOfRows, 1)

        let shown = try writePNG(in: fixture.folder, named: "shown.png", color: .systemBlue)
        _ = fixture.coordinator.handle(
            .displayImage(.init(path: shown.path, title: nil)), for: fixture.sessionID
        )

        XCTAssertEqual(filter.selectedIndex, 0, "the filter kept hiding the picture just shown")
        XCTAssertEqual(try attachmentsTable(in: attachments.view).numberOfRows, 3)
        XCTAssertEqual(
            try preview(in: attachments.view).fileURL?.lastPathComponent,
            "shown.png"
        )
    }

    /// Settings temporarily empties the display pane while its tab controllers stay cached. The
    /// app-wide theme sweep cannot reach that detached tree, so remounting is where its frozen
    /// layer colours have to catch up. This is the exact path that left the Attachments filter in
    /// Threading navy after the user selected System.
    func testAttachmentsFilterCatchesUpWithAThemeSwitchMissedWhileDetached() throws {
        let previousTheme = AppThemePalette.current
        defer { AppThemePalette.set(previousTheme) }
        AppThemePalette.set(AppThemeStyles.threading)

        let fixture = try projectSession()
        defer { fixture.tearDown() }

        let mine = try writePNG(in: fixture.folder, named: "mine.png", color: .systemGreen)
        SessionAttachmentStore.shared.record(
            declared: mine,
            sessionID: fixture.sessionID,
            projectRoot: fixture.folder,
            origin: .user
        )
        let theirs = try writePNG(in: fixture.folder, named: "theirs.png", color: .systemRed)
        SessionAttachmentStore.shared.record(
            declared: theirs,
            sessionID: fixture.sessionID,
            projectRoot: fixture.folder,
            origin: .agent
        )

        let attachments = try XCTUnwrap(
            fixture.pane.activateAttachments(for: fixture.sessionID)
        )
        fixture.pane.view.layoutSubtreeIfNeeded()
        let filter = try XCTUnwrap(
            descendants(of: attachments.view).compactMap { $0 as? ThemedSegmentedControl }.first,
            "the pane offered no filter for a list with both sides in it"
        )
        AppThemeRefresh.repaint(attachments.view)
        let threadingTrack = try XCTUnwrap(filter.layer?.backgroundColor)

        fixture.pane.showSession(nil)
        XCTAssertNil(attachments.view.superview, "the cached Attachments tree stayed mounted")

        AppThemePalette.set(.system)
        AppThemeRefresh.repaintEverything()
        XCTAssertEqual(
            filter.layer?.backgroundColor,
            threadingTrack,
            "the detached fixture unexpectedly joined the window-only theme sweep"
        )

        fixture.pane.showSession(fixture.sessionID)
        let systemTrack = try XCTUnwrap(filter.layer?.backgroundColor)
        var expectedSystemTrack: String?
        filter.effectiveAppearance.performAsCurrentDrawingAppearance {
            expectedSystemTrack = Design.Surface.controlResting.usingColorSpace(.sRGB)?.hexString
        }

        XCTAssertNotEqual(systemTrack, threadingTrack, "the Attachments filter kept Threading navy")
        XCTAssertEqual(
            NSColor(cgColor: systemTrack)?.usingColorSpace(.sRGB)?.hexString,
            expectedSystemTrack,
            "the reattached filter did not resolve System's control surface"
        )
    }

    /// A session with no project has nowhere to keep a list — `makeAttachments` needs a folder to
    /// belong to — so the picture is shown the old way rather than not at all.
    func testASessionWithoutAProjectStillOpensAnImageTab() throws {
        let sessionID = SessionID()
        let pane = DisplayPaneController()
        let coordinator = AgentToolCoordinator(
            displayPaneController: pane,
            visibleSessionID: { sessionID },
            setPaneVisible: { _ in },
            windowProvider: { nil }
        )
        defer {
            for tab in pane.tabs(for: sessionID) { _ = pane.closeTab(id: tab.id, for: sessionID) }
        }
        let (_, url) = try imageOnDisk(size: NSSize(width: 12, height: 12))

        let result = coordinator.handle(.displayImage(.init(path: url.path, title: nil)), for: sessionID)
        XCTAssertFalse(result.isError, result.text)

        let tabs = pane.tabs(for: sessionID)
        XCTAssertEqual(tabs.count, 1)
        XCTAssertNotNil(tabs.first?.content, "the fallback stopped opening a tab for the image")
    }

    /// A relaunch converts what the old panel wrote: the tab becomes a row, its cached PNG goes
    /// with it, and the panel does not come back pointing at a tab it no longer has.
    func testARestoredImageTabBecomesARowAndTakesItsCacheWithIt() throws {
        let fixture = try projectAndSession()
        defer { fixture.tearDown() }
        let png = try writePNG(in: fixture.folder, named: "restored.png", color: .systemOrange)

        let tabID = UUID()
        let cacheFile = try XCTUnwrap(
            DisplayPaneStore.shared.cacheImage(
                NSImage(contentsOf: png) ?? NSImage(),
                tabID: tabID,
                for: fixture.sessionID
            )
        )
        DisplayPaneStore.shared.saveLayout(
            tabs: [PersistedTab(
                id: tabID.uuidString, kind: .image, title: "Restored",
                subtitle: "", url: png.absoluteString, html: nil, cacheFile: cacheFile
            )],
            activeID: tabID.uuidString,
            for: fixture.sessionID
        )

        let pane = DisplayPaneController()
        let tabs = pane.tabs(for: fixture.sessionID)

        XCTAssertTrue(tabs.allSatisfy { $0.content == nil }, "the image tab came back as a tab")
        let attachments = try XCTUnwrap(
            tabs.first(where: { $0.attachments != nil }),
            "the converted image left no list to find it in"
        )
        XCTAssertEqual(
            pane.activeTabID(for: fixture.sessionID),
            attachments.id,
            "the panel came back pointing at a tab that is not there"
        )
        XCTAssertEqual(
            SessionAttachmentStore.shared.attachments(for: fixture.sessionID).map(\.name),
            ["restored.png"]
        )
        XCTAssertNil(
            DisplayPaneStore.shared.loadImage(cacheFile, for: fixture.sessionID),
            "the tab's cached copy outlived the tab"
        )
        XCTAssertFalse(
            DisplayPaneStore.shared.loadLayout(for: fixture.sessionID)?.panelTabs
                .contains { $0.kind == .image } ?? false,
            "the converted tab is still in the stored layout, so the next launch converts again"
        )
    }

    func testPersistedImageNameCannotEscapeItsSessionCache() throws {
        let sessionID = SessionID()
        let image = NSImage(size: NSSize(width: 8, height: 8), flipped: false) { rect in
            NSColor.systemBlue.setFill()
            rect.fill()
            return true
        }
        let cacheFile = try XCTUnwrap(
            DisplayPaneStore.shared.cacheImage(image, tabID: UUID(), for: sessionID)
        )
        defer { DisplayPaneStore.shared.removeCachedImage(cacheFile, for: sessionID) }

        let traversal = "../\(sessionID.uuidString)/\(cacheFile)"
        XCTAssertNil(DisplayPaneStore.shared.loadImage(traversal, for: sessionID))
        DisplayPaneStore.shared.removeCachedImage(traversal, for: sessionID)
        XCTAssertNotNil(
            DisplayPaneStore.shared.loadImage(cacheFile, for: sessionID),
            "a persisted traversal name escaped the cache and deleted a valid image"
        )

        let cacheURL = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        )[0]
            .appendingPathComponent("Threading", isDirectory: true)
            .appendingPathComponent(DisplayPaneStoreDefaults.rootDirectory, isDirectory: true)
            .appendingPathComponent(sessionID.uuidString, isDirectory: true)
            .appendingPathComponent(cacheFile)
        let handle = try FileHandle(forWritingTo: cacheURL)
        try handle.truncate(atOffset: UInt64(
            DisplayPaneStoreDefaults.maximumCachedImageBytes + 1
        ))
        try handle.close()
        XCTAssertNil(
            DisplayPaneStore.shared.loadImage(cacheFile, for: sessionID),
            "a cached image that grew after persistence bypassed the decode boundary"
        )
    }

    // MARK: - Fixtures for the list

    /// A real project and session — `makeAttachments` asks `ProjectStore` for a folder — with a
    /// pane and a coordinator wired to them.
    private struct ProjectSessionFixture {
        let sessionID: SessionID
        let folder: URL
        let pane: DisplayPaneController
        let coordinator: AgentToolCoordinator
        let tearDown: () -> Void
    }

    private struct ProjectFixture {
        let sessionID: SessionID
        let folder: URL
        let tearDown: () -> Void
    }

    /// The project is added to the shared store and removed again, the way every other test that
    /// needs one does: its own folder, since `addProject` returns the existing project for a
    /// folder it already knows and the teardown deletes whatever it was handed.
    ///
    /// Deliberately without a pane. A `DisplayPaneController` listens for attachment changes for
    /// *every* session, so a second live pane would convert a restored layout in parallel with
    /// the one under test — the restore case builds its own and nothing else.
    private func projectAndSession() throws -> ProjectFixture {
        let folder = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("threading-shown-image-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        let store = ProjectStore.shared
        let project = try XCTUnwrap(store.addProject(folderURL: folder))
        let session = try XCTUnwrap(
            store.addSession(to: project.id, kind: .claude, usesNativeUI: false, title: "Shown")
        )
        return ProjectFixture(
            sessionID: session.id,
            folder: folder,
            tearDown: {
                store.removeProject(id: project.id)
                try? FileManager.default.removeItem(at: folder)
            }
        )
    }

    private func projectSession() throws -> ProjectSessionFixture {
        let fixture = try projectAndSession()
        let sessionID = fixture.sessionID
        let pane = DisplayPaneController()
        let coordinator = AgentToolCoordinator(
            displayPaneController: pane,
            visibleSessionID: { sessionID },
            setPaneVisible: { _ in },
            windowProvider: { nil }
        )
        // Loaded before anything is shown, so the list's own view exists to be asserted on.
        pane.showSession(sessionID)
        pane.view.frame = NSRect(x: 0, y: 0, width: 360, height: 720)
        pane.view.layoutSubtreeIfNeeded()

        return ProjectSessionFixture(
            sessionID: sessionID,
            folder: fixture.folder,
            pane: pane,
            coordinator: coordinator,
            tearDown: fixture.tearDown
        )
    }

    /// A flat 12×12 picture, written where the session's project will find it.
    private func writePNG(in folder: URL, named name: String, color: NSColor) throws -> URL {
        let url = folder.appendingPathComponent(name)
        let rep = try XCTUnwrap(NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: 12, pixelsHigh: 12, bitsPerSample: 8,
            samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ))
        let converted = try XCTUnwrap(color.usingColorSpace(.deviceRGB))
        for x in 0..<12 {
            for y in 0..<12 { rep.setColor(converted, atX: x, y: y) }
        }
        try XCTUnwrap(rep.representation(using: .png, properties: [:])).write(to: url)
        return url
    }

    private func descendants(of view: NSView) -> [NSView] {
        view.subviews.flatMap { [$0] + descendants(of: $0) }
    }

    private func attachmentsTable(in view: NSView) throws -> NSTableView {
        try XCTUnwrap(
            descendants(of: view).compactMap { $0 as? ThemedTableView }.first,
            "the pane grew no list"
        )
    }

    private func preview(in view: NSView) throws -> ThemedImagePreview {
        try XCTUnwrap(
            descendants(of: view).compactMap { $0 as? ThemedImagePreview }.first,
            "the pane grew no preview"
        )
    }
}

// MARK: - Menu Reading

/// A menu is asserted by its semantic entries, since presenting one needs a window on screen.
private extension ThemedMenuEntry {

    var item: ThemedMenuItem? {
        guard case .item(let item) = self else { return nil }
        return item
    }

    var itemTitle: String? { item?.title }
}
