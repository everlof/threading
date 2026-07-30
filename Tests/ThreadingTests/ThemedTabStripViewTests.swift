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

    private func makeStrip(items: [TabStripItem]) -> ThemedTabStripView {
        let strip = ThemedTabStripView(inkSource: .chrome)
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
            strip.topAnchor.constraint(equalTo: content.topAnchor),
            strip.heightAnchor.constraint(equalToConstant: ThemedTabStripView.bandHeight)
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
}
