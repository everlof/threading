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

    // MARK: - Scroll Routing

    /// The reported defect: a two-finger pan down the pane, with the pointer over the strip, was
    /// answered by the strip — which has nothing above or below its one row to reveal, so it
    /// rubber-banded — while the surface the reader was aiming at stood still.
    func testAVerticalPanOverTheStripGoesToTheSurfaceBehindIt() throws {
        let fixture = try scrollingHost(tabCount: 8)
        let restingOffset = fixture.viewport.contentView.bounds.origin.x

        fixture.viewport.scrollWheel(with: try pan(dx: 1, dy: -18, phase: .began))

        XCTAssertEqual(
            fixture.host.receivedGestureEvents, 1,
            "the strip swallowed a gesture it has no range for"
        )
        XCTAssertEqual(
            fixture.viewport.contentView.bounds.origin.x, restingOffset,
            "the strip moved along its own axis for a gesture that was not about it"
        )
    }

    /// The other half of the same decision: a pan *across* the strip is the strip's, and the
    /// pane behind it must not move for it.
    func testAHorizontalPanScrollsTheStripAndNotItsHost() throws {
        let fixture = try scrollingHost(tabCount: 8)
        var reachedTheStrip = 0
        fixture.viewport.onUserScroll = { reachedTheStrip += 1 }

        fixture.viewport.scrollWheel(with: try pan(dx: -22, dy: 2, phase: .began))

        XCTAssertEqual(reachedTheStrip, 1, "a gesture along the strip's own axis escaped it")
        XCTAssertEqual(
            fixture.host.receivedGestureEvents, 0,
            "the pane behind the strip scrolled for a gesture across the strip"
        )
    }

    /// Routing is decided once, at the gesture's begin, and holds for the whole thing.
    ///
    /// Momentum arrives with the fingers already off the trackpad and the content moving under a
    /// stationary pointer, so its deltas wobble and AppKit is free to re-target them. Deciding
    /// per event lets a horizontally biased tail be taken back by the strip halfway through a
    /// flick the reader aimed down the pane, which reads as hitting an invisible stop.
    func testTheMomentumTailOfAVerticalPanStaysWithTheSurfaceBehind() throws {
        let fixture = try scrollingHost(tabCount: 8)

        fixture.viewport.scrollWheel(with: try pan(dx: 1, dy: -18, phase: .began))
        fixture.viewport.scrollWheel(with: try pan(dx: 4, dy: -9, phase: .changed))
        fixture.viewport.scrollWheel(with: try pan(dx: 0, dy: 0, phase: .ended))
        fixture.viewport.scrollWheel(with: try pan(dx: 7, dy: -2, momentumPhase: .began))
        fixture.viewport.scrollWheel(with: try pan(dx: 6, dy: -1, momentumPhase: .changed))
        fixture.viewport.scrollWheel(with: try pan(dx: 0, dy: 0, momentumPhase: .ended))

        XCTAssertEqual(
            fixture.host.receivedGestureEvents, 6,
            "the tail of a vertical flick was taken back by the strip when it turned diagonal"
        )
        XCTAssertEqual(
            fixture.viewport.contentView.bounds.origin.x, 0,
            "the strip scrolled itself on the momentum of somebody else's gesture"
        )
    }

    /// And the gesture after it is decided afresh: the lock is per gesture, not a mode.
    func testAHorizontalPanAfterAVerticalOneIsTheStripsAgain() throws {
        let fixture = try scrollingHost(tabCount: 8)
        fixture.viewport.scrollWheel(with: try pan(dx: 1, dy: -18, phase: .began))
        fixture.viewport.scrollWheel(with: try pan(dx: 0, dy: 0, phase: .ended))
        XCTAssertEqual(fixture.host.receivedGestureEvents, 2)

        var reachedTheStrip = 0
        fixture.viewport.onUserScroll = { reachedTheStrip += 1 }
        fixture.viewport.scrollWheel(with: try pan(dx: -22, dy: 2, phase: .began))

        XCTAssertEqual(reachedTheStrip, 1, "a new gesture inherited the last one's routing")
        XCTAssertEqual(fixture.host.receivedGestureEvents, 2)
    }

    /// A wheel turns along the axis the strip does not have, so over the strip it did nothing at
    /// all. Its ticks can only be asking for the one axis there is.
    func testAPlainWheelScrollsTheStripAlongItsOneAxis() throws {
        let fixture = try scrollingHost(tabCount: 12)
        let clip = fixture.viewport.contentView
        XCTAssertGreaterThan(
            clip.documentRect.width, clip.bounds.width,
            "fixture strip fits its host — there is nothing here to scroll"
        )

        fixture.viewport.scrollWheel(with: try wheel(ticks: -3))

        XCTAssertEqual(
            clip.bounds.origin.x,
            3 * fixture.viewport.horizontalLineScroll,
            accuracy: 0.5,
            "a wheel tick over the strip moved it by something other than a line"
        )
        XCTAssertEqual(
            fixture.host.receivedGestureEvents, 0,
            "the wheel went past the strip to the pane behind it"
        )
    }

    /// The sign is the one a horizontal event already carries, and the ends hold: a wheel turned
    /// the other way at the resting position has nowhere to go and must not bounce.
    func testTheWheelTurnsBothWaysAndStopsAtTheEnds() throws {
        let fixture = try scrollingHost(tabCount: 12)
        let clip = fixture.viewport.contentView

        fixture.viewport.scrollWheel(with: try wheel(ticks: 3))
        XCTAssertEqual(clip.bounds.origin.x, 0, "the strip scrolled past its own beginning")

        fixture.viewport.scrollWheel(with: try wheel(ticks: -3))
        let advanced = clip.bounds.origin.x
        XCTAssertGreaterThan(advanced, 0)

        fixture.viewport.scrollWheel(with: try wheel(ticks: 3))
        XCTAssertEqual(
            clip.bounds.origin.x, 0,
            accuracy: 0.5,
            "the wheel's two directions do not undo each other"
        )
        XCTAssertGreaterThan(advanced, 0)
    }

    /// Shift+wheel is AppKit's own translation, applied to the event before any view sees it, so
    /// the strip must add none of its own: two flips would put the ticks back on the axis the
    /// strip does not have, and the wheel would go dead again with a modifier held.
    func testAShiftedWheelIsLeftToAppKitAndFlippedExactlyOnce() throws {
        let shifted = try wheel(ticks: -3, modifiers: .maskShift)
        XCTAssertEqual(
            shifted.scrollingDeltaX, -3,
            "AppKit stopped swapping a shifted wheel's axes in the event itself"
        )
        XCTAssertEqual(shifted.scrollingDeltaY, 0)
        XCTAssertFalse(
            HorizontalOnlyWheelMapping.mapsVerticalTicksToHorizontal(shifted),
            "the strip translated an event AppKit had already translated"
        )

        let fixture = try scrollingHost(tabCount: 12)
        fixture.viewport.scrollWheel(with: shifted)

        XCTAssertEqual(
            fixture.viewport.contentView.bounds.origin.x, 0,
            "the strip moved a shifted wheel itself instead of leaving it to AppKit"
        )
        XCTAssertEqual(fixture.host.receivedGestureEvents, 0)
    }

    /// A trackpad names its own axis in the event and is routed, never translated. A precise
    /// delta is the tell, and it is the one a Magic Mouse carries too.
    func testPreciseDeltasAreNeverReadAsWheelTicks() throws {
        let precise = try pan(dx: 0, dy: -30, phase: .began)
        XCTAssertTrue(precise.hasPreciseScrollingDeltas)
        XCTAssertFalse(HorizontalOnlyWheelMapping.mapsVerticalTicksToHorizontal(precise))

        let fixture = try scrollingHost(tabCount: 12)
        fixture.viewport.scrollWheel(with: precise)

        XCTAssertEqual(
            fixture.viewport.contentView.bounds.origin.x, 0,
            "a trackpad pan was translated into a wheel and scrolled the strip sideways"
        )
        XCTAssertEqual(fixture.host.receivedGestureEvents, 1)
    }

    /// The whole matrix, stated where it can be read: the translation is a function of nothing
    /// but the event's own properties, so it can be asserted exhaustively without a window —
    /// which matters because AppKit ignores a synthesised `scrollWheel` outside a real event
    /// stream, and `super`'s half of this can only ever be exercised by hand.
    func testTheWheelDecisionIsExhaustiveOverTheEventsProperties() {
        func maps(
            phase: NSEvent.Phase = [],
            momentumPhase: NSEvent.Phase = [],
            precise: Bool = false,
            modifiers: NSEvent.ModifierFlags = [],
            deltaX: CGFloat = 0,
            deltaY: CGFloat = -3
        ) -> Bool {
            HorizontalOnlyWheelMapping.mapsVerticalTicksToHorizontal(
                phase: phase,
                momentumPhase: momentumPhase,
                hasPreciseScrollingDeltas: precise,
                modifiers: modifiers,
                scrollingDeltaX: deltaX,
                scrollingDeltaY: deltaY
            )
        }

        XCTAssertTrue(maps(), "a plain wheel tick is the whole case this exists for")
        XCTAssertTrue(maps(deltaY: 3), "a wheel turned the other way is still a wheel")
        XCTAssertTrue(
            maps(modifiers: [.command, .option, .control]),
            "only Shift means something to a scroll event's axes"
        )

        for phase in [NSEvent.Phase.began, .changed, .ended, .cancelled, .mayBegin, .stationary] {
            XCTAssertFalse(maps(phase: phase), "a phased gesture is routed, not translated")
        }
        for momentum in [NSEvent.Phase.began, .changed, .ended] {
            XCTAssertFalse(maps(momentumPhase: momentum), "momentum belongs to its own gesture")
        }
        XCTAssertFalse(maps(precise: true), "a precise delta already names its axis")
        XCTAssertFalse(maps(modifiers: .shift), "AppKit has already flipped a shifted wheel")
        XCTAssertFalse(maps(deltaY: 0), "a wheel that turned nowhere asks for nothing")
        XCTAssertFalse(
            maps(deltaX: -3, deltaY: -3),
            "a tilt wheel already names the axis the strip has"
        )
        XCTAssertFalse(maps(deltaX: -3, deltaY: 0), "a horizontal wheel needs no help")
    }

    // MARK: - Scroll Fixtures

    private struct ScrollFixture {
        let strip: ThemedTabStripView
        let host: GestureCountingScrollView
        /// The strip's own viewport, found the way AppKit finds it: whatever is under the
        /// pointer over a chip, walked up to the scroll view that would answer for it.
        let viewport: ThemedScrollView
    }

    /// The strip inside something that scrolls, which is the arrangement all of this is about.
    /// The host counts rather than scrolls, because a synthesised event moves no real
    /// `NSScrollView`: what is being asserted is where the gesture was sent.
    private func scrollingHost(tabCount: Int) throws -> ScrollFixture {
        let tabs = items((0..<tabCount).map { ("Tab number \($0)", false) })
        let strip = ThemedTabStripView(inkSource: .chrome)
        strip.update(items: tabs)

        let host = GestureCountingScrollView(frame: NSRect(x: 0, y: 0, width: 260, height: 400))
        let page = NSView(frame: NSRect(x: 0, y: 0, width: 260, height: 1_200))
        host.documentView = page
        host.hasVerticalScroller = false
        page.addSubview(strip)
        NSLayoutConstraint.activate([
            strip.leadingAnchor.constraint(equalTo: page.leadingAnchor),
            strip.trailingAnchor.constraint(equalTo: page.trailingAnchor),
            strip.topAnchor.constraint(equalTo: page.topAnchor)
        ])

        let window = NSWindow(
            contentRect: host.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        self.window = window
        let content = try XCTUnwrap(window.contentView)
        content.addSubview(host)
        content.layoutSubtreeIfNeeded()

        let chip = try XCTUnwrap(strip.chipView(for: try XCTUnwrap(tabs.first).id))
        let pointer = chip.convert(
            NSPoint(x: chip.bounds.midX, y: chip.bounds.midY),
            to: strip.superview
        )
        let hit = try XCTUnwrap(
            strip.hitTest(pointer),
            "nothing sits under a pointer over the strip's first chip"
        )
        let viewport = sequence(first: hit, next: { $0.superview })
            .prefix { $0 !== strip }
            .compactMap { $0 as? ThemedScrollView }
            .first
        return ScrollFixture(
            strip: strip,
            host: host,
            viewport: try XCTUnwrap(
                viewport,
                "AppKit would deliver a scroll over a chip to a viewport inside the strip"
            )
        )
    }

    /// A trackpad pan: precise deltas and a phase for its whole life, which is what tells one
    /// from a wheel. The flags are stated rather than inherited — a `CGEvent` built from a nil
    /// source reads the modifiers the developer happens to be holding.
    private func pan(
        dx: Int32,
        dy: Int32,
        phase: NSEvent.Phase = [],
        momentumPhase: NSEvent.Phase = [],
        modifiers: CGEventFlags = []
    ) throws -> NSEvent {
        let event = try XCTUnwrap(CGEvent(
            scrollWheelEvent2Source: nil,
            units: .pixel,
            wheelCount: 2,
            wheel1: dy,
            wheel2: dx,
            wheel3: 0
        ))
        event.setIntegerValueField(
            .scrollWheelEventScrollPhase,
            value: ScrollFixtureCGPhase.scroll(phase)
        )
        event.setIntegerValueField(
            .scrollWheelEventMomentumPhase,
            value: ScrollFixtureCGPhase.momentum(momentumPhase)
        )
        event.flags = modifiers
        return try XCTUnwrap(NSEvent(cgEvent: event))
    }

    /// A real wheel: line units, no phase at any point in its life, no precise deltas.
    private func wheel(ticks: Int32, modifiers: CGEventFlags = []) throws -> NSEvent {
        let event = try XCTUnwrap(CGEvent(
            scrollWheelEvent2Source: nil,
            units: .line,
            wheelCount: 2,
            wheel1: ticks,
            wheel2: 0,
            wheel3: 0
        ))
        event.flags = modifiers
        return try XCTUnwrap(NSEvent(cgEvent: event))
    }

    private func descendants(in root: NSView) -> [NSView] {
        root.subviews.flatMap { [$0] + descendants(in: $0) }
    }
}

