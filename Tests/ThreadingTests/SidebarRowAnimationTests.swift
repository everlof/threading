import AppKit
import XCTest
@testable import Threading

/// What the sidebar does when a row arrives, leaves or moves — driven through the real outline
/// view, its real data source and its real row reuse.
///
/// These assert on motion, which sounds untestable and is not. A row animation leaves two marks
/// a test can read: the arriving row's `alphaValue` ramps from zero, and every row it displaced
/// keeps a CoreAnimation `position` animation whose *presentation* is still behind the frame the
/// row has already been given. Both were measured on a real `NSOutlineView` first, and a window
/// that is never ordered on screen animates and settles exactly the same — which is what keeps
/// this in the fast plan.
///
/// Two things the fixture has to do, both learnt the hard way. **The rows must have been drawn
/// once**: an outline that has only laid out has no row views, so there is nothing to watch, and
/// once drawn the displacement animates on the layer rather than the frame. And **nothing may be
/// drawn between the change and the assertion** — a change lands in microseconds, the motion
/// lasts a fifth of a second, and a full redraw in between is the only thing here slow enough to
/// matter.
///
/// The other half is what the list must never do: hand every row back to the reuse pool. That is
/// what `reloadData` does, it is invisible in a screenshot, and it is the difference between a
/// list that moves and one that blinks. It shows here as row views that are not the same objects.
@MainActor
final class SidebarRowAnimationTests: XCTestCase {

    // MARK: - Fixtures

    private var directories: [URL] = []
    private var windows: [NSWindow] = []

    override func tearDown() {
        for directory in directories {
            try? FileManager.default.removeItem(at: directory)
        }
        directories = []
        windows = []
        Design.Motion.reduceMotionOverrideForTesting = nil
        super.tearDown()
    }

    private struct Fixture {
        let controller: ProjectSidebarViewController
        let store: ProjectStore
        let projects: [Project]
    }

    /// A sidebar over its own store, in a window that is built, drawn and never shown.
    private func makeSidebar(projects: Int = 1, sessionsEach: Int = 3) -> Fixture {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "threading-sidebar-animation-\(UUID().uuidString)",
            isDirectory: true
        )
        directories.append(directory)

        let built: [Project] = (0..<projects).map { index in
            var project = Project(
                name: "Project \(index)",
                folderURL: directory.appendingPathComponent("project-\(index)")
            )
            project.sessions = (0..<sessionsEach).map { session in
                AgentSession(kind: .claude, title: "Session \(index)-\(session)")
            }
            return project
        }

        let manager = StateManager(appSupportDirectory: directory)
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
        // Taking a controller makes the window adopt *its* size, which for a view with no
        // intrinsic height is a column too short to hold a row. Stated again after, so the
        // fixture is the pane it stands in.
        window.setContentSize(NSSize(width: 320, height: 900))
        controller.view.frame = NSRect(x: 0, y: 0, width: 320, height: 900)
        windows.append(window)

        draw()
        settle()

