import AppKit
import ThreadingExtensionKit
import ThreadingPluginKit
import XCTest
@testable import Threading

@MainActor
final class NativePluginWorkspaceNavigatorHostTests: XCTestCase {
    func testHostBuildsDeclaredNavigatorAppliesThemeAndBridgesUpdatesAndIntents() throws {
        let plugin = NavigatorPresentationProbe()
        let item = PluginWorkspaceItem(
            identity: .init(kind: .session, identifier: "session-1"),
            title: "First"
        )
        var activated: PluginWorkspaceItemIdentity?
        var performed: (PluginWorkspaceAction, PluginWorkspaceItemIdentity)?
        let controller = NativePluginWorkspaceNavigatorHostViewController(
            descriptor: descriptor(),
            initialSnapshot: .init(revision: 1, items: [item], selectedItemIdentity: nil),
            activate: { activated = $0; return true },
            perform: { performed = ($0, $1); return true },
            loadPlugin: { _ in .success(plugin) },
            onUnavailable: { _ in XCTFail("valid navigator fell back") }
        )

        controller.loadView()

        XCTAssertTrue(controller.loaded === plugin)
        XCTAssertTrue(plugin.presentation.superview === controller.view)
        XCTAssertEqual(plugin.requestedIdentifier, "focused")
        XCTAssertEqual(plugin.context?.snapshot.items.first?.title, "First")
        XCTAssertEqual(plugin.appliedThemes.count, 1)

        let changed = PluginWorkspaceItem(
            identity: item.identity,
            title: "Changed"
        )
        controller.receive(.init(revision: 2, items: [changed]))
        XCTAssertEqual(plugin.receivedUpdates.count, 1)
        XCTAssertEqual(plugin.context?.snapshot.items.first?.title, "Changed")

        XCTAssertTrue(try XCTUnwrap(plugin.context).activate(identity: item.identity))
        XCTAssertEqual(activated, item.identity)
        XCTAssertTrue(try XCTUnwrap(plugin.context).perform(action: .archive, identity: item.identity))
        XCTAssertEqual(performed?.0, .archive)
        XCTAssertEqual(performed?.1, item.identity)

        NotificationCenter.default.post(AppThemeDidChange(themeID: .system))
        XCTAssertEqual(plugin.appliedThemes.count, 2)
    }

    func testHostAuditsOnlyItsOwnChromeAroundAPluginPresentation() {
        let plugin = NavigatorPresentationProbe()
        plugin.presentation.addSubview(NSScrollView())
        let controller = NativePluginWorkspaceNavigatorHostViewController(
            descriptor: descriptor(),
            initialSnapshot: .init(revision: 1, items: [], selectedItemIdentity: nil),
            activate: { _ in false },
            perform: { _, _ in false },
            loadPlugin: { _ in .success(plugin) },
            onUnavailable: { _ in XCTFail("valid navigator fell back") }
        )

        controller.loadView()

        XCTAssertEqual(ThemeBoundaryAudit.violations(in: controller.view), [])
        controller.view.addSubview(NSScrollView())
        XCTAssertEqual(
            ThemeBoundaryAudit.violations(in: controller.view).map(\.className),
            ["NSScrollView", "NSClipView"]
        )
    }

    func testHostRejectsAPluginThatClaimsAnotherIdentityAndFallsBack() async {
        let plugin = NavigatorPresentationProbe()
        plugin.pluginIdentifier = "tests.someone-else"
        var unavailableCount = 0
        let controller = NativePluginWorkspaceNavigatorHostViewController(
            descriptor: descriptor(),
            initialSnapshot: .init(revision: 1, items: [], selectedItemIdentity: nil),
            activate: { _ in false },
            perform: { _, _ in false },
            loadPlugin: { _ in .success(plugin) },
            onUnavailable: { _ in unavailableCount += 1 }
        )

        controller.loadView()
        await Task.yield()

        XCTAssertNil(controller.loaded)
        XCTAssertEqual(controller.refusal?.code, "capability_unavailable")
        XCTAssertEqual(unavailableCount, 1)
    }

    func testContainerSelectsNativePluginAndSettingsTemporarilyRevealDefault() throws {
        let plugin = NavigatorPresentationProbe()
        let route = descriptor()
        let registry = NativeWorkspaceNavigatorRegistry(inventory: [route])
        let store = try emptyStore()
        let native = ProjectSidebarViewController(projectStore: store)
        let container = WorkspaceSidebarContainerViewController(
            nativeController: native,
            routing: EmptyNavigatorRouter(),
            nativeRegistry: registry,
            nativeSnapshotSource: .init(projectStore: store),
            nativePluginLoader: { _ in .success(plugin) },
            contextProvider: { .init() },
            destinationHandler: { _ in nil }
        )

        container.loadView()
        container.activate(route.selection)
        XCTAssertEqual(container.effectiveSelection, route.selection)
        XCTAssertTrue(plugin.presentation.isDescendant(of: container.view))

        container.setSettingsOverride(true)
        XCTAssertEqual(container.effectiveSelection, .native)
        XCTAssertTrue(native.view.isDescendant(of: container.view))

        container.setSettingsOverride(false)
        XCTAssertEqual(container.effectiveSelection, route.selection)
        XCTAssertTrue(plugin.presentation.isDescendant(of: container.view))
    }

