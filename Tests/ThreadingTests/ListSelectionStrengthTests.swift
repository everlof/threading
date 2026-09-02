import AppKit
import XCTest
@testable import Threading

/// A list draws its selection at the strength of its window, never of the focus inside it.
///
/// The report was about the sidebar: *first tap hovers, second tap selects*. What actually
/// happened is that the first tap selected the row and then lost first responder to the terminal
/// the selection had just opened, so AppKit demoted the row to its quiet fill — a flat grey under
/// **System** — and the second tap, which selected nothing new and therefore took no focus, was
/// the one that looked like it worked.
///
/// It was the second sighting of one defect: `ThemedIconButton.mouseDown` used to take first
/// responder and recoloured a different row's selection, and fixing that one control left every
/// other way of taking focus able to bring it back. So the rule lives on the *list*
/// (`ListSelectionStrength`), which is the last point every row passes through whatever class
/// vends it, and these assert it there rather than at any one row.
@MainActor
final class ListSelectionStrengthTests: XCTestCase {

    // MARK: - Fixture

    private enum Fixture {
        static let width: CGFloat = 240
        static let rowHeight: CGFloat = 28
        static let rows = 3

        /// Mid-grey, so both selection strengths are legible against it whichever way the
        /// theme's colours lean.
        static let ground = NSColor(white: 0.5, alpha: 1)
    }

    /// The rows the list is asked for.
    ///
    /// A cell but deliberately **no** `rowViewForRow:`, which is what makes this fixture the case
    /// worth asserting: the row of a list that says nothing about its rows is not a class its
    /// author chose, and is exactly what a fix living in one row class cannot reach. (`viewFor`
    /// is not optional dressing here: without it a table runs cell-based and builds no row views
    /// at all.)
    private final class Rows:
        NSObject,
        NSTableViewDataSource,
        NSTableViewDelegate,
        NSOutlineViewDataSource,
        NSOutlineViewDelegate {

        /// Set to hand back a row class of the fixture's choosing. Left nil, the list is asked for
        /// nothing and vends its own — which is the case that matters most, since that is the row
        /// nobody wrote.
        var rowView: (() -> NSTableRowView)?

        func numberOfRows(in tableView: NSTableView) -> Int { Fixture.rows }

        func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
            rowView?()
        }

        func outlineView(_ outlineView: NSOutlineView, rowViewForItem item: Any) -> NSTableRowView? {
            rowView?()
        }

        func tableView(
            _ tableView: NSTableView,
            viewFor tableColumn: NSTableColumn?,
            row: Int
        ) -> NSView? {
            NSTableCellView()
        }

