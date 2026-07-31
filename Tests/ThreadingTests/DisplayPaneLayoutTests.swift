import AppKit
import XCTest
@testable import Threading

/// What the display panel lets the window do, and how the picture inside it is reached.
///
/// Both halves of this file are the same bug seen twice: the panel is a *panel*, and it had
/// been quietly deciding things that belong to the window and to the user — how small the
/// window may be, and whether the image in it can be opened properly.
@MainActor
final class DisplayPaneLayoutTests: XCTestCase {

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

    private func paneShowing(_ content: DisplayContent) -> DisplayPaneController {
        let pane = DisplayPaneController()
        let sessionID = SessionID()
        pane.showSession(sessionID)
        pane.addContentTab(content, for: sessionID)
        pane.view.layoutSubtreeIfNeeded()
        return pane
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
    /// also a window minimum — and `display_image` opens this panel, which meant showing a
    /// picture quietly took 200pt off how small the window was allowed to be.
    ///
    /// The claim is not that opening a pane is free; it is that it costs the panel's own
    /// chrome rather than the width it happens to open at.
    func testOpeningThePanelDoesNotCostTheWindowTheWidthItOpensAt() throws {
        let controller = MainWindowController()
        let window = try XCTUnwrap(controller.window)
        let root = try XCTUnwrap(window.contentView)

        // Opened first: the very first `fittingSize` on a window that has never been laid out
        // answers for a tree that has not settled, and the difference is the measurement.
        controller.setDisplayPaneVisible(true)
        window.layoutIfNeeded()
        let open = root.fittingSize.width

        controller.setDisplayPaneVisible(false)
        window.layoutIfNeeded()
        let closed = root.fittingSize.width

        XCTAssertGreaterThan(closed, 0, "the window never laid out, so nothing was measured")
        XCTAssertLessThan(
            open - closed,
            DisplayPaneDefaults.minWidth,
            "opening the panel put its whole opening width under the window"
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
        defer { DisplayPaneWidth.stored = previous }
        DisplayPaneWidth.stored = 420

        let controller = MainWindowController()
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
        let newTab = descendant(in: pane.view, accessibilityLabel: L10n.string("New tab"))
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

    func testWindowCommandTogglesTheInspectorWithoutOpeningSettings() throws {
        let settings = AppSettings.shared
        let previous = settings.disabledToolGroupIDs
        defer { settings.disabledToolGroupIDs = previous }
        settings.setToolGroup(MCPToolCatalog.appearance.id, enabled: true)

        let controller = MainWindowController()
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

        let titles = paneShowing(content).makeContentMenu().items.map(\.title)

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

        let titles = paneShowing(content).makeContentMenu().items.map(\.title)

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

    func testCanPreviewOnlyAcceptsAFileThatExists() throws {
        let (_, url) = try imageOnDisk(size: NSSize(width: 10, height: 10))

        XCTAssertTrue(QuickLookPresenter.canPreview(url))
        XCTAssertFalse(QuickLookPresenter.canPreview(nil))
        XCTAssertFalse(QuickLookPresenter.canPreview(URL(string: "https://example.com/a.png")))

        try FileManager.default.removeItem(at: url)
        XCTAssertFalse(QuickLookPresenter.canPreview(url), "a deleted file is not previewable")
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