    func testBuildChangeFailureRefreshesTheRouteToItsReplacementIdentity() async throws {
        let old = descriptor(installedHash: "old")
        let replacement = descriptor(installedHash: "replacement")
        let registry = NativeWorkspaceNavigatorRegistry(
            inventory: [old],
            discover: { _ in [replacement] }
        )
        let store = try emptyStore()
        let native = ProjectSidebarViewController(projectStore: store)
        let container = WorkspaceSidebarContainerViewController(
            nativeController: native,
            routing: EmptyNavigatorRouter(),
            nativeRegistry: registry,
            nativeSnapshotSource: .init(projectStore: store),
            nativePluginLoader: { descriptor in
                .failure(.buildChanged(identifier: descriptor.pluginIdentifier))
            },
            contextProvider: { .init() },
            destinationHandler: { _ in nil }
        )

        container.loadView()
        container.activate(old.selection)
        for _ in 0..<100 where registry.inventory != [replacement] {
            try await Task.sleep(for: .milliseconds(10))
        }

        XCTAssertEqual(container.effectiveSelection, .native)
        XCTAssertEqual(registry.inventory, [replacement])
    }

    private func descriptor(
        preferredWidth: Int? = 280,
        installedHash: String? = nil
    ) -> NativeWorkspaceNavigatorDescriptor {
        NativeWorkspaceNavigatorDescriptor(
            pluginIdentifier: "tests.navigator-presentation",
            pluginName: "Navigator",
            navigatorID: "focused",
            title: "Focused",
            preferredWidth: preferredWidth,
            bundleURL: URL(fileURLWithPath: "/tmp/Navigator.bundle"),
            isBundled: installedHash == nil,
            verifiedInstalledIdentity: installedHash.map {
                PluginLoader.PluginIdentity(
                    bundleIdentifier: "tests.navigator-presentation",
                    team: "TESTS",
                    cdHash: $0
                )
            }
        )
    }

    private func emptyStore() throws -> ProjectStore {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "threading-native-navigator-host-\(UUID().uuidString)",
            isDirectory: true
        )
        let manager = StateManager(appSupportDirectory: directory)
        XCTAssertTrue(manager.saveProjectsState(ProjectsState(projects: [])))
        addTeardownBlock {
            await MainActor.run { manager.closeDatabase() }
            try? FileManager.default.removeItem(at: directory)
        }
        return ProjectStore(stateManager: manager)
    }
}

@MainActor
final class NativeWorkspaceNavigatorWidthTests: HostedStoreTestCase {
    func testSameRouteDescriptorRefreshReplacesItsWidthHint() throws {
        let previousSelection = AppSettings.shared.workspaceNavigatorSelection
        let previousWidth = SidebarWidth.stored
        defer {
            AppSettings.shared.workspaceNavigatorSelection = previousSelection
            if let previousWidth {
                SidebarWidth.record(previousWidth)
            } else {
                SidebarWidth.reset()
            }
        }
        SidebarWidth.reset()

        let first = descriptor(width: 248)
        let replacement = descriptor(width: 376)
        let registry = NativeWorkspaceNavigatorRegistry(
            inventory: [first],
            discover: { _ in [replacement] }
        )
        let plugin = NavigatorPresentationProbe()
        plugin.pluginIdentifier = first.pluginIdentifier
        let controller = makeMainWindowController(
            initialFramePlan: .useDefaultFrame,
            nativeWorkspaceNavigatorRegistry: registry,
            nativeWorkspaceNavigatorPluginLoader: { _ in
                .success(plugin)
            }
        )
        let window = try XCTUnwrap(controller.window)
        window.setContentSize(NSSize(width: 1_400, height: 900))
        settleMainQueue(controller)

        controller.selectWorkspaceNavigator(first.selection)
        settleMainQueue(controller)
        XCTAssertEqual(sidebarWidth(in: controller), 248, accuracy: 1)

        let refreshed = expectation(
            forNotification: NativeWorkspaceNavigatorsDidChange.name,
            object: nil
        )
        registry.refresh()
        wait(for: [refreshed], timeout: 2)
        settleMainQueue(controller)

        XCTAssertEqual(first.selection, replacement.selection)
        XCTAssertEqual(sidebarWidth(in: controller), 376, accuracy: 1)
    }

