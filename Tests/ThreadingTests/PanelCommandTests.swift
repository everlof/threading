import AppKit
import ThreadingExtensionKit
import XCTest
@testable import Threading

@MainActor
final class PanelCommandTests: HostedStoreTestCase {
    func testEveryBuiltInPlusMenuActionIsDiscoverableAndBindable() throws {
        let pane = DisplayPaneController()
        for item in pane.newTabEntries(for: SessionID()).compactMap(\.item) {
            let id = try XCTUnwrap(item.representedValue as? String, item.title)
            let command = try XCTUnwrap(CommandRegistry.shared.command(id: id), item.title)
            XCTAssertTrue(command.isEditable, id)
            XCTAssertEqual(command.scope, .session, id)
        }
    }

    func testNativePanelsJoinAndLeaveTheRegistryWithoutLosingIdentity() throws {
        let registry = CommandRegistry()
        let bundle = URL(fileURLWithPath: "/tmp/Marketeer.bundle")
        registry.replaceNativePluginBundles([bundle])
        let id = PanelCommands.nativePluginID(bundle)
        let command = try XCTUnwrap(registry.command(id: id))
        XCTAssertEqual(command.panelTarget, .nativePlugin(bundle))
        XCTAssertTrue(command.isEditable)
        registry.replaceNativePluginBundles([])
        XCTAssertNil(registry.command(id: id))
        registry.replaceNativePluginBundles([bundle])
        XCTAssertEqual(registry.command(id: id)?.id, id)
    }

    func testManagedSectionCommandsRemainAvailableBeforeInstallation() throws {
        let registry = CommandRegistry()
        registry.replaceNativePluginBundles([])
        let regular = try XCTUnwrap(registry.command(id: "panel.deviceLogs"))
        let bluetooth = try XCTUnwrap(registry.command(id: "panel.bluetoothLogs"))
        XCTAssertEqual(regular.panelTarget, .nativePluginSection(
            identifier: NativePluginManagedOffer.deviceLogs.identifier,
            section: NativePluginManagedOffer.DeviceLogsSection.regular
        ))
        XCTAssertEqual(bluetooth.panelTarget, .nativePluginSection(
            identifier: NativePluginManagedOffer.deviceLogs.identifier,
            section: NativePluginManagedOffer.DeviceLogsSection.bluetooth
        ))
        XCTAssertTrue(regular.isEditable)
        XCTAssertTrue(bluetooth.isEditable)
    }

    func testIndependentNativePluginDeclaresSectionsAndCommands() throws {
        let bundle = URL(fileURLWithPath: "/tmp/IndependentNotes.bundle")
        let identifier = "example.notes"
        let plist: [String: Any] = [
            "CFBundleIdentifier": identifier,
            "ThreadingPaneSections": [
                "schemaVersion": 1,
                "sections": [
                    ["id": "notes", "title": "Notes", "command": [
                        "title": "Open notes", "symbol": "note.text", "detail": "Session notes"
                    ]],
                    ["id": "history", "title": "History", "command": [
                        "title": "Note history", "symbol": "clock"
                    ]]
                ],
                "routes": [["id": "from-device", "section": "notes",
                            "placement": "panel", "context": "selected-device"]]
            ]
        ]
        let pane = try XCTUnwrap(NativePluginPaneDiscovery.descriptor(
            in: plist, bundleURL: bundle, verifiedInstalledIdentity: nil
        ))
        let registry = CommandRegistry()
        registry.replaceNativePluginBundles([bundle], paneDescriptors: [pane])
        XCTAssertEqual(registry.nativePluginRoutes(context: .selectedDevice).count, 1)
        XCTAssertEqual(registry.nativePluginRoutes(context: .selectedDevice).first?.pane.pluginIdentifier,
                       identifier)
        let notes = try XCTUnwrap(registry.command(id: PanelCommands.nativePluginSectionID(
            identifier: identifier, section: "notes"
        )))
        XCTAssertEqual(notes.title, "Open notes")
        XCTAssertEqual(notes.detail, "Session notes")
        XCTAssertEqual(notes.panelTarget, .nativePluginSection(identifier: identifier, section: "notes"))
        XCTAssertNil(registry.command(id: PanelCommands.nativePluginID(bundle)))
        XCTAssertTrue(pane.contains("history"))
        XCTAssertEqual(pane.route("from-device")?.section, "notes")
        XCTAssertEqual(pane.route("from-device")?.placement, .panel)
        XCTAssertEqual(pane.route("from-device")?.context, .selectedDevice)
        registry.replaceNativePluginBundles([])
        XCTAssertNil(registry.command(id: notes.id))
    }

    func testPaneDeclarationRejectsUnknownVersionAndDuplicateSections() {
        let bundle = URL(fileURLWithPath: "/tmp/IndependentNotes.bundle")
        let section = ["id": "notes", "title": "Notes"]
        let base: [String: Any] = ["CFBundleIdentifier": "example.notes"]
        var unknown = base
        unknown["ThreadingPaneSections"] = ["schemaVersion": 2, "sections": [section]]
        XCTAssertNil(NativePluginPaneDiscovery.descriptor(
            in: unknown, bundleURL: bundle, verifiedInstalledIdentity: nil
        ))
        var duplicate = base
        duplicate["ThreadingPaneSections"] = ["schemaVersion": 1, "sections": [section, section]]
        XCTAssertNil(NativePluginPaneDiscovery.descriptor(
            in: duplicate, bundleURL: bundle, verifiedInstalledIdentity: nil
        ))
    }

