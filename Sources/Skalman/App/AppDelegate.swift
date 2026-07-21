import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {

    // MARK: - Singleton

    static var shared: AppDelegate {
        NSApp.delegate as! AppDelegate
    }

    // MARK: - Properties

    private var mainWindowController: MainWindowController!

    // MARK: - NSApplicationDelegate

    func applicationDidFinishLaunching(_ notification: Notification) {
        setupMenuBar()

        mainWindowController = MainWindowController()
        mainWindowController.showWindow(nil)

        cleanupOrphanedHistoryFiles()
        StateManager.shared.clearLegacySessionState()

        // Session restore waits for the listener, because a launch reads the port to build the
        // session's `--mcp-config`. The callback runs whether the server came up or not, so a
        // failed listener costs the restored session its display panel and nothing else.
        MCPServer.shared.handler = mainWindowController
        mainWindowController.installPermissionPresenter()
        MCPServer.shared.start { [weak self] in
            self?.mainWindowController.restoreSelectedSession()
        }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        // Projects are persisted by ProjectStore as they change, but a coalesced write may
        // still be pending, so it is flushed before the agents are torn down.
        ProjectStore.shared.flushPendingSave()
        AgentRuntime.shared.terminateAll()
        MCPServer.shared.stop()
        return .terminateNow
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
        true
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            mainWindowController.showWindow(nil)
        }
        return true
    }

    /// Folders dropped on the app icon are added as projects.
    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls {
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
                  isDirectory.boolValue else { continue }

            ProjectStore.shared.addProject(folderURL: url)
        }
    }

    // MARK: - Private Methods

    /// Removes history files belonging to sessions that no longer exist.
    private func cleanupOrphanedHistoryFiles() {
        let activeSessionIDs = Set(
            ProjectStore.shared.projects.flatMap { $0.sessions.map(\.id) }
        )
        HistoryManager.cleanupOrphanedHistoryFiles(activeSessionIDs: activeSessionIDs)
    }

    // MARK: - Menu Setup

    private func setupMenuBar() {
        let mainMenu = NSMenu()

        mainMenu.addItem(makeApplicationMenuItem())
        mainMenu.addItem(makeProjectMenuItem())
        mainMenu.addItem(makeEditMenuItem())
        mainMenu.addItem(makeViewMenuItem())

        let windowMenuItem = makeWindowMenuItem()
        mainMenu.addItem(windowMenuItem)
        NSApp.windowsMenu = windowMenuItem.submenu

        let helpMenuItem = makeHelpMenuItem()
        mainMenu.addItem(helpMenuItem)
        NSApp.helpMenu = helpMenuItem.submenu

        NSApp.mainMenu = mainMenu
    }

    private func makeApplicationMenuItem() -> NSMenuItem {
        let appName = ProcessInfo.processInfo.processName
        let menu = NSMenu()

        menu.addItem(
            withTitle: "About \(appName)",
            action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)),
            keyEquivalent: ""
        )
        menu.addItem(.separator())
        menu.addItem(withTitle: "Preferences…", action: #selector(showPreferences), keyEquivalent: ",")
        menu.addItem(.separator())
        menu.addItem(
            withTitle: "Hide \(appName)",
            action: #selector(NSApplication.hide(_:)),
            keyEquivalent: "h"
        )

        let hideOthersItem = NSMenuItem(
            title: "Hide Others",
            action: #selector(NSApplication.hideOtherApplications(_:)),
            keyEquivalent: "h"
        )
        hideOthersItem.keyEquivalentModifierMask = [.command, .option]
        menu.addItem(hideOthersItem)

        menu.addItem(
            withTitle: "Show All",
            action: #selector(NSApplication.unhideAllApplications(_:)),
            keyEquivalent: ""
        )
        menu.addItem(.separator())
        menu.addItem(
            withTitle: "Quit \(appName)",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        )

        let item = NSMenuItem()
        item.submenu = menu
        return item
    }

    private func makeProjectMenuItem() -> NSMenuItem {
        let menu = NSMenu(title: MenuIdentifiers.projectMenu)

        menu.addItem(withTitle: "New Session", action: #selector(newSession), keyEquivalent: "n")

        // Explicit per-agent entries, so the default kind and account can be bypassed.
        NewSessionMenuBuilder.addItems(
            to: menu,
            target: self,
            action: #selector(newSessionFromMenu(_:))
        )

        menu.addItem(.separator())

        let addProjectItem = NSMenuItem(
            title: "Add Project…",
            action: #selector(addProject),
            keyEquivalent: "n"
        )
        addProjectItem.keyEquivalentModifierMask = [.command, .shift]
        menu.addItem(addProjectItem)

        menu.addItem(.separator())
        menu.addItem(withTitle: "Close Session", action: #selector(closeSession), keyEquivalent: "w")

        let item = NSMenuItem()
        item.submenu = menu
        return item
    }

    private func makeEditMenuItem() -> NSMenuItem {
        let menu = NSMenu(title: MenuIdentifiers.editMenu)

        menu.addItem(withTitle: "Undo", action: #selector(UndoManager.undo), keyEquivalent: "z")
        menu.addItem(withTitle: "Redo", action: #selector(UndoManager.redo), keyEquivalent: "Z")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        menu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        menu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        menu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Find…", action: #selector(showFind), keyEquivalent: "f")

        let item = NSMenuItem()
        item.submenu = menu
        return item
    }

    private func makeViewMenuItem() -> NSMenuItem {
        let menu = NSMenu(title: MenuIdentifiers.viewMenu)

        let toggleSidebarItem = NSMenuItem(
            title: "Toggle Sidebar",
            action: #selector(toggleSidebar),
            keyEquivalent: "s"
        )
        toggleSidebarItem.keyEquivalentModifierMask = [.command, .control]
        menu.addItem(toggleSidebarItem)

        menu.addItem(.separator())

        let fullScreenItem = NSMenuItem(
            title: "Enter Full Screen",
            action: #selector(NSWindow.toggleFullScreen(_:)),
            keyEquivalent: "f"
        )
        fullScreenItem.keyEquivalentModifierMask = [.command, .control]
        menu.addItem(fullScreenItem)

        menu.addItem(.separator())
        menu.addItem(withTitle: "Bigger", action: #selector(increaseFontSize), keyEquivalent: "+")
        menu.addItem(withTitle: "Smaller", action: #selector(decreaseFontSize), keyEquivalent: "-")

        let item = NSMenuItem()
        item.submenu = menu
        return item
    }

    private func makeWindowMenuItem() -> NSMenuItem {
        let menu = NSMenu(title: MenuIdentifiers.windowMenu)

        menu.addItem(
            withTitle: "Minimize",
            action: #selector(NSWindow.performMiniaturize(_:)),
            keyEquivalent: "m"
        )
        menu.addItem(withTitle: "Zoom", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(
            withTitle: "Bring All to Front",
            action: #selector(NSApplication.arrangeInFront(_:)),
            keyEquivalent: ""
        )

        let item = NSMenuItem()
        item.submenu = menu
        return item
    }

    private func makeHelpMenuItem() -> NSMenuItem {
        let appName = ProcessInfo.processInfo.processName
        let menu = NSMenu(title: MenuIdentifiers.helpMenu)

        menu.addItem(
            withTitle: "\(appName) Help",
            action: #selector(NSApplication.showHelp(_:)),
            keyEquivalent: "?"
        )

        let item = NSMenuItem()
        item.submenu = menu
        return item
    }

    // MARK: - Menu Actions

    @objc private func showPreferences() {
        mainWindowController.showSettings()
    }

    @objc private func newSession() {
        mainWindowController.newSession()
    }

    @objc private func newSessionFromMenu(_ sender: NSMenuItem) {
        guard let request = sender.representedObject as? NewSessionRequest else { return }
        mainWindowController.newSession(kind: request.kind, accountHandle: request.accountHandle)
    }

    @objc private func addProject() {
        mainWindowController.addProject()
    }

    @objc private func closeSession() {
        mainWindowController.closeCurrentSession()
    }

    @objc private func toggleSidebar() {
        mainWindowController.toggleSidebar()
    }

    @objc private func showFind() {
        mainWindowController.showFind()
    }

    @objc private func increaseFontSize() {
        mainWindowController.increaseFontSize()
    }

    @objc private func decreaseFontSize() {
        mainWindowController.decreaseFontSize()
    }
}
