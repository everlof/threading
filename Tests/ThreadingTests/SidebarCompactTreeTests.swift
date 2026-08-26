import AppKit
import XCTest
@testable import Threading

/// The compact tree: every row starting at one leading edge, groups told apart by vertical
/// rhythm and a rule instead of indentation. Opt-in — `AppSettings.compactsSidebarTree` — so
/// the first assertions here are that *nothing* changes while it is off.
///
/// Driven through the real outline view, data source and row reuse, in a window that is built
/// and drawn but never shown, the same fixture shape as `SidebarRowAnimationTests`. Geometry is
/// read off the built row views rather than off the constants that asked for it, because the
/// flattening happens inside `NSOutlineView`'s own cell placement (`frameOfCell`) and only the
/// placed frames can say it worked.
@MainActor
final class SidebarCompactTreeTests: XCTestCase {

    // MARK: - Fixtures

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

    /// A sidebar over its own store, drawn once: one project whose sessions gather under
    /// branch headings — the deepest level the tree reaches without a repository group, and
    /// therefore where the compact edge is furthest from the indented one — and one flat
    /// project beside it, so both shapes are in every assertion and every render.
    private func makeSidebar(compact: Bool) -> ProjectSidebarViewController {
        UserDefaults.standard.set(compact, forKey: "compactsSidebarTree")
        // Stated rather than assumed, so a test elsewhere overriding the grouping defaults
        // cannot decide how deep this fixture's tree is.
        UserDefaults.standard.set(true, forKey: "groupsSessionsByBranch")
        UserDefaults.standard.set(true, forKey: "groupsLoneBranches")

        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "threading-sidebar-compact-\(UUID().uuidString)",
            isDirectory: true
        )
        directories.append(directory)

        var branched = Project(
            name: "Threading",
            folderURL: directory.appendingPathComponent("threading")
        )
        branched.sessions = [
            session("Ship the compact tree", branch: "main"),
            session("Hover wash under receipts", branch: "fix/hover-wash"),
            session("Stale tracking areas", branch: "fix/hover-wash")
        ]

        var flat = Project(
            name: "SwiftTerm",
            folderURL: directory.appendingPathComponent("swiftterm")
        )
        flat.sessions = [
            session("Emoji backgrounds"),
            session("Scrollback capture"),
            session("OSC 7 reports")
        ]

        let built = [branched, flat]