        return Fixture(controller: controller, store: store, projects: store.projects)
    }

    /// Lays out and draws, without ordering anything on screen — an outline that has never been
    /// drawn has no row views for a test to watch.
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

    /// Lets the animation run to its end.
    private func settle(_ seconds: TimeInterval = Design.Motion.standard + 0.2) {
        RunLoop.current.run(until: Date().addingTimeInterval(seconds))
        draw()
    }

    /// Whether the row is travelling to the place it has been given, rather than being there.
    ///
    /// The animation object, not the drawn position: a layer whose frame was set without any
    /// animation also reads as "behind" until the next commit, so lag alone cannot tell a row
    /// that is moving from one that has just been put down.
    private func isSliding(_ view: NSTableRowView?) -> Bool {
        view?.layer?.animation(forKey: "position") != nil
    }

    /// How far the row is drawn from the place it has been given — the distance still to travel.
    private func lag(_ view: NSTableRowView?) -> CGFloat {
        guard let layer = view?.layer, let presented = layer.presentation() else { return 0 }
        return abs(presented.frame.minY - layer.frame.minY)
    }

    private func rowViews(
        _ controller: ProjectSidebarViewController
    ) -> [SidebarNodeKey: ObjectIdentifier] {
        var views: [SidebarNodeKey: ObjectIdentifier] = [:]
        for key in controller.presentedRowKeys {
            if let view = controller.presentedRowView(of: key) {
                views[key] = ObjectIdentifier(view)
            }
        }
        return views
    }

    @discardableResult
    private func addSession(
        to project: Project,
        titled title: String,
        store: ProjectStore
    ) -> AgentSession? {
        store.addSession(to: project.id, kind: .claude, title: title)
    }

    // MARK: - Arriving

    func testAnArrivingRowFadesInWhileTheRowsBelowSlideDown() throws {
        let fixture = makeSidebar(projects: 2, sessionsEach: 2)
        let below = SidebarNodeKey.project(fixture.projects[1].id)
        let rowsBefore = fixture.controller.outlineRowCount
        XCTAssertNotNil(fixture.controller.presentedRowView(of: below), "nothing was drawn")

        // The store change reaches the sidebar on its own — nothing between it and the
        // assertions below, which are reading an animation that lasts a fifth of a second.
        let arriving = try XCTUnwrap(
            addSession(to: fixture.projects[0], titled: "New", store: fixture.store)
        )

        XCTAssertEqual(fixture.controller.outlineRowCount, rowsBefore + 1)

        // The arriving row is on its way in rather than simply there.
        let arrivingView = fixture.controller.presentedRowView(of: .session(arriving.id))
        XCTAssertNotNil(arrivingView, "the arriving row has no view to animate")
        XCTAssertLessThan(arrivingView?.alphaValue ?? 1, 1)

        // And the row it pushed down is travelling, drawn behind where it has been put.
        let displaced = fixture.controller.presentedRowView(of: below)
        XCTAssertTrue(isSliding(displaced), "the row below did not slide")
        XCTAssertGreaterThan(lag(displaced), 0)

        settle()

        XCTAssertEqual(
            fixture.controller.presentedRowView(of: .session(arriving.id))?.alphaValue,
            1
        )
        XCTAssertEqual(lag(fixture.controller.presentedRowView(of: below)), 0)
    }

    /// The rows that did not change are the same views they were. A `reloadData` hands every one
    /// of them back to the reuse pool — which is, among other things, exactly what a name
    /// morphing from the name it replaces cannot survive.
    func testTheRowsThatStayedAreTheSameRowViews() throws {
        let fixture = makeSidebar(projects: 2, sessionsEach: 3)
        let before = rowViews(fixture.controller)
        XCTAssertFalse(before.isEmpty, "no row views to compare")

        addSession(to: fixture.projects[0], titled: "New", store: fixture.store)
        settle()

        let after = rowViews(fixture.controller)
        for (key, view) in before {
            XCTAssertEqual(after[key], view, "row \(key) was rebuilt rather than kept")
        }
    }

    // MARK: - Leaving

    func testALeavingRowTakesTheListWithIt() throws {
        let fixture = makeSidebar(projects: 2, sessionsEach: 3)
        let leaving = try XCTUnwrap(fixture.projects[0].sessions.last)
        let below = SidebarNodeKey.project(fixture.projects[1].id)
        let rowsBefore = fixture.controller.outlineRowCount

        fixture.store.removeSession(id: leaving.id)

        XCTAssertEqual(fixture.controller.outlineRowCount, rowsBefore - 1)
        let displaced = fixture.controller.presentedRowView(of: below)
        XCTAssertTrue(isSliding(displaced), "the list closed over the row instead of sliding up")
        XCTAssertGreaterThan(lag(displaced), 0)

        settle()

        XCTAssertFalse(fixture.controller.presentedRowKeys.contains(.session(leaving.id)))
        XCTAssertEqual(lag(fixture.controller.presentedRowView(of: below)), 0)
    }

    // MARK: - Rearranging

    /// The sidebar rearranges itself whenever what it sorts by changes — under Recent Activity a
    /// session that has just done something is hoisted to the top of its project. The row has to
    /// travel there, not be redrawn there.
    func testARowThatChangedPlaceTravelsToItAndIsNotRebuilt() throws {
        let defaults = UserDefaults.standard
        let previousOrder = defaults.object(forKey: "sidebarSessionOrder")
        defaults.set(SidebarSessionOrder.recentActivity.rawValue, forKey: "sidebarSessionOrder")
        defer {
            if let previousOrder {
                defaults.set(previousOrder, forKey: "sidebarSessionOrder")
            } else {
                defaults.removeObject(forKey: "sidebarSessionOrder")
            }
        }

        let fixture = makeSidebar(projects: 1, sessionsEach: 3)
        let store = fixture.store
        for (index, session) in try XCTUnwrap(store.projects.first).sessions.enumerated() {
            store.update(sessionID: session.id) {
                $0.lastActiveAt = Date(timeIntervalSince1970: 1_000 - Double(index))
            }
        }
        fixture.controller.reload()
        settle()

        let orderBefore = fixture.controller.presentedRowKeys
        let viewsBefore = rowViews(fixture.controller)
        let hoisted = try XCTUnwrap(store.projects.first?.sessions.last)

        // `update` is the store's quiet edit — it persists and says nothing, so the sidebar is
        // asked directly, which is also what the arrangement menu does.
        store.update(sessionID: hoisted.id) { $0.lastActiveAt = Date(timeIntervalSince1970: 2_000) }
        fixture.controller.reload()

        // It moved, and it moved by travelling: the row is drawn behind its new place while the
        // move plays out.
        let moved = fixture.controller.presentedRowView(of: .session(hoisted.id))
        XCTAssertTrue(isSliding(moved), "the row jumped to its new place")
        XCTAssertGreaterThan(lag(moved), 0)

        settle()

        let orderAfter = fixture.controller.presentedRowKeys
        XCTAssertNotEqual(orderBefore, orderAfter)
        XCTAssertEqual(Set(orderBefore), Set(orderAfter), "rearranging changed which rows exist")
        XCTAssertEqual(orderAfter.dropFirst().first, .session(hoisted.id))

        let viewsAfter = rowViews(fixture.controller)
        for (key, view) in viewsBefore {
            XCTAssertEqual(viewsAfter[key], view, "row \(key) was rebuilt rather than moved")
        }
    }

    // MARK: - Regrouping

    /// Branch grouping moves sessions between the project and a heading under it — the one
    /// change that names a row twice, leaving one parent and arriving in another.
    func testRegroupingLandsEveryRowInItsNewPlace() throws {
        let defaults = UserDefaults.standard
        let key = "groupsSessionsByBranch"
        let previous = defaults.object(forKey: key)
        defer {
            if let previous {
                defaults.set(previous, forKey: key)
            } else {
                defaults.removeObject(forKey: key)
            }
        }
        defaults.set(false, forKey: key)

        let fixture = makeSidebar(projects: 1, sessionsEach: 4)
        let store = fixture.store
        let sessions = try XCTUnwrap(store.projects.first).sessions
        for session in sessions.prefix(2) {
            store.update(sessionID: session.id) { $0.branch = "feature" }
        }
        fixture.controller.reload()
        settle()

        let flat = fixture.controller.presentedRowKeys
        XCTAssertFalse(flat.contains { if case .branch = $0 { true } else { false } })

        defaults.set(true, forKey: key)
        fixture.controller.reload()
        settle()

        let grouped = fixture.controller.presentedRowKeys
        XCTAssertTrue(
            grouped.contains { if case .branch = $0 { true } else { false } },
            "the branch heading never arrived"
        )
        // Every session is still shown, exactly once.
        for session in sessions {
            XCTAssertEqual(grouped.filter { $0 == .session(session.id) }.count, 1)
        }

        // And back again, which is the same move in reverse.
        defaults.set(false, forKey: key)
        fixture.controller.reload()
        settle()

        XCTAssertEqual(fixture.controller.presentedRowKeys, flat)
    }

    // MARK: - Not animating

    func testReduceMotionPutsTheRowStraightIntoPlace() throws {
        Design.Motion.reduceMotionOverrideForTesting = true

        let fixture = makeSidebar(projects: 2, sessionsEach: 2)
        let below = SidebarNodeKey.project(fixture.projects[1].id)
        let arriving = try XCTUnwrap(
            addSession(to: fixture.projects[0], titled: "New", store: fixture.store)
        )

        XCTAssertEqual(
            fixture.controller.presentedRowView(of: .session(arriving.id))?.alphaValue,
            1,
            "the row faded in under Reduce Motion"
        )
        XCTAssertFalse(
            isSliding(fixture.controller.presentedRowView(of: below)),
            "the row below slid under Reduce Motion"
        )

        // Still the incremental path — the rows that stayed are still the same views, which is
        // what keeps a reduced sidebar from blinking whole instead of merely not sliding.
        XCTAssertTrue(fixture.controller.presentedRowKeys.contains(.session(arriving.id)))
    }

    /// A list nobody has seen yet has nothing to animate from.
    func testTheFirstListArrivesWhole() throws {
        let fixture = makeSidebar(projects: 2, sessionsEach: 2)

        XCTAssertFalse(fixture.controller.presentedRowKeys.isEmpty)
        for key in fixture.controller.presentedRowKeys {
            XCTAssertEqual(
                fixture.controller.presentedRowView(of: key)?.alphaValue,
                1,
                "the first list faded itself in"
            )
        }
    }

    // MARK: - What the outline is showing

    /// The whole point of the incremental path: it must reach the same list a rebuild would.
    /// `NSOutlineView` throws rather than drawing a wrong list, so a mismatch here is loud.
    func testTheListMatchesTheStoreAfterEveryKindOfChange() throws {
        let fixture = makeSidebar(projects: 2, sessionsEach: 2)
        let store = fixture.store

        func assertMatchesStore(_ message: String, line: UInt = #line) {
            var expected: [SidebarNodeKey] = []
            for project in store.projects {
                expected.append(.project(project.id))
                expected.append(
                    contentsOf: project.sessions
                        .filter { !$0.isArchived }
                        .map { SidebarNodeKey.session($0.id) }
                )
            }
            XCTAssertEqual(
                Set(fixture.controller.presentedRowKeys),
                Set(expected),
                message,
                line: line
            )
            XCTAssertEqual(fixture.controller.outlineRowCount, expected.count, message, line: line)
        }

        assertMatchesStore("the first list is wrong")

        addSession(to: fixture.projects[0], titled: "Added", store: store)
        settle()
        assertMatchesStore("after adding a session")

        let removed = try XCTUnwrap(store.projects.first?.sessions.first)
        store.removeSession(id: removed.id)
        settle()
        assertMatchesStore("after removing a session")

        store.setArchived(true, for: try XCTUnwrap(store.projects.first?.sessions.first).id)
        settle()
        assertMatchesStore("after archiving a session")

        store.removeProject(id: fixture.projects[1].id)
        settle()
        assertMatchesStore("after removing a project")

        store.addProject(folderURL: directories[0].appendingPathComponent("added-project"))
        settle()
        assertMatchesStore("after adding a project")

        for session in try XCTUnwrap(store.projects.first).sessions {
            store.removeSession(id: session.id)
        }
        settle()
        assertMatchesStore("after emptying a project")
    }

    /// Several changes landing one after another, each on the list the last one left.
    func testChangesArrivingOneAfterAnotherStillLandTheStoresList() throws {
        let fixture = makeSidebar(projects: 2, sessionsEach: 3)
        let store = fixture.store

        addSession(to: fixture.projects[0], titled: "One", store: store)
        addSession(to: fixture.projects[1], titled: "Two", store: store)
        let removed = try XCTUnwrap(store.projects.first?.sessions.first)
        store.removeSession(id: removed.id)
        settle()

        let expected = store.projects.flatMap { project in
            [SidebarNodeKey.project(project.id)]
                + project.sessions.filter { !$0.isArchived }.map { SidebarNodeKey.session($0.id) }
        }
        XCTAssertEqual(Set(fixture.controller.presentedRowKeys), Set(expected))
        XCTAssertEqual(fixture.controller.outlineRowCount, expected.count)
    }
}
