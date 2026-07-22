import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {

    // MARK: - Singleton

    static var shared: AppDelegate {
        NSApp.delegate as! AppDelegate
    }

    // MARK: - Properties

    private var mainWindowController: MainWindowController!

    /// Whether this process won the single-instance lock and therefore owns the state.
    private var ownsSingleInstanceLock = false

    // MARK: - NSApplicationDelegate

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Unit tests host their bundle in this app, so `main()` runs before them. Skip the real
        // startup then: the tests exercise types directly and must not spawn agents, start the MCP
        // server, or touch the user's stores.
        if NSClassFromString("XCTestCase") != nil { return }

        // Before anything can touch the stores: a second instance must never get far enough
        // to write projects.json, or the two silently overwrite each other's state.
        guard SingleInstanceLock.acquire() else {
            presentAlreadyRunningAlert()
            NSApp.terminate(nil)
            return
        }
        ownsSingleInstanceLock = true

        // After the lock, so only the instance that owns the state writes the journal — and
        // early, because the first thing it reports is how the *previous* launch ended.
        EventLog.shared.beginLaunch()

        setupMenuBar()

        mainWindowController = MainWindowController()
        mainWindowController.showWindow(nil)

        cleanupOrphanedHistoryFiles()
        StateManager.shared.clearLegacySessionState()

        // Fills empty icon slots in the background; it observes the store from here on, so
        // projects added later are swept as they appear.
        ProjectIconDiscovery.shared.start()

        // One throttled sweep, so the first account menu opened in a launch already carries
        // each login's usage rather than filling in only on a second look.
        AccountUsageMenu.prefetch()

        // Session restore waits for the listener, because a launch reads the port to build the
        // session's `--mcp-config`. The callback runs whether the server came up or not, so a
        // failed listener costs the restored session its display panel and nothing else.
        MCPServer.shared.handler = mainWindowController
        mainWindowController.installPermissionPresenter()

        // Installed here rather than on the window, because a lifecycle report is about a
        // running session and stays meaningful whether or not anything is showing it.
        HookLifecycleRelay.observe = { report in
            AgentRuntime.shared.applyLifecycle(report)
        }

        MCPServer.shared.start { [weak self] in
            self?.mainWindowController.restoreSelectedSession()
        }

        // The disk survey runs itself from here on, at background priority and on its own
        // delay — it is the least urgent thing the app does, and the Storage page is only ever
        // reading what it has already found.
        ArtifactScanService.shared.startPassiveScanning()
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        // A lock-losing instance quits without touching the stores: even *instantiating*
        // ProjectStore writes projects.json once, which is the exact clobber the lock exists
        // to prevent.
        guard ownsSingleInstanceLock else { return .terminateNow }

        // Projects are persisted by ProjectStore as they change, but a coalesced write may
        // still be pending, so it is flushed before the agents are torn down.
        ProjectStore.shared.flushPendingSave()
        AgentRuntime.shared.terminateAll()
        MCPServer.shared.stop()

        // Last, and only on this path: the marker it removes is what distinguishes a quit
        // from a launch that never came back.
        EventLog.shared.endLaunch()

        return .terminateNow
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
        true
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        // There is a window only in an instance that actually started up — and two that never
        // do still run a real `NSApplication` with a real delegate: a hosted test bundle, and a
        // second instance that lost the single-instance lock. The system sends this whenever the
        // Dock icon is clicked, so the force-unwrap that used to be here was a crash waiting for
        // a click. It found one, in the middle of a test run that was pumping the main run loop.
        guard let mainWindowController else { return true }

        if !flag {
            mainWindowController.showWindow(nil)
        }
        return true
    }

    /// Folders dropped on the app icon are added as projects.
    func application(_ application: NSApplication, open urls: [URL]) {
        // Same reachability, worse consequence: *instantiating* `ProjectStore` writes
        // projects.json, which is the exact clobber the lock exists to prevent — so an instance
        // that does not own the state does not adopt folders into it either.
        guard ownsSingleInstanceLock else { return }

        for url in urls {
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
                  isDirectory.boolValue else { continue }

            ProjectStore.shared.addProject(folderURL: url)
        }
    }

    // MARK: - Private Methods

    private func presentAlreadyRunningAlert() {
        let alert = NSAlert()
        alert.messageText = "Skalman is already running"
        alert.informativeText = """
            Another Skalman is open and owns the session state. Running two at once would \
            silently overwrite each other's projects, so this one will quit.
            """
        alert.alertStyle = .warning
        alert.runModal()
    }

    /// Removes history files belonging to sessions that no longer exist.
    @MainActor
    private func cleanupOrphanedHistoryFiles() {
        // An empty project list caused by a failed load is not evidence that every history
        // file is orphaned. Preserve all histories for this launch so recovery stays possible.
        guard ProjectStore.shared.didLoadStateSuccessfully else {
            SkalmanLogger.agent.error(
                "Skipping orphaned history cleanup because project state failed to load"
            )
            return
        }

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

        // Opens the project's composer rather than creating anything: agent, account, model
        // and checkout are chosen there. The per-agent entries that used to sit here answered
        // all four silently, which is the friction this menu should not remove.
        menu.addItem(withTitle: "New Session", action: #selector(newSession), keyEquivalent: "n")

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

        let browserItem = NSMenuItem(
            title: "Browser",
            action: #selector(openBrowser),
            keyEquivalent: "b"
        )
        browserItem.keyEquivalentModifierMask = [.command, .shift]
        menu.addItem(browserItem)

        // ⇧⌘R, deliberately not ⇧⌘G — that is the platform's Find Previous.
        let reviewItem = NSMenuItem(
            title: "Git Review",
            action: #selector(openReview),
            keyEquivalent: "r"
        )
        reviewItem.keyEquivalentModifierMask = [.command, .shift]
        menu.addItem(reviewItem)

        // ⌃` — the shortcut every editor with a terminal drawer uses, and free here because
        // ⌘` is the platform's cycle-windows.
        let shellItem = NSMenuItem(title: "Shell", action: #selector(toggleShell), keyEquivalent: "`")
        shellItem.keyEquivalentModifierMask = [.control]
        menu.addItem(shellItem)

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

        menu.addItem(.separator())

        let logItem = NSMenuItem(
            title: "Reveal Diagnostics Log",
            action: #selector(revealDiagnosticsLog),
            keyEquivalent: ""
        )
        logItem.target = self
        menu.addItem(logItem)

        let item = NSMenuItem()
        item.submenu = menu
        return item
    }

    // MARK: - Menu Actions

    @objc private func showPreferences() {
        mainWindowController.showSettings()
    }

    /// Reveals today's journal rather than opening it: `.jsonl` has no owning app, and what
    /// is usually wanted is the folder, where the previous days sit alongside it.
    @objc private func revealDiagnosticsLog() {
        let journal = EventLog.shared.currentJournalURL

        guard FileManager.default.fileExists(atPath: journal.path) else {
            NSWorkspace.shared.open(EventLog.shared.directory)
            return
        }

        NSWorkspace.shared.activateFileViewerSelecting([journal])
    }

    @objc private func openBrowser() {
        mainWindowController.showBrowser()
    }

    @objc private func openReview() {
        mainWindowController.showReview()
    }

    @objc private func toggleShell() {
        mainWindowController.toggleShellDrawer()
    }

    @objc private func newSession() {
        mainWindowController.newSession()
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
