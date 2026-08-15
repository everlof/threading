import AppKit
import XCTest
@testable import Threading

/// The strip's behaviour contract: chips are reused by id (what rename morphing, drag survival
/// and reorder animation all hang on), the arranged order follows the items, callbacks carry
/// the right tab, and everything a pointer can do has an accessibility route.
///
/// Fixture windows are built, never shown — see the testing notes in CLAUDE.md.
@MainActor
final class ThemedTabStripViewTests: XCTestCase {

    // MARK: - Fixtures

    private var window: NSWindow?

    override func tearDown() {
        window = nil
        AppThemePalette.set(.system)
        super.tearDown()
    }

    private func items(_ specs: [(String, Bool)]) -> [TabStripItem] {
        specs.map { title, isActive in
            TabStripItem(
                id: UUID(),
                title: title,
                symbolName: "terminal",
                isActive: isActive
            )
        }
    }

    /// `chipMaxWidth` is read as each chip is made, so a test about a *capped* chip has to state
    /// it here rather than after the update — the same order the hosts use at setup.
    private func makeStrip(
        items: [TabStripItem],
        chipMaxWidth: CGFloat? = nil
    ) -> ThemedTabStripView {
        let strip = ThemedTabStripView(inkSource: .chrome)
        strip.chipMaxWidth = chipMaxWidth
        strip.update(items: items)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 60),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        self.window = window
        guard let content = window.contentView else {
            XCTFail("Fixture window has no content view")
            return strip
        }
        content.addSubview(strip)
        NSLayoutConstraint.activate([
            strip.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            strip.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            strip.topAnchor.constraint(equalTo: content.topAnchor)
        ])
        content.layoutSubtreeIfNeeded()
        return strip
    }

    // MARK: - Reconciliation

    func testChipsAreReusedByIDAcrossUpdates() {
        let items = items([("One", true), ("Two", false)])
        let strip = makeStrip(items: items)
        let firstChip = strip.chipView(for: items[0].id)
        XCTAssertNotNil(firstChip)

        let renamed = TabStripItem(
            id: items[0].id,
            title: "Renamed",
            symbolName: "terminal",
            isActive: true
        )
        strip.update(items: [renamed, items[1]])

        XCTAssertTrue(
            strip.chipView(for: items[0].id) === firstChip,
            "A surviving tab must keep its chip — reuse is what a rename morph and a live drag both depend on"
        )
        XCTAssertEqual(firstChip?.title, "Renamed")
    }

    func testRemovedItemsLoseTheirChips() {
        let items = items([("One", true), ("Two", false)])
        let strip = makeStrip(items: items)
        let secondChip = strip.chipView(for: items[1].id)

        strip.update(items: [items[0]])

        XCTAssertNil(strip.chipView(for: items[1].id))
        XCTAssertNil(secondChip?.superview)
    }

    func testArrangedOrderFollowsTheItems() {
        let items = items([("One", true), ("Two", false), ("Three", false)])
        let strip = makeStrip(items: items)

        strip.update(items: [items[2], items[0], items[1]])
        strip.layoutSubtreeIfNeeded()

        let chipFrames = [items[2], items[0], items[1]].compactMap {
            strip.chipView(for: $0.id)?.frame.minX
        }
        XCTAssertEqual(chipFrames, chipFrames.sorted(), "Chips must lay out in item order")
    }

    func testSelectionStateReachesTheChips() {
        let items = items([("One", true), ("Two", false)])
        let strip = makeStrip(items: items)

        XCTAssertEqual(strip.chipView(for: items[0].id)?.isSelected, true)
        XCTAssertEqual(strip.chipView(for: items[1].id)?.isSelected, false)
    }

    // MARK: - Callbacks

    func testSelectAndCloseReportTheRightTab() {
        let items = items([("One", true), ("Two", false)])
        let strip = makeStrip(items: items)

        var selected: UUID?
        var closed: UUID?
        strip.onSelect = { selected = $0 }
        strip.onClose = { closed = $0 }

        _ = strip.chipView(for: items[1].id)?.accessibilityPerformPress()
        XCTAssertEqual(selected, items[1].id)

        strip.chipView(for: items[0].id)?.onClose?()
        XCTAssertEqual(closed, items[0].id)
    }

    // MARK: - Accessibility Menu Route

    func testShowMenuIsRefusedWithoutContextEntries() {
        let items = items([("One", true)])
        let strip = makeStrip(items: items)
        strip.contextEntries = nil

        let chip = strip.chipView(for: items[0].id)
        XCTAssertEqual(chip?.accessibilityPerformShowMenu(), false)
    }

    func testShowMenuOpensTheHostsEntries() {
        let items = items([("One", true), ("Two", false)])
        let strip = makeStrip(items: items)

        var asked: UUID?
        strip.contextEntries = { id in
            asked = id
            return [.item(ThemedMenuItem(title: "Move Right"))]
        }

        let handled = strip.chipView(for: items[0].id)?.accessibilityPerformShowMenu()
        XCTAssertEqual(handled, true)
        XCTAssertEqual(asked, items[0].id)
    }

    // MARK: - Reorder Lift

    /// A travelling chip crosses its neighbours, so for the drag's duration it must be the one
    /// opaque thing moving — a translucent traveller shows the crossed tab through itself.
    func testADraggedChipIsLiftedOpaqueUntilTheDragEnds() throws {
        let items = items([("One", true), ("Two", false)])
        let strip = makeStrip(items: items)
        strip.onReorder = { _, _ in }
        let chip = try XCTUnwrap(strip.chipView(for: items[0].id))

        chip.onDrag?(.began, try dragEvent(at: chip.frame.origin))
        XCTAssertTrue(chip.isLifted, "The gesture must lift the chip it grabbed")

        chip.onDrag?(.ended, try dragEvent(at: chip.frame.origin))
        XCTAssertFalse(chip.isLifted, "A landed chip rests back into the strip's translucency")
    }

    /// The opacity the lift composites against: a ground that is itself see-through would
    /// re-open the exact defect the lift exists to close.
    func testBothGroundsFlattenToAnOpaqueColour() {
        XCTAssertEqual(InkSource.chrome.ground.alphaComponent, 1)
        XCTAssertEqual(NSColor.clear.composited(over: InkSource.chrome.ground).alphaComponent, 1)
    }

    /// Landing on another pane hands the tab over instead of reordering, and the strip's own
    /// geometry — alpha, transform — is back to resting before the host takes it.
    func testADragOverAnotherPaneDropsOutInsteadOfReordering() throws {
        let items = items([("One", true), ("Two", false)])
        let strip = makeStrip(items: items)
        var reordered = false
        var dropped: UUID?
        strip.onReorder = { _, _ in reordered = true }
        strip.externalDropTarget = { _, _ in true }
        strip.onDropOut = { id, _ in dropped = id }
        let chip = try XCTUnwrap(strip.chipView(for: items[0].id))

        chip.onDrag?(.began, try dragEvent(at: chip.frame.origin))
        chip.onDrag?(.changed, try dragEvent(at: NSPoint(x: 10, y: -50)))
        XCTAssertEqual(
            chip.alphaValue, Design.Opacity.dragAway,
            "Over a pane that will take it, the chip reads as on its way out"
        )

        chip.onDrag?(.ended, try dragEvent(at: NSPoint(x: 10, y: -50)))
        XCTAssertEqual(dropped, items[0].id)
        XCTAssertFalse(reordered, "A drop-out is a move between panes, not a reorder")
        XCTAssertEqual(chip.alphaValue, 1)
        XCTAssertFalse(chip.isLifted)
    }

    /// With one tab there is nothing to reorder — but wired for drop-out it can still leave,
    /// which is the common case: a drawer holding only the session's shell.
    func testALoneChipCanStillBeDraggedOut() throws {
        let items = items([("Only", true)])
        let strip = makeStrip(items: items)
        var dropped: UUID?
        strip.onReorder = { _, _ in }
        strip.externalDropTarget = { _, _ in true }
        strip.onDropOut = { id, _ in dropped = id }
        let chip = try XCTUnwrap(strip.chipView(for: items[0].id))

        chip.onDrag?(.began, try dragEvent(at: chip.frame.origin))
        XCTAssertTrue(chip.isLifted)
        chip.onDrag?(.changed, try dragEvent(at: chip.frame.origin))
        chip.onDrag?(.ended, try dragEvent(at: chip.frame.origin))

        XCTAssertEqual(dropped, items[0].id)
    }

    /// A cross-pane drop lands by the same midpoint rule the reorder gesture uses, so the
    /// slot a pointer names is the slot the tab takes.
    func testTheInsertionIndexFollowsChipMidpoints() throws {
        let items = items([("One", true), ("Two", false), ("Three", false)])
        let strip = makeStrip(items: items)
        let first = try XCTUnwrap(strip.chipView(for: items[0].id))
        let last = try XCTUnwrap(strip.chipView(for: items[2].id))

        let beforeAll = first.convert(NSPoint(x: -Design.Spacing.large, y: 0), to: nil)
        let pastFirstMid = first.convert(NSPoint(x: first.bounds.midX + 1, y: 0), to: nil)
        let afterAll = last.convert(NSPoint(x: last.bounds.maxX + Design.Spacing.large, y: 0), to: nil)

        XCTAssertEqual(strip.insertionIndex(forWindowPoint: beforeAll), 0)
        XCTAssertEqual(strip.insertionIndex(forWindowPoint: pastFirstMid), 1)
        XCTAssertEqual(strip.insertionIndex(forWindowPoint: afterAll), items.count)
    }

    /// Whatever way a drag lands, it says so last — after the drop-out or the reorder — which
    /// is what lets the window settle anything it arranged for the gesture.
    func testEveryDragReportsItsEndAfterItsOutcome() throws {
        let items = items([("One", true), ("Two", false)])
        let strip = makeStrip(items: items)
        var order: [String] = []
        strip.onReorder = { _, _ in order.append("reorder") }
        strip.onDropOut = { _, _ in order.append("drop") }
        strip.onDragEnded = { _ in order.append("ended") }
        let chip = try XCTUnwrap(strip.chipView(for: items[0].id))

        chip.onDrag?(.began, try dragEvent(at: chip.frame.origin))
        chip.onDrag?(.ended, try dragEvent(at: chip.frame.origin))
        XCTAssertEqual(order, ["ended"], "A drag that went nowhere still reports its end")

        order = []
        strip.externalDropTarget = { _, _ in true }
        chip.onDrag?(.began, try dragEvent(at: chip.frame.origin))
        chip.onDrag?(.changed, try dragEvent(at: chip.frame.origin))
        chip.onDrag?(.ended, try dragEvent(at: chip.frame.origin))
        XCTAssertEqual(order, ["drop", "ended"], "The move happens first, the settle last")
    }

    private func dragEvent(at point: NSPoint) throws -> NSEvent {
        try XCTUnwrap(NSEvent.mouseEvent(
            with: .leftMouseDragged,
            location: point,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: window?.windowNumber ?? 0,
            context: nil,
            eventNumber: 0,
            clickCount: 1,
            pressure: 1
        ))
    }

    // MARK: - Geometry

    func testTheStripBandMatchesThePaneHeaderBand() {
        XCTAssertEqual(ThemedTabStripView.bandHeight, PaneHeaderView.bandHeight)
    }

    /// A strip embedded in a pane header takes the header's required height. Its own preferred
    /// band height is intrinsic: making both dimensions required caused a transient 42-versus-41
    /// conflict while theme observers remeasured the nested views in sequence.
    func testAHostCanOwnTheStripBandAcrossALiveThemeSwitch() throws {
        AppThemePalette.set(.system)
        let strip = ThemedTabStripView(inkSource: .chrome)
        let header = PaneHeaderView(margin: .paneEdge)
        header.addSubview(strip)
        NSLayoutConstraint.activate([
            strip.leadingAnchor.constraint(equalTo: header.leadingAnchor),
            strip.trailingAnchor.constraint(equalTo: header.trailingAnchor),
            strip.topAnchor.constraint(equalTo: header.topAnchor),
            strip.bottomAnchor.constraint(equalTo: header.bottomAnchor)
        ])
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 80),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        self.window = window
        let content = try XCTUnwrap(window.contentView)
        content.addSubview(header)
        NSLayoutConstraint.activate([
            header.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            header.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            header.topAnchor.constraint(equalTo: content.topAnchor)
        ])
        content.layoutSubtreeIfNeeded()

        for theme in [AppThemeStyles.bauhaus, AppThemeStyles.cyberpunk, AppTheme.system] {
            AppThemePalette.set(theme)
            NotificationCenter.default.post(AppThemeDidChange(themeID: theme.id))
            header.superview?.layoutSubtreeIfNeeded()
            XCTAssertEqual(strip.frame.height, header.frame.height, accuracy: 0.5)
            XCTAssertEqual(header.frame.height, PaneHeaderView.bandHeight, accuracy: 0.5)
        }
    }

    /// The visible regression: Bauhaus's four-point rule sat inside a band sized only for the
    /// tab and its two margins, leaving two points below the selected plate and six above it.
    /// The strip already on screen must grow with the rule and keep both margins at the token.
    func testALiveBauhausSwitchKeepsEqualAirAboveAndBelowTheTab() throws {
        AppThemePalette.set(.system)
        let item = TabStripItem(
            id: UUID(),
            title: "Attachments",
            symbolName: "paperclip",
            isActive: true
        )
        let strip = makeStrip(items: [item])
        let host = try XCTUnwrap(strip.superview)
        let systemHeight = strip.frame.height
        let systemRule = Design.Radius.border

        AppThemePalette.set(AppThemeStyles.bauhaus)
        NotificationCenter.default.post(AppThemeDidChange(themeID: AppThemeStyles.bauhaus.id))
        host.layoutSubtreeIfNeeded()

        let tab = try XCTUnwrap(strip.chipView(for: item.id))
        let frame = tab.convert(tab.bounds, to: strip)
        XCTAssertEqual(
            strip.frame.height - systemHeight,
            Design.Radius.border - systemRule,
            accuracy: 0.5
        )
        XCTAssertEqual(
            strip.bounds.maxY - frame.maxY,
            Design.Spacing.small,
            accuracy: 0.5
        )
        XCTAssertEqual(
            frame.minY - Design.Radius.border,
            Design.Spacing.small,
            accuracy: 0.5
        )
    }

    /// A chip whose title had to be shortened must end where the shortened title ends.
    ///
    /// Capped, it used to settle at exactly the cap and hand its label a slot the label could
    /// not fill: tail truncation lands on a character boundary, so the line that arrives is up
    /// to one character narrower than the room offered — measured between 0.1 and 8.1pt for one
    /// title across the widths a cap can fall on — and that remainder sat as air between the
    /// title and the ×, moving from tab to tab with the name.
    func testACappedChipEndsWhereItsShortenedTitleEnds() throws {
        let items = items([("skalman.app vs Threading", true)])
        let strip = makeStrip(items: items, chipMaxWidth: DisplayPaneDefaults.tabChipMaxWidth)
        let tab = try XCTUnwrap(strip.chipView(for: items[0].id))
        let title = try XCTUnwrap(
            descendants(in: tab).compactMap { $0 as? MorphingTitleLabel }.first
        )

        let drawn = title.width(fitting: title.bounds.width)
        XCTAssertLessThan(
            drawn,
            title.intrinsicContentSize.width,
            "fixture title fits — nothing here is about truncation"
        )
        XCTAssertEqual(
            title.bounds.width,
            drawn,
            accuracy: 1,
            "the title's slot is wider than the line in it: dead space inside the tab"
        )
        XCTAssertLessThan(
            tab.bounds.width,
            DisplayPaneDefaults.tabChipMaxWidth,
            "the chip is holding the whole cap rather than the width of what it draws"
        )
    }

    /// The × is a 12pt glyph inside a 20pt click target, so spacing measured to its *frame*
    /// lands the visible glyph 4pt further out at both ends — and the eye measures the glyph.
    /// Every other container that places one of these subtracts that padding
    /// (`OpticalInsetProviding`); this asserts the tab does too, in the same terms
    /// `PaneFooterTests` uses.
    func testTheCloseGlyphSitsOnTheStatedSpacingAndInset() throws {
        let items = items([("skalman.app vs Threading", true)])
        let strip = makeStrip(items: items, chipMaxWidth: DisplayPaneDefaults.tabChipMaxWidth)
        let tab = try XCTUnwrap(strip.chipView(for: items[0].id))
        let title = try XCTUnwrap(
            descendants(in: tab).compactMap { $0 as? MorphingTitleLabel }.first
        )
        let close = try XCTUnwrap(
            descendants(in: tab).compactMap { $0 as? ThemedIconButton }.first
        )

        let lineEnd = title.convert(
            NSPoint(x: title.width(fitting: title.bounds.width), y: 0),
            to: tab
        ).x
        let glyph = close.convert(
            close.bounds.insetBy(dx: close.opticalHorizontalInset, dy: 0),
            to: tab
        )

        XCTAssertEqual(
            glyph.minX - lineEnd,
            Design.Spacing.medium,
            accuracy: 0.5,
            "the gap between the title and the × is not the one the tokens state"
        )
        XCTAssertEqual(
            tab.bounds.maxX - glyph.maxX,
            Design.Spacing.inset,
            accuracy: 0.5,
            "the × is inset by its click target rather than by its ink"
        )
    }

    /// A strip that scrolls rather than shrinks is not a measurement of its host.
    ///
    /// `fittingSize` resolves at `.fittingSizeCompression` (50), so a strip resisting compression
    /// above that answers it with the whole width of its tabs however narrow the host really is.
    /// That is how the display panel's *minimum* width came to be its widest tab plus its chrome
    /// — and so to move with the name of the page open in it — while the pane's own caption and
    /// placeholder had already been floored below the threshold for exactly this. See
    /// `docs/architecture/mcp-and-display.md`.
    func testAStripIsNotItsHostsMeasurement() throws {
        let strip = makeStrip(
            items: items([("A tab title long enough to be shortened", true)]),
            chipMaxWidth: DisplayPaneDefaults.tabChipMaxWidth
        )
        let host = try XCTUnwrap(strip.superview)

        XCTAssertLessThan(
            strip.contentCompressionResistancePriority(for: .horizontal).rawValue,
            NSLayoutConstraint.Priority.fittingSizeCompression.rawValue
        )
        XCTAssertLessThan(
            host.fittingSize.width,
            DisplayPaneDefaults.tabChipMaxWidth,
            "the strip charged its host the width of tabs it would have scrolled"
        )
    }

    private func descendants(in root: NSView) -> [NSView] {
        root.subviews.flatMap { [$0] + descendants(in: $0) }
    }
}
