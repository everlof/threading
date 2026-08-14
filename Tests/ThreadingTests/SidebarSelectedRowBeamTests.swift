import AppKit
import XCTest
@testable import Threading

/// The sidebar keeps the agent-activity beam on exactly one row: the **selected** session's,
/// while that session is loading or working. Driven through the real outline view, data source
/// and row views, in a window that is built and drawn but never shown — the fixture shape
/// `SidebarRowAnimationTests` documents.
///
/// The stamping is the controller's, not the row's, because only the controller knows which row
/// is the selected session and what that session is doing. These tests hold the three edges of
/// that judgement: the ring lands on the selected busy row and nowhere else, it fades when the
/// work ends, and it leaves a row the selection leaves.
@MainActor
final class SidebarSelectedRowBeamTests: XCTestCase {

    // MARK: - Fixtures

    private var directories: [URL] = []
    private var stateManagers: [StateManager] = []
    private var windows: [NSWindow] = []

    override func setUp() {
        super.setUp()
        AppThemePalette.set(.system)
    }

    override func tearDown() {
        MainActor.assumeIsolated {
            AppThemePalette.set(.system)
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
        }
        super.tearDown()
    }

    private struct Fixture {
        let controller: ProjectSidebarViewController
        let sessions: [AgentSession]
    }

    /// A sidebar over its own store — one project, three sessions — drawn once so the outline
    /// has real row views to stamp.
    private func makeSidebar() -> Fixture {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "threading-sidebar-beam-\(UUID().uuidString)",
            isDirectory: true
        )
        directories.append(directory)

        var project = Project(
            name: "Threading",
            folderURL: directory.appendingPathComponent("threading")
        )
        project.sessions = (0..<3).map {
            AgentSession(kind: .claude, title: "Session \($0)")
        }

        let manager = StateManager(appSupportDirectory: directory)
        stateManagers.append(manager)
        XCTAssertTrue(manager.saveProjectsState(ProjectsState(projects: [project])))
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
        return Fixture(
            controller: controller,
            sessions: store.projects.first?.sessions ?? []
        )
    }

    /// Lays out and draws without ordering anything on screen — an outline that has never
    /// been drawn has no row views for the controller to stamp.
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

    private func beamRow(
        _ controller: ProjectSidebarViewController,
        _ sessionID: SessionID
    ) -> SidebarHoverRowView? {
        controller.presentedRowView(of: .session(sessionID)) as? SidebarHoverRowView
    }

    // MARK: - Tests

    /// The reported flow, end to end: clicking a session raises its loading presentation, and
    /// the ring lights on that row — while every other row, loading or not, stays bare. This
    /// is what lets the pointer swap the row's status mark for the archive button without the
    /// row's activity disappearing under it.
    func testTheRingLandsOnTheSelectedLoadingRowAndOnlyThere() throws {
        let fixture = makeSidebar()
        let selected = fixture.sessions[0]
        let bystander = fixture.sessions[1]

        fixture.controller.select(sessionID: selected.id, notifyDelegate: false)
        fixture.controller.setSessionLoading(true, reason: .gitStatus, for: selected.id)
        fixture.controller.setSessionLoading(true, reason: .gitStatus, for: bystander.id)

        let selectedRow = try XCTUnwrap(beamRow(fixture.controller, selected.id))
        let beam = try XCTUnwrap(
            selectedRow.activityBeamForTesting,
            "the selected loading row should wear the ring"
        )
        XCTAssertEqual(beam.appliedActiveForTesting, true)

        let bystanderRow = try XCTUnwrap(beamRow(fixture.controller, bystander.id))
        XCTAssertNil(
            bystanderRow.activityBeamForTesting,
            "a loading row that is not selected mounts no ring at all"
        )
    }

    /// The work ending is the ring's exit: lowering the spinner deactivates the beam without
    /// tearing the host down, so the fade-out the component owns can play.
    func testLoweringTheSpinnerFadesTheRingOut() throws {
        let fixture = makeSidebar()
        let selected = fixture.sessions[0]

        fixture.controller.select(sessionID: selected.id, notifyDelegate: false)
        fixture.controller.setSessionLoading(true, reason: .gitStatus, for: selected.id)
        fixture.controller.setSessionLoading(false, reason: .gitStatus, for: selected.id)

        let row = try XCTUnwrap(beamRow(fixture.controller, selected.id))
        XCTAssertEqual(row.activityBeamForTesting?.appliedActiveForTesting, false)
    }

    /// The ring follows the selection, not the work: moving to another session takes the beam
    /// off the row that keeps loading, because the ring says "the chat you are looking at is
    /// busy" — its status mark still says the rest.
    func testTheRingLeavesARowTheSelectionLeaves() throws {
        let fixture = makeSidebar()
        let first = fixture.sessions[0]
        let second = fixture.sessions[1]

        fixture.controller.select(sessionID: first.id, notifyDelegate: false)
        fixture.controller.setSessionLoading(true, reason: .gitStatus, for: first.id)
        fixture.controller.select(sessionID: second.id, notifyDelegate: false)

        let firstRow = try XCTUnwrap(beamRow(fixture.controller, first.id))
        XCTAssertEqual(
            firstRow.activityBeamForTesting?.appliedActiveForTesting,
            false,
            "the ring should leave with the selection even while the row keeps loading"
        )
        let secondRow = try XCTUnwrap(beamRow(fixture.controller, second.id))
        XCTAssertNil(
            secondRow.activityBeamForTesting,
            "the newly selected idle session earns no ring"
        )
    }
}
