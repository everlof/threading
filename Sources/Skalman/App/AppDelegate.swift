import AppKit
import UniformTypeIdentifiers

final class AppDelegate: NSObject, NSApplicationDelegate {

    // MARK: - Singleton

    static var shared: AppDelegate {
        NSApp.delegate as! AppDelegate
    }

    // MARK: - Properties

    private var windowControllers: [TerminalWindowController] = []

    /// The currently active workspace ID, if any.
    private var activeWorkspaceID: UUID?

    private var activeWindowController: TerminalWindowController? {
        // Get the window controller for the currently active window
        guard let keyWindow = NSApp.keyWindow else { return windowControllers.first }
        return windowControllers.first { $0.window === keyWindow }
    }

    // MARK: - Window Controller Management

    func addWindowController(_ controller: TerminalWindowController) {
        guard !windowControllers.contains(where: { $0 === controller }) else { return }
        windowControllers.append(controller)
    }

    func removeWindowController(_ controller: TerminalWindowController) {
        windowControllers.removeAll { $0 === controller }
    }

    // MARK: - NSApplicationDelegate

    func applicationDidFinishLaunching(_ notification: Notification) {
        setupMenuBar()

        // Try to restore last active workspace first
        if let lastWorkspaceID = WorkspaceManager.getLastActiveWorkspaceID(),
           let workspace = WorkspaceManager.loadWorkspace(id: lastWorkspaceID) {
            restoreWorkspace(workspace)
            return
        }

        // Fall back to session state
        if let savedState = StateManager.shared.loadAppState() {
            restoreState(savedState)
            cleanupOrphanedHistoryFiles(for: savedState)
        } else {
            // No saved state - clean up all history files
            HistoryManager.cleanupOrphanedHistoryFiles(activeSessionIDs: [])
            openNewWindow()
        }
    }

    private func cleanupOrphanedHistoryFiles(for state: AppState) {
        // Collect all session IDs from restored windows
        var activeSessionIDs = Set<UUID>()
        for windowState in state.windows {
            for session in windowState.sessions {
                activeSessionIDs.insert(session.identifier)
            }
        }
        HistoryManager.cleanupOrphanedHistoryFiles(activeSessionIDs: activeSessionIDs)
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        // Save current state BEFORE windows close (this is called when Cmd+Q is pressed)
        if !windowControllers.isEmpty {
            // If we have an active workspace, update it
            if let workspaceID = activeWorkspaceID {
                updateWorkspace(id: workspaceID)
            }
            saveCurrentState()
        }
        return .terminateNow
    }

