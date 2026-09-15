import AppKit
import XCTest
@testable import Threading

@MainActor
final class SidebarWorktreePathTests: HostedStoreTestCase {
    func testRendersWorktreePathsInShippingSidebar() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("sidebar-worktree-\(UUID().uuidString)")
        let checkout = directory.appendingPathComponent("sonda")
        try FileManager.default.createDirectory(
            at: checkout.appendingPathComponent(".git"), withIntermediateDirectories: true
        )
        try Data("ref: refs/heads/fix/component-audit\n".utf8)
            .write(to: checkout.appendingPathComponent(".git/HEAD"))
        defer { try? FileManager.default.removeItem(at: directory) }
        let project = try XCTUnwrap(ProjectStore.shared.addProject(folderURL: checkout))
        let controller = makeMainWindowController(initialFramePlan: .useDefaultFrame)
        let window = try XCTUnwrap(controller.window)
        window.setContentSize(NSSize(width: 1120, height: 720))
        let sidebarItem = try XCTUnwrap(controller.splitViewController.splitViewItems.first)
        controller.splitViewController.setCollapsed(false, on: sidebarItem, animated: false)
        controller.splitViewController.splitView.setPosition(360, ofDividerAt: 0)
        controller.sidebarViewController.mountInitialTreeIfNeeded()
        controller.projectSidebar(controller.sidebarViewController, didSelectProject: project.id)
        let content = try XCTUnwrap(window.contentView)
        let priorTheme = AppThemePalette.current
        defer { AppThemePalette.set(priorTheme) }
        AppThemePalette.set(.system)
        let output = ProcessInfo.processInfo.environment["THREADING_RENDER_OUT"]
            ?? NSTemporaryDirectory() + "/ThreadingRenders"
        try FileManager.default.createDirectory(atPath: output, withIntermediateDirectories: true)
        for (name, width, appearance) in [
            ("light", CGFloat(360), NSAppearance.Name.aqua),
            ("dark", CGFloat(360), NSAppearance.Name.darkAqua),
            ("narrow-light", CGFloat(240), NSAppearance.Name.aqua),
            ("narrow-dark", CGFloat(240), NSAppearance.Name.darkAqua),
        ] {
            controller.splitViewController.splitView.setPosition(width, ofDividerAt: 0)
            content.appearance = NSAppearance(named: appearance)
            AppThemeRefresh.repaint(content)
            content.layoutSubtreeIfNeeded()
            let pathLabel = try XCTUnwrap(descendants(content).compactMap { $0 as? MorphingTitleLabel }
                .first { $0.accessibilityIdentifier() == "sidebar.project.worktree-path" && !$0.isHidden })
            XCTAssertEqual(pathLabel.stringValue, "[\(PathAbbreviation.abbreviatingHome(in: project.folderPath))]")
            XCTAssertEqual(pathLabel.toolTip, project.folderPath)
            XCTAssertGreaterThan(pathLabel.frame.width, 0)
            let bitmap = try XCTUnwrap(content.bitmapImageRepForCachingDisplay(in: content.bounds))
            content.cacheDisplay(in: content.bounds, to: bitmap)
            try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
                .write(to: URL(fileURLWithPath: output).appendingPathComponent("sidebar-worktree-\(name).png"))
        }
    }

    func testAbbreviationAndReuse() throws {
        let row = ProjectRowView()
        let path = NSHomeDirectory() + "/repo/sonda"
        row.configure(with: Project(name: "sonda", folderURL: URL(fileURLWithPath: path)), style: .checkout)
        let label = try XCTUnwrap(descendants(row).compactMap { $0 as? MorphingTitleLabel }
            .first { $0.accessibilityIdentifier() == "sidebar.project.worktree-path" })
        XCTAssertEqual(label.stringValue, "[~/repo/sonda]")
        row.configureAsRepository(named: "sonda")
        XCTAssertTrue(label.isHidden)
        row.configureAsBranch(named: "old-branch")
        XCTAssertTrue(label.isHidden)
        XCTAssertEqual(PathAbbreviation.abbreviatingHome(in: "/home/davidson/repo", home: "/home/david"), "/home/davidson/repo")
    }

    private func descendants(_ view: NSView) -> [NSView] {
        view.subviews.flatMap { [$0] + descendants($0) }
    }
}
