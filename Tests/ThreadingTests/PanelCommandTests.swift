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
