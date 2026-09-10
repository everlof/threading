import AppKit
import ThreadingPluginKit
import XCTest

@testable import Threading

/// Renders the bundled DesignKit navigator through the shipping main-window host.
///
/// This intentionally does not import or reconstruct the plugin's views. Static discovery finds
/// the bundle, the ordinary plugin loader creates its principal object, the main window selects
/// its declared route, and the host/model tests separately drive the controls the user receives.
/// That keeps the evidence on the real native-plugin boundary instead of turning it into a
/// lookalike preview that could pass after the host stopped working.
@MainActor
final class NativePluginNavigatorRenderTests: HostedStoreTestCase {
    private struct EvidenceTimeout: LocalizedError {
        let message: String

        var errorDescription: String? { message }
    }

    private enum Render {
        static var directory: URL {
            if let override = ProcessInfo.processInfo.environment["THREADING_RENDER_OUT"],
               !override.isEmpty {
                return URL(fileURLWithPath: override, isDirectory: true)
            }
            return FileManager.default.temporaryDirectory
                .appendingPathComponent("ThreadingRenders", isDirectory: true)
        }

        static let windowSize = NSSize(width: 1_120, height: 720)
    }

    private struct Fixture {
        let directory: URL
        let selectedSession: AgentSession
    }

    private struct AppearanceFixture {
        let name: String
        let theme: AppTheme
        let appearance: NSAppearance.Name
    }