        func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
            item == nil ? Fixture.rows : 0
        }

        func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
            String(index) as NSString
        }

        func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
            false
        }

        func outlineView(
            _ outlineView: NSOutlineView,
            viewFor tableColumn: NSTableColumn?,
            item: Any
        ) -> NSView? {
            NSTableCellView()
        }
    }

    private let rows = Rows()

    // MARK: - The Rule

    /// The regression, stated the way AppKit states it: the list resigning demotes every row, and
    /// that must not survive to the next draw. The end-to-end shape of the rule — the row now
    /// declines the demotion outright, so what this pins is the *outcome* a draw arrives at. See
    /// `testADemotionIsRefusedWhereItArrivesRatherThanAtTheNextDraw` for why the draw alone was
    /// never enough.
    func testTheListRestoresItsSelectionStrengthBeforeItDraws() throws {
        let table = try list(isKey: true)

        demoteEveryRow(in: table)
        try draw(table)

        XCTAssertEqual(
            emphasizedRowCount(in: table),
            Fixture.rows,
            "A list in the front window should draw its selection at full strength"
        )
    }

    /// The same, taken through the move that caused it rather than through its consequence: focus
    /// leaving the list for something beside it, which is what selecting a session does to the
    /// sidebar when it focuses the terminal.
    func testMovingFocusOutOfTheListLeavesItsSelectionAtFullStrength() throws {
        let table = try list(isKey: true)
        let window = try XCTUnwrap(table.window, "Fixture premise: the list is in a window")
        let elsewhere = ThemedTextView(frame: .zero, textContainer: nil)
        window.contentView?.addSubview(elsewhere)

        XCTAssertTrue(
            window.makeFirstResponder(table),
            "Fixture premise: the list can hold focus in order to lose it"
        )
        XCTAssertTrue(
            window.makeFirstResponder(elsewhere),
            "Fixture premise: focus can move out of the list"
        )
        try draw(table)

        XCTAssertEqual(
            emphasizedRowCount(in: table),
            Fixture.rows,
            "Focus moving out of a list should not change how its selection reads"
        )
    }

    /// The other half, so this is "follow the window" rather than "always shout": behind another
    /// window the selection steps back, which is the state AppKit's quiet fill was meant for.
    func testAListInABackgroundWindowKeepsTheQuietFill() throws {
        let table = try list(isKey: false)

        try draw(table)

        XCTAssertEqual(
            emphasizedRowCount(in: table),
            0,
            "A background window's list should keep the unemphasized fill"
        )
    }

    /// A row built later — the one scrolling adds, after every notification has been and gone —
    /// arrives with AppKit's answer and has to be corrected before it paints. This is why the
    /// rule is applied at the draw and not only where focus and key state change.
    func testARowBuiltAfterTheListSettledDrawsAtTheListsStrength() throws {
        let table = try list(isKey: true)
        try draw(table)

        table.reloadData()
        table.selectRowIndexes(IndexSet(0..<Fixture.rows), byExtendingSelection: false)
        try draw(table)

        XCTAssertEqual(
            emphasizedRowCount(in: table),
            Fixture.rows,
            "Rows built after the list settled should still draw at its strength"
        )
    }

    /// And the strength is a difference anyone can see, not just a flag: the fill under a plain
    /// row is AppKit's own — under **System**, which is where this was reported, that is the
    /// difference between the accent and a flat grey — so this also pins that raising the flag
    /// reaches the drawing we do not do ourselves.
    func testTheTwoStrengthsPaintDifferentFills() throws {
        let previousTheme = AppThemeLibrary.current
        defer { AppThemeLibrary.apply(previousTheme) }
        AppThemeLibrary.apply(.system)

        let front = try draw(try list(isKey: true))
        let behind = try draw(try list(isKey: false))

        let x = front.pixelsWide / 2
        let y = front.pixelsHigh / 2
        let strong = try XCTUnwrap(front.colorAt(x: x, y: y), "No pixel at \(x),\(y)")
        let quiet = try XCTUnwrap(behind.colorAt(x: x, y: y), "No pixel at \(x),\(y)")
        let delta = abs(strong.redComponent - quiet.redComponent)
            + abs(strong.greenComponent - quiet.greenComponent)
            + abs(strong.blueComponent - quiet.blueComponent)

        XCTAssertGreaterThan(
            delta,
            0.1,
            "The front window's selection should be visibly the stronger of the two fills"
        )
    }

    // MARK: - Where The Rule Is Applied

    /// **The regression, and the one every test above missed.**
    ///
    /// The rule shipped as a re-assert from `viewWillDraw`, and the defect was reported again
    /// against the built app while all of these kept passing — because they reach the list's draw
    /// through `cacheDisplay`, and nothing in a running window does. Every window is layer-backed
    /// on modern macOS, so a demoted row repaints from its own layer and the list is never asked
    /// to draw: probed against a live window, `viewWillDraw` fires once for the first paint and
    /// not again as focus comes and goes.
    ///
    /// So this asserts the demotion is refused **where it arrives**, with no draw of any kind
    /// between the two lines — which is the only form of the rule that survives the app.
    func testADemotionIsRefusedWhereItArrivesRatherThanAtTheNextDraw() throws {
        let table = try list(isKey: true)
        try draw(table)

        demoteEveryRow(in: table)

        XCTAssertEqual(
            emphasizedRowCount(in: table),
            Fixture.rows,
            "A demotion should be refused as it arrives, not repaired by a draw that never comes"
        )
    }

    /// The other direction, asserted the same way: refusing AppKit's demotion must not become
    /// "always shout". A list that is genuinely not in the front window takes the quiet fill the
    /// moment it is asked, with no draw to recover through either.
    func testABackgroundWindowsListTakesTheQuietFillWithoutADrawEither() throws {
        let table = try list(isKey: false)
        try draw(table)

        table.enumerateAvailableRowViews { row, _ in row.isEmphasized = true }

        XCTAssertEqual(
            emphasizedRowCount(in: table),
            0,
            "A background window's list should hold the quiet fill against a promotion too"
        )
    }

    /// A row built while scrolling arrives after every notification and after the list's last
    /// draw. It cannot refuse anything on the way in — AppKit sets its emphasis *before* it has a
    /// superview to ask, which is measured rather than assumed — so landing in the list is where
    /// it takes the list's answer.
    func testARowTakesTheListsStrengthAsItLandsInTheList() throws {
        let table = try list(isKey: true)
        let row = ThemedTableRowView()
        row.isEmphasized = false

        table.addSubview(row)

        XCTAssertTrue(
            row.isEmphasized,
            "A row joining a list in the front window should adopt its strength on arrival"
        )
    }

    /// Both row classes, asked of each rather than of one: the override is a property, so it has
    /// to be restated per class and is exactly the kind of thing that gets half-written.
    func testBothRowClassesRefuseADemotionTheirListDidNotAskFor() throws {
        for make in [{ ThemedTableRowView() as NSTableRowView }, { SidebarHoverRowView() }] {
            rows.rowView = make
            defer { rows.rowView = nil }

            let table = try list(isKey: true)
            try draw(table)
            let vended = String(describing: type(of: try XCTUnwrap(
                table.rowView(atRow: 0, makeIfNecessary: false),
                "Fixture premise: the list built the row it was handed"
            )))

            demoteEveryRow(in: table)

            XCTAssertEqual(
                emphasizedRowCount(in: table),
                Fixture.rows,
                "\(vended) should hold its list's strength against AppKit's demotion"
            )
        }
    }

    /// And a list that is asked for nothing still gets a row that carries it — the row nobody
    /// wrote, which is what made this a rule about lists in the first place.
    func testTheRowAListVendsForItselfCarriesTheRefusal() throws {
        let table = try list(isKey: true)
        try draw(table)

        XCTAssertTrue(
            table.rowView(atRow: 0, makeIfNecessary: false) is ThemedTableRowView,
            "A list whose delegate returns no row view should still get the themed row"
        )
    }

    // MARK: - Reach

    /// What makes this a construction rather than another fix: there is nowhere else to put a
    /// list. Both classes carry the rule and the theme boundary refuses a third, so a list
    /// written next year inherits it without its author needing to know it exists.
    func testEveryListInTheAppIsOneOfTheTwoThatCarryTheRule() throws {
        let declarations = try NSRegularExpression(
            pattern: #"(?m)^(?:(?:public|internal|package|private|fileprivate|open|final)\s+)*class\s+([A-Za-z_][A-Za-z0-9_]*)\s*:\s*(?:NSTableView|NSOutlineView)\b"#
        )

        var lists: Set<String> = []
        for source in try appSources() {
            let text = try String(contentsOf: source, encoding: .utf8)
            let range = NSRange(text.startIndex..., in: text)
            for match in declarations.matches(in: text, range: range) {
                guard let name = Range(match.range(at: 1), in: text) else { continue }
                lists.insert(String(text[name]))
            }
        }

        XCTAssertEqual(
            lists,
            ["ThemedTableView", "ThemedOutlineView"],
            "A list outside these two would draw its selection by AppKit's rule again"
        )
    }

    /// The same reach argument for the half of the rule that lives on the row. A *direct*
    /// subclass of `NSTableRowView` is one that has not inherited the refusal from anywhere, so
    /// a third one is a row that would believe AppKit again — deriving from either of these two
    /// is free and stays free.
    func testEveryRowBuiltFromScratchInTheAppIsOneOfTheTwoThatRefuseTheDemotion() throws {
        let declarations = try NSRegularExpression(
            pattern: #"(?m)^(?:(?:public|internal|package|private|fileprivate|open|final)\s+)*class\s+([A-Za-z_][A-Za-z0-9_]*)\s*:\s*NSTableRowView\b"#
        )

        var rowClasses: Set<String> = []
        for source in try appSources() {
            let text = try String(contentsOf: source, encoding: .utf8)
            let range = NSRange(text.startIndex..., in: text)
            for match in declarations.matches(in: text, range: range) {
                guard let name = Range(match.range(at: 1), in: text) else { continue }
                rowClasses.insert(String(text[name]))
            }
        }

        XCTAssertEqual(
            rowClasses,
            ["ThemedTableRowView", "SidebarHoverRowView"],
            "A row built straight on NSTableRowView would take AppKit's demotion again"
        )
    }

    /// And both of them actually carry it, asked of each class rather than of one instance: the
    /// duplication `NSOutlineView` forces — it is already an `NSTableView`, so the two cannot
    /// share a superclass — is exactly the kind that gets half-written.
    func testBothListClassesFollowTheWindowRatherThanTheFocus() throws {
        for make in [{ ThemedTableView() as NSTableView }, { ThemedOutlineView() as NSTableView }] {
            let table = try list(isKey: true, make: make)
            demoteEveryRow(in: table)
            try draw(table)

            XCTAssertEqual(
                emphasizedRowCount(in: table),
                Fixture.rows,
                "\(type(of: table)) should hold its rows to its window's strength"
            )
        }
    }

    // MARK: - Harness

    /// A list in an **unshown** window, with rows and a selection, at a stated key state — the
    /// one state a test window can never actually reach. See `ListSelectionStrength.fixtureIsKey`.
    private func list(
        isKey: Bool,
        make: () -> NSTableView = { ThemedOutlineView() }
    ) throws -> NSTableView {
        let table = make()
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("list"))
        column.width = Fixture.width
        table.addTableColumn(column)
        (table as? NSOutlineView)?.outlineTableColumn = column
        table.headerView = nil
        table.rowHeight = Fixture.rowHeight
        table.dataSource = rows
        table.delegate = rows

        let frame = NSRect(
            x: 0,
            y: 0,
            width: Fixture.width,
            height: Fixture.rowHeight * CGFloat(Fixture.rows)
        )
        table.frame = frame

        // Built and never ordered on screen, and `defer: false` so the backing store exists:
        // a list only builds its row views for a window that can actually draw.
        let window = NSWindow(
            contentRect: frame,
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false

        let host = NSView(frame: frame)
        host.wantsLayer = true
        host.layer?.backgroundColor = Fixture.ground.cgColor
        host.addSubview(table)
        window.contentView = host

        switch table {
        case let table as ThemedTableView: table.fixtureIsKey = isKey
        case let table as ThemedOutlineView: table.fixtureIsKey = isKey
        default: XCTFail("Fixture premise: the list states its own key state")
        }

        table.reloadData()
        table.selectRowIndexes(IndexSet(0..<Fixture.rows), byExtendingSelection: false)
        return table
    }

    /// Exactly what AppKit does to every row when the list stops being first responder.
    private func demoteEveryRow(in table: NSTableView) {
        table.enumerateAvailableRowViews { row, _ in row.isEmphasized = false }
    }

    /// Through a real display pass rather than by calling the rule, so what is asserted is the
    /// state the rows would have painted in.
    @discardableResult
    private func draw(_ table: NSTableView) throws -> NSBitmapImageRep {
        let host = try XCTUnwrap(table.window?.contentView, "Fixture premise: the list has a host")
        host.layoutSubtreeIfNeeded()

        let rep = try XCTUnwrap(
            host.bitmapImageRepForCachingDisplay(in: host.bounds),
            "Failed to build a bitmap for the list"
        )
        host.cacheDisplay(in: host.bounds, to: rep)
        return rep
    }

    private func emphasizedRowCount(in table: NSTableView) -> Int {
        var count = 0
        table.enumerateAvailableRowViews { row, _ in
            if row.isEmphasized { count += 1 }
        }
        return count
    }

    private func appSources() throws -> [URL] {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/Threading")
        let walk = try XCTUnwrap(
            FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil),
            "Failed to walk the app's sources"
        )

        return walk.compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" }
    }
}
