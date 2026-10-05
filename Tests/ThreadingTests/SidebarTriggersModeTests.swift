import AppKit
import XCTest
@testable import Threading

/// Opening Automations leaves no row selected.
///
/// The page is not any row's, and a session left highlighted beside it was more than a wrong
/// picture: `NSOutlineView` posts no selection change for a click on the row already selected,
/// so clicking that session to go back did nothing at all.
@MainActor
final class SidebarTriggersModeTests: XCTestCase {

    private var directory: URL?
    private var stateManager: StateManager?
    private var window: NSWindow?

    override func tearDown() async throws {
        window?.contentViewController = nil
        window = nil
        stateManager?.closeDatabase()
        stateManager = nil
        if let directory { try? FileManager.default.removeItem(at: directory) }
        directory = nil
        try await super.tearDown()
    }

    func testOpeningAutomationsClearsTheSelectedSession() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "threading-sidebar-triggers-\(UUID().uuidString)",
            isDirectory: true
        )
        self.directory = directory

        let session = AgentSession(kind: .claude, title: "Automations")
        var project = Project(name: "Sonda", folderURL: directory.appendingPathComponent("sonda"))
        project.sessions = [session]

        let manager = StateManager(appSupportDirectory: directory)
        stateManager = manager
        XCTAssertTrue(manager.saveProjectsState(ProjectsState(projects: [project])))
        let store = ProjectStore(stateManager: manager)
        let controller = ProjectSidebarViewController(projectStore: store)

        // Built and laid out, never shown: the outline needs rows, not a screen.
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 600),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentViewController = controller
        self.window = window
        controller.view.layoutSubtreeIfNeeded()

        controller.select(sessionID: session.id, notifyDelegate: false)
        store.selectedSessionID = session.id
        XCTAssertNotNil(controller.selectedRowKey)

        controller.setTriggersMode(true)

        XCTAssertNil(controller.selectedRowKey)
        XCTAssertNil(store.selectedSessionID)
    }
}
