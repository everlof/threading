import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {

    // MARK: - Singleton

    static var shared: AppDelegate {
        NSApp.delegate as! AppDelegate
    }

    // MARK: - Properties

    private var mainWindowController: MainWindowController!
    private var componentGalleryWindowController: ComponentGalleryWindowController?

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

        // Before the first window is built, so everything is created already themed and nothing
        // has to be repainted at launch. `AppThemeRefresh` exists for the *later* changes.
        AppThemeLibrary.restore()
        AppThemeRefresh.startObservingAccessibilityDisplayOptions()

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

        // The same idea for *who* each login is. Only accounts whose address is not already on
        // disk are asked, and the answer is cached across launches, so this is normally a
        // no-op — the default Claude login is the one it exists for.
        AccountEmailProbe.prefetch(AgentAccountDiscovery.accounts(for: .claude)) {
            NotificationCenter.default.post(AccountPreferencesDidChange())
        }

        // Session restore waits for the listener, because a launch reads the port to build the
        // session's `--mcp-config`. The callback runs whether the server came up or not, so a
        // failed listener costs the restored session its display panel and nothing else.
        MCPServer.shared.handler = mainWindowController.agentToolCoordinator
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

        // Replaces names the old agent-name scheme left behind ("Claude Code 2") with what
        // the transcripts still hold. Idempotent: a backfilled session no longer carries a
        // placeholder title, so later launches skip it without reading anything.
        SessionNaming.backfillLegacyNames()
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

    // MARK: - Command Bindings

    /// The menu items whose key equivalent comes from `AppCommands`, kept so a rebinding can be
    /// applied to them directly.
    ///
    /// Re-applying beats rebuilding the menu bar: `setupMenuBar` also re-points `NSApp.windowsMenu`
    /// and `NSApp.helpMenu`, and running all of that again to change one character is both more
    /// work and more ways to be wrong.
    private var commandItems: [String: NSMenuItem] = [:]

    /// Holds the shortcut-change subscription for the process lifetime.
    private let menuEvents = AppEventObservations()

    /// Builds a menu item that takes its shortcut from the command table instead of a literal.
    private func commandItem(_ id: String, action: Selector) -> NSMenuItem {
        guard let command = AppCommands.command(id: id) else {
            return NSMenuItem(title: id, action: action, keyEquivalent: "")
        }

        let item = NSMenuItem(title: command.title, action: action, keyEquivalent: "")
        apply(ShortcutOverrideStore.shared.shortcut(for: command), to: item)
        commandItems[id] = item
        return item
    }

    private func apply(_ shortcut: KeyboardShortcut?, to item: NSMenuItem) {
        item.keyEquivalent = shortcut?.key ?? ""
        item.keyEquivalentModifierMask = shortcut?.modifiers ?? []
    }

    /// Re-reads every bound item. Called on the change event, so a shortcut edited in Settings
    /// works immediately rather than after a relaunch.
    func applyShortcutBindings() {
        for (id, item) in commandItems {
            guard let command = AppCommands.command(id: id) else { continue }
            apply(ShortcutOverrideStore.shared.shortcut(for: command), to: item)
        }
    }

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

        // The menu is built once, so a rebinding has to be pushed into the items that already
        // exist — otherwise a shortcut changed in Settings would not work until the next launch.
        menuEvents.observe(KeyboardShortcutsDidChange.self) { [weak self] _ in
            self?.applyShortcutBindings()
        }
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
        menu.addItem(commandItem(AppCommands.ID.newSession, action: #selector(newSession)))

        menu.addItem(.separator())

        // Two ways to a project, matching the sidebar's `+` menu: create the folder, or
        // adopt one that exists. Add Project keeps its shortcut and its meaning.
        menu.addItem(commandItem(AppCommands.ID.newProject, action: #selector(newProject)))
        menu.addItem(commandItem(AppCommands.ID.addProject, action: #selector(addProject)))

        menu.addItem(.separator())
        menu.addItem(commandItem(AppCommands.ID.closeSession, action: #selector(closeSession)))

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
        menu.addItem(commandItem(AppCommands.ID.find, action: #selector(showFind)))

        let item = NSMenuItem()
        item.submenu = menu
        return item
    }

    private func makeViewMenuItem() -> NSMenuItem {
        let menu = NSMenu(title: MenuIdentifiers.viewMenu)

        menu.addItem(commandItem(AppCommands.ID.toggleSidebar, action: #selector(toggleSidebar)))

        // The display pane's family. Their defaults live in `AppCommands`, which is also where
        // the reasoning for each now sits — ⇧⌘R rather than ⇧⌘G (the platform's Find Previous),
        // ⇧⌘I rather than ⌘I (Get Info) or ⌥⌘I (the element inspector), and ⌃` for the shell,
        // free because ⌘` is the platform's cycle-windows.
        menu.addItem(commandItem(AppCommands.ID.newTerminalTab, action: #selector(openTerminalTab)))
        menu.addItem(commandItem(AppCommands.ID.browser, action: #selector(openBrowser)))
        menu.addItem(commandItem(AppCommands.ID.files, action: #selector(openFilesTab)))
        menu.addItem(commandItem(AppCommands.ID.review, action: #selector(openReview)))
        menu.addItem(commandItem(AppCommands.ID.sessionInfo, action: #selector(openInfo)))
        menu.addItem(commandItem(AppCommands.ID.shell, action: #selector(toggleShell)))
        menu.addItem(commandItem(AppCommands.ID.displayPanel, action: #selector(toggleDisplayPanel)))

        menu.addItem(.separator())

        menu.addItem(commandItem(AppCommands.ID.componentGallery, action: #selector(showComponentGallery)))

        menu.addItem(.separator())

        let fullScreenItem = NSMenuItem(
            title: "Enter Full Screen",
            action: #selector(NSWindow.toggleFullScreen(_:)),
            keyEquivalent: "f"
        )
        fullScreenItem.keyEquivalentModifierMask = [.command, .control]
        menu.addItem(fullScreenItem)

        menu.addItem(.separator())
        menu.addItem(commandItem(AppCommands.ID.biggerText, action: #selector(increaseFontSize)))
        menu.addItem(commandItem(AppCommands.ID.smallerText, action: #selector(decreaseFontSize)))

        menu.addItem(.separator())

        // ⌥⌘I — the browser devtools shortcut, for the same gesture: point at the thing on
        // screen and get something you can paste into a conversation about it. The shifted
        // variant is the freeflow twin; invoking one while the other is active switches mode.
        menu.addItem(commandItem(AppCommands.ID.inspectElement, action: #selector(inspectElement)))
        menu.addItem(commandItem(AppCommands.ID.inspectGeometry, action: #selector(inspectPoint)))

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

    @objc private func openTerminalTab() {
        mainWindowController.showTerminalTab()
    }

    @objc private func openFilesTab() {
        mainWindowController.showFilesTab()
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

    @objc private func openInfo() {
        mainWindowController.showInfo()
    }

    @objc private func toggleShell() {
        mainWindowController.toggleShellDrawer()
    }

    @objc private func toggleDisplayPanel() {
        mainWindowController.toggleDisplayPane()
    }

    @objc private func showComponentGallery() {
        let controller = componentGalleryWindowController ?? ComponentGalleryWindowController()
        componentGalleryWindowController = controller
        controller.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func newSession() {
        mainWindowController.newSession()
    }

    @objc private func addProject() {
        mainWindowController.addProject()
    }

    @objc private func newProject() {
        mainWindowController.newProject()
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

    @objc private func inspectElement() {
        mainWindowController.toggleElementInspector(mode: .element)
    }

    @objc private func inspectPoint() {
        mainWindowController.toggleElementInspector(mode: .freeflow)
    }

    @objc private func increaseFontSize() {
        mainWindowController.increaseFontSize()
    }

    @objc private func decreaseFontSize() {
        mainWindowController.decreaseFontSize()
    }
}