    func testRendersBundledNativeNavigatorInTheShippingWindow() throws {
        try FileManager.default.createDirectory(
            at: Render.directory,
            withIntermediateDirectories: true
        )
        let previousTheme = AppThemePalette.current
        let previousSelection = AppSettings.shared.workspaceNavigatorSelection
        let previousDefaultAgent = AppSettings.shared.defaultAgentKind
        let previousSidebarWidth = SidebarWidth.stored
        defer {
            AppSettings.shared.defaultAgentKind = previousDefaultAgent
            AppSettings.shared.workspaceNavigatorSelection = previousSelection
            if let previousSidebarWidth {
                SidebarWidth.record(previousSidebarWidth)
            } else {
                SidebarWidth.reset()
            }
            AppThemePalette.set(previousTheme)
        }

        AppSettings.shared.defaultAgentKind = .openCode
        SidebarWidth.reset()
        let fixture = try makeFixture()
        addTeardownBlock { try? FileManager.default.removeItem(at: fixture.directory) }

        let bundleURL = try XCTUnwrap(NativePluginCatalog.bundledPlugin(
            identifier: "codes.threading.plugin.t3navigator"
        ))
        let descriptor = try XCTUnwrap(NativeWorkspaceNavigatorDiscovery.descriptors(
            at: bundleURL,
            isBundled: true
        ).first { $0.navigatorID == "t3-native" })
        let registry = NativeWorkspaceNavigatorRegistry(inventory: [descriptor])
        let controller = makeMainWindowController(
            initialFramePlan: .useDefaultFrame,
            nativeWorkspaceNavigatorRegistry: registry,
            nativeWorkspaceNavigatorPluginLoader: { route in
                NativePluginCatalog.load(route.bundleURL)
            }
        )
        let window = try XCTUnwrap(controller.window)
        window.setContentSize(Render.windowSize)
        let content = try XCTUnwrap(window.contentView)
        window.makeKeyAndOrderFront(nil)

        controller.sidebarViewController.mountInitialTreeIfNeeded()
        controller.sidebarViewController.select(sessionID: fixture.selectedSession.id)
        try waitUntil("shipping sidebar did not select the fixture session") {
            controller.currentSessionID == fixture.selectedSession.id
        }
        XCTAssertEqual(controller.currentSessionID, fixture.selectedSession.id)
        controller.selectWorkspaceNavigator(descriptor.selection)
        settle(content)
        let host = try waitForNativeHost(in: controller)
        XCTAssertNotNil(host.loaded, "the production host did not retain the bundled plugin")
        let selectedProject = try XCTUnwrap(
            ProjectStore.shared.project(forSessionID: fixture.selectedSession.id)
        )
        host.receive(PluginWorkspaceUpdate(
            revision: 10_000,
            items: [PluginWorkspaceItem(
                identity: .init(
                    kind: .session,
                    identifier: fixture.selectedSession.id.uuidString.lowercased()
                ),
                parentIdentity: .init(
                    kind: .project,
                    identifier: selectedProject.id.uuidString.lowercased()
                ),
                title: fixture.selectedSession.displayTitle,
                detail: fixture.selectedSession.kind.displayName,
                branch: fixture.selectedSession.branch,
                activity: .idle,
                lastActiveAt: fixture.selectedSession.lastUsedAt,
                changeRequest: PluginWorkspaceChangeRequest(
                    providerName: "Forgejo",
                    changeRequestName: "pull request",
                    number: 128,
                    title: "Keep provider status inside the native navigator",
                    webURL: try XCTUnwrap(URL(
                        string: "https://forge.example/threading/app/pulls/128"
                    )),
                    lifecycle: .draft,
                    successfulChecks: 6,
                    activeChecks: 1,
                    approvals: 2,
                    reviewsRequested: 1
                )
            )]
        ))
        settle(content)
        var changeRequestLabel: NSTextField?
        try waitUntil("native navigator did not present the change-request status") {
            settle(content)
            changeRequestLabel = self.viewDescendants(of: host.view)
                .compactMap { $0 as? NSTextField }
                .first { $0.stringValue.contains("#128") }
            return changeRequestLabel != nil
        }
        let statusLabel = try XCTUnwrap(changeRequestLabel)
        let statusRow = try XCTUnwrap(
            viewAncestors(of: statusLabel)
                .compactMap { $0 as? NSTableRowView }
                .first
        )
        XCTAssertFalse(statusLabel.isHidden)
        XCTAssertGreaterThan(statusLabel.visibleRect.height, 0)
        XCTAssertTrue(statusRow.bounds.contains(statusLabel.convert(statusLabel.bounds, to: statusRow)))
        let expectedStatusRowHeight = ceil(
            Design.Typography.lineHeight(of: Design.Typography.detail())
                + Design.Spacing.small
                + Design.Typography.lineHeight(of: Design.Typography.subheading())
                + Design.Spacing.tight
                + Design.Typography.lineHeight(of: Design.Typography.caption())
                + Design.Spacing.inset * 2
        )
        XCTAssertEqual(statusRow.bounds.height, expectedStatusRowHeight, accuracy: 1)
        let sidebarWidth = try XCTUnwrap(
            controller.splitViewController.splitViewItems.first?.viewController.view.bounds.width
        )
        if abs(sidebarWidth - 400) > 1 {
            try waitUntil("native navigator preferred width did not settle") {
                content.layoutSubtreeIfNeeded()
                return abs(
                    (controller.splitViewController.splitViewItems.first?
                        .viewController.view.bounds.width ?? 0) - 400
                ) <= 1
            }
        }
        XCTAssertEqual(
            controller.splitViewController.splitViewItems[0].viewController.view.bounds.width,
            400,
            accuracy: 1
        )

        // Give the real shell its ordered-window lifecycle, then pin one state the window server
        // can guarantee under xcodebuild. `makeKeyAndOrderFront` cannot make an inactive test app
        // key, and leaving the window ordered made AppKit control ink depend on whichever app
        // launched the evidence run. An ordered-out product view still exercises the shipping
        // hierarchy while rendering a deterministic inactive control state.
        window.orderOut(nil)
        settle(content)
        XCTAssertFalse(window.isVisible)
        XCTAssertFalse(window.isKeyWindow)

        let appearances = [
            AppearanceFixture(name: "system-light", theme: .system, appearance: .aqua),
            AppearanceFixture(name: "system-dark", theme: .system, appearance: .darkAqua),
            AppearanceFixture(
                name: "cyberpunk",
                theme: AppThemeStyles.cyberpunk,
                appearance: .darkAqua
            ),
            AppearanceFixture(
                name: "swiss",
                theme: AppThemeStyles.swissMinimalist,
                appearance: .aqua
            ),
        ]
        for fixture in appearances {
            apply(fixture, to: content, host: host)
            try write(content, named: "native-plugin-navigator-\(fixture.name).png")
            if fixture.name == "system-light" || fixture.name == "swiss" {
                try write(
                    controller.splitViewController.splitViewItems[0].viewController.view,
                    named: "native-plugin-navigator-\(fixture.name)-sidebar-detail.png"
                )
            }
        }
    }

    private func makeFixture() throws -> Fixture {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "threading-native-plugin-navigator-evidence-\(UUID().uuidString)",
            isDirectory: true
        )
        let firstDirectory = directory.appendingPathComponent("AnotherTerminal", isDirectory: true)
        let secondDirectory = directory.appendingPathComponent("RuntimeLab", isDirectory: true)
        try FileManager.default.createDirectory(at: firstDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: secondDirectory, withIntermediateDirectories: true)

        let store = ProjectStore.shared
        let first = try XCTUnwrap(store.addProject(folderURL: firstDirectory))
        let second = try XCTUnwrap(store.addProject(folderURL: secondDirectory))
        XCTAssertEqual(store.renameProject(id: first.id, to: "AnotherTerminal"), .unchanged)
        XCTAssertEqual(store.renameProject(id: second.id, to: "Runtime Lab"), .applied)

