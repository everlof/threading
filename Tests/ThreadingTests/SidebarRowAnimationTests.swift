import AppKit
import LabelMorph
import ThreadingExtensionKit
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
            Design.Motion.reduceMotionOverrideForTesting = nil
        }
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

    // MARK: - Renaming

    /// The title's morph, driven the way the app drives it: a store rename, reaching the row
    /// through the sidebar's own change handling rather than through a `configure` call the
    /// test makes itself. The row-level tests in `SidebarTitleMorphTests` all pass while a
    /// rename lands instantly, because `stringValue` is set the moment a morph *starts*.
    func testRenamingASessionMorphsTheRowThatWasShowingTheOldName() throws {
        let fixture = makeSidebar(projects: 1, sessionsEach: 3)
        let renamed = try XCTUnwrap(fixture.projects[0].sessions.first)
        let key = SidebarNodeKey.session(renamed.id)
        XCTAssertNotNil(fixture.controller.presentedRowView(of: key), "nothing was drawn")

        // Nothing between the change and the assertion: see this class's note about redraws.
        XCTAssertTrue(
            fixture.store.renameSession(id: renamed.id, to: "A thoroughly different name")
                .succeeded
        )
        // A layout pass, not a redraw: the morph is built when the label lays out.
        fixture.controller.view.layoutSubtreeIfNeeded()

        let title = try XCTUnwrap(
            titleLabel(of: key, in: fixture.controller),
            "the renamed row has no title label"
        )
        XCTAssertEqual(title.stringValue, "A thoroughly different name")
        XCTAssertFalse(
            animatingGlyphs(in: title).isEmpty,
            "the rename landed without animating a single glyph"
        )
    }

    /// Whether the glyphs are being *drawn* somewhere other than their final places — the
    /// question every other assertion here skips.
    ///
    /// A morph adds its animations synchronously, so "an animation exists" is true even when
    /// the whole transition elapses before a single frame is composited. What the user sees is
    /// the presentation layer, so that is what this reads: a glyph drawn away from the model
    /// position it has already been given is a glyph the eye is watching move.
    private func drawnMidFlightGlyphCount(in title: MorphingTitleLabel) -> Int {
        guard let morphing = title.subviews.compactMap({ $0 as? MorphingLabel }).first else {
            return 0
        }
        return (morphing.layer?.sublayers ?? []).reduce(into: 0) { count, layer in
            guard let presented = layer.presentation() else { return }
            if presented.frame != layer.frame || presented.opacity != layer.opacity {
                count += 1
            }
        }
    }

    /// The baseline the modal case is measured against: a rename with nothing in the way is
    /// still being drawn mid-transition a couple of frames later.
    func testARenamedRowIsStillBeingDrawnMidMorphAFewFramesLater() throws {
        let fixture = makeSidebar(projects: 1, sessionsEach: 3)
        let renamed = try XCTUnwrap(fixture.projects[0].sessions.first)
        let key = SidebarNodeKey.session(renamed.id)
        XCTAssertNotNil(fixture.controller.presentedRowView(of: key), "nothing was drawn")

        XCTAssertTrue(
            fixture.store.renameSession(id: renamed.id, to: "A thoroughly different name")
                .succeeded
        )
        RunLoop.current.run(until: Date().addingTimeInterval(0.1))

        let title = try XCTUnwrap(titleLabel(of: key, in: fixture.controller))
        XCTAssertGreaterThan(
            drawnMidFlightGlyphCount(in: title),
            0,
            "the morph was never drawn anywhere other than its final state"
        )
    }

    /// The same rename performed where the Rename Session… dialog performs it: on the far side
    /// of `runModal`, while AppKit is still unwinding the modal session the alert ran in.
    func testARenameAnsweredAsAModalUnwindsIsStillDrawnMidMorph() throws {
        let fixture = makeSidebar(projects: 1, sessionsEach: 3)
        let renamed = try XCTUnwrap(fixture.projects[0].sessions.first)
        let key = SidebarNodeKey.session(renamed.id)
        XCTAssertNotNil(fixture.controller.presentedRowView(of: key), "nothing was drawn")

        let modal = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 260, height: 120),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        modal.isReleasedWhenClosed = false
        windows.append(modal)
        DispatchQueue.main.async { NSApp.stopModal() }
        NSApp.runModal(for: modal)
        modal.orderOut(nil)

        // Exactly what `renameSessionClicked` does with the answer, in the same breath.
        XCTAssertTrue(
            fixture.store.renameSession(id: renamed.id, to: "A thoroughly different name")
                .succeeded
        )
        fixture.controller.reload()
        RunLoop.current.run(until: Date().addingTimeInterval(0.1))

        let title = try XCTUnwrap(titleLabel(of: key, in: fixture.controller))
        XCTAssertGreaterThan(
            drawnMidFlightGlyphCount(in: title),
            0,
            "a rename answered on the modal's way out was never drawn moving"
        )
    }

    /// The Rename Session… dialog's own sequence: the store rename, then the reload its
    /// completion asks for. The reload finds the tree's shape unchanged and reconfigures the
    /// viewport in place, which reaches the row whose title is mid-morph.
    func testTheRenameDialogsReloadDoesNotCancelTheMorphItJustStarted() throws {
        let fixture = makeSidebar(projects: 1, sessionsEach: 3)
        let renamed = try XCTUnwrap(fixture.projects[0].sessions.first)
        let key = SidebarNodeKey.session(renamed.id)
        XCTAssertNotNil(fixture.controller.presentedRowView(of: key), "nothing was drawn")

        XCTAssertTrue(
            fixture.store.renameSession(id: renamed.id, to: "A thoroughly different name")
                .succeeded
        )
        fixture.controller.reload()
        fixture.controller.view.layoutSubtreeIfNeeded()

        let title = try XCTUnwrap(
            titleLabel(of: key, in: fixture.controller),
            "the renamed row has no title label"
        )
        XCTAssertFalse(
            animatingGlyphs(in: title).isEmpty,
            "the reload after the rename dialog cancelled the morph"
        )
    }

    /// The same rename with an extension patching the row, which is the shape the app is
    /// actually used in: the example extension fills every session and project row's
    /// `after-title` slot by default, so a row's customization host is live and re-renders
    /// its slot on the same refresh that carries the new name.
    func testRenamingMorphsWhileAnExtensionFillsTheRowSlot() throws {
        let provider = SlotFillingCustomizationProvider()
        ComponentCustomizationProviderSlot.shared.provider = provider
        defer { ComponentCustomizationProviderSlot.shared.provider = nil }

        let fixture = makeSidebar(projects: 1, sessionsEach: 3)
        let renamed = try XCTUnwrap(fixture.projects[0].sessions.first)
        let key = SidebarNodeKey.session(renamed.id)
        XCTAssertNotNil(fixture.controller.presentedRowView(of: key), "nothing was drawn")

        XCTAssertTrue(
            fixture.store.renameSession(id: renamed.id, to: "A thoroughly different name")
                .succeeded
        )
        // A layout pass, not a redraw: the morph is built when the label lays out.
        fixture.controller.view.layoutSubtreeIfNeeded()

        let title = try XCTUnwrap(
            titleLabel(of: key, in: fixture.controller),
            "the renamed row has no title label"
        )
        XCTAssertEqual(title.stringValue, "A thoroughly different name")
        XCTAssertFalse(
            animatingGlyphs(in: title).isEmpty,
            "the rename landed without animating while an extension patched the row"
        )
    }

    /// Stands in for the example extension as installed: a status in every session and
    /// project row's `after-title` slot, and a replacement for the session's identity mark —
    /// the two patches `HelloStatusExtension` publishes for a sidebar row.
    private final class SlotFillingCustomizationProvider: ComponentCustomizationProvider {
        func customization(
            for target: ExtensionComponentTarget
        ) -> ComponentCustomizationResolution {
            if target.component == ExtensionComponentTarget.sessionIdentity().component,
               target.entityID != nil {
                return ComponentCustomizationResolution(
                    properties: [:],
                    slots: [:],
                    replacement: .stack(
                        axis: .horizontal,
                        spacing: .tight,
                        children: [ExtensionNode.status("◆", role: .neutral)]
                    ),
                    replacementExtensionIdentifier: "test.hello-status",
                    replacementCandidates: ["test.hello-status"],
                    hooks: []
                )
            }

            let rowComponents = [
                HostComponentContracts.sidebarSessionRow.id,
                HostComponentContracts.sidebarProjectRow.id
            ]
            guard rowComponents.contains(target.component), target.entityID != nil else {
                return .empty
            }
            return ComponentCustomizationResolution(
                properties: [:],
                slots: ["after-title": [ExtensionNode.status("Hello · 7", role: .neutral)]],
                replacement: nil,
                replacementExtensionIdentifier: nil,
                replacementCandidates: [],
                hooks: []
            )
        }
    }

    /// The row's title label, found through the presented row view rather than built here.
    private func titleLabel(
        of key: SidebarNodeKey,
        in controller: ProjectSidebarViewController
    ) -> MorphingTitleLabel? {
        func walk(_ node: NSView) -> MorphingTitleLabel? {
            if let found = node as? MorphingTitleLabel { return found }
            for child in node.subviews {
                if let found = walk(child) { return found }
            }
            return nil
        }
        return controller.presentedRowView(of: key).flatMap(walk)
    }

    private func animatingGlyphs(in title: MorphingTitleLabel) -> [CALayer] {
        guard let morphing = title.subviews.compactMap({ $0 as? MorphingLabel }).first else {
            return []
        }
        return (morphing.layer?.sublayers ?? [])
            .filter { !($0.animationKeys() ?? []).isEmpty }
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

    func testPendingArchiveLeavesBeforeTheDurableProviderTransactionFinishes() throws {
        let fixture = makeSidebar(projects: 1, sessionsEach: 3)
        let archiving = try XCTUnwrap(fixture.projects[0].sessions[1])

        fixture.controller.setArchivePresentationPending(true, for: archiving.id)

        XCTAssertFalse(
            fixture.controller.presentedRowKeys.contains(.session(archiving.id)),
            "the row stayed visible while process/provider archive work was pending"
        )
        XCTAssertFalse(
            try XCTUnwrap(fixture.store.session(withID: archiving.id)).isArchived,
            "presentation optimism must not bypass the provider transaction"
        )

        fixture.controller.setArchivePresentationPending(false, for: archiving.id)

        XCTAssertTrue(
            fixture.controller.presentedRowKeys.contains(.session(archiving.id)),
            "a refused archive did not restore the unchanged durable row"
        )
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

    /// A checkout moving between branches takes every chat standing in it at once, so the
    /// heading over them is relabelled rather than replaced.
    ///
    /// Keyed by name it read as one group leaving and another arriving: the heading and every row
    /// under it faded out, a closed heading arrived, and it re-expanded — the branch visibly
    /// disappearing from the sidebar for a moment on every `git checkout`. Nothing may move here.
    func testSwitchingTheCheckoutsBranchRenamesTheHeadingWithoutMovingARow() throws {
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
        defaults.set(true, forKey: key)

        let fixture = makeSidebar(projects: 1, sessionsEach: 3)
        let store = fixture.store
        let project = try XCTUnwrap(store.projects.first)
        for session in project.sessions {
            store.update(sessionID: session.id) { $0.branch = "master" }
        }
        fixture.controller.reload()
        settle()

        let was = SidebarNodeKey.branch(project.id, "master")
        let now = SidebarNodeKey.branch(project.id, "feature")
        let keysBefore = fixture.controller.presentedRowKeys
        XCTAssertTrue(keysBefore.contains(was), "the branch heading never arrived")
        let viewsBefore = rowViews(fixture.controller)
        let headingBefore = try XCTUnwrap(fixture.controller.presentedRowView(of: was))
        XCTAssertEqual(title(in: headingBefore), "master")

        for session in project.sessions {
            store.update(sessionID: session.id) { $0.branch = "feature" }
        }
        fixture.controller.reload()

        // Read before anything settles: an arriving row would still be part-way through its fade
        // and the rows below it part-way through their slide.
        let keysAfter = fixture.controller.presentedRowKeys
        XCTAssertEqual(keysAfter.firstIndex(of: now), keysBefore.firstIndex(of: was))
        XCTAssertFalse(keysAfter.contains(was))
        XCTAssertEqual(keysAfter.count, keysBefore.count)
        XCTAssertEqual(fixture.controller.presentedRowView(of: now)?.alphaValue, 1)
        XCTAssertFalse(isSliding(fixture.controller.presentedRowView(of: .project(project.id))))

        settle()

        // The row the outline is showing is the row it was already showing, saying the new name.
        let headingAfter = fixture.controller.presentedRowView(of: now)
        XCTAssertIdentical(headingAfter, headingBefore, "the heading was replaced, not renamed")
        XCTAssertEqual(title(in: try XCTUnwrap(headingAfter)), "feature")

        let viewsAfter = rowViews(fixture.controller)
        for session in project.sessions {
            XCTAssertEqual(
                viewsAfter[.session(session.id)],
                viewsBefore[.session(session.id)],
                "a chat row was rebuilt by a branch switch"
            )
        }
    }

    /// What a row's name label actually says, found through the identifier the row publishes
    /// rather than through its private outlets.
    private func title(in view: NSView) -> String? {
        if view.accessibilityIdentifier() == "sidebar.project.title" {
            return (view as? MorphingTitleLabel)?.stringValue
        }
        for subview in view.subviews {
            if let found = title(in: subview) { return found }
        }
        return nil
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