    func applicationWillTerminate(_ notification: Notification) {
        for controller in windowControllers {
            controller.close()
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        // When user manually closes all windows, clear state so we don't restore them
        StateManager.shared.clearAppState()
        return true
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
        return true
    }

    // MARK: - Window Management

    @objc func openNewWindow() {
        let windowController = TerminalWindowController()
        windowControllers.append(windowController)
        windowController.showWindow(nil)
        windowController.startShell()
    }

    @objc func openNewTab() {
        activeWindowController?.openNewTab()
    }

    // MARK: - State Persistence

    private func saveCurrentState() {
        var windowStates: [WindowState] = []

        // Group controllers by their tab groups
        var processedTabGroups = Set<UUID>()

        for controller in windowControllers {
            guard let window = controller.window else { continue }

            // Skip if we've already processed this tab group
            guard !processedTabGroups.contains(controller.tabGroupID) else { continue }
            processedTabGroups.insert(controller.tabGroupID)

            // Get all tabbed windows in this group
            let tabbedWindows = window.tabbedWindows ?? [window]

            for (index, tabbedWindow) in tabbedWindows.enumerated() {
                if let tabbedController = windowControllers.first(where: { $0.window === tabbedWindow }) {
                    let state = tabbedController.collectWindowState(tabIndex: index)
                    windowStates.append(state)
                }
            }
        }

        let appState = AppState(windows: windowStates, savedAt: Date())
        StateManager.shared.saveAppState(appState)
    }

    private func restoreState(_ state: AppState) {
        // Group windows by tabGroupID to restore tab groups
        let tabGroups = Dictionary(grouping: state.windows) { $0.tabGroupID }

        for (_, windowStates) in tabGroups {
            let sorted = windowStates.sorted { $0.tabIndex < $1.tabIndex }
            var firstWindow: NSWindow?

            for windowState in sorted {
                // Restore session identifier for history persistence
                let sessionIdentifier = windowState.sessions.first?.identifier
                let controller = TerminalWindowController(
                    tabGroupID: windowState.tabGroupID,
                    windowTitleOverride: windowState.windowTitleOverride,
                    sessionIdentifier: sessionIdentifier
                )
                windowControllers.append(controller)

                if let first = firstWindow {
                    // Exclude tab windows from Window menu - only the first window should appear
                    controller.window?.isExcludedFromWindowsMenu = true
                    // Add as a tab to the first window
                    first.addTabbedWindow(controller.window!, ordered: .above)
                } else {
                    // First window in this tab group - restore its frame
                    firstWindow = controller.window
                    controller.window?.setFrame(windowState.frame, display: true)
                }

                controller.showWindow(nil)

                // Start shell in the saved working directory
                let initialDirectory: URL?
                if let path = windowState.sessions.first?.workingDirectory {
                    initialDirectory = URL(fileURLWithPath: path)
                } else {
                    initialDirectory = nil
                }
                controller.startShell(initialDirectory: initialDirectory)
            }
        }

        // If no windows were restored, open a fresh one
        if windowControllers.isEmpty {
            openNewWindow()
        }
    }

    // MARK: - Workspace Management

    private func restoreWorkspace(_ workspace: Workspace) {
        activeWorkspaceID = workspace.id
        WorkspaceManager.setLastActiveWorkspace(id: workspace.id)

        // Restore windows from workspace
        let appState = AppState(windows: workspace.windows, savedAt: workspace.lastUsedAt)
        restoreState(appState)

        // Collect session IDs for history cleanup
        var activeSessionIDs = Set<UUID>()
        for windowState in workspace.windows {
            for session in windowState.sessions {
                activeSessionIDs.insert(session.identifier)
            }
        }
        HistoryManager.cleanupOrphanedHistoryFiles(activeSessionIDs: activeSessionIDs)

        // Update last used timestamp
        WorkspaceManager.touchWorkspace(id: workspace.id)
    }

    private func updateWorkspace(id: UUID) {
        guard var workspace = WorkspaceManager.loadWorkspace(id: id) else { return }

        // Collect current window states
        workspace.windows = collectCurrentWindowStates()
        workspace.lastUsedAt = Date()

        WorkspaceManager.saveWorkspace(workspace)
    }

    private func collectCurrentWindowStates() -> [WindowState] {
        var windowStates: [WindowState] = []
        var processedTabGroups = Set<UUID>()

        for controller in windowControllers {
            guard let window = controller.window else { continue }
            guard !processedTabGroups.contains(controller.tabGroupID) else { continue }
            processedTabGroups.insert(controller.tabGroupID)

            let tabbedWindows = window.tabbedWindows ?? [window]

            for (index, tabbedWindow) in tabbedWindows.enumerated() {
                if let tabbedController = windowControllers.first(where: { $0.window === tabbedWindow }) {
                    let state = tabbedController.collectWindowState(tabIndex: index)
                    windowStates.append(state)
                }
            }
        }

        return windowStates
    }

    private func closeAllWindows() {
        // Close all windows without saving state
        for controller in windowControllers {
            controller.window?.close()
        }
        windowControllers.removeAll()
    }

    @objc private func saveWorkspace() {
        guard !windowControllers.isEmpty else { return }

        let alert = NSAlert()
        alert.messageText = "Save Workspace"
        alert.informativeText = "Enter a name for this workspace:"
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")

        let textField = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        textField.stringValue = "My Workspace"
        alert.accessoryView = textField
        alert.window.initialFirstResponder = textField

        guard alert.runModal() == .alertFirstButtonReturn else { return }

        let name = textField.stringValue.isEmpty ? "Untitled Workspace" : textField.stringValue
        let windows = collectCurrentWindowStates()

        let workspace = Workspace(name: name, windows: windows)
        WorkspaceManager.saveWorkspace(workspace)

        // Make this the active workspace
        activeWorkspaceID = workspace.id
        WorkspaceManager.setLastActiveWorkspace(id: workspace.id)
    }

    @objc private func openWorkspacePicker() {
        let workspaces = WorkspaceManager.listWorkspaces()

        if workspaces.isEmpty {
            let alert = NSAlert()
            alert.messageText = "No Workspaces"
            alert.informativeText = "You haven't saved any workspaces yet. Use 'Save Workspace...' to create one."
            alert.addButton(withTitle: "OK")
            alert.runModal()
            return
        }

        let alert = NSAlert()
        alert.messageText = "Open Workspace"
        alert.informativeText = "Select a workspace to open. This will close all current windows."
        alert.addButton(withTitle: "Open")
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Delete")

        let popup = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 260, height: 24), pullsDown: false)
        for workspace in workspaces {
            let title = "\(workspace.name) (\(workspace.windowCount) window\(workspace.windowCount == 1 ? "" : "s"))"
            popup.addItem(withTitle: title)
            popup.lastItem?.representedObject = workspace.id
        }
        alert.accessoryView = popup