    func testRegistryRefreshPreservesAUserDraggedWidth() throws {
        let previousSelection = AppSettings.shared.workspaceNavigatorSelection
        let previousWidth = SidebarWidth.stored
        defer {
            AppSettings.shared.workspaceNavigatorSelection = previousSelection
            if let previousWidth {
                SidebarWidth.record(previousWidth)
            } else {
                SidebarWidth.reset()
            }
        }
        SidebarWidth.reset()

        let first = descriptor(width: 248)
        let replacement = descriptor(width: 376)
        let registry = NativeWorkspaceNavigatorRegistry(
            inventory: [first],
            discover: { _ in [replacement] }
        )
        let plugin = NavigatorPresentationProbe()
        plugin.pluginIdentifier = first.pluginIdentifier
        let controller = makeMainWindowController(
            initialFramePlan: .useDefaultFrame,
            nativeWorkspaceNavigatorRegistry: registry,
            nativeWorkspaceNavigatorPluginLoader: { _ in .success(plugin) }
        )
        let window = try XCTUnwrap(controller.window)
        window.setContentSize(NSSize(width: 1_400, height: 900))
        settleMainQueue(controller)
        controller.selectWorkspaceNavigator(first.selection)
        settleMainQueue(controller)

        controller.splitViewController.splitView.setPosition(312, ofDividerAt: 0)
        settleMainQueue(controller)
        XCTAssertEqual(sidebarWidth(in: controller), 312, accuracy: 1)

        let refreshed = expectation(
            forNotification: NativeWorkspaceNavigatorsDidChange.name,
            object: nil
        )
        registry.refresh()
        wait(for: [refreshed], timeout: 2)
        settleMainQueue(controller)

        XCTAssertEqual(sidebarWidth(in: controller), 312, accuracy: 1)
    }

    private func descriptor(width: Int) -> NativeWorkspaceNavigatorDescriptor {
        NativeWorkspaceNavigatorDescriptor(
            pluginIdentifier: "tests.navigator-width",
            pluginName: "Width",
            navigatorID: "focused",
            title: "Focused",
            preferredWidth: width,
            bundleURL: URL(fileURLWithPath: "/tmp/Width.bundle"),
            isBundled: true,
            verifiedInstalledIdentity: nil
        )
    }

    private func settleMainQueue(_ controller: MainWindowController) {
        let settled = expectation(description: "main queue settled")
        DispatchQueue.main.async { settled.fulfill() }
        wait(for: [settled], timeout: 1)
        controller.window?.contentView?.layoutSubtreeIfNeeded()
    }

    private func sidebarWidth(in controller: MainWindowController) -> CGFloat {
        controller.splitViewController.splitViewItems[0].viewController.view.bounds.width
    }
}

@MainActor
private final class EmptyNavigatorRouter: ExtensionWorkspaceNavigatorRouting {
    var extensionWorkspaceNavigatorInventory: [ExtensionWorkspaceNavigatorInventoryItem] { [] }

    func registeredWorkspaceNavigator(
        extensionIdentifier _: String,
        navigatorID _: String
    ) -> ExtensionWorkspaceNavigatorInventoryItem? { nil }

    func extensionImageResourceURL(
        extensionIdentifier _: String,
        relativePath _: String
    ) -> URL? { nil }

    func invokeWorkspaceNavigatorAction(
        extensionIdentifier _: String,
        navigatorID _: String,
        actionID _: String,
        value _: ExtensionJSONValue?,
        context _: ExtensionCommandContext,
        completion _: @escaping (
            Result<ExtensionWorkspaceNavigatorActionResponse, Error>
        ) -> Void
    ) -> Bool { false }
}

@MainActor
private final class NavigatorPresentationProbe: NSObject, ThreadingNativePlugin {
    static let pluginAPIVersion = 4
    var pluginIdentifier = "tests.navigator-presentation"
    let presentation = NSView()
    private(set) var requestedIdentifier: String?
    private(set) var context: PluginWorkspaceNavigatorContext?
    private(set) var receivedUpdates: [PluginWorkspaceUpdate] = []
    private(set) var appliedThemes: [PluginTheme] = []

    required override init() { super.init() }

    func makeWorkspaceNavigatorView(
        identifier: String,
        context: PluginWorkspaceNavigatorContext
    ) -> NSView {
        requestedIdentifier = identifier
        self.context = context
        context.observeUpdates { [weak self] update in
            self?.receivedUpdates.append(update)
        }
        return presentation
    }

    func apply(theme: PluginTheme) { appliedThemes.append(theme) }
}
