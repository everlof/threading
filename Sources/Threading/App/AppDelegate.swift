import AppKit
import ThreadingExtensionKit
import ThreadingRemoteKit

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuItemValidation {

    // MARK: - Singleton

    static var shared: AppDelegate {
        NSApp.delegate as! AppDelegate
    }

    // MARK: - Properties

    private var mainWindowController: MainWindowController!
    private var componentGalleryWindowController: ComponentGalleryWindowController?
    private var componentCustomizationRegistry: ComponentCustomizationRegistry?

    /// Whether this process won the single-instance lock and therefore owns the state.
    private var ownsSingleInstanceLock = false

    /// Whether the system, rather than the user, started this quit.
    ///
    /// `applicationShouldTerminate` is the same entry point for Cmd+Q and for a logout, restart
    /// or shutdown — and a modal on the second path is what makes macOS report "Threading
    /// prevented logout" and hand the user a dialog they did not ask for about an app they were
    /// not looking at. `willPowerOffNotification` arrives before the termination request, so the
    /// flag is set by the time the confirmation would go up. Read `NSWorkspace`'s own signal
    /// rather than the quit Apple Event's reason: the notification is one documented name, and
    /// getting the event's descriptor keywords subtly wrong fails silently in the direction of
    /// blocking a shutdown.
    private var isSystemInitiatedQuit = false

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

        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.willPowerOffNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.isSystemInitiatedQuit = true
        }

        // After the lock, so only the instance that owns the state writes the journal — and
        // early, because the first thing it reports is how the *previous* launch ended.
        EventLog.shared.beginLaunch()
        MacRemoteDiagnostics.record(.appLaunched, fields: [
            .protocolVersion: String(RemoteProtocol.current),
            .minimumProtocolVersion: String(RemoteProtocol.minimumSupported),
        ])

        // Before the first window is built, so everything is created already themed and nothing
        // has to be repainted at launch. `AppThemeRefresh` exists for the *later* changes.
        // Extension-contributed themes and fonts are pure package data, so they register first
        // — a restore that resolves a contributed theme must find it already in the library.
        ExtensionManager.shared.prepareAppearanceContributions()
        AppThemeLibrary.restore()
        AppThemeRefresh.startObservingAccessibilityDisplayOptions()
        AppThemeRefresh.startObservingSystemAppearance()
        AppThemeRefresh.startObservingFontOverrides()

        // After the restore, so the first Dock tile is the theme the user actually launched
        // into rather than System's for one frame.
        AppIconPresenter.install()

        setupMenuBar()

        // Optional MCP systems are installed at the composition root. The MCP server itself
        // knows only its replaceable provider seam and works unchanged when this remains nil.
        MCPExternalToolRegistry.shared.provider = ExtensionMCPToolProvider()
        installComponentCustomizationProvider()
        ExtensionIdentityResolverProviderSlot.shared.provider =
            ExtensionIdentityResolverRegistry.shared

        mainWindowController = MainWindowController()
        RemoteWorkspaceBridge.install(mainWindowController)
        mainWindowController.showWindow(nil)

        // After the window exists, so a clicked notification always has somewhere to land.
        // Never under tests: only `start()` touches `UNUserNotificationCenter`.
        AttentionAlertCenter.shared.start()
        ExtensionHostService.shared.installSessionRuntimeShellRootProvider {
            [weak mainWindowController] sessionID in
            mainWindowController?.extensionShellRootPid(for: sessionID)
        }

        // Installed extensions get a separate, tokenized host-data/service channel. It must be
        // ready before a host-capable process starts, because that process receives the
        // short-lived endpoint and bearer token only in its launch environment.
        if let componentCustomizationRegistry {
            ExtensionHostService.shared.start(
                registry: componentCustomizationRegistry,
                identityRegistry: .shared
            ) {
                ExtensionManager.shared.startEnabledExtensions()
            }
        } else {
            ExtensionManager.shared.startEnabledExtensions()
        }

        cleanupOrphanedHistoryFiles()
        StateManager.shared.clearLegacySessionState()

        // Fills empty icon slots in the background; it observes the store from here on, so
        // projects added later are swept as they appear.
        ProjectIconDiscovery.shared.start()

        // Keeps dormant sessions' branch records following their checkout. Started
        // unconditionally: it gates itself on the setting and re-checks on every change,
        // which is how toggling it on mid-run takes effect.
        CheckoutBranchFollower.shared.start()

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

        // Remote access is a separate loopback server behind a tunnel, independent of the MCP
        // listener — no ordering dependency, and it starts only if the user has turned it on.
        RemoteAccessCoordinator.shared.startIfEnabled()

        // The disk survey runs itself from here on, at background priority and on its own
        // delay — it is the least urgent thing the app does, and the Storage page is only ever
        // reading what it has already found.
        ArtifactScanService.shared.startPassiveScanning()

        // The code count too, on a much shorter leash: scc answers a repository in tens of
        // milliseconds, so its first pass does not need to wait out the launch.
        CodeStatsService.shared.startPassiveScanning()

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

        guard confirmQuitIfAgentsRunning() else { return .terminateCancel }

        // Projects are persisted by ProjectStore as they change, but a coalesced write may
        // still be pending, so it is flushed before the agents are torn down.
        ProjectStore.shared.flushPendingSave()
        AgentRuntime.shared.terminateAll()
        ExtensionManager.shared.terminateAll()
        // Stops the tunnel child and closes remote sockets before the listeners go, so nothing
        // spawned for remote access outlives the app.
        RemoteAccessCoordinator.shared.stop()
        ExtensionHostService.shared.stop()
        MCPServer.shared.stop()

        // Last, and only on this path: the marker it removes is what distinguishes a quit
        // from a launch that never came back.
        EventLog.shared.endLaunch()

        return .terminateNow
    }

    /// Whether the quit may go ahead.
    ///
    /// A session outliving its terminal is the app's premise, so quitting is nearer to closing
    /// a session than to deleting one: the conversations are kept and resume on the next launch,
    /// and only the turn in flight is lost. That is what makes the prompt suppressible, and it is
    /// also why it stays quiet when nothing is running — a confirmation on every quit would be
    /// asking about nothing most of the time, which is how a prompt teaches people to dismiss it.
    @MainActor
    private func confirmQuitIfAgentsRunning() -> Bool {
        guard !isSystemInitiatedQuit else { return true }

        let running = AgentRuntime.shared.runningSessionCount
        guard running > 0 else { return true }

        return ConfirmationAlert.ask(Self.quitConfirmation(runningSessionCount: running))
    }

    /// Built separately from being asked, so a test can hold the wording to what quitting does
    /// without a modal — the seam `SessionCoordinator`'s lifecycle requests already offer.
    static func quitConfirmation(runningSessionCount: Int) -> ConfirmationRequest {
        ConfirmationRequest(
            prompt: .quitWithRunningAgents,
            title: runningSessionCount == 1
                ? L10n.string("Quit with one agent still running?")
                : L10n.format("Quit with %lld agents still running?", Int64(runningSessionCount)),
            message: L10n.string(
                "Every running agent stops. The conversations are kept and can be resumed on "
                    + "the next launch; only what an agent is working on right now is lost."
            ),
            confirmTitle: L10n.string("Quit")
        )
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        // A hosted XCTest bundle runs inside the real application and creates short-lived
        // windows for rendering and chrome tests. Closing one must not terminate the host
        // process underneath whatever test XCTest scheduled next.
        if NSClassFromString("XCTestCase") != nil { return false }
        return true
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

    /// Brings a remotely selected dormant session back on its configured surface. Going
    /// through the window's ordinary selection path preserves the one-live-process invariant,
    /// but deliberately does not activate the app: a phone should not steal focus from whoever
    /// is using the Mac merely because it reopened a session.
    @MainActor
    func resumeRemoteSession(_ sessionID: SessionID) {
        guard ownsSingleInstanceLock,
              ProjectStore.shared.session(withID: sessionID) != nil else {
            return
        }
        mainWindowController.resumeRemoteSession(sessionID)
    }

    @MainActor
    func startRemoteSession(
        in projectID: ProjectID,
        kind: AgentKind,
        accountHandle: AccountHandle,
        model: String?,
        reasoningEffort: String?,
        usesNativeUI: Bool,
        prompt: String
    ) -> AgentSession? {
        guard ownsSingleInstanceLock, mainWindowController != nil else { return nil }
        return mainWindowController.startRemoteSession(
            in: projectID,
            kind: kind,
            accountHandle: accountHandle,
            model: model,
            reasoningEffort: reasoningEffort,
            usesNativeUI: usesNativeUI,
            prompt: prompt
        )
    }

    @MainActor
    func refreshAfterRemoteSessionMutation(sessionID: SessionID, archived: Bool) {
        guard ownsSingleInstanceLock, mainWindowController != nil else { return }
        mainWindowController.refreshAfterRemoteSessionMutation(
            sessionID: sessionID,
            archived: archived
        )
    }

    @MainActor
    func refreshAfterRemoteSurfaceMutation(sessionID: SessionID) {
        guard ownsSingleInstanceLock, mainWindowController != nil else { return }
        mainWindowController.refreshAfterRemoteSurfaceMutation(sessionID: sessionID)
    }

    // MARK: - Private Methods

    /// Installs the optional UI customization seam before the first sidebar row is built.
    ///
    /// The registry starts empty. The tokenized extension host service writes accepted process
    /// publications into it; tests and the Component Gallery use the same provider boundary
    /// without opening IPC.
    @MainActor
    private func installComponentCustomizationProvider() {
        let registry = ComponentCustomizationRegistry(selectionDefaults: .standard)
        do {
            for contract in HostComponentContracts.all {
                try registry.register(contract)
            }
        } catch {
            assertionFailure("Invalid host component contract: \(error)")
            ComponentCustomizationProviderSlot.shared.provider = nil
            return
        }

        componentCustomizationRegistry = registry
        ComponentCustomizationProviderSlot.shared.provider = registry
        ComponentCustomizationProviderSlot.shared.actionHandler = { action in
            ExtensionManager.shared.invokeComponentAction(action)
        }
    }

    private func presentAlreadyRunningAlert() {
        let alert = NSAlert()
        alert.messageText = L10n.string("Threading is already running")
        alert.informativeText = L10n.string("""
            Another Threading is open and owns the session state. Running two at once would \
            silently overwrite each other's projects, so this one will quit.
            """)
        alert.alertStyle = .warning
        alert.runModal()
    }

    /// Removes history files belonging to sessions that no longer exist.
    @MainActor
    private func cleanupOrphanedHistoryFiles() {
        // An empty project list caused by a failed load is not evidence that every history
        // file is orphaned. Preserve all histories for this launch so recovery stays possible.
        guard ProjectStore.shared.didLoadStateSuccessfully else {
            ThreadingLogger.agent.error(
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

    /// The menu items whose key equivalent comes from `CommandRegistry`, kept so a rebinding can be
    /// applied to them directly.
    ///
    /// Re-applying beats rebuilding the menu bar: `setupMenuBar` also re-points `NSApp.windowsMenu`
    /// and `NSApp.helpMenu`, and running all of that again to change one character is both more
    /// work and more ways to be wrong.
    private var commandItems: [String: NSMenuItem] = [:]
    private var extensionMenu: NSMenu?
    private var projectExtensionSeparator: NSMenuItem?
    private var projectExtensionItem: NSMenuItem?
    private var viewExtensionSeparator: NSMenuItem?
    private var viewExtensionItem: NSMenuItem?

    /// Holds the shortcut-change subscription for the process lifetime.
    private let menuEvents = AppEventObservations()

    /// Builds a menu item that takes its shortcut from the command table instead of a literal.
    private func commandItem(_ id: String, action: Selector) -> NSMenuItem {
        guard let command = CommandRegistry.shared.command(id: id) else {
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
            guard let command = CommandRegistry.shared.command(id: id) else { continue }
            apply(ShortcutOverrideStore.shared.shortcut(for: command), to: item)
        }
    }

    /// Internal so the hosted app tests can verify the real AppKit menu tree. Production calls
    /// this exactly once during launch.
    func setupMenuBar() {
        let mainMenu = NSMenu()

        mainMenu.addItem(makeApplicationMenuItem())
        mainMenu.addItem(makeProjectMenuItem())
        mainMenu.addItem(makeEditMenuItem())
        mainMenu.addItem(makeViewMenuItem())
        mainMenu.addItem(makeExtensionsMenuItem())

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
        menuEvents.observe(CommandRegistryDidChange.self) { [weak self] _ in
            self?.rebuildExtensionMenus()
        }
    }

    private func makeExtensionsMenuItem() -> NSMenuItem {
        let menu = NSMenu(title: L10n.string("Extensions"))
        extensionMenu = menu
        rebuildExtensionMenus()

        let item = NSMenuItem()
        item.title = L10n.string("Extensions")
        item.submenu = menu
        return item
    }

    /// Rebuilds only the dynamic menu. The Window and Help menu identities remain untouched.
    private func rebuildExtensionMenus() {
        guard let menu = extensionMenu else { return }
        menu.removeAllItems()
        for id in Array(commandItems.keys) where id.hasPrefix("extension.") {
            commandItems.removeValue(forKey: id)
        }

        let allCommands = CommandRegistry.shared.extensionCommands
        populate(
            menu,
            commands: allCommands,
            placement: .extensions
        )
        populate(
            projectExtensionItem?.submenu,
            commands: allCommands,
            placement: .project
        )
        populate(
            viewExtensionItem?.submenu,
            commands: allCommands,
            placement: .view
        )

        let hasVisibleCommands = !menu.items.isEmpty
        if !hasVisibleCommands {
            let empty = NSMenuItem(
                title: L10n.string("No Extension Commands Here"),
                action: nil,
                keyEquivalent: ""
            )
            empty.isEnabled = false
            menu.addItem(empty)
        }

        updatePlacementVisibility(
            item: projectExtensionItem,
            separator: projectExtensionSeparator
        )
        updatePlacementVisibility(
            item: viewExtensionItem,
            separator: viewExtensionSeparator
        )

        // A command may deliberately omit every menu-bar placement — no placements at all,
        // or row placements only — and still receive a user-assigned shortcut. AppKit
        // dispatches key equivalents through menu items, so retain one hidden host-owned
        // item instead of installing a global event monitor.
        for command in allCommands
            where ExtensionCommandMenuLayout.needsHiddenShortcutCarrier(command) {
            let item = extensionCommandMenuItem(command, bindsShortcut: true)
            item.isHidden = true
            item.allowsKeyEquivalentWhenHidden = true
            menu.addItem(item)
        }
    }

    private func populate(
        _ menu: NSMenu?,
        commands: [AppCommand],
        placement: ExtensionMenuPlacement
    ) {
        guard let menu else { return }
        menu.removeAllItems()

        for group in ExtensionCommandMenuLayout.groups(
            commands: commands,
            placement: placement
        ) {
            let submenu = NSMenu(title: group.extensionName)
            for command in group.commands {
                submenu.addItem(extensionCommandMenuItem(
                    command,
                    bindsShortcut:
                        ExtensionCommandMenuLayout.canonicalPlacement(for: command)
                            == placement
                ))
            }

            let groupItem = NSMenuItem()
            groupItem.title = group.extensionName
            groupItem.submenu = submenu
            menu.addItem(groupItem)
        }
    }

    private func updatePlacementVisibility(
        item: NSMenuItem?,
        separator: NSMenuItem?
    ) {
        let isVisible = item?.submenu?.items.isEmpty == false
        item?.isHidden = !isVisible
        separator?.isHidden = !isVisible
    }

    private func extensionCommandMenuItem(
        _ command: AppCommand,
        bindsShortcut: Bool
    ) -> NSMenuItem {
        let item = NSMenuItem(
            title: command.title,
            action: #selector(performExtensionCommand(_:)),
            keyEquivalent: ""
        )
        item.target = self
        item.representedObject = command.id
        if bindsShortcut {
            apply(ShortcutOverrideStore.shared.shortcut(for: command), to: item)
            commandItems[command.id] = item
        }
        return item
    }

    private func makeApplicationMenuItem() -> NSMenuItem {
        let appName = ProcessInfo.processInfo.processName
        let menu = NSMenu()

        menu.addItem(
            withTitle: L10n.format("About %@", appName),
            action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)),
            keyEquivalent: ""
        )
        menu.addItem(.separator())
        menu.addItem(
            withTitle: L10n.string("Preferences…"),
            action: #selector(showPreferences),
            keyEquivalent: ","
        )
        menu.addItem(.separator())
        menu.addItem(
            withTitle: L10n.format("Hide %@", appName),
            action: #selector(NSApplication.hide(_:)),
            keyEquivalent: "h"
        )

        let hideOthersItem = NSMenuItem(
            title: L10n.string("Hide Others"),
            action: #selector(NSApplication.hideOtherApplications(_:)),
            keyEquivalent: "h"
        )
        hideOthersItem.keyEquivalentModifierMask = [.command, .option]
        menu.addItem(hideOthersItem)

        menu.addItem(
            withTitle: L10n.string("Show All"),
            action: #selector(NSApplication.unhideAllApplications(_:)),
            keyEquivalent: ""
        )
        menu.addItem(.separator())
        menu.addItem(
            withTitle: L10n.format("Quit %@", appName),
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
        menu.addItem(commandItem(AppCommands.ID.closeTab, action: #selector(closeActiveTab)))
        menu.addItem(commandItem(AppCommands.ID.closeSession, action: #selector(closeSession)))

        let extensionSeparator = NSMenuItem.separator()
        extensionSeparator.isHidden = true
        menu.addItem(extensionSeparator)
        projectExtensionSeparator = extensionSeparator

        let extensionItem = NSMenuItem()
        extensionItem.title = L10n.string("Extensions")
        extensionItem.submenu = NSMenu(title: L10n.string("Project Extensions"))
        extensionItem.isHidden = true
        menu.addItem(extensionItem)
        projectExtensionItem = extensionItem

        let item = NSMenuItem()
        item.submenu = menu
        return item
    }

    private func makeEditMenuItem() -> NSMenuItem {
        let menu = NSMenu(title: MenuIdentifiers.editMenu)

        menu.addItem(withTitle: L10n.string("Undo"), action: #selector(UndoManager.undo), keyEquivalent: "z")
        menu.addItem(withTitle: L10n.string("Redo"), action: #selector(UndoManager.redo), keyEquivalent: "Z")
        menu.addItem(.separator())
        menu.addItem(withTitle: L10n.string("Cut"), action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        menu.addItem(withTitle: L10n.string("Copy"), action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        menu.addItem(withTitle: L10n.string("Paste"), action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        menu.addItem(withTitle: L10n.string("Select All"), action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        menu.addItem(.separator())
        menu.addItem(commandItem(AppCommands.ID.find, action: #selector(showFind)))

        let item = NSMenuItem()
        item.submenu = menu
        return item
    }

    private func makeViewMenuItem() -> NSMenuItem {
        let menu = NSMenu(title: MenuIdentifiers.viewMenu)

        menu.addItem(commandItem(AppCommands.ID.toggleSidebar, action: #selector(toggleSidebar)))

        // Selection history — the toolbar's < > pair, on Xcode's chords. Enablement is
        // stamped in `validateMenuItem`, since a Back with nowhere to go should read that way.
        menu.addItem(commandItem(AppCommands.ID.navigateBack, action: #selector(navigateBack)))
        menu.addItem(commandItem(AppCommands.ID.navigateForward, action: #selector(navigateForward)))

        // The sidebar's own arrangement, beside its toggle: what the list groups and how it
        // sorts are View concerns, and the two toggles need a home a shortcut can live in.
        // Their checkmarks are stamped in `validateMenuItem`, which AppKit asks on every open.
        menu.addItem(commandItem(AppCommands.ID.groupByBranch, action: #selector(toggleBranchGrouping)))
        menu.addItem(commandItem(AppCommands.ID.loneBranchHeadings, action: #selector(toggleLoneBranchHeadings)))

        menu.addItem(.separator())

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
            title: L10n.string("Enter Full Screen"),
            action: #selector(NSWindow.toggleFullScreen(_:)),
            keyEquivalent: "f"
        )
        fullScreenItem.keyEquivalentModifierMask = [.command, .control]
        menu.addItem(fullScreenItem)

        menu.addItem(.separator())
        menu.addItem(commandItem(AppCommands.ID.biggerText, action: #selector(increaseFontSize)))
        menu.addItem(commandItem(AppCommands.ID.smallerText, action: #selector(decreaseFontSize)))

        menu.addItem(.separator())

        // Tab traversal, wherever tabs are: the commands land on the focused tab host.
        menu.addItem(commandItem(AppCommands.ID.previousTab, action: #selector(selectPreviousTab)))
        menu.addItem(commandItem(AppCommands.ID.nextTab, action: #selector(selectNextTab)))

        // ⌘1–⌘9 ride hidden items: AppKit dispatches key equivalents through menu items, and
        // nine visible rows would say little a strip does not already show. Same carrier trick
        // the extension commands use.
        for number in AppCommands.ID.selectTabNumbers {
            let item = commandItem(
                AppCommands.ID.selectTab(number),
                action: #selector(selectTabByNumber(_:))
            )
            item.tag = number
            item.isHidden = true
            item.allowsKeyEquivalentWhenHidden = true
            menu.addItem(item)
        }

        menu.addItem(.separator())

        // ⌥⌘I — the browser devtools shortcut, for the same gesture: point at the thing on
        // screen and get something you can paste into a conversation about it. The shifted
        // variant is the freeflow twin; invoking one while the other is active switches mode.
        menu.addItem(commandItem(AppCommands.ID.inspectElement, action: #selector(inspectElement)))
        menu.addItem(commandItem(AppCommands.ID.inspectGeometry, action: #selector(inspectPoint)))

        let extensionSeparator = NSMenuItem.separator()
        extensionSeparator.isHidden = true
        menu.addItem(extensionSeparator)
        viewExtensionSeparator = extensionSeparator

        let extensionItem = NSMenuItem()
        extensionItem.title = L10n.string("Extensions")
        extensionItem.submenu = NSMenu(title: L10n.string("View Extensions"))
        extensionItem.isHidden = true
        menu.addItem(extensionItem)
        viewExtensionItem = extensionItem

        let item = NSMenuItem()
        item.submenu = menu
        return item
    }

    private func makeWindowMenuItem() -> NSMenuItem {
        let menu = NSMenu(title: MenuIdentifiers.windowMenu)

        menu.addItem(
            withTitle: L10n.string("Minimize"),
            action: #selector(NSWindow.performMiniaturize(_:)),
            keyEquivalent: "m"
        )
        menu.addItem(
            withTitle: L10n.string("Zoom"),
            action: #selector(NSWindow.performZoom(_:)),
            keyEquivalent: ""
        )
        menu.addItem(.separator())
        menu.addItem(
            withTitle: L10n.string("Bring All to Front"),
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
            withTitle: L10n.format("%@ Help", appName),
            action: #selector(NSApplication.showHelp(_:)),
            keyEquivalent: "?"
        )

        menu.addItem(.separator())

        let reportItem = NSMenuItem(
            title: L10n.string("Create Remote Support Report…"),
            action: #selector(createRemoteSupportReport),
            keyEquivalent: ""
        )
        reportItem.target = self
        menu.addItem(reportItem)

        let logItem = NSMenuItem(
            title: L10n.string("Reveal Diagnostics Log"),
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

    @MainActor @objc private func performExtensionCommand(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String,
              let command = CommandRegistry.shared.command(id: id),
              case .extensionCommand = command.origin,
              commandIsAvailable(command) else {
            return
        }

        // Lowercased to match the sanitized snapshot IDs an extension already holds —
        // context and snapshots must name the same entity with the same token.
        let context = ExtensionCommandContext(
            projectID: mainWindowController?.currentProjectID?.uuidString.lowercased(),
            sessionID: mainWindowController?.currentSessionID?.uuidString.lowercased()
        )
        ExtensionCommandInvoker.perform(
            command,
            context: context,
            window: mainWindowController?.window
        )
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        // The arrangement toggles carry state, so their checks are stamped here — validation
        // runs on every menu open, which is the one moment the check has to be true.
        if menuItem.action == #selector(toggleBranchGrouping) {
            menuItem.state = AppSettings.shared.groupsSessionsByBranch ? .on : .off
            return true
        }
        if menuItem.action == #selector(toggleLoneBranchHeadings) {
            menuItem.state = AppSettings.shared.groupsLoneBranches ? .on : .off
            // The refinement has nothing to refine while grouping is off.
            return AppSettings.shared.groupsSessionsByBranch
        }
        if menuItem.action == #selector(navigateBack) {
            return mainWindowController?.canGoBack ?? false
        }
        if menuItem.action == #selector(navigateForward) {
            return mainWindowController?.canGoForward ?? false
        }

        guard menuItem.action == #selector(performExtensionCommand(_:)),
              let id = menuItem.representedObject as? String,
              let command = CommandRegistry.shared.command(id: id) else {
            return true
        }
        return commandIsAvailable(command)
    }

    private func commandIsAvailable(_ command: AppCommand) -> Bool {
        switch command.scope {
        case .application:
            return true
        case .project:
            return mainWindowController?.currentProjectID != nil
        case .session:
            return mainWindowController?.currentSessionID != nil
        }
    }

    // MARK: - Menu Actions

    /// Every action below routes through `mainWindowController?`, deliberately.
    ///
    /// Two processes run a real `NSApplication` with this delegate and never build a window: a
    /// hosted test bundle, and a second instance that lost the single-instance lock. A command
    /// arriving in either — a menu item validated a moment early, a key equivalent, a test that
    /// pumps the run loop — has *nothing to act on*, and the honest answer to that is to do
    /// nothing. It used to be a trap, which is how the same force-unwrap in
    /// `applicationShouldHandleReopen` took a test run down.
    @objc private func showPreferences() {
        mainWindowController?.toggleSettingsFromCommand()
    }

    @objc private func openTerminalTab() {
        mainWindowController?.showTerminalTab()
    }

    @objc private func closeActiveTab() {
        mainWindowController?.closeActiveTab()
    }

    @objc private func navigateBack() {
        mainWindowController?.goBack()
    }

    @objc private func navigateForward() {
        mainWindowController?.goForward()
    }

    @objc private func selectPreviousTab() {
        mainWindowController?.selectAdjacentTab(offset: -1)
    }

    @objc private func selectNextTab() {
        mainWindowController?.selectAdjacentTab(offset: 1)
    }

    @objc private func selectTabByNumber(_ sender: NSMenuItem) {
        mainWindowController?.selectTab(atIndex: sender.tag - 1)
    }

    @objc private func openFilesTab() {
        mainWindowController?.showFilesTab()
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

    /// Creates the share-safe report, not a copy of the owner-local journal. The latter may
    /// contain prompts, commands and paths and remains available separately for local diagnosis.
    /// The grants are read first because two of them arrive through a callback, and a report
    /// missing the notification row is missing the answer to the most common question about it.
    @MainActor @objc private func createRemoteSupportReport() {
        SystemPrivacyStatusReader().load { [weak self] statuses in
            self?.writeSupportReport(privacyStatuses: statuses)
        }
    }

    @MainActor
    private func writeSupportReport(
        privacyStatuses: [SystemPrivacyPermission: SystemPrivacyStatus]
    ) {
        let projects = ProjectStore.shared.projects
        let extensions = ExtensionManager.shared.installedExtensions
        let accounts = AgentKind.allCases.reduce(into: [String: Int]()) { counts, kind in
            counts[kind.rawValue] = AgentAccountDiscovery.allAccounts(for: kind).count
        }

        let details = MacSupportReportDetails(
            privacyStatuses: privacyStatuses,
            remoteAccessEnabled: AppSettings.shared.remoteAccessEnabled,
            appThemeID: AppThemeLibrary.current.id.rawValue,
            projectCount: projects.count,
            sessionCount: projects.reduce(0) { $0 + $1.sessions.count },
            extensionCount: extensions.count,
            companionCount: extensions.reduce(0) { $0 + $1.companions.count },
            agentAccounts: accounts,
            previousLaunchWasClean: EventLog.shared.previousLaunchEndedCleanly
        )

        do {
            let report = try MacRemoteDiagnostics.supportReport(
                additionalDetails: details.fields
            )
            NSWorkspace.shared.activateFileViewerSelecting([report])
        } catch {
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = L10n.string("Couldn’t create support report")
            alert.informativeText = L10n.string(
                "Threading could not prepare the remote diagnostics file."
            )
            alert.addButton(withTitle: L10n.string("OK"))
            alert.runModal()
        }
    }

    @objc private func openBrowser() {
        mainWindowController?.showBrowser()
    }

    @objc private func openReview() {
        mainWindowController?.showReview()
    }

    @objc private func openInfo() {
        mainWindowController?.showInfo()
    }

    @objc private func toggleShell() {
        mainWindowController?.toggleShellDrawer()
    }

    @objc private func toggleDisplayPanel() {
        mainWindowController?.toggleDisplayPane()
    }

    @objc private func showComponentGallery() {
        let controller = componentGalleryWindowController ?? ComponentGalleryWindowController()
        componentGalleryWindowController = controller
        controller.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func newSession() {
        mainWindowController?.newSession()
    }

    @objc private func addProject() {
        mainWindowController?.addProject()
    }

    @objc private func newProject() {
        mainWindowController?.newProject()
    }

    @objc private func closeSession() {
        mainWindowController?.closeCurrentSession()
    }

    @objc private func toggleSidebar() {
        mainWindowController?.toggleSidebar()
    }

    // The two sidebar-arrangement toggles act on settings, not on the window, so they work
    // even before a window exists — and they post `ProjectsDidChange` because that is what
    // the sidebar rebuilds its tree on, the same route its own menus take.
    @MainActor @objc private func toggleBranchGrouping() {
        AppSettings.shared.groupsSessionsByBranch.toggle()
        NotificationCenter.default.post(ProjectsDidChange())
    }

    @MainActor @objc private func toggleLoneBranchHeadings() {
        AppSettings.shared.groupsLoneBranches.toggle()
        NotificationCenter.default.post(ProjectsDidChange())
    }

    @objc private func showFind() {
        mainWindowController?.showFind()
    }

    @objc private func inspectElement() {
        mainWindowController?.toggleElementInspector(mode: .element)
    }

    @objc private func inspectPoint() {
        mainWindowController?.toggleElementInspector(mode: .freeflow)
    }

    @objc private func increaseFontSize() {
        mainWindowController?.increaseFontSize()
    }

    @objc private func decreaseFontSize() {
        mainWindowController?.decreaseFontSize()
    }
}