        let response = alert.runModal()

        guard let selectedID = popup.selectedItem?.representedObject as? UUID else { return }

        if response == .alertFirstButtonReturn {
            // Open
            guard let workspace = WorkspaceManager.loadWorkspace(id: selectedID) else { return }

            // Save current workspace if active
            if let currentID = activeWorkspaceID {
                updateWorkspace(id: currentID)
            }

            closeAllWindows()
            restoreWorkspace(workspace)

        } else if response == .alertThirdButtonReturn {
            // Delete
            let confirm = NSAlert()
            confirm.messageText = "Delete Workspace?"
            confirm.informativeText = "Are you sure you want to delete this workspace? This cannot be undone."
            confirm.addButton(withTitle: "Delete")
            confirm.addButton(withTitle: "Cancel")
            confirm.alertStyle = .warning

            if confirm.runModal() == .alertFirstButtonReturn {
                WorkspaceManager.deleteWorkspace(id: selectedID)

                // If we deleted the active workspace, clear it
                if activeWorkspaceID == selectedID {
                    activeWorkspaceID = nil
                }
            }
        }
    }

    @objc private func closeWorkspace() {
        guard activeWorkspaceID != nil else {
            let alert = NSAlert()
            alert.messageText = "No Active Workspace"
            alert.informativeText = "There is no workspace currently open."
            alert.addButton(withTitle: "OK")
            alert.runModal()
            return
        }

        // Save and close
        if let workspaceID = activeWorkspaceID {
            updateWorkspace(id: workspaceID)
        }

        activeWorkspaceID = nil
        WorkspaceManager.setLastActiveWorkspace(id: nil)

        // Don't close windows, just detach from workspace
        let alert = NSAlert()
        alert.messageText = "Workspace Closed"
        alert.informativeText = "The workspace has been saved and closed. Your windows remain open but are no longer associated with a workspace."
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    // MARK: - Menu Setup

    private func setupMenuBar() {
        let mainMenu = NSMenu()

        // Application Menu
        let appMenu = NSMenu()
        let appMenuItem = NSMenuItem()
        appMenuItem.submenu = appMenu

        let appName = ProcessInfo.processInfo.processName
        appMenu.addItem(withTitle: "About \(appName)", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(NSMenuItem.separator())
        appMenu.addItem(withTitle: "Preferences...", action: #selector(showPreferences), keyEquivalent: ",")
        appMenu.addItem(NSMenuItem.separator())
        appMenu.addItem(withTitle: "Hide \(appName)", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")

        let hideOthersItem = NSMenuItem(title: "Hide Others", action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h")
        hideOthersItem.keyEquivalentModifierMask = [.command, .option]
        appMenu.addItem(hideOthersItem)

        appMenu.addItem(withTitle: "Show All", action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: "")
        appMenu.addItem(NSMenuItem.separator())
        appMenu.addItem(withTitle: "Quit \(appName)", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")

        mainMenu.addItem(appMenuItem)

        // Shell Menu
        let shellMenu = NSMenu(title: MenuIdentifiers.shellMenu)
        let shellMenuItem = NSMenuItem()
        shellMenuItem.submenu = shellMenu

        shellMenu.addItem(withTitle: "New Window", action: #selector(openNewWindow), keyEquivalent: "n")
        shellMenu.addItem(withTitle: "New Tab", action: #selector(openNewTab), keyEquivalent: "t")
        shellMenu.addItem(NSMenuItem.separator())

        let setTitleItem = NSMenuItem(title: "Set Window Title...", action: #selector(setWindowTitle), keyEquivalent: "T")
        setTitleItem.keyEquivalentModifierMask = [.command, .shift]
        shellMenu.addItem(setTitleItem)
        shellMenu.addItem(NSMenuItem.separator())

        let openWindowItem = NSMenuItem(title: "Open Window...", action: #selector(openWindowConfigFromFile), keyEquivalent: "O")
        openWindowItem.keyEquivalentModifierMask = [.command, .shift]
        shellMenu.addItem(openWindowItem)

        let saveWindowItem = NSMenuItem(title: "Save Window As...", action: #selector(saveWindowConfig), keyEquivalent: "S")
        saveWindowItem.keyEquivalentModifierMask = [.command, .shift]
        shellMenu.addItem(saveWindowItem)

        shellMenu.addItem(NSMenuItem.separator())

        // Workspaces submenu
        let workspacesMenu = NSMenu(title: "Workspaces")
        let workspacesMenuItem = NSMenuItem(title: "Workspaces", action: nil, keyEquivalent: "")
        workspacesMenuItem.submenu = workspacesMenu

        let saveWorkspaceItem = NSMenuItem(title: "Save Workspace...", action: #selector(saveWorkspace), keyEquivalent: "S")
        saveWorkspaceItem.keyEquivalentModifierMask = [.command, .control]
        workspacesMenu.addItem(saveWorkspaceItem)

        let openWorkspaceItem = NSMenuItem(title: "Open Workspace...", action: #selector(openWorkspacePicker), keyEquivalent: "O")
        openWorkspaceItem.keyEquivalentModifierMask = [.command, .control]
        workspacesMenu.addItem(openWorkspaceItem)

        workspacesMenu.addItem(NSMenuItem.separator())

        let closeWorkspaceItem = NSMenuItem(title: "Close Workspace", action: #selector(closeWorkspace), keyEquivalent: "")
        workspacesMenu.addItem(closeWorkspaceItem)

        shellMenu.addItem(workspacesMenuItem)

        shellMenu.addItem(NSMenuItem.separator())
        shellMenu.addItem(withTitle: "Close Window", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "W")
        shellMenu.addItem(withTitle: "Close Tab", action: #selector(closeCurrentTab), keyEquivalent: "w")

        mainMenu.addItem(shellMenuItem)

        // Edit Menu
        let editMenu = NSMenu(title: MenuIdentifiers.editMenu)
        let editMenuItem = NSMenuItem()
        editMenuItem.submenu = editMenu

        editMenu.addItem(withTitle: "Undo", action: #selector(UndoManager.undo), keyEquivalent: "z")
        editMenu.addItem(withTitle: "Redo", action: #selector(UndoManager.redo), keyEquivalent: "Z")
        editMenu.addItem(NSMenuItem.separator())
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editMenu.addItem(NSMenuItem.separator())
        editMenu.addItem(withTitle: "Find...", action: #selector(showFind), keyEquivalent: "f")

        mainMenu.addItem(editMenuItem)

        // AI Menu
        let aiMenu = NSMenu(title: "AI")
        let aiMenuItem = NSMenuItem()
        aiMenuItem.submenu = aiMenu

        let toggleAIModeItem = NSMenuItem(title: "Toggle AI Mode", action: #selector(toggleAIMode), keyEquivalent: "a")
        toggleAIModeItem.keyEquivalentModifierMask = [.command, .shift]
        aiMenu.addItem(toggleAIModeItem)

        aiMenu.addItem(NSMenuItem.separator())
        aiMenu.addItem(withTitle: "AI Preferences...", action: #selector(showAIPreferences), keyEquivalent: "")

        mainMenu.addItem(aiMenuItem)

        // View Menu
        let viewMenu = NSMenu(title: MenuIdentifiers.viewMenu)
        let viewMenuItem = NSMenuItem()
        viewMenuItem.submenu = viewMenu

        let fullScreenItem = NSMenuItem(title: "Enter Full Screen", action: #selector(NSWindow.toggleFullScreen(_:)), keyEquivalent: "f")
        fullScreenItem.keyEquivalentModifierMask = [.command, .control]
        viewMenu.addItem(fullScreenItem)

        viewMenu.addItem(NSMenuItem.separator())
        viewMenu.addItem(withTitle: "Bigger", action: #selector(increaseFontSize), keyEquivalent: "+")
        viewMenu.addItem(withTitle: "Smaller", action: #selector(decreaseFontSize), keyEquivalent: "-")

        viewMenu.addItem(NSMenuItem.separator())
        viewMenu.addItem(withTitle: "Toggle Process Tree", action: #selector(toggleProcessTree), keyEquivalent: "p")

        mainMenu.addItem(viewMenuItem)

        // Window Menu
        let windowMenu = NSMenu(title: MenuIdentifiers.windowMenu)
        let windowMenuItem = NSMenuItem()
        windowMenuItem.submenu = windowMenu

        windowMenu.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowMenu.addItem(withTitle: "Zoom", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        windowMenu.addItem(NSMenuItem.separator())

        let showPreviousTabItem = NSMenuItem(title: "Show Previous Tab", action: #selector(selectPreviousTab), keyEquivalent: "[")
        showPreviousTabItem.keyEquivalentModifierMask = [.command, .shift]
        windowMenu.addItem(showPreviousTabItem)

        let showNextTabItem = NSMenuItem(title: "Show Next Tab", action: #selector(selectNextTab), keyEquivalent: "]")
        showNextTabItem.keyEquivalentModifierMask = [.command, .shift]
        windowMenu.addItem(showNextTabItem)

        windowMenu.addItem(NSMenuItem.separator())

        // Cmd+1 through Cmd+9 for tab switching
        for i in 1...9 {
            let tabItem = NSMenuItem(title: "Select Tab \(i)", action: #selector(selectTabByNumber(_:)), keyEquivalent: "\(i)")
            tabItem.tag = i
            windowMenu.addItem(tabItem)
        }

        windowMenu.addItem(NSMenuItem.separator())

        // Cmd+Ctrl+1 through Cmd+Ctrl+9 for window group switching
        for i in 1...9 {
            let windowItem = NSMenuItem(title: "Select Window \(i)", action: #selector(selectWindowByNumber(_:)), keyEquivalent: "\(i)")
            windowItem.keyEquivalentModifierMask = [.command, .control]
            windowItem.tag = i
            windowMenu.addItem(windowItem)
        }

        windowMenu.addItem(NSMenuItem.separator())
        windowMenu.addItem(withTitle: "Bring All to Front", action: #selector(NSApplication.arrangeInFront(_:)), keyEquivalent: "")

        mainMenu.addItem(windowMenuItem)
        NSApp.windowsMenu = windowMenu

        // Help Menu
        let helpMenu = NSMenu(title: MenuIdentifiers.helpMenu)
        let helpMenuItem = NSMenuItem()
        helpMenuItem.submenu = helpMenu

        let appHelpItem = NSMenuItem(title: "\(appName) Help", action: #selector(NSApplication.showHelp(_:)), keyEquivalent: "?")
        helpMenu.addItem(appHelpItem)

        mainMenu.addItem(helpMenuItem)
        NSApp.helpMenu = helpMenu

        NSApp.mainMenu = mainMenu
    }

    // MARK: - Menu Actions

    @objc private func showPreferences() {
        PreferencesWindowController.show()
    }

    @objc private func showFind() {
        activeWindowController?.showFind()
    }

    @objc private func increaseFontSize() {
        activeWindowController?.increaseFontSize()
    }

    @objc private func decreaseFontSize() {
        activeWindowController?.decreaseFontSize()
    }

    @objc private func selectNextTab() {
        activeWindowController?.selectNextTab()
    }

    @objc private func selectPreviousTab() {
        activeWindowController?.selectPreviousTab()
    }

    @objc private func closeCurrentTab() {
        activeWindowController?.closeCurrentTab()
    }

    @objc private func selectTabByNumber(_ sender: NSMenuItem) {
        let tabIndex = sender.tag - 1  // Convert 1-based to 0-based
        activeWindowController?.selectTab(at: tabIndex)
    }

    @objc private func selectWindowByNumber(_ sender: NSMenuItem) {
        let windowIndex = sender.tag - 1  // Convert 1-based to 0-based

        // Get unique window groups (first window of each tab group)
        var seenTabGroups = Set<UUID>()
        var mainWindows: [NSWindow] = []

        for controller in windowControllers {
            guard let window = controller.window, !seenTabGroups.contains(controller.tabGroupID) else { continue }
            seenTabGroups.insert(controller.tabGroupID)
            mainWindows.append(window)
        }

        // Sort by window order (front to back based on orderfront time isn't available,
        // so we use the order they appear in windowControllers which is creation order)
        guard windowIndex >= 0, windowIndex < mainWindows.count else { return }
        mainWindows[windowIndex].makeKeyAndOrderFront(nil)
    }

    @objc private func toggleProcessTree() {
        activeWindowController?.toggleProcessTree()
    }

    @objc private func setWindowTitle() {
        activeWindowController?.showSetTitleDialog()
    }

    @objc private func toggleAIMode() {
        activeWindowController?.toggleAIMode()
    }

    @objc private func showAIPreferences() {
        PreferencesWindowController.show()
        // TODO: Auto-select AI tab when showing preferences
    }

    // MARK: - Window Config File Actions

    @objc private func openWindowConfigFromFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "skalman")].compactMap { $0 }
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false

        guard panel.runModal() == .OK, let url = panel.url else { return }
        openWindowConfig(from: url)
    }

    @objc private func saveWindowConfig() {
        guard let controller = activeWindowController,
              let window = controller.window else { return }

        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "skalman")].compactMap { $0 }
        panel.nameFieldStringValue = "Window.skalman"

        guard panel.runModal() == .OK, let url = panel.url else { return }

        // Collect state for all tabs in the current window
        var sessions: [SessionSnapshot] = []
        let tabbedWindows = window.tabbedWindows ?? [window]

        for tabbedWindow in tabbedWindows {
            if let tabbedController = windowControllers.first(where: { $0.window === tabbedWindow }) {
                let snapshot = SessionSnapshot(
                    identifier: tabbedController.session.identifier,
                    profileName: tabbedController.session.profileName,
                    workingDirectory: tabbedController.session.effectiveWorkingDirectory()?.path,
                    title: tabbedController.session.title
                )
                sessions.append(snapshot)
            }
        }

        let windowState = WindowState(
            identifier: UUID(),
            frame: window.frame,
            tabGroupID: controller.tabGroupID,
            tabIndex: 0,
            sessions: sessions,
            windowTitleOverride: controller.windowTitleOverride
        )

        StateManager.shared.saveWindowState(windowState, to: url)
    }

    private func openWindowConfig(from url: URL) {
        guard let windowState = StateManager.shared.loadWindowState(from: url) else { return }

        // Create a new window with all the tabs from the saved config
        var firstWindow: NSWindow?
        let newTabGroupID = UUID()

        for session in windowState.sessions {
            // Restore session identifier for history persistence
            let controller = TerminalWindowController(
                tabGroupID: newTabGroupID,
                windowTitleOverride: windowState.windowTitleOverride,
                sessionIdentifier: session.identifier
            )
            windowControllers.append(controller)

            if let first = firstWindow {
                // Exclude tab windows from Window menu - only the first window should appear
                controller.window?.isExcludedFromWindowsMenu = true
                first.addTabbedWindow(controller.window!, ordered: .above)
            } else {
                firstWindow = controller.window
                controller.window?.setFrame(windowState.frame, display: true)
            }

            controller.showWindow(nil)

            let initialDirectory: URL?
            if let path = session.workingDirectory {
                initialDirectory = URL(fileURLWithPath: path)
            } else {
                initialDirectory = nil
            }
            controller.startShell(initialDirectory: initialDirectory)
        }
    }

    // MARK: - Open Files

    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls where url.pathExtension == "skalman" {
            openWindowConfig(from: url)
        }
    }
}

// MARK: - NSWindowDelegate

extension AppDelegate: NSWindowDelegate {

    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }

        // Save state BEFORE removing the controller (so we capture all windows)
        // But only if this isn't the last window (last window save is handled specially)
        if windowControllers.count > 1 {
            saveCurrentState()
        }

        windowControllers.removeAll { $0.window === window }
    }
}
