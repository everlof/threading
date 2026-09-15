import AppKit
import XCTest
@testable import Threading

/// The sidebar's disclosure chevron is AppKit's own button: the full height of its row, but 13pt
/// wide, so a press a few points beside the mark selected the row instead of folding it.
/// `ThemedOutlineView.disclosureHitOutsets` widens the press target without moving the button;
/// these hold both of its edges in the shipping sidebar — the column's side, and the row's content,
/// which must keep selecting the row — in the indented tree and the compact one.
///
/// Built and drawn in a window that is never shown, the same fixture shape as
/// `SidebarCompactTreeTests`. A press is only ever delivered once `disclosureButton(forPressAt:)`
/// has claimed it: a press the outline does not claim goes to `NSTableView.mouseDown`, whose
/// tracking loop would wait for a mouse-up that no test sends.
@MainActor
final class SidebarDisclosureHitTargetTests: XCTestCase {

    // MARK: - Fixtures

    private var directories: [URL] = []
    private var stateManagers: [StateManager] = []
    private var windows: [NSWindow] = []

    override func tearDown() async throws {
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
        try await super.tearDown()
    }

    /// One project whose sessions gather under branch headings, and one flat project, so the list
    /// holds both chevron depths and rows with nothing to disclose.
    private func makeSidebar(compact: Bool) -> ProjectSidebarViewController {
        UserDefaults.standard.set(compact, forKey: "compactsSidebarTree")
        UserDefaults.standard.set(true, forKey: "groupsSessionsByBranch")
        UserDefaults.standard.set(true, forKey: "groupsLoneBranches")

        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "threading-sidebar-disclosure-\(UUID().uuidString)",
            isDirectory: true
        )
        directories.append(directory)

        var branched = Project(
            name: "Threading",
            folderURL: directory.appendingPathComponent("threading")
        )
        branched.sessions = [
            session("Ship the compact tree", branch: "main"),
            session("Hover wash under receipts", branch: "fix/hover-wash")
        ]
        var flat = Project(
            name: "SwiftTerm",
            folderURL: directory.appendingPathComponent("swiftterm")
        )
        flat.sessions = [session("Emoji backgrounds")]

        let manager = StateManager(appSupportDirectory: directory)
        stateManagers.append(manager)
        XCTAssertTrue(manager.saveProjectsState(ProjectsState(projects: [branched, flat])))
        let controller = ProjectSidebarViewController(
            projectStore: ProjectStore(stateManager: manager)
        )

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

    /// Lays out and draws without ordering anything on screen.
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

    /// A built row as the outline sees it, with its chevron if it has one. Frames are in the
    /// outline's coordinates, which is where a press is resolved.
    private struct BuiltRow {
        let outline: ThemedOutlineView
        let item: Any
        let rowFrame: NSRect
        let cellFrame: NSRect
        let chevronFrame: NSRect?
    }

    private func builtRows(_ controller: ProjectSidebarViewController) -> [BuiltRow] {
        controller.presentedRowKeys.compactMap { key in
            guard let rowView = controller.presentedRowView(of: key),
                  let outline = rowView.superview as? ThemedOutlineView,
                  let cell = rowView.subviews.compactMap({ $0 as? NSTableCellView }).first
            else { return nil }
            let row = outline.row(at: NSPoint(x: rowView.frame.midX, y: rowView.frame.midY))
            guard let item = outline.item(atRow: row) else { return nil }
            let chevron = rowView.subviews.first {
                $0.identifier == NSOutlineView.disclosureButtonIdentifier
            }
            return BuiltRow(
                outline: outline,
                item: item,
                rowFrame: rowView.frame,
                cellFrame: outline.convert(cell.frame, from: rowView),
                chevronFrame: chevron.map { outline.convert($0.frame, from: rowView) }
            )
        }
    }

    private func firstDisclosingRow(_ controller: ProjectSidebarViewController) throws -> BuiltRow {
        try XCTUnwrap(builtRows(controller).first { $0.chevronFrame != nil })
    }

    /// Delivers a left press at `point` once the outline has claimed it for a chevron.
    private func press(_ outline: ThemedOutlineView, at point: NSPoint) throws {
        _ = try XCTUnwrap(
            outline.disclosureButton(forPressAt: point),
            "the press at \(point) should belong to a chevron"
        )
        let event = try XCTUnwrap(NSEvent.mouseEvent(
            with: .leftMouseDown,
            location: outline.convert(point, to: nil),
            modifierFlags: [],
            timestamp: 0,
            windowNumber: outline.window?.windowNumber ?? 0,
            context: nil,
            eventNumber: 0,
            clickCount: 1,
            pressure: 1
        ))
        outline.mouseDown(with: event)
    }

