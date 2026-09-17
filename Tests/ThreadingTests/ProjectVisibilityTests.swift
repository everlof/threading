import AppKit
import XCTest
@testable import Threading

@MainActor
final class ProjectVisibilityTests: HostedStoreTestCase {
    func testLegacyProjectDefaultsVisibleAndHiddenRoundTrips() throws {
        let project = Project(name: "Old project", folderURL: URL(fileURLWithPath: "/tmp/old-project"))
        let encoder = JSONEncoder()
        XCTAssertFalse(try JSONDecoder().decode(Project.self, from: encoder.encode(project)).isHidden)
        var hidden = project
        hidden.isHidden = true
        XCTAssertTrue(try JSONDecoder().decode(Project.self, from: encoder.encode(hidden)).isHidden)
    }

    func testHidePersistsWithoutRemovingChatsAndWritingHonorsSetting() throws {
        let previous = AppSettings.shared.unhidesProjectsOnWriting
        defer { AppSettings.shared.unhidesProjectsOnWriting = previous }
        let project = try XCTUnwrap(ProjectStore.shared.addProject(folderURL: URL(fileURLWithPath: NSTemporaryDirectory())))
        let chat = try XCTUnwrap(ProjectStore.shared.addSession(to: project.id, kind: .claude))
        XCTAssertTrue(ProjectStore.shared.setProjectHidden(true, projectID: project.id).succeeded)
        XCTAssertTrue(try XCTUnwrap(ProjectStore.shared.project(withID: project.id)).isHidden)
        XCTAssertNotNil(ProjectStore.shared.session(withID: chat.id))
        guard case .loaded(let saved) = StateManager.shared.loadProjectsState() else {
            return XCTFail("The durable project graph could not be read")
        }
        XCTAssertTrue(try XCTUnwrap(saved.projects.first { $0.id == project.id }).isHidden)
        XCTAssertEqual(saved.projects.first { $0.id == project.id }?.sessions.map(\.id), [chat.id])
        AppSettings.shared.unhidesProjectsOnWriting = false
        ProjectStore.shared.noteUserWriting(in: chat.id)
        XCTAssertTrue(try XCTUnwrap(ProjectStore.shared.project(withID: project.id)).isHidden)
        AppSettings.shared.unhidesProjectsOnWriting = true
        ProjectStore.shared.noteUserWriting(in: chat.id)
        XCTAssertFalse(try XCTUnwrap(ProjectStore.shared.project(withID: project.id)).isHidden)
        ProjectStore.shared.noteUserWriting(in: chat.id)
        XCTAssertEqual(ProjectStore.shared.setProjectHidden(false, projectID: project.id), .unchanged)
    }

    func testHiddenProjectsAreFilteredBeforeTheirSessionsAreProjected() {
        var hidden = Project(name: "Hidden", folderURL: URL(fileURLWithPath: "/tmp/hidden"))
        hidden.isHidden = true
        let visible = Project(name: "Visible", folderURL: URL(fileURLWithPath: "/tmp/visible"))
        XCTAssertEqual(ProjectVisibility.visible([hidden, visible], showHidden: false).map(\.id), [visible.id])
        XCTAssertEqual(ProjectVisibility.visible([hidden, visible], showHidden: true).map(\.id), [hidden.id, visible.id])
    }

    func testVisibilityProjectionAtTwentyFiveThousandProjects() {
        let projects = (0..<25_000).map { index in
            var project = Project(name: "Project \(index)", folderURL: URL(fileURLWithPath: "/tmp/project-\(index)"))
            project.isHidden = index.isMultiple(of: 2)
            return project
        }
        let start = DispatchTime.now().uptimeNanoseconds
        for _ in 0..<5 {
            XCTAssertEqual(ProjectVisibility.visible(projects, showHidden: false).count, 12_500)
            XCTAssertEqual(ProjectVisibility.visible(projects, showHidden: true).count, 25_000)
        }
        let elapsed = Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
        print("Project visibility: five 25,000-project hide/show pairs in \(elapsed) ms")
    }

