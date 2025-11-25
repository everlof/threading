import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {

    // MARK: - Properties

    private var windowControllers: [TerminalWindowController] = []

    private var activeWindowController: TerminalWindowController? {
        // Get the window controller for the currently active window
        guard let keyWindow = NSApp.keyWindow else { return windowControllers.first }
        return windowControllers.first { $0.window === keyWindow }
    }

    // MARK: - NSApplicationDelegate

    func applicationDidFinishLaunching(_ notification: Notification) {
        setupMenuBar()
        openNewWindow()
    }

    func applicationWillTerminate(_ notification: Notification) {
        for controller in windowControllers {
            controller.close()
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return true
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
        return true
    }

    // MARK: - Window Management

    @objc func openNewWindow() {
        let windowController = TerminalWindowController()
        windowController.window?.delegate = self
        windowControllers.append(windowController)
        windowController.showWindow(nil)
    }

    @objc func openNewTab() {
        activeWindowController?.openNewTab()
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
}

// MARK: - NSWindowDelegate

extension AppDelegate: NSWindowDelegate {

    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        windowControllers.removeAll { $0.window === window }
    }
}