    /// Where the row's own content — its icon or title — begins.
    private func contentLeading(of row: BuiltRow) -> CGFloat {
        row.cellFrame.minX + SidebarDensity.relaxed.rowLeadingInset
    }

    // MARK: - The indented tree

    /// The strip before a top-level chevron and the gutter after it both fold the row, and
    /// neither selects it — which is what a press there used to do.
    func testAPressBesideTheChevronFoldsTheRowWithoutSelectingIt() throws {
        let controller = makeSidebar(compact: false)
        let row = try firstDisclosingRow(controller)
        let chevron = try XCTUnwrap(row.chevronFrame)
        let outline = row.outline
        XCTAssertGreaterThan(chevron.minX, row.rowFrame.minX, "the strip before it exists")
        XCTAssertTrue(outline.isItemExpanded(row.item))
        let selectionBefore = outline.selectedRow

        try press(outline, at: NSPoint(x: row.rowFrame.minX + 0.5, y: row.rowFrame.midY))
        XCTAssertFalse(
            outline.isItemExpanded(row.item),
            "a press at the column's edge folds the row its chevron belongs to"
        )
        XCTAssertEqual(outline.selectedRow, selectionBefore, "and does not select it")

        draw()
        let folded = try XCTUnwrap(
            builtRows(controller).first { ($0.item as AnyObject) === (row.item as AnyObject) }
        )
        try press(
            outline,
            at: NSPoint(x: contentLeading(of: folded) - 0.5, y: folded.rowFrame.midY)
        )
        XCTAssertTrue(
            outline.isItemExpanded(folded.item),
            "a press in the gutter just before the row's content unfolds it again"
        )
        XCTAssertEqual(outline.selectedRow, selectionBefore)
    }

    /// The target ends where the row's content begins, and a row with nothing to disclose has
    /// no target at all — both keep selecting the row as before.
    func testTheRowsContentKeepsItsOwnClick() throws {
        let controller = makeSidebar(compact: false)
        let rows = builtRows(controller)

        let disclosing = try firstDisclosingRow(controller)
        XCTAssertNil(
            disclosing.outline.disclosureButton(forPressAt: NSPoint(
                x: contentLeading(of: disclosing) + 0.5,
                y: disclosing.rowFrame.midY
            )),
            "the icon or title of a row with a chevron still selects the row"
        )

        let leaf = try XCTUnwrap(rows.first { $0.chevronFrame == nil })
        XCTAssertNil(
            leaf.outline.disclosureButton(forPressAt: NSPoint(
                x: leaf.cellFrame.minX - 0.5,
                y: leaf.rowFrame.midY
            )),
            "a row with nothing to disclose has no disclosure target"
        )
    }

    // MARK: - The compact tree

    /// The compact tree's chevrons sit in a 16pt gutter at the column's edge; the target spans it
    /// and the row's leading gutter, and stops at the same content edge.
    func testTheCompactTreeReachesTheSameContentEdge() throws {
        let controller = makeSidebar(compact: true)
        let row = try firstDisclosingRow(controller)
        let outline = row.outline

        XCTAssertNotNil(outline.disclosureButton(forPressAt: NSPoint(
            x: row.rowFrame.minX + 0.5,
            y: row.rowFrame.midY
        )))
        XCTAssertNotNil(outline.disclosureButton(forPressAt: NSPoint(
            x: contentLeading(of: row) - 0.5,
            y: row.rowFrame.midY
        )))
        XCTAssertNil(outline.disclosureButton(forPressAt: NSPoint(
            x: contentLeading(of: row) + 0.5,
            y: row.rowFrame.midY
        )))

        try press(outline, at: NSPoint(x: row.rowFrame.minX + 0.5, y: row.rowFrame.midY))
        XCTAssertFalse(outline.isItemExpanded(row.item))
    }

    // MARK: - Other lists

    /// Only a host that states outsets widens the target; every other outline keeps AppKit's.
    func testAnOutlineThatStatesNoOutsetsKeepsAppKitsTarget() {
        XCTAssertEqual(ThemedOutlineView().disclosureHitOutsets, .zero)
    }
}
