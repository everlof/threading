import AppKit
import XCTest
@testable import Threading

/// Where a click inside a sidebar row actually lands, and what it costs when the answer is wrong.
///
/// Three reports, one cause. A session row's archive box "did nothing at all"; its `⋯` "worked
/// sometimes"; and the sidebar's selection was "sometimes gray sometimes blue". All three are
/// `NSTableView.validateProposedFirstResponder(_:for:)`, which decides whether a click inside a
/// cell reaches the view it landed on or is taken by the table to select the row — and answers no
/// for anything in a row that is not already selected. The button drew its hover fill, took the
/// press nowhere, and the row underneath was selected instead: which switched the session on
/// screen, and moved the focus that decides whether the selection draws emphasized.
///
/// The row's own tests could not see any of this. They press the button directly on a row held in
/// a plain `NSView`, where no table is between the click and the button, so they passed against a
/// button that was unreachable in the app. These put the row where it actually lives.
@MainActor
final class SidebarRowClickRoutingTests: XCTestCase {

    // MARK: - Fixtures

    /// One session row inside a real outline view, in an unshown window.
    ///
    /// The window is built and never ordered on screen — `applicationShouldTerminateAfterLastWindowClosed`
    /// is true, and a shown-then-released window queues a termination AppKit acts on inside some
    /// later, unrelated test.
    private func hostedOutline<Outline: NSOutlineView>(
        _ make: () -> Outline
    ) -> (outline: Outline, source: RowSource) {
        let source = RowSource()
        let outline = make()
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("column"))
        column.width = 240
        outline.addTableColumn(column)
        outline.outlineTableColumn = column
        outline.headerView = nil
        outline.dataSource = source
        outline.delegate = source
        outline.frame = NSRect(x: 0, y: 0, width: 240, height: 60)

        let window = NSWindow(
            contentRect: outline.frame,
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = outline
        outline.reloadData()
        outline.layoutSubtreeIfNeeded()

        return (outline, source)
    }

    /// The single row the fixture vends, kept alive by the test through the data source.
    final class RowSource: NSObject, NSOutlineViewDataSource, NSOutlineViewDelegate {

        let item = NSString("session")
        let row = SessionRowView(customizationLookup: { _ in .empty })

        override init() {
            super.init()
            row.configure(with: AgentSession(kind: .claude, title: "Working session"), activity: .idle)
        }

        func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
            item == nil ? 1 : 0
        }

