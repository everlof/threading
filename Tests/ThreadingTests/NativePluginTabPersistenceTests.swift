import AppKit
import XCTest
@testable import Threading

@MainActor
final class NativePluginTabPersistenceTests: HostedStoreTestCase {
    func testNativePluginRouteIsVersionedAndRejectsUnsafeOrReservedNames() throws {
        let tab = route(host: PersistedTab.drawerHost)
        let panel = PersistedPanel(
            tabs: [tab], activeTabID: nil, observedSignature: nil,
            drawerActiveTabID: tab.id, drawerOpen: true
        )
        XCTAssertEqual(panel.requiredFormatVersion, 8)
        let decoded = try JSONDecoder().decode(PersistedPanel.self, from: JSONEncoder().encode(panel))
        XCTAssertEqual(decoded.drawerTabs.first?.pluginIdentifier, tab.pluginIdentifier)
        XCTAssertEqual(decoded.drawerTabs.first?.pluginBundleName, tab.pluginBundleName)

        var escaping = tab
        escaping.pluginBundleName = "../Other.bundle"
        XCTAssertThrowsError(try JSONDecoder().decode(PersistedPanel.self,
            from: JSONEncoder().encode(PersistedPanel(
                tabs: [escaping], activeTabID: nil, observedSignature: nil))))
        XCTAssertNil(NativePluginCatalog.restoredPaneBundle(
            identifier: NativePluginManagedOffer.deviceLogs.identifier,
            bundleName: "Other.bundle"
        ))
        XCTAssertNil(NativePluginCatalog.restoredPaneBundle(
            identifier: "example.viewer", bundleName: "DeviceLogsPlugin.bundle"
        ))

        var customName = tab
        customName.host = nil
        customName.mode = nil
        customName.pluginIdentifier = "example.viewer"
        customName.pluginBundleName = "Å Viewer.bundle"
        let customPanel = PersistedPanel(
            tabs: [customName], activeTabID: customName.id, observedSignature: nil
        )
        let restoredCustom = try JSONDecoder().decode(PersistedPanel.self,
            from: JSONEncoder().encode(customPanel))
        XCTAssertEqual(restoredCustom.panelTabs.first?.pluginBundleName, "Å Viewer.bundle")

        customName.mode = "bluetooth"
        let customSection = try JSONDecoder().decode(PersistedPanel.self,
            from: JSONEncoder().encode(PersistedPanel(
                tabs: [customName], activeTabID: customName.id,
                observedSignature: nil)))
        XCTAssertEqual(customSection.panelTabs.first?.mode, "bluetooth")

        customName.mode = "../unsafe"
        XCTAssertThrowsError(try JSONDecoder().decode(PersistedPanel.self,
            from: JSONEncoder().encode(PersistedPanel(
                tabs: [customName], activeTabID: customName.id,
                observedSignature: nil))))

        var unknownSection = tab
        unknownSection.mode = "future-stream"
        XCTAssertThrowsError(try JSONDecoder().decode(PersistedPanel.self,
            from: JSONEncoder().encode(PersistedPanel(
                tabs: [unknownSection], activeTabID: nil,
                observedSignature: nil))))
    }

    func testPanelDockAndDrawerRestoreAPluginByIdentityAndSection() throws {
        let session = SessionID()
        defer { DisplayPaneStore.shared.removeSession(session) }
        let panelTab = route()
        var drawerTab = route(host: PersistedTab.drawerHost)
        drawerTab.id = UUID().uuidString
        let dockID = UUID()
        let dockTab = route(host: PersistedTab.dockHost(dockID))
        var layout = WorkspaceDockLayout()
        XCTAssertTrue(layout.insert(dockID, beside: nil, edge: .bottom))
        DisplayPaneStore.shared.saveLayout(
            tabs: [panelTab], activeID: panelTab.id, for: session
        )
        DisplayPaneStore.shared.saveDockLayout(layout, for: session)
        DisplayPaneStore.shared.saveDockTabs(
            [dockTab], activeID: dockTab.id, dockID: dockID, for: session
        )
        DisplayPaneStore.shared.saveDrawerLayout(
            tabs: [drawerTab], activeID: drawerTab.id, open: true, for: session
        )

        let panel = DisplayPaneController()
        panel.showSession(session)
        let panelPlugin = try plugin(in: panel.tabs(for: session))
        XCTAssertEqual(panelPlugin.bundleURL, NativePluginCatalog.deviceLogsBundle)
        XCTAssertEqual(panelPlugin.paneSection, "bluetooth")
        XCTAssertEqual(panel.activeTabID(for: session)?.uuidString, panelTab.id)

        let dock = DisplayPaneController(scope: .dock(dockID, session: session))
        dock.showSession(session)
        let dockPlugin = try plugin(in: dock.tabs(for: session))
        XCTAssertEqual(dockPlugin.bundleURL, NativePluginCatalog.deviceLogsBundle)
        XCTAssertEqual(dockPlugin.paneSection, "bluetooth")
        XCTAssertEqual(dock.activeTabID(for: session)?.uuidString, dockTab.id)

        let drawer = DrawerHostViewController(directoryProvider: { _ in nil })
        drawer.showSession(session)
        let drawerPlugin = try plugin(in: drawer.tabs(for: session))
        XCTAssertEqual(drawerPlugin.bundleURL, NativePluginCatalog.deviceLogsBundle)
        XCTAssertEqual(drawerPlugin.paneSection, "bluetooth")
        XCTAssertEqual(drawer.activeTabID(for: session)?.uuidString, drawerTab.id)
    }