    func testPaneRouteRejectsUnknownContextAndUndeclaredSection() {
        let bundle = URL(fileURLWithPath: "/tmp/IndependentNotes.bundle")
        let section = ["id": "notes", "title": "Notes"]
        let base: [String: Any] = ["CFBundleIdentifier": "example.notes"]
        func descriptor(_ route: [String: String]) -> NativePluginPaneDescriptor? {
            var plist = base
            plist["ThreadingPaneSections"] = ["schemaVersion": 1,
                                               "sections": [section], "routes": [route]]
            return NativePluginPaneDiscovery.descriptor(
                in: plist, bundleURL: bundle, verifiedInstalledIdentity: nil
            )
        }
        let valid = ["id": "from-device", "section": "notes",
                     "placement": "drawer", "context": "selected-device"]
        XCTAssertEqual(descriptor(valid)?.route("from-device")?.placement, .drawer)
        var unknown = valid
        unknown["context"] = "arbitrary-host-state"
        XCTAssertNil(descriptor(unknown))
        var missing = valid
        missing["section"] = "undeclared"
        XCTAssertNil(descriptor(missing))
        var invalidPlacement = valid
        invalidPlacement["placement"] = "window"
        XCTAssertNil(descriptor(invalidPlacement))
    }

    func testBuiltDeviceLogsDeclaresItsManagedSections() throws {
        let plugins = try XCTUnwrap(Bundle.main.builtInPlugInsURL)
        let bundle = plugins.appendingPathComponent("DeviceLogsPlugin.bundle")
        let pane = try XCTUnwrap(NativePluginPaneDiscovery.inventory(
            bundled: [bundle], installed: []
        ).first)
        XCTAssertEqual(pane.pluginIdentifier, NativePluginManagedOffer.deviceLogs.identifier)
        XCTAssertEqual(pane.sections.map(\.identifier), ["regular", "bluetooth"])
        XCTAssertEqual(pane.sections.compactMap(\.command).count, 2)
        XCTAssertEqual(pane.route("from-device")?.section, "regular")
        XCTAssertEqual(pane.route("from-device")?.placement, .drawer)
    }

    func testNavigatorOnlyPluginDoesNotOfferAnEmptyPaneCommand() {
        let registry = CommandRegistry()
        let navigator = URL(fileURLWithPath: "/tmp/T3NavigatorPlugin.bundle")
        registry.replaceNativePluginBundles([navigator])
        XCTAssertNil(registry.command(id: PanelCommands.nativePluginID(navigator)))
    }

    func testExtensionPanelsRegisterAutomaticallyAndDisappearWhenDisabled() throws {
        let registry = CommandRegistry()
        registry.replaceExtensionCommands(extensionIdentifier: "example", extensionName: "Example",
            commands: [], panels: [ExtensionPanel(id: "status", title: "Status", root: .text("Ready", role: .body))])
        let id = PanelCommands.extensionPanelID(identifier: "example", panelID: "status")
        let command = try XCTUnwrap(registry.command(id: id))
        XCTAssertEqual(command.panelTarget, .extensionPanel(identifier: "example", panelID: "status"))
        XCTAssertTrue(command.isEditable)
        XCTAssertTrue(registry.extensionCommands.isEmpty, "Panel opening must not dispatch as an extension action")
        registry.removeExtensionCommands(extensionIdentifier: "example")
        XCTAssertNil(registry.command(id: id))
    }

    func testMenuRoutesToHostWithStableIdentity() throws {
        let pane = DisplayPaneController()
        var invoked: [String] = []
        pane.onInvokePanelCommand = { invoked.append($0) }
        let entries = pane.newTabEntries(for: SessionID()).compactMap(\.item)
        for item in entries { item.onChoose?() }
        XCTAssertEqual(invoked, entries.compactMap { $0.representedValue as? String })
    }

    func testPanelCommandsHaveRealMenuItemsForShortcutDispatch() throws {
        let previousMenu = NSApp.mainMenu
        let previousWindowsMenu = NSApp.windowsMenu
        let previousHelpMenu = NSApp.helpMenu
        let delegate = AppDelegate()
        defer {
            NSApp.mainMenu = previousMenu
            NSApp.windowsMenu = previousWindowsMenu
            NSApp.helpMenu = previousHelpMenu
        }
        delegate.setupMenuBar()
        func items(_ menu: NSMenu) -> [NSMenuItem] {
            menu.items.flatMap { item in [item] + (item.submenu.map(items) ?? []) }
        }
        let menu = try XCTUnwrap(NSApp.mainMenu)
        let entries = items(menu)
        for command in CommandRegistry.shared.panelCommands {
            let item = try XCTUnwrap(entries.first { $0.representedObject as? String == command.id }, command.id)
            XCTAssertNotNil(item.action)
            XCTAssertTrue(item.target === delegate)
        }
    }

    func testBrowserCapacityUsesEveryHostAndRefusesBeforeConstructingAView() {
        let pane = DisplayPaneController()
        pane.sessionBrowserCount = { _ in DisplayPaneDefaults.maximumBrowserTabs }
        let sessionID = SessionID()
        for target in [PanelCommandTarget.browser, .privateBrowser, .audit] {
            XCTAssertNotNil(pane.panelCommandRefusal(target, for: sessionID))
            XCTAssertFalse(pane.performPanelCommand(target, title: "Browser", for: sessionID))
        }
        XCTAssertTrue(pane.tabs(for: sessionID).isEmpty)
    }

    func testManagerPanelRefusesOrdinarySession() {
        XCTAssertNotNil(DisplayPaneController().panelCommandRefusal(.supervision, for: SessionID()))
    }
}
