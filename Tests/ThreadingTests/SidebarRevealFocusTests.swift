import AppKit
import XCTest
@testable import Threading

/// Reveal's two contracts: the main window opens and selects the native sidebar, and the sidebar
/// control can genuinely own a key window's keyboard after that selection. The latter uses the
/// same borderless non-activating panel as keyboard popovers. The test host still has to activate:
/// AppKit exposes no key window at all for an inactive application, regardless of panel style.
/// Kept out of the fast plan because activation and an on-screen panel are deliberately visible.
final class SidebarRevealFocusTests: HostedStoreTestCase {

    @MainActor
    func testRevealShowsTheNativeSidebarAndSelectsTheActiveProject() throws {
        let controller = makeMainWindowController(initialFramePlan: .useDefaultFrame)
        defer {
            if let window = controller.window {
                window.orderOut(nil)
                window.delegate = nil
                window.contentView = nil
                controller.window = nil
                RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.35))
            }
        }

        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("threading-sidebar-reveal-\(UUID().uuidString)")
        let project = try XCTUnwrap(ProjectStore.shared.addProject(folderURL: folder))
        defer { ProjectStore.shared.removeProject(id: project.id) }

        controller.sidebarViewController.mountInitialTreeIfNeeded()
        controller.projectSidebar(controller.sidebarViewController, didSelectProject: project.id)
        XCTAssertEqual(controller.currentProjectID, project.id)

        let sidebarItem = try XCTUnwrap(controller.splitViewController.splitViewItems.first)
        controller.splitViewController.setCollapsed(false, on: sidebarItem, animated: false)
        controller.selectWorkspaceNavigator(.extensionNavigator(
            extensionIdentifier: "test.navigator",
            navigatorID: "alternate"
        ))
        controller.splitViewController.setCollapsed(true, on: sidebarItem, animated: false)
        XCTAssertTrue(sidebarItem.isCollapsed)

        XCTAssertTrue(controller.revealActivePageInSidebar(focusingSidebar: true))
        XCTAssertTrue(waitUntil {
            !sidebarItem.isCollapsed
                && controller.sidebarViewController.selectedRowKey == .project(project.id)
                && controller.sidebarViewController.selectionHasKeyboardFocus
        })

        XCTAssertEqual(controller.effectiveWorkspaceNavigatorSelection, .native)
        XCTAssertEqual(AppSettings.shared.workspaceNavigatorSelection, .native)

        // The return value reports the reveal, not whether AppKit accepted the optional focus
        // request. Detach the already-selected native controller so focus must fail while the
        // row itself remains a valid reveal destination.
        controller.sidebarViewController.view.removeFromSuperview()
        XCTAssertNil(controller.sidebarViewController.view.window)
        XCTAssertFalse(controller.sidebarViewController.focusSelection())
        XCTAssertTrue(controller.revealActivePageInSidebar(focusingSidebar: true))
        XCTAssertEqual(controller.sidebarViewController.selectedRowKey, .project(project.id))
    }

    @MainActor
    func testFocusedSidebarOwnsTheKeyPanelsKeyboard() throws {
        try activateHost()

        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("threading-sidebar-key-focus-\(UUID().uuidString)")
        let project = try XCTUnwrap(ProjectStore.shared.addProject(folderURL: folder))
        defer { ProjectStore.shared.removeProject(id: project.id) }

        let sidebar = ProjectSidebarViewController()
        let panel = SidebarRevealKeyPanel(
            contentRect: NSRect(x: 20, y: 20, width: 280, height: 420),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.contentViewController = sidebar
        panel.makeKeyAndOrderFront(nil)
        defer {
            panel.orderOut(nil)
            panel.contentViewController = nil
        }

        sidebar.reveal(projectID: project.id)
        XCTAssertTrue(sidebar.focusSelection())
        XCTAssertTrue(panel.isKeyWindow, "the sidebar's window does not own the keyboard")
        XCTAssertTrue(NSApp.keyWindow === panel, "keyboard events are routed to another window")
        XCTAssertEqual(sidebar.selectedRowKey, .project(project.id))
        XCTAssertTrue(sidebar.selectionHasKeyboardFocus)
    }

    @MainActor
    private func activateHost() throws {
        guard !NSApp.isActive else { return }
        NSApp.activate(ignoringOtherApps: true)
        let deadline = Date().addingTimeInterval(2)
        while !NSApp.isActive, Date() < deadline {
            RunLoop.main.run(until: min(deadline, Date().addingTimeInterval(0.01)))
        }
        try XCTSkipUnless(
            NSApp.isActive,
            "the test host could not come to the front, so no window can hold key status"
        )
    }

    @MainActor
    private func waitUntil(
        timeout: TimeInterval = 2,
        _ condition: () -> Bool
    ) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline {
            RunLoop.main.run(until: min(deadline, Date().addingTimeInterval(0.01)))
        }
        return condition()
    }
}

@MainActor
private final class SidebarRevealKeyPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}