// MARK: - Scroll Fixture Helpers

/// `CGEvent`'s phase numbering is its own — `1, 2, 4, 8, 128` for
/// began/changed/ended/cancelled/mayBegin, and `1, 2, 3` for momentum — and `NSEvent` translates
/// it on the way in, to values that share none of those numbers. Stated once here so a fixture
/// can ask for the phase it means rather than for a number that happens to arrive as one. There
/// is no `CGEvent` spelling of `.stationary`; nothing needs one.
private enum ScrollFixtureCGPhase {
    static func scroll(_ phase: NSEvent.Phase) -> Int64 {
        switch phase {
        case .began: 1
        case .changed: 2
        case .ended: 4
        case .cancelled: 8
        case .mayBegin: 128
        default: 0
        }
    }

    static func momentum(_ phase: NSEvent.Phase) -> Int64 {
        switch phase {
        case .began: 1
        case .changed: 2
        case .ended: 3
        default: 0
        }
    }
}

/// A host that counts what reached it rather than scrolling for it. A synthesised `NSEvent` has
/// no window and `NSScrollView` ignores one outside a real event stream, so the assertable fact
/// about a handed-off gesture is that it was handed off.
private final class GestureCountingScrollView: ThemedScrollView {
    private(set) var receivedGestureEvents = 0

    override func scrollWheel(with event: NSEvent) {
        receivedGestureEvents += 1
    }
}