    func testRendersHiddenProjectsAndFooterInShippingShell() throws {
        let settings = AppSettings.shared
        let priorShown = settings.showsHiddenProjects
        let priorTheme = AppThemePalette.current
        let priorMotion = Design.Motion.reduceMotionOverrideForTesting
        Design.Motion.reduceMotionOverrideForTesting = true
        defer {
            settings.showsHiddenProjects = priorShown
            AppThemePalette.set(priorTheme)
            Design.Motion.reduceMotionOverrideForTesting = priorMotion
        }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("hidden-projects-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let active = try XCTUnwrap(ProjectStore.shared.addProject(folderURL: directory.appendingPathComponent("Daily work")))
        let hidden = try XCTUnwrap(ProjectStore.shared.addProject(folderURL: directory.appendingPathComponent("Occasional work")))
        XCTAssertTrue(ProjectStore.shared.setProjectHidden(true, projectID: hidden.id).succeeded)
        settings.showsHiddenProjects = false
        let controller = makeMainWindowController(initialFramePlan: .useDefaultFrame)
        let window = try XCTUnwrap(controller.window)
        window.setContentSize(NSSize(width: 1120, height: 720))
        let sidebarItem = try XCTUnwrap(controller.splitViewController.splitViewItems.first)
        controller.splitViewController.setCollapsed(false, on: sidebarItem, animated: false)
        controller.splitViewController.splitView.setPosition(260, ofDividerAt: 0)
        controller.sidebarViewController.mountInitialTreeIfNeeded()
        controller.projectSidebar(controller.sidebarViewController, didSelectProject: active.id)
        let content = try XCTUnwrap(window.contentView)
        let outline = try XCTUnwrap(descendants(controller.sidebarViewController.view).compactMap { $0 as? NSOutlineView }.first)
        let output = ProcessInfo.processInfo.environment["THREADING_RENDER_OUT"] ?? NSTemporaryDirectory()
        try FileManager.default.createDirectory(atPath: output, withIntermediateDirectories: true)
        for (name, theme, appearance) in [
            ("system-light", AppTheme.system, NSAppearance.Name.aqua),
            ("system-dark", AppTheme.system, NSAppearance.Name.darkAqua),
            ("swiss", AppThemeStyles.swissMinimalist, NSAppearance.Name.aqua),
            ("cyberpunk", AppThemeStyles.cyberpunk, NSAppearance.Name.darkAqua)
        ] {
            AppThemePalette.set(theme)
            for showHidden in [false, true] {
                settings.showsHiddenProjects = showHidden
                content.appearance = NSAppearance(named: appearance)
                AppThemeRefresh.repaint(content)
                content.layoutSubtreeIfNeeded()
                let projectIDs = (0..<outline.numberOfRows).compactMap { (outline.item(atRow: $0) as? ProjectNode)?.projectID }
                XCTAssertEqual(projectIDs.contains(hidden.id), showHidden)
                XCTAssertTrue(projectIDs.contains(active.id))
                let hideButton = try XCTUnwrap(descendants(content).first {
                    $0.accessibilityIdentifier() == "sidebar.show-hidden-projects"
                } as? ThemedIconButton)
                XCTAssertEqual(hideButton.isSelected, showHidden)
                let bitmap = try XCTUnwrap(content.bitmapImageRepForCachingDisplay(in: content.bounds))
                content.cacheDisplay(in: content.bounds, to: bitmap)
                try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(
                    to: URL(fileURLWithPath: output).appendingPathComponent("hidden-projects-\(name)-\(showHidden ? "shown" : "hidden").png"))
            }
        }
    }

    private func descendants(_ view: NSView) -> [NSView] {
        view.subviews.flatMap { [$0] + descendants($0) }
    }
}
