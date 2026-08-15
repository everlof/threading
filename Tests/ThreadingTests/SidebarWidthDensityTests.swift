import AppKit
import XCTest
@testable import Threading

/// The list fitted to the column it has: as the divider narrows the sidebar, the gutters on both
/// sides of a row and the outline's per-level step close in step with the drag, and the title —
/// the only thing anyone reads in a sidebar — keeps the space they give up.
///
/// Two halves, asserted separately. `SidebarDensity` is the arithmetic, which can be read
/// straight. The rest is placement, and placement is only true once `NSOutlineView` has built the
/// rows: the cell and the disclosure chevron are AppKit's to position, so the geometry is read
/// off the built views in a window that is laid out and drawn but never shown — the same fixture
/// shape as `SidebarCompactTreeTests`, which owns the other density this list has.
@MainActor
final class SidebarWidthDensityTests: XCTestCase {

    // MARK: - Fixtures

    /// What the `.inset` style keeps past every cell's trailing edge — 16pt, measured on
    /// macOS 26 and the band the reclaim is spent out of. Written down here rather than read
    /// off the app, because a number taken from the code under test proves nothing about it.
    private static let styleTrailingBand: CGFloat = 16

    private var directories: [URL] = []
    private var stateManagers: [StateManager] = []
    private var windows: [NSWindow] = []

    override func tearDown() {
        MainActor.assumeIsolated {
            for window in windows {
                window.orderOut(nil)
                window.contentViewController = nil
                window.close()
            }
            windows = []
            for manager in stateManagers { manager.closeDatabase() }
            stateManagers = []
            for directory in directories {
                try? FileManager.default.removeItem(at: directory)
            }
            directories = []
            UserDefaults.standard.removeObject(forKey: "compactsSidebarTree")
            UserDefaults.standard.removeObject(forKey: "groupsSessionsByBranch")
            UserDefaults.standard.removeObject(forKey: "groupsLoneBranches")
        }
        super.tearDown()
    }

    /// A sidebar over its own store at a stated width: one project whose sessions gather under
    /// branch headings, so the tree is two levels deep — where the depth step costs the most and
    /// the tightening has the most to give back.
    @discardableResult
    private func makeSidebar(
        width: CGFloat,
        compact: Bool = false
    ) -> (controller: ProjectSidebarViewController, store: ProjectStore) {
        UserDefaults.standard.set(compact, forKey: "compactsSidebarTree")
        UserDefaults.standard.set(true, forKey: "groupsSessionsByBranch")
        UserDefaults.standard.set(true, forKey: "groupsLoneBranches")

        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "threading-sidebar-density-\(UUID().uuidString)",
            isDirectory: true
        )
        directories.append(directory)

        var project = Project(
            name: "Threading",
            folderURL: directory.appendingPathComponent("threading")
        )
        // One session is pinned, so every measurement and every render has the trailing mark the
        // reclaimed band is judged against — the thing that ends up nearest the seam.
        project.sessions = [
            session("Fit the sidebar to its column", branch: "main", pinned: true),
            session("Compact the gutters", branch: "fix/density"),
            session("Lower the depth step", branch: "fix/density")
        ]