        let manager = StateManager(appSupportDirectory: directory)
        stateManagers.append(manager)
        XCTAssertTrue(manager.saveProjectsState(ProjectsState(projects: built)))
        let store = ProjectStore(stateManager: manager)
        let controller = ProjectSidebarViewController(projectStore: store)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 900),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentViewController = controller
        window.setContentSize(NSSize(width: 320, height: 900))
        controller.view.frame = NSRect(x: 0, y: 0, width: 320, height: 900)
        windows.append(window)

        draw()
        return controller
    }

    private func session(_ title: String, branch: String? = nil) -> AgentSession {
        var session = AgentSession(kind: .claude, title: title)
        session.branch = branch
        return session
    }

    /// Lays out and draws without ordering anything on screen — an outline that has never
    /// been drawn has no row views for a test to measure.
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

    /// A project row and a branch heading are the same cell class, so the reuse identifier —
    /// which the dequeue stamps per role — is what tells them apart.
    private func projectCells(
        _ rows: [(row: NSTableRowView, cell: NSTableCellView)]
    ) -> [(row: NSTableRowView, cell: NSTableCellView)] {
        rows.filter { $0.cell.identifier == SidebarIdentifiers.projectCell }
    }

    private func branchHeadingCells(
        _ rows: [(row: NSTableRowView, cell: NSTableCellView)]
    ) -> [(row: NSTableRowView, cell: NSTableCellView)] {
        rows.filter { $0.cell.identifier == SidebarIdentifiers.branchCell }
    }

    private func sessionCells(
        _ rows: [(row: NSTableRowView, cell: NSTableCellView)]
    ) -> [(row: NSTableRowView, cell: NSTableCellView)] {
        rows.filter { $0.cell is SessionRowView }
    }

    // MARK: - The ordinary tree is untouched

    /// Off is the default, and off means the indented tree: a branch heading starts deeper
    /// than its project and a session under it deeper still, which is the depth the compact
    /// mode exists to spend differently. This is also what makes the one-edge assertion
    /// below mean anything.
    func testTheDefaultTreeKeepsItsIndentation() throws {
        let controller = makeSidebar(compact: false)
        let rows = builtRows(controller)

        let project = try XCTUnwrap(projectCells(rows).first)
        let heading = try XCTUnwrap(branchHeadingCells(rows).first)
        let session = try XCTUnwrap(sessionCells(rows).first)
        XCTAssertGreaterThan(
            heading.cell.frame.minX,
            project.cell.frame.minX,
            "without the option, a branch heading indents under its project"
        )
        XCTAssertGreaterThan(
            session.cell.frame.minX,
            heading.cell.frame.minX,
            "and a session on that branch indents under its heading"
        )

        XCTAssertEqual(
            project.row.frame.height,
            SidebarDefaults.projectCompactRowHeight,
            "the ordinary project row keeps its ordinary height"
        )

        for (rowView, _) in rows {
            XCTAssertEqual(
                (rowView as? SidebarHoverRowView)?.showsGroupRule ?? false,
                false,
                "no rules outside the compact tree"
            )
        }
    }

    // MARK: - One edge

    /// Compact on: every cell — projects, branch headings, and sessions two levels deep
    /// alike — starts at the one stated edge, and every disclosure chevron drops into the
    /// same fixed gutter before it.
    func testEveryRowStartsAtTheSameEdge() throws {
        let controller = makeSidebar(compact: true)
        let rows = builtRows(controller)
        XCTAssertEqual(
            rows.count, 10,
            "two project rows, two branch headings, and six sessions"
        )

        for (_, cell) in rows {
            XCTAssertEqual(
                cell.frame.minX,
                SidebarDefaults.compactCellLeading,
                "every row's content shares one leading edge"
            )
        }

        let disclosureButtons = rows.flatMap { row, _ in
            row.subviews.compactMap { subview -> NSButton? in
                guard let button = subview as? NSButton,
                      button.identifier == NSOutlineView.disclosureButtonIdentifier
                else { return nil }
                return button
            }
        }
        XCTAssertEqual(
            disclosureButtons.count, 4,
            "each project and each branch heading keeps its chevron"
        )
        for button in disclosureButtons {
            XCTAssertEqual(
                button.frame.minX,
                SidebarDefaults.compactMarkerLeading,
                "the chevron sits in the gutter, clear of the shared edge"
            )
            XCTAssertLessThanOrEqual(
                button.frame.maxX,
                SidebarDefaults.compactCellLeading,
                "the gutter must actually clear the content it stands before"
            )
        }
    }

    // MARK: - Vertical rhythm

    /// The space indentation used to spend beside a group goes above it: top-level project
    /// rows take the group gap, while branch headings — inside a project, not opening one —
    /// and sessions keep their ordinary heights.
    func testGroupRowsTakeTheGroupSpacing() throws {
        let controller = makeSidebar(compact: true)
        let rows = builtRows(controller)

        for (rowView, _) in projectCells(rows) {
            XCTAssertEqual(
                rowView.frame.height,
                SidebarDefaults.projectCompactRowHeight + SidebarDefaults.compactGroupSpacing
            )
        }
        for (rowView, _) in branchHeadingCells(rows) {
            XCTAssertEqual(rowView.frame.height, SidebarDefaults.projectCompactRowHeight)
        }
        for (rowView, _) in sessionCells(rows) {
            XCTAssertEqual(rowView.frame.height, SidebarDefaults.rowHeight)
        }
    }

    /// The rule says "a new group begins here", so the first root — whose upstairs neighbour
    /// is the header band's own hairline — does not draw one, and no session ever does.
    func testTheRuleMarksEveryGroupButTheFirst() throws {
        let controller = makeSidebar(compact: true)
        let rows = builtRows(controller)

        let projects = projectCells(rows).compactMap { $0.row as? SidebarHoverRowView }
        XCTAssertEqual(projects.count, 2)
        XCTAssertEqual(projects.first?.showsGroupRule, false, "the first group opens under the header")
        XCTAssertEqual(projects.last?.showsGroupRule, true, "the second group is what the rule is for")

        // One line, one meaning: nothing inside a project draws it — not a branch heading,
        // not a session — or the column becomes graph paper.
        for (rowView, _) in branchHeadingCells(rows) + sessionCells(rows) {
            XCTAssertEqual((rowView as? SidebarHoverRowView)?.showsGroupRule ?? false, false)
        }
    }

    // MARK: - The live flip

    /// Flipping the setting re-draws the standing list through the settings event alone — no
    /// `ProjectsDidChange`, because density changes no node. Both directions, one fixture.
    func testFlippingTheSettingReLaysOutTheStandingList() throws {
        let controller = makeSidebar(compact: false)

        AppSettings.shared.compactsSidebarTree = true
        draw()

        var rows = builtRows(controller)
        let session = try XCTUnwrap(sessionCells(rows).first)
        XCTAssertEqual(session.cell.frame.minX, SidebarDefaults.compactCellLeading)
        let project = try XCTUnwrap(projectCells(rows).first)
        XCTAssertEqual(
            project.row.frame.height,
            SidebarDefaults.projectCompactRowHeight + SidebarDefaults.compactGroupSpacing
        )

        AppSettings.shared.compactsSidebarTree = false
        draw()

        rows = builtRows(controller)
        let indentedSession = try XCTUnwrap(sessionCells(rows).first)
        let indentedProject = try XCTUnwrap(projectCells(rows).first)
        XCTAssertGreaterThan(indentedSession.cell.frame.minX, indentedProject.cell.frame.minX)
        XCTAssertEqual(
            indentedProject.row.frame.height,
            SidebarDefaults.projectCompactRowHeight,
            "switching back returns the ordinary tree, spacing included"
        )
    }

    // MARK: - Rendered

    /// Both densities as a reader meets them, light and dark — the review surface for the
    /// spacing and the rule, which no frame assertion can judge the look of, and the record
    /// of the trade the option makes. One fixture, flipped live between the two renders,
    /// which is also the path the toggle takes in the app.
    func testRendersBothTreeDensities() throws {
        let controller = makeSidebar(compact: true)
        _ = controller
        let window = try XCTUnwrap(windows.last)
        let view = try XCTUnwrap(window.contentView)

        let directory = ProcessInfo.processInfo.environment["THREADING_RENDER_OUT"]
            .flatMap { $0.isEmpty ? nil : $0 }
            .map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? URL(
                fileURLWithPath: NSTemporaryDirectory(),
                isDirectory: true
            ).appendingPathComponent("ThreadingRenders", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        func render(as density: String) throws {
            for (name, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
                window.appearance = NSAppearance(named: appearance)
                AppThemeRefresh.repaint(view)
                view.layoutSubtreeIfNeeded()

                // The window's content view is not flipped, so the list — pinned under the
                // header band — lives at the *top* of its coordinate space. Tall enough for
                // the compact tree, which spends more height than the default one: that trade
                // is the point, and a crop that hid it would be the render lying.
                let bounds = NSRect(x: 0, y: view.bounds.height - 420, width: 320, height: 420)
                let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: bounds))
                view.cacheDisplay(in: bounds, to: bitmap)
                let data = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
                try data.write(
                    to: directory.appendingPathComponent("sidebar-\(density)-tree-\(name).png")
                )
            }
        }

        try render(as: "compact")

        AppSettings.shared.compactsSidebarTree = false
        draw()
        try render(as: "default")
    }
}