        let release = try XCTUnwrap(store.addSession(
            to: first.id,
            kind: .openCode,
            title: "Prepare native navigator release"
        ))
        let selected = try XCTUnwrap(store.addSession(
            to: first.id,
            kind: .openCode,
            title: "Finish workspace sidebar contract"
        ))
        let responsive = try XCTUnwrap(store.addSession(
            to: first.id,
            kind: .openCode,
            title: "Investigate responsive layout"
        ))
        let permissions = try XCTUnwrap(store.addSession(
            to: second.id,
            kind: .openCode,
            title: "Review plugin permission boundary"
        ))
        let archived = try XCTUnwrap(store.addSession(
            to: second.id,
            kind: .openCode,
            title: "Retire Wasm-only sidebar prototype"
        ))
        _ = store.update(sessionID: release.id) { $0.branch = "release/1.4" }
        _ = store.update(sessionID: selected.id) { $0.branch = "feature/native-navigator" }
        _ = store.update(sessionID: responsive.id) { $0.branch = "ui/sidebar" }
        _ = store.update(sessionID: permissions.id) { $0.branch = "security/plugin-host" }
        _ = store.update(sessionID: archived.id) { $0.branch = "archive/wasm-poc" }
        XCTAssertEqual(store.setPinned(true, for: release.id), .applied)
        XCTAssertEqual(store.setArchived(true, for: archived.id), .applied)

        return Fixture(
            directory: directory,
            selectedSession: try XCTUnwrap(store.session(withID: selected.id))
        )
    }

    private func apply(
        _ fixture: AppearanceFixture,
        to content: NSView,
        host: NativePluginWorkspaceNavigatorHostViewController
    ) {
        AppThemePalette.set(fixture.theme)
        content.appearance = NSAppearance(named: fixture.appearance)
        // Evidence changes the palette without posting the production theme event. Deliver the
        // same fresh payload the host sends in production so the plugin's private DesignKit copy
        // installs the exact current theme before either tree is repainted.
        host.loaded?.apply(theme: NativePluginCatalog.theme())
        AppThemeRefresh.repaint(content)
        settle(content)
    }

    private func waitForNativeHost(
        in controller: MainWindowController,
        timeout: TimeInterval = 2
    ) throws -> NativePluginWorkspaceNavigatorHostViewController {
        var found: NativePluginWorkspaceNavigatorHostViewController?
        try waitUntil("the selected native navigator host did not load", timeout: timeout) {
            found = self.controllerDescendants(of: controller.splitViewController)
                .compactMap { $0 as? NativePluginWorkspaceNavigatorHostViewController }
                .first { $0.loaded != nil }
            return found != nil
        }
        return try XCTUnwrap(found)
    }

    private func controllerDescendants(of controller: NSViewController) -> [NSViewController] {
        controller.children.flatMap { [$0] + controllerDescendants(of: $0) }
    }

    private func waitUntil(
        _ failure: String,
        timeout: TimeInterval = 2,
        condition: () -> Bool
    ) throws {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if condition() { return }
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.01))
        } while Date() < deadline
        throw EvidenceTimeout(message: failure)
    }

    private func settle(_ view: NSView?) {
        RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05))
        view?.layoutSubtreeIfNeeded()
        view?.displayIfNeeded()
        // Account usage is outside this feature and can refresh from a developer service while
        // evidence runs. Hide only that live reading, leaving the shipping composer intact.
        for usage in view.map(viewDescendants(of:)) ?? [] {
            guard let label = usage as? UsageReadingLabel,
                  label.accessibilityIdentifier() == "composer.session-start.usage" else {
                continue
            }
            label.readings = []
            label.toolTip = nil
            label.isHidden = true
        }
    }

    private func write(_ view: NSView, named filename: String) throws {
        let bounds = view.bounds.integral
        let rep = try XCTUnwrap(NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: max(1, Int(bounds.width)),
            pixelsHigh: max(1, Int(bounds.height)),
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ))
        rep.size = bounds.size
        view.cacheDisplay(in: bounds, to: rep)
        let png = try XCTUnwrap(rep.representation(using: .png, properties: [:]))
        try png.write(to: Render.directory.appendingPathComponent(filename))
    }

    private func viewDescendants(of view: NSView) -> [NSView] {
        view.subviews.flatMap { [$0] + viewDescendants(of: $0) }
    }

    private func viewAncestors(of view: NSView) -> [NSView] {
        var result: [NSView] = []
        var ancestor = view.superview
        while let current = ancestor {
            result.append(current)
            ancestor = current.superview
        }
        return result
    }
}