        let manager = StateManager(appSupportDirectory: directory)
        stateManagers.append(manager)
        XCTAssertTrue(manager.saveProjectsState(ProjectsState(projects: [project])))
        let store = ProjectStore(stateManager: manager)
        let controller = ProjectSidebarViewController(projectStore: store)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: width, height: 900),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentViewController = controller
        windows.append(window)

        resize(to: width)
        return (controller, store)
    }

    private func session(
        _ title: String,
        branch: String? = nil,
        pinned: Bool = false
    ) -> AgentSession {
        var session = AgentSession(kind: .claude, title: title)
        session.branch = branch
        session.isPinned = pinned
        return session
    }

    /// Moves the column to a width and lets the list answer, the way a divider drag does: a new
    /// size, a layout pass, a draw. Nothing is ordered on screen — an outline that has never been
    /// drawn has no row views for a test to measure.
    private func resize(to width: CGFloat) {
        for window in windows {
            window.setContentSize(NSSize(width: width, height: 900))
            window.contentViewController?.view.frame = NSRect(
                x: 0,
                y: 0,
                width: width,
                height: 900
            )
        }
        draw()
    }

    private func draw() {
        for window in windows {
            guard let view = window.contentView else { continue }
            view.layoutSubtreeIfNeeded()
            guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
                continue
            }
            view.cacheDisplay(in: view.bounds, to: bitmap)
        }
    }

    /// Every built row view, top to bottom, with the cell it holds.
    private func builtRows(
        _ controller: ProjectSidebarViewController
    ) -> [(row: NSTableRowView, cell: NSTableCellView)] {
        controller.presentedRowKeys.compactMap { key in
            guard let rowView = controller.presentedRowView(of: key),
                  let cell = rowView.subviews.compactMap({ $0 as? NSTableCellView }).first
            else { return nil }
            return (rowView, cell)
        }
    }

    private func sessionCells(
        _ rows: [(row: NSTableRowView, cell: NSTableCellView)]
    ) -> [(row: NSTableRowView, cell: NSTableCellView)] {
        rows.filter { $0.cell is SessionRowView }
    }

    private func branchHeadingCells(
        _ rows: [(row: NSTableRowView, cell: NSTableCellView)]
    ) -> [(row: NSTableRowView, cell: NSTableCellView)] {
        rows.filter { $0.cell.identifier == SidebarIdentifiers.branchCell }
    }

    /// Where a row's own content begins, in the row's coordinates: the cell's placement plus the
    /// leading gutter the row holds inside it. The two move independently — AppKit owns the
    /// first, the row owns the second — and a reader sees only their sum.
    private func contentLeadingEdge(_ cell: NSTableCellView) -> CGFloat {
        let identifiers = [
            "sidebar.session.title",
            "sidebar.project.title",
            "sidebar.terminal.title"
        ]
        let title = descendant(of: cell) { view in
            identifiers.contains(view.accessibilityIdentifier())
        }
        guard let title else { return cell.frame.minX }
        return cell.frame.minX + cell.convert(title.bounds, from: title).minX
    }

    private func descendant(of view: NSView, matching: (NSView) -> Bool) -> NSView? {
        for subview in view.subviews {
            if matching(subview) { return subview }
            if let found = descendant(of: subview, matching: matching) { return found }
        }
        return nil
    }

    /// Where a row's trailing mark ends, in the row's coordinates: a session's status indicator
    /// and its hover buttons share one slot, and the slot's edge is what a reader sees against
    /// the seam.
    private func trailingMarkEdge(of cell: NSTableCellView?) -> CGFloat? {
        guard let cell else { return nil }
        let slot = cell.subviews
            .filter { !$0.isHidden }
            .max { $0.frame.maxX < $1.frame.maxX }
        guard let slot else { return nil }
        return cell.frame.minX + slot.frame.maxX
    }

    private func disclosureButton(in rowView: NSTableRowView) -> NSView? {
        rowView.subviews.first { $0.identifier == NSOutlineView.disclosureButtonIdentifier }
    }

    // MARK: - The arithmetic

    /// Nothing tightens until the column is actually narrow: at and above the width the app opens
    /// itself to, every metric is the one it was measured at.
    func testAColumnAtItsOpeningWidthGivesNothingUp() {
        for width in [SidebarDefaults.relaxedDensityWidth, 320, SidebarDefaults.maxWidth] {
            let density = SidebarDensity(width: width)
            XCTAssertEqual(density, .relaxed, "\(width)pt is not a narrow column")
        }

        XCTAssertEqual(
            SidebarDensity.relaxed.indentationPerLevel,
            SidebarDefaults.indentationPerLevel
        )
        XCTAssertEqual(SidebarDensity.relaxed.rowLeadingInset, SidebarRowDefaults.leadingInset)
        XCTAssertEqual(SidebarDensity.relaxed.rowTrailingInset, SidebarRowDefaults.trailingInset)
    }

    /// And it stops giving at the narrowest the column goes — a width pushed past that floor
    /// draws the same tightest list rather than extrapolating into negative gutters.
    func testTheTighteningBottomsOutAtTheNarrowestColumn() {
        let floor = SidebarDensity(width: SidebarDefaults.tightDensityWidth)
        XCTAssertEqual(floor.indentationPerLevel, SidebarDefaults.tightIndentationPerLevel)
        XCTAssertEqual(floor.rowLeadingInset, SidebarRowDefaults.tightLeadingInset)
        XCTAssertEqual(floor.rowTrailingInset, SidebarRowDefaults.tightTrailingInset)
        XCTAssertEqual(floor.selectionInsetX, SidebarRowDefaults.tightHoverHighlightInsetX)

        XCTAssertEqual(SidebarDensity(width: 40), floor, "past the floor is still the floor")
        XCTAssertEqual(SidebarDensity(width: 0), floor)
    }

    /// Which floor, though, is the split view's to say and not this file's — it is raised at
    /// runtime to clear the window controls floating over the column. The band has to end there
    /// or its tight end is a set of values no drag can reach: measured on the running window,
    /// the column stopped at 208pt while the arithmetic was still halfway down, so the most
    /// compact sidebar the app allowed drew a depth step of 11 where 6 was the answer.
    func testTheBandEndsAtTheWidthTheColumnCanActuallyReach() {
        let reachable: CGFloat = 208

        XCTAssertEqual(
            SidebarDensity(width: reachable, floor: reachable),
            SidebarDensity(width: SidebarDefaults.tightDensityWidth),
            "the narrowest column there is has to draw the tightest list there is"
        )
        XCTAssertNotEqual(
            SidebarDensity(width: reachable),
            SidebarDensity(width: reachable, floor: reachable),
            "which is exactly what a band ending below the last reachable width does not do"
        )

        // A column that cannot be narrowed at all is not a column that should be drawn tight.
        for floor in [SidebarDefaults.relaxedDensityWidth, 260] {
            XCTAssertEqual(SidebarDensity(width: floor, floor: floor), .relaxed)
        }
    }

    /// In between it is a fraction, not a threshold: every metric falls with the drag, and the
    /// halfway column draws halfway between the two ends.
    func testTheGuttersCloseInStepWithTheDrag() {
        let relaxed = SidebarDefaults.relaxedDensityWidth
        let tight = SidebarDefaults.tightDensityWidth
        let midpoint = SidebarDensity(width: (relaxed + tight) / 2)

        XCTAssertEqual(
            midpoint.indentationPerLevel,
            (
                (SidebarDefaults.indentationPerLevel
                    + SidebarDefaults.tightIndentationPerLevel) / 2
            ).rounded()
        )
        XCTAssertEqual(
            midpoint.rowLeadingInset,
            ((SidebarRowDefaults.leadingInset + SidebarRowDefaults.tightLeadingInset) / 2)
                .rounded()
        )

        // Monotonic the whole way down, so no drag makes the list wider than the width before it.
        var previous = SidebarDensity(width: relaxed)
        for width in stride(from: relaxed, through: tight, by: -5) {
            let density = SidebarDensity(width: width)
            XCTAssertLessThanOrEqual(density.indentationPerLevel, previous.indentationPerLevel)
            XCTAssertLessThanOrEqual(density.rowLeadingInset, previous.rowLeadingInset)
            XCTAssertLessThanOrEqual(density.rowTrailingInset, previous.rowTrailingInset)
            previous = density
        }

        // Whole points only: two widths a fraction apart draw identically, which is what lets a
        // live drag skip the passes that would move nothing.
        XCTAssertEqual(SidebarDensity(width: 209), SidebarDensity(width: 209.4))
    }

    // MARK: - The built tree

    /// The whole point, on the rows themselves: narrow the column and a session two levels deep
    /// starts further left than it did — by the depth the outline gave up *plus* the gutter the
    /// row gave up — while its trailing mark moves out towards the seam.
    func testANarrowColumnGivesTheTitleBothGutters() throws {
        let (controller, _) = makeSidebar(width: 320)

        let wideRows = builtRows(controller)
        let wideSession = try XCTUnwrap(sessionCells(wideRows).first)
        let wideHeading = try XCTUnwrap(branchHeadingCells(wideRows).first)
        let wideLeading = contentLeadingEdge(wideSession.cell)
        let wideChevron = try XCTUnwrap(disclosureButton(in: wideHeading.row)).frame.minX

        resize(to: SidebarDefaults.tightDensityWidth)

        let tightRows = builtRows(controller)
        let tightSession = try XCTUnwrap(sessionCells(tightRows).first)
        let tightHeading = try XCTUnwrap(branchHeadingCells(tightRows).first)

        let relaxed = SidebarDensity.relaxed
        let tight = SidebarDensity(width: SidebarDefaults.tightDensityWidth)
        let stepGiven = relaxed.indentationPerLevel - tight.indentationPerLevel
        let gutterGiven = relaxed.rowLeadingInset - tight.rowLeadingInset

        XCTAssertEqual(
            contentLeadingEdge(tightSession.cell),
            wideLeading - (2 * stepGiven + gutterGiven),
            accuracy: 0.5,
            "a session under a branch heading wins back two depth steps and its own gutter"
        )
        XCTAssertEqual(
            try XCTUnwrap(disclosureButton(in: tightHeading.row)).frame.minX,
            wideChevron - stepGiven,
            accuracy: 0.5,
            "the chevron moves with the depth it marks, or it drifts off its own row"
        )
    }

    /// And it happens *to the rows that are already there*. The frames AppKit computed when it
    /// built each row are re-placed in situ; nothing is reloaded, because a wholesale rebuild per
    /// frame of a divider drag is the cost this route exists to avoid.
    func testTighteningKeepsTheRowsItAlreadyBuilt() throws {
        let (controller, _) = makeSidebar(width: 320)

        let before = builtRows(controller)
        let identities = before.map { ObjectIdentifier($0.cell) }
        let wideLeading = contentLeadingEdge(try XCTUnwrap(sessionCells(before).first).cell)

        resize(to: SidebarDefaults.tightDensityWidth)

        let after = builtRows(controller)
        XCTAssertEqual(
            after.map { ObjectIdentifier($0.cell) },
            identities,
            "the same cells, moved — not a rebuilt list"
        )
        XCTAssertLessThan(
            contentLeadingEdge(try XCTUnwrap(sessionCells(after).first).cell),
            wideLeading
        )

        // Moved sideways and *only* sideways. The frames the re-placement reads are stated in
        // the table's coordinates while a cell lives in its row's, so taking one whole drops
        // every row's content by its own offset down the list — which drew a column holding one
        // clipped project row and nothing beneath it.
        for (rowView, cell) in after {
            XCTAssertEqual(cell.frame.minY, 0, "a cell sits at the top of its own row")
            XCTAssertEqual(cell.frame.height, rowView.frame.height, "and fills it")
            XCTAssertLessThanOrEqual(
                cell.frame.maxX,
                rowView.frame.width,
                "and stays inside it"
            )
        }
    }

    /// The larger half of the trailing gap is not the row's at all: the `.inset` style keeps 16pt
    /// past every cell, and a narrow column takes some of it back. The mark ends up nearer the
    /// seam than the row's own gutter could ever bring it.
    func testANarrowColumnTakesBackTheStylesTrailingPadding() throws {
        let (controller, _) = makeSidebar(width: 320)

        let wideRows = builtRows(controller)
        let wideEdge = try XCTUnwrap(sessionCells(wideRows).first).cell.frame.maxX
        let wideMark = try XCTUnwrap(trailingMarkEdge(of: sessionCells(wideRows).first?.cell))

        resize(to: SidebarDefaults.tightDensityWidth)

        let tightRows = builtRows(controller)
        let session = try XCTUnwrap(sessionCells(tightRows).first)
        let rowWidth = session.row.frame.width

        XCTAssertEqual(
            rowWidth - session.cell.frame.maxX,
            (320 - wideEdge) - SidebarDefaults.tightTrailingCellReclaim,
            accuracy: 0.5,
            "the cell reaches further out than the style would have left it"
        )

        // And the mark inside it follows. It moves out by the whole reclaim, plus as much of the
        // row's own gutter as the row can actually give: that gutter is measured to the button's
        // ink and clamped so the slot never overhangs the cell that hit-tests it, so the two
        // reductions do not simply add.
        let relaxed = SidebarDensity.relaxed
        let tight = SidebarDensity(width: SidebarDefaults.tightDensityWidth)
        let tightMark = try XCTUnwrap(trailingMarkEdge(of: session.cell))
        let moved = (320 - wideMark) - (rowWidth - tightMark)
        XCTAssertGreaterThanOrEqual(moved, tight.trailingCellReclaim)
        XCTAssertLessThanOrEqual(
            moved,
            tight.trailingCellReclaim + (relaxed.rowTrailingInset - tight.rowTrailingInset)
        )
    }

    /// What bounds that reclaim: the selection capsule this list draws itself. Content may move
    /// out into the band the style keeps, and must stop inside the shape a selected row fills —
    /// a pin drawn over the edge of its own accent capsule is the failure this prevents.
    ///
    /// The capsule is not a fixed edge to stay inside, because it closes with the column too. So
    /// the rule is asserted at both ends of the band and every point between: whatever the drag
    /// is doing, the cell stops inside the shape drawn over it.
    func testReclaimedContentStaysInsideTheSelectionCapsule() {
        for width in [SidebarDefaults.relaxedDensityWidth, 220, SidebarDefaults.tightDensityWidth] {
            let (controller, _) = makeSidebar(width: width)
            let inset = SidebarDensity(width: width).selectionInsetX

            for (rowView, cell) in builtRows(controller) {
                XCTAssertLessThanOrEqual(
                    cell.frame.maxX,
                    rowView.frame.width - inset,
                    "\(type(of: cell)) at \(width)pt reaches past the capsule it is drawn inside"
                )
            }
        }

        // And the clearance between the two closes without ever running out, which is the thing
        // the numbers above are only safe while doing. Asserted as a floor across the band
        // rather than as a monotone fall: the reclaim and the capsule round to whole points
        // independently, so between the two steps that answer one drag the gap gives a point
        // back before taking it again. Six at the top, two at the bottom, never under.
        func clearance(at width: CGFloat) -> CGFloat {
            let density = SidebarDensity(width: width)
            return (Self.styleTrailingBand - density.trailingCellReclaim) - density.selectionInsetX
        }

        for width in stride(
            from: SidebarDefaults.relaxedDensityWidth,
            through: SidebarDefaults.tightDensityWidth,
            by: -1
        ) {
            XCTAssertGreaterThanOrEqual(
                clearance(at: width),
                2,
                "at \(width)pt the cell reaches its own capsule"
            )
        }

        XCTAssertEqual(clearance(at: SidebarDefaults.relaxedDensityWidth), 6)
        XCTAssertEqual(clearance(at: SidebarDefaults.tightDensityWidth), 2)
    }

    /// The same thing on the rows: told the floor the split view actually enforces, the list at
    /// that width draws what the tightest list draws — rather than the halfway one it drew while
    /// the band ran on down to a width no drag could reach.
    func testTheListDrawsItsTightestAtTheFloorItIsGiven() throws {
        let reachable: CGFloat = 208
        let (controller, _) = makeSidebar(width: 320)

        resize(to: reachable)
        let halfway = contentLeadingEdge(try XCTUnwrap(sessionCells(builtRows(controller)).first).cell)

        controller.densityFloor = reachable
        draw()
        let tightened = contentLeadingEdge(
            try XCTUnwrap(sessionCells(builtRows(controller)).first).cell
        )
        XCTAssertLessThan(tightened, halfway, "the floor has to move the list it bounds")

        // And it is the *tightest* list, not merely a tighter one: the same leading edge the
        // fixture draws at the floor the constant states.
        let reference = makeSidebar(width: SidebarDefaults.tightDensityWidth).controller
        XCTAssertEqual(
            tightened,
            contentLeadingEdge(try XCTUnwrap(sessionCells(builtRows(reference)).first).cell),
            accuracy: 0.5
        )
    }

    /// A drag is not one resize but a hundred, and the re-placement is applied on top of frames
    /// AppKit will not restate. So the whole band is walked a point at a time, down and back, and
    /// the list has to land exactly where it started — nothing accumulated, nothing drifted.
    func testADragDownAndBackLeavesTheListWhereItStarted() throws {
        let (controller, _) = makeSidebar(width: SidebarDefaults.relaxedDensityWidth)

        let start = builtRows(controller).map { $0.cell.frame }
        let widths = stride(
            from: SidebarDefaults.relaxedDensityWidth,
            through: SidebarDefaults.tightDensityWidth,
            by: -1
        )
        for width in widths { resize(to: width) }

        let tight = builtRows(controller).map { $0.cell.frame }
        XCTAssertNotEqual(tight, start, "the walk down has to have moved something")

        for width in widths.reversed() { resize(to: width) }
        XCTAssertEqual(
            builtRows(controller).map { $0.cell.frame },
            start,
            "the same width must draw the same list, however it was arrived at"
        )
    }

    /// A row built *after* the drag — scrolled in, or inserted by the store — arrives at the
    /// width the column actually has, because the dequeue stamps every cell on its way out of
    /// the reuse pool.
    func testARowBuiltAfterTheDragArrivesTightened() throws {
        let (controller, store) = makeSidebar(width: 320)
        let wideLeading = contentLeadingEdge(
            try XCTUnwrap(sessionCells(builtRows(controller)).first).cell
        )

        resize(to: SidebarDefaults.tightDensityWidth)
        let project = try XCTUnwrap(store.projects.first)
        store.addSession(to: project.id, kind: .claude, title: "Arrived narrow")
        draw()

        let arrived = builtRows(controller).first {
            ($0.cell as? SessionRowView)?.accessibilityLabel()?.contains("Arrived narrow") ?? false
        } ?? sessionCells(builtRows(controller)).last
        let cell = try XCTUnwrap(arrived?.cell)
        XCTAssertLessThan(
            contentLeadingEdge(cell),
            wideLeading,
            "a row that has never seen the wide column must not be drawn for one"
        )
    }

    /// The trailing gutter closes towards the seam and stops there. A slot allowed past the row's
    /// own edge draws perfectly and cannot be clicked at all — `hitTest` stops at the bounds — so
    /// the tightest column is still a column whose `⋯` and archive button work.
    func testTheTrailingControlsStayInsideTheirRow() {
        let (controller, _) = makeSidebar(width: SidebarDefaults.tightDensityWidth)

        for (_, cell) in builtRows(controller) {
            for subview in cell.subviews {
                XCTAssertLessThanOrEqual(
                    subview.frame.maxX,
                    cell.bounds.width + 0.5,
                    "\(type(of: cell)) hangs its trailing content outside its own bounds"
                )
            }
        }
    }

    /// The two densities compose, and the compact tree keeps its own edge while they do. It has
    /// already spent its depth, and its gutter is the chevron's own width — AppKit draws that
    /// mark 13pt wide and does not shrink it — so a narrow column tightens the row gutters there
    /// and takes nothing from the edge every row shares.
    func testTheCompactTreeKeepsItsEdgeInANarrowColumn() throws {
        let (controller, _) = makeSidebar(
            width: SidebarDefaults.tightDensityWidth,
            compact: true
        )

        let rows = builtRows(controller)
        XCTAssertFalse(rows.isEmpty)
        for (_, cell) in rows {
            XCTAssertEqual(
                cell.frame.minX,
                SidebarDefaults.compactCellLeading,
                "every row shares the one edge, narrow column included"
            )
        }

        let chevrons = rows.compactMap { disclosureButton(in: $0.row) }
        XCTAssertFalse(chevrons.isEmpty, "projects and branch headings keep their chevrons")
        for chevron in chevrons {
            XCTAssertEqual(chevron.frame.minX, SidebarDefaults.compactMarkerLeading)
            XCTAssertLessThanOrEqual(
                chevron.frame.maxX,
                SidebarDefaults.compactCellLeading,
                "the gutter must still clear the content it stands before"
            )
        }

        // What the narrow column does take there: the row's own gutter, inside that edge. The
        // title stands one icon slot and one gap after it, both of which the density leaves.
        let session = try XCTUnwrap(sessionCells(rows).first)
        let tight = SidebarDensity(width: SidebarDefaults.tightDensityWidth)
        XCTAssertEqual(
            contentLeadingEdge(session.cell) - session.cell.frame.minX,
            tight.rowLeadingInset
                + SidebarRowDefaults.iconSlotWidth
                + SidebarRowDefaults.horizontalSpacing,
            accuracy: 0.5
        )
    }

    // MARK: - Rendered

    /// The column at both ends of the band, light and dark — the review surface for how much a
    /// narrow sidebar actually wins, which no frame assertion can judge the look of. One fixture,
    /// resized between the renders, which is the path a divider drag takes in the app.
    ///
    /// The narrow render is taken at the width the window controls leave, with the floor to
    /// match, because that is the narrowest column a person can actually drag to — a picture of
    /// a 180pt sidebar reviews a list nobody is ever shown.
    func testRendersTheColumnAtBothEndsOfTheBand() throws {
        let (controller, store) = makeSidebar(width: SidebarDefaults.relaxedDensityWidth)
        // With the pinned session selected: the capsule is what bounds how far the reclaimed
        // band may be spent, and a mark riding its edge is only visible in a picture.
        if let pinned = store.projects.first?.sessions.first(where: \.isPinned) {
            controller.select(sessionID: pinned.id, notifyDelegate: false)
        }
        let window = try XCTUnwrap(windows.last)

        let directory = ProcessInfo.processInfo.environment["THREADING_RENDER_OUT"]
            .map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
                .appendingPathComponent("ThreadingRenders", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        func render(as label: String) throws {
            let view = try XCTUnwrap(window.contentView)
            for (name, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
                window.appearance = NSAppearance(named: appearance)
                AppThemeRefresh.repaint(view)
                view.layoutSubtreeIfNeeded()

                // The content view is not flipped, so the list — pinned under the header band —
                // lives at the top of its coordinate space.
                let bounds = NSRect(
                    x: 0,
                    y: view.bounds.height - 340,
                    width: view.bounds.width,
                    height: 340
                )
                let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: bounds))
                view.cacheDisplay(in: bounds, to: bitmap)
                let data = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
                try data.write(
                    to: directory.appendingPathComponent("sidebar-density-\(label)-\(name).png")
                )
            }
        }

        try render(as: "wide")

        let reachable = PaneHeaderDefaults.assumedWindowControlsWidth + Design.Spacing.medium
        controller.densityFloor = reachable
        resize(to: reachable)
        try render(as: "narrow")
    }
}

