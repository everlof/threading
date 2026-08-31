import AppKit
import XCTest
@testable import Threading

/// Captures both sides of the collapsed-edge interaction in the shipping window. The trigger is
/// deliberately invisible, so the collapsed image proves its six-point overlay adds no chrome;
/// the revealed image proves hovering restores the real navigable sidebar rather than a replica.
@MainActor
final class SidebarEdgeRevealRenderTests: HostedStoreTestCase {
    private enum Render {
        static var directory: URL {
            if let override = ProcessInfo.processInfo.environment["THREADING_RENDER_OUT"],
               !override.isEmpty {
                return URL(fileURLWithPath: override, isDirectory: true)
            }
            return FileManager.default.temporaryDirectory
                .appendingPathComponent("ThreadingRenders", isDirectory: true)
        }

        static let windowSize = NSSize(width: 960, height: 620)
    }

    func testRendersCollapsedAndHoverRevealedSidebarInShippingWindow() throws {
        try FileManager.default.createDirectory(
            at: Render.directory,
            withIntermediateDirectories: true
        )
        let previousTheme = AppThemePalette.current
        defer { AppThemePalette.set(previousTheme) }

        let controller = makeMainWindowController(initialFramePlan: .useDefaultFrame)
        let window = try XCTUnwrap(controller.window)
        window.setContentSize(Render.windowSize)
        let content = try XCTUnwrap(window.contentView)
        let sidebarItem = try XCTUnwrap(controller.splitViewController.splitViewItems.first)
        let sidebar = controller.sidebarViewController.view
        let originalSuperview = try XCTUnwrap(sidebar.superview)
        controller.sidebarEdgeRevealPolicyForTesting = .init(openDelay: 0, closeGrace: 60)

        let greeting = try XCTUnwrap(
            descendants(of: content).compactMap { $0 as? MorphingMultilineTitleLabel }.first
        )
        greeting.setStringValue("What are we building today?", animated: false)

        for (name, appearance) in [
            ("light", NSAppearance.Name.aqua),
            ("dark", NSAppearance.Name.darkAqua),
        ] {
            AppThemePalette.set(.system)
            content.appearance = try XCTUnwrap(NSAppearance(named: appearance))
            AppThemeRefresh.repaint(content)

            controller.splitViewController.setCollapsed(false, on: sidebarItem, animated: false)
            controller.splitViewController.setCollapsed(true, on: sidebarItem, animated: false)
            render(content)
            XCTAssertFalse(controller.sidebarEdgeTrackingViewForTesting.isHidden)
            try write(content, named: "sidebar-edge-reveal-\(name)-collapsed.png")

            controller.simulateSidebarEdgeHoverForTesting(true)
            RunLoop.current.run(until: Date(timeIntervalSinceNow: Design.Motion.standard + 0.1))
            render(content)
            XCTAssertFalse(sidebarItem.isCollapsed)
            XCTAssertTrue(controller.sidebarIsTemporarilyRevealedForTesting)
            XCTAssertTrue(sidebar.superview === originalSuperview, "hover rebuilt the sidebar")
            XCTAssertTrue(controller.sidebarEdgeTrackingViewForTesting.isHidden)
            try write(content, named: "sidebar-edge-reveal-\(name)-hovered.png")

            controller.splitViewController.setCollapsed(true, on: sidebarItem, animated: false)
        }
    }

    private func render(_ view: NSView) {
        view.layoutSubtreeIfNeeded()
        view.displayIfNeeded()
    }

    private func write(_ view: NSView, named filename: String) throws {
        let rep = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: rep)
        let png = try XCTUnwrap(rep.representation(using: .png, properties: [:]))
        try png.write(to: Render.directory.appendingPathComponent(filename))
    }

    private func descendants(of view: NSView) -> [NSView] {
        view.subviews.flatMap { [$0] + descendants(of: $0) }
    }
}