        func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
            self.item
        }

        func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool { false }

        func outlineView(
            _ outlineView: NSOutlineView,
            viewFor tableColumn: NSTableColumn?,
            item: Any
        ) -> NSView? {
            row
        }
    }

    private func archiveButton(in root: NSView) throws -> NSView {
        func walk(_ node: NSView) -> NSView? {
            if node.accessibilityIdentifier() == "sidebar.session.archive" { return node }
            for child in node.subviews where walk(child) != nil { return walk(child) }
            return nil
        }
        return try XCTUnwrap(walk(root), "the row grew no archive button")
    }

    // MARK: - The reported bug

    /// The archive box, on a row nobody has selected — which is every row a user reaches for it on.
    ///
    /// Asserted against a stock `NSOutlineView` in the same fixture, because the point is not that
    /// our answer is `true`; it is that AppKit's is `false` and that this is what the sidebar was
    /// living with. If a future macOS starts exempting custom controls the way it exempts
    /// `NSButton`, the second assertion is what will say so.
    func testARowsButtonTakesItsOwnFirstClickWhereAStockOutlineWouldSwallowIt() throws {
        let themed = hostedOutline { ThemedOutlineView(frame: .zero) }
        let themedArchive = try archiveButton(in: themed.source.row)

        XCTAssertEqual(themed.outline.selectedRow, -1, "the fixture starts with nothing selected")
        XCTAssertTrue(
            themed.outline.validateProposedFirstResponder(themedArchive, for: nil),
            "the row's archive button could not have its own click on an unselected row"
        )

        let stock = hostedOutline { NSOutlineView(frame: .zero) }
        let stockArchive = try archiveButton(in: stock.source.row)

        XCTAssertFalse(
            stock.outline.validateProposedFirstResponder(stockArchive, for: nil),
            "AppKit no longer swallows this click, so the override above may be unnecessary"
        )
    }

    /// The other half of the rule: only a control that acts on its own click is exempted, so a
    /// click anywhere else in the row still selects it.
    func testTheRowsTitleIsNotAControlAndStillSelectsTheRow() throws {
        let themed = hostedOutline { ThemedOutlineView(frame: .zero) }
        let title = try XCTUnwrap(
            descendants(of: themed.source.row)
                .first { $0.accessibilityIdentifier() == "sidebar.session.title" },
            "the row grew no title"
        )

        XCTAssertFalse(
            RowControls.takesItsOwnClick(title),
            "the row's title claimed a click that belongs to the row"
        )
        XCTAssertTrue(
            RowControls.takesItsOwnClick(try archiveButton(in: themed.source.row)),
            "the row's archive button gave its click away"
        )
    }

    /// The same rule for flat tables, since both classes state it and only one was reported.
    func testAThemedTableAnswersTheSameWayAsTheOutline() throws {
        let table = ThemedTableView(frame: NSRect(x: 0, y: 0, width: 200, height: 40))
        let button = ThemedIconButton(symbolName: "archivebox", accessibility: "Archive")

        XCTAssertTrue(table.validateProposedFirstResponder(button, for: nil))
    }

    // MARK: - The selection that changed colour

    /// Pressing a row's button leaves the keyboard focus where it was.
    ///
    /// The button used to call `makeFirstResponder(self)` on its way into the press, and in a
    /// sidebar row that is visible: the outline view resigns, and its selected row drops from
    /// emphasized to unemphasized — under the System theme, from the accent blue to a flat grey.
    /// The row whose colour changed was not the row being pressed, which is what made it read as
    /// the selection being random.
    func testPressingAnIconButtonDoesNotTakeTheKeyboardFocus() throws {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 200, height: 80),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        let root = try XCTUnwrap(window.contentView)

        let holder = ThemedIconButton(symbolName: "gearshape", accessibility: "Holder")
        holder.translatesAutoresizingMaskIntoConstraints = true
        holder.frame = NSRect(x: 10, y: 20, width: 20, height: 20)
        root.addSubview(holder)

        let button = ThemedIconButton(symbolName: "archivebox", accessibility: "Archive")
        button.translatesAutoresizingMaskIntoConstraints = true
        button.frame = NSRect(x: 60, y: 20, width: 20, height: 20)
        root.addSubview(button)

        XCTAssertTrue(window.makeFirstResponder(holder), "the fixture could not seat a responder")

        let centre = button.convert(
            NSPoint(x: button.bounds.midX, y: button.bounds.midY),
            to: nil
        )
        let down = try XCTUnwrap(
            NSEvent.mouseEvent(
                with: .leftMouseDown,
                location: centre,
                modifierFlags: [],
                timestamp: 0,
                windowNumber: window.windowNumber,
                context: nil,
                eventNumber: 0,
                clickCount: 1,
                pressure: 1
            )
        )
        button.mouseDown(with: down)

        XCTAssertTrue(
            window.firstResponder === holder,
            "a press moved the keyboard focus, which is what recoloured the sidebar's selection"
        )

        // Tab-reachability is the affordance the ring exists for, and it is untouched.
        XCTAssertTrue(button.acceptsFirstResponder)
        XCTAssertTrue(window.makeFirstResponder(button))
    }

    // MARK: - Helpers

    private func descendants(of root: NSView) -> [NSView] {
        root.subviews + root.subviews.flatMap { descendants(of: $0) }
    }
}
