import AppKit
import XCTest
@testable import Skalman

/// The delegate methods the system can call in an instance that never started up.
///
/// This is not a hypothetical: a hosted test bundle *is* a running `NSApplication` with this
/// delegate installed, and `applicationDidFinishLaunching` deliberately returns early there —
/// so the window controller is nil while the app is otherwise live. Any test that waits on a
/// main-queue completion pumps the run loop, and a Dock click delivered into that window used
/// to take the whole run down on a force-unwrap.
@MainActor
final class AppDelegateTests: XCTestCase {

    func testClosingTheLastTestWindowDoesNotTerminateTheHostedRunner() {
        XCTAssertFalse(
            AppDelegate().applicationShouldTerminateAfterLastWindowClosed(NSApp)
        )
    }

    func testReopenWithoutAWindowControllerDoesNotCrash() {
        let delegate = AppDelegate()

        // Both arms: `false` is the one that used to reach for the window.
        XCTAssertTrue(delegate.applicationShouldHandleReopen(NSApp, hasVisibleWindows: false))
        XCTAssertTrue(delegate.applicationShouldHandleReopen(NSApp, hasVisibleWindows: true))
    }

    /// Every window-scoped menu action, performed on a delegate that has no window.
    ///
    /// This is the same shape as the reopen crash above, spread across twenty call sites: two
    /// processes run a real `NSApplication` with this delegate and never build a window — a
    /// hosted test bundle, and a second instance that lost the single-instance lock — and a
    /// command arriving in either has nothing to act on. Doing nothing is the answer; trapping
    /// is not. Performed by selector because the actions are private, which is also how the
    /// menu itself reaches them.
    func testWindowActionsDoNothingRatherThanTrapWithoutAWindow() {
        let delegate = AppDelegate()

        let actions = [
            "showPreferences", "openTerminalTab", "openFilesTab", "openBrowser", "openReview",
            "openInfo", "toggleShell", "toggleDisplayPanel", "newSession", "addProject",
            "newProject", "closeSession", "toggleSidebar", "showFind", "inspectElement",
            "inspectPoint", "increaseFontSize", "decreaseFontSize"
        ]

        for name in actions {
            let selector = Selector(name)
            XCTAssertTrue(
                delegate.responds(to: selector),
                "\(name) is no longer an action the menu can reach"
            )
            delegate.perform(selector)
        }
    }

    func testOpeningFoldersIsIgnoredWithoutTheStateLock() {
        // Adopting a folder instantiates ProjectStore, and instantiating it writes
        // projects.json — the user's real one. An instance that does not own the lock must not.
        let delegate = AppDelegate()
        delegate.application(NSApp, open: [URL(fileURLWithPath: NSTemporaryDirectory())])
    }

    func testExtensionCommandsRenderAtDeclaredHostMenuAnchors() throws {
        let previousMainMenu = NSApp.mainMenu
        let previousWindowsMenu = NSApp.windowsMenu
        let previousHelpMenu = NSApp.helpMenu
        CommandRegistry.shared.removeAllExtensionCommands()
        defer {
            CommandRegistry.shared.removeAllExtensionCommands()
            NSApp.mainMenu = previousMainMenu
            NSApp.windowsMenu = previousWindowsMenu
            NSApp.helpMenu = previousHelpMenu
        }

        CommandRegistry.shared.replaceExtensionCommands(
            extensionIdentifier: "com.example.ci",
            extensionName: "CI",
            commands: [
                .init(
                    id: "open-build",
                    title: "Open Build",
                    scope: .project,
                    menuPlacements: [.project, .view]
                )
            ]
        )

        let delegate = AppDelegate()
        delegate.setupMenuBar()

        let projectMenu = try XCTUnwrap(
            NSApp.mainMenu?.items.compactMap(\.submenu).first {
                $0.title == MenuIdentifiers.projectMenu
            }
        )
        let viewMenu = try XCTUnwrap(
            NSApp.mainMenu?.items.compactMap(\.submenu).first {
                $0.title == MenuIdentifiers.viewMenu
            }
        )
        let extensionsMenu = try XCTUnwrap(
            NSApp.mainMenu?.items.compactMap(\.submenu).first {
                $0.title == "Extensions"
            }
        )

        let projectGroup = try XCTUnwrap(projectMenu.item(withTitle: "Extensions"))
        let viewGroup = try XCTUnwrap(viewMenu.item(withTitle: "Extensions"))
        XCTAssertFalse(projectGroup.isHidden)
        XCTAssertFalse(viewGroup.isHidden)
        XCTAssertEqual(
            projectGroup.submenu?.item(withTitle: "CI")?
                .submenu?.item(withTitle: "Open Build")?.representedObject as? String,
            "extension.com.example.ci.open-build"
        )
        XCTAssertEqual(
            viewGroup.submenu?.item(withTitle: "CI")?
                .submenu?.item(withTitle: "Open Build")?.representedObject as? String,
            "extension.com.example.ci.open-build"
        )
        XCTAssertEqual(
            extensionsMenu.items.filter { !$0.isHidden }.map(\.title),
            ["No Extension Commands Here"]
        )
    }
}