    func testExternalSectionRestoresFromCachedDeclaration() throws {
        let session = SessionID()
        defer {
            DisplayPaneStore.shared.removeSession(session)
            CommandRegistry.shared.replaceNativePluginBundles([])
        }
        let bundle = NativePluginCatalog.directory.appendingPathComponent("IndependentNotes.bundle")
        let descriptor = NativePluginPaneDescriptor(
            bundleURL: bundle, pluginIdentifier: "example.notes",
            sections: [
                .init(identifier: "notes", title: "Notes", command: nil),
                .init(identifier: "history", title: "History", command: nil)
            ], routes: [], verifiedInstalledIdentity: nil
        )
        CommandRegistry.shared.replaceNativePluginBundles([bundle], paneDescriptors: [descriptor])
        var saved = route()
        saved.pluginIdentifier = descriptor.pluginIdentifier
        saved.pluginBundleName = bundle.lastPathComponent
        saved.mode = "history"
        DisplayPaneStore.shared.saveLayout(tabs: [saved], activeID: saved.id, for: session)
        XCTAssertEqual(DisplayPaneStore.shared.loadLayout(for: session)?.panelTabs.first?.mode,
                       "history")
        XCTAssertEqual(NativePluginCatalog.restoredPaneBundle(
            identifier: descriptor.pluginIdentifier, bundleName: bundle.lastPathComponent
        )?.standardizedFileURL.path, bundle.standardizedFileURL.path)
        XCTAssertNotNil(CommandRegistry.shared.nativePluginPane(at: bundle))
        XCTAssertNotNil(NativePluginPaneViewController.forBundle(
            bundle, sessionID: session, section: "history",
            expectedIdentifier: descriptor.pluginIdentifier
        ))

        let pane = DisplayPaneController()
        pane.showSession(session)
        let plugin = try plugin(in: pane.tabs(for: session))
        XCTAssertEqual(plugin.paneSection, "history")
        XCTAssertEqual(plugin.displayName, "History")
        XCTAssertEqual(pane.activeTabID(for: session)?.uuidString, saved.id)
    }

    func testExternalSectionWaitsForAsyncDiscoveryWithoutLosingSavedTab() throws {
        let session = SessionID()
        defer {
            DisplayPaneStore.shared.removeSession(session)
            CommandRegistry.shared.replaceNativePluginBundles([])
        }
        let bundle = NativePluginCatalog.directory.appendingPathComponent("DelayedNotes.bundle")
        var saved = route()
        saved.pluginIdentifier = "example.delayed"
        saved.pluginBundleName = bundle.lastPathComponent
        saved.mode = "history"
        DisplayPaneStore.shared.saveLayout(tabs: [saved], activeID: saved.id, for: session)
        CommandRegistry.shared.replaceNativePluginBundles([])

        let pane = DisplayPaneController()
        pane.showSession(session)
        XCTAssertTrue(pane.tabs(for: session).isEmpty)
        XCTAssertEqual(DisplayPaneStore.shared.loadLayout(for: session)?.panelTabs.first?.id, saved.id)

        let descriptor = NativePluginPaneDescriptor(
            bundleURL: bundle, pluginIdentifier: "example.delayed",
            sections: [.init(identifier: "history", title: "History", command: nil)],
            routes: [],
            verifiedInstalledIdentity: nil
        )
        CommandRegistry.shared.replaceNativePluginBundles([bundle], paneDescriptors: [descriptor])
        let restored = try plugin(in: pane.tabs(for: session))
        XCTAssertEqual(restored.paneSection, "history")
        XCTAssertEqual(pane.activeTabID(for: session)?.uuidString, saved.id)
        XCTAssertEqual(DisplayPaneStore.shared.loadLayout(for: session)?.panelTabs.first?.id, saved.id)
        XCTAssertEqual(DisplayPaneStore.shared.loadLayout(for: session)?.panelTabs.first?.mode, "history")
    }

    func testChangedBundleIdentityIsRefusedBeforeMapping() async throws {
        let bundle = try XCTUnwrap(NativePluginCatalog.deviceLogsBundle)
        let controller = NativePluginPaneViewController(
            bundleURL: bundle,
            owningSessionID: SessionID(),
            expectedBundleIdentifier: "example.wrong"
        )
        _ = controller.view
        for _ in 0..<100 where controller.refusal == nil {
            try await Task.sleep(for: .milliseconds(20))
        }
        guard case .some(.buildChanged(identifier: "example.wrong")) = controller.refusal else {
            return XCTFail("Expected a build-changed refusal, got \(String(describing: controller.refusal))")
        }
        XCTAssertNil(controller.loaded)
    }

    func testDeclaredSectionsUseOneOwnerAndRejectUndeclaredRoutes() throws {
        let bundle = try XCTUnwrap(NativePluginCatalog.deviceLogsBundle)
        let session = SessionID()
        let regular = try XCTUnwrap(NativePluginPaneViewController.forBundle(
            bundle, sessionID: session
        ))
        let bluetooth = try XCTUnwrap(NativePluginPaneViewController.forBundle(
            bundle, sessionID: session, section: "bluetooth"
        ))
        XCTAssertEqual(regular.paneSection, "regular")
        XCTAssertEqual(bluetooth.paneSection, "bluetooth")
        XCTAssertTrue(regular === NativePluginPaneViewController.forBundle(
            bundle, sessionID: session, section: "regular"
        ))
        XCTAssertFalse(regular === bluetooth)
        XCTAssertEqual(bluetooth.displayName, L10n.string("Bluetooth"))
        XCTAssertTrue(NativePluginPaneViewController.forBundle(
            bundle, sessionID: session, section: "unknown"
        ) == nil)
        XCTAssertEqual(NativePluginManagedOffer.paneOffer(at: bundle)?.identifier,
            NativePluginManagedOffer.deviceLogs.identifier)
    }

    func testDrawerAcceptsRestorableManagedPaneAndRefusesUnknownIdentity() throws {
        let session = SessionID()
        defer { DisplayPaneStore.shared.removeSession(session) }
        let drawer = DrawerHostViewController(directoryProvider: { _ in nil })
        drawer.showSession(session)
        let offeredURL = NativePluginCatalog.directory.appendingPathComponent(
            NativePluginManagedOffer.proxy.bundleName, isDirectory: true
        )
        let offered = PaneTab(
            body: .nativePlugin(NativePluginPaneViewController(
                bundleURL: offeredURL, owningSessionID: session
            )),
            owningSessionID: session
        )
        XCTAssertTrue(drawer.canAdopt(offered))
        drawer.adopt(offered, at: nil, for: session)
        let saved = try XCTUnwrap(DisplayPaneStore.shared.loadLayout(for: session)?.drawerTabs.first)
        XCTAssertEqual(saved.kind, .nativePlugin)
        XCTAssertEqual(saved.pluginIdentifier, NativePluginManagedOffer.proxy.identifier)
        XCTAssertEqual(saved.pluginBundleName, NativePluginManagedOffer.proxy.bundleName)

        let unknown = PaneTab(
            body: .nativePlugin(NativePluginPaneViewController(
                bundleURL: NativePluginCatalog.directory.appendingPathComponent("Unknown.bundle"),
                owningSessionID: session
            )),
            owningSessionID: session
        )
        XCTAssertFalse(drawer.canAdopt(unknown))
    }

    func testMovedDeviceLogsRevealTheirToolSectionInTheDrawer() throws {
        let session = SessionID()
        defer { DisplayPaneStore.shared.removeSession(session) }
        let panel = DisplayPaneController()
        panel.showSession(session)
        let logs = try XCTUnwrap(panel.activateDeviceLog(for: session))
        let tabID = try XCTUnwrap(panel.tabs(for: session).first?.id)
        let drawer = DrawerHostViewController(directoryProvider: { _ in nil })
        drawer.showSession(session)
        let moved = try XCTUnwrap(panel.detachTab(id: tabID, for: session))
        XCTAssertTrue(drawer.canAdopt(moved))
        drawer.adopt(moved, at: nil, for: session)
        var reveals = 0
        drawer.onNativePluginToolReveal = { _ in reveals += 1 }

        XCTAssertEqual(logs.onRevealSection?("bluetooth"), true)
        let sections = drawer.tabs(for: session).compactMap { tab -> String? in
            guard case let .nativePlugin(plugin) = tab.body else { return nil }
            return plugin.paneSection
        }
        XCTAssertEqual(sections, ["regular", "bluetooth"])
        XCTAssertEqual(reveals, 1)
    }

    private func route(host: String? = nil) -> PersistedTab {
        PersistedTab(
            id: UUID().uuidString,
            kind: .nativePlugin,
            title: "Bluetooth",
            subtitle: "",
            mode: "bluetooth",
            pluginIdentifier: NativePluginManagedOffer.deviceLogs.identifier,
            pluginBundleName: NativePluginManagedOffer.deviceLogs.bundleName,
            host: host
        )
    }

    private func plugin(in tabs: [PaneTab]) throws -> NativePluginPaneViewController {
        let tab = try XCTUnwrap(tabs.first)
        return try XCTUnwrap(tab.hostedController as? NativePluginPaneViewController)
    }
}
