import AppKit
import SwiftTerm

final class TerminalWindowController: NSWindowController {

    // MARK: - Properties

    private var splitViewController: NSSplitViewController!
    private var terminalViewController: TerminalTabViewController!
    private var processTreePaneController: ProcessTreePaneController?
    private var processTreeSplitItem: NSSplitViewItem?

    private var findBar: FindBarView?
    private var findBarTopConstraint: NSLayoutConstraint?

    private var aiInputBar: AIInputBar?
    private var aiInputBarBottomConstraint: NSLayoutConstraint?
    private(set) var isAIModeActive: Bool = false

    /// Identifier for grouping tabbed windows together for state persistence.
    private(set) var tabGroupID: UUID = UUID()

    /// Whether the process tree pane is currently visible.
    private(set) var isProcessTreeVisible: Bool = false

    /// Custom window title override (nil means use shell title).
    /// This is shared across all windows in the same tab group.
    private var _windowTitleOverride: String?
    var windowTitleOverride: String? {
        get { _windowTitleOverride }
        set {
            _windowTitleOverride = newValue
            // Only apply if view controller is set up
            if terminalViewController != nil {
                applyWindowTitleToTabGroup()
            }
        }
    }

    var session: TerminalSession {
        terminalViewController.session
    }

    // MARK: - Initialization

    override init(window: NSWindow?) {
        super.init(window: window)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    convenience init() {
        self.init(windowTitleOverride: nil)
    }

    convenience init(windowTitleOverride: String?) {
        let window = Self.createWindow()
        self.init(window: window)
        self.windowTitleOverride = windowTitleOverride
        setupSplitViewController()
        window.delegate = self
    }

    /// Initialize with a specific tab group ID (for restoring tabbed windows).
    convenience init(tabGroupID: UUID, windowTitleOverride: String? = nil) {
        self.init(windowTitleOverride: windowTitleOverride)
        self.tabGroupID = tabGroupID
    }

    // MARK: - Window Creation

    private static func createWindow() -> NSWindow {
        let contentRect = NSRect(
            x: 0,
            y: 0,
            width: WindowDefaults.defaultWidth,
            height: WindowDefaults.defaultHeight
        )

        let styleMask: NSWindow.StyleMask = [
            .titled,
            .closable,
            .miniaturizable,
            .resizable
        ]

        let window = NSWindow(
            contentRect: contentRect,
            styleMask: styleMask,
            backing: .buffered,
            defer: false
        )

        window.minSize = NSSize(
            width: WindowDefaults.minWidth,
            height: WindowDefaults.minHeight
        )

        window.title = TerminalDefaults.defaultShell
        window.center()
        window.isReleasedWhenClosed = false

        // Native macOS tabs (like Terminal.app/Safari)
        window.tabbingMode = .automatic
        window.tabbingIdentifier = "SkalmanWindow"

        return window
    }

    // MARK: - Setup

    private func setupSplitViewController() {
        splitViewController = NSSplitViewController()
        splitViewController.splitView.isVertical = false  // Horizontal split (top/bottom)
        splitViewController.splitView.dividerStyle = .thin

        // Process tree pane (top, initially collapsed)
        processTreePaneController = ProcessTreePaneController()
        processTreePaneController?.onClose = { [weak self] in
            self?.hideProcessTree()
        }

        let paneItem = NSSplitViewItem(contentListWithViewController: processTreePaneController!)
        paneItem.canCollapse = true
        paneItem.isCollapsed = true
        paneItem.minimumThickness = ProcessTreeDefaults.minPaneHeight
        paneItem.automaticMaximumThickness = ProcessTreeDefaults.maxPaneHeight
        processTreeSplitItem = paneItem
        splitViewController.addSplitViewItem(paneItem)

        // Terminal view controller (bottom, main content)
        terminalViewController = TerminalTabViewController()
        terminalViewController.delegate = self

        let terminalItem = NSSplitViewItem(viewController: terminalViewController)
        terminalItem.canCollapse = false
        splitViewController.addSplitViewItem(terminalItem)

        window?.contentViewController = splitViewController
    }

    // MARK: - Public Methods

    func startShell() {
        startShell(initialDirectory: nil)
    }

    func startShell(initialDirectory: URL?) {
        terminalViewController.startShell(initialDirectory: initialDirectory)
        window?.makeFirstResponder(terminalViewController.session.terminalView)
        // Apply initial window title override if set
        if let override = windowTitleOverride, !override.isEmpty {
            window?.title = override
        }
    }

    // MARK: - Tab Management

    func openNewTab() {
        guard let currentWindow = window else { return }

        // New tabs inherit the window title override from the tab group
        let newWindowController = TerminalWindowController(tabGroupID: tabGroupID, windowTitleOverride: windowTitleOverride)
        guard let newWindow = newWindowController.window else { return }

        // Exclude tab windows from Window menu - only the main window should appear
        newWindow.isExcludedFromWindowsMenu = true

        currentWindow.addTabbedWindow(newWindow, ordered: .above)
        newWindow.makeKeyAndOrderFront(nil)
        newWindowController.startShell()

        // Keep reference to prevent deallocation
        AppDelegate.shared.addWindowController(newWindowController)
    }

    func closeCurrentTab() {
        window?.close()
    }

    func selectNextTab() {
        window?.selectNextTab(nil)
    }

    func selectPreviousTab() {
        window?.selectPreviousTab(nil)
    }

    func selectTab(at index: Int) {
        guard let window = window,
              let tabbedWindows = window.tabbedWindows,
              index >= 0, index < tabbedWindows.count else { return }

        tabbedWindows[index].makeKeyAndOrderFront(nil)
    }

    // MARK: - Font Management

    func increaseFontSize() {
        terminalViewController.increaseFontSize()
    }

    func decreaseFontSize() {
        terminalViewController.decreaseFontSize()
    }

    // MARK: - Process Tree

    /// Toggles the process tree pane visibility.
    func toggleProcessTree() {
        if isProcessTreeVisible {
            hideProcessTree()
        } else {
            showProcessTree()
        }
    }

    /// Shows the process tree pane.
    func showProcessTree() {
        guard let paneItem = processTreeSplitItem else { return }

        // Update the pane with current shell PID
        processTreePaneController?.setRootPid(session.shellPid)

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.2
            context.allowsImplicitAnimation = true
            paneItem.isCollapsed = false
        }

        isProcessTreeVisible = true

        // Keep focus on terminal
        window?.makeFirstResponder(terminalViewController.session.terminalView)
    }

    /// Hides the process tree pane.
    func hideProcessTree() {
        guard let paneItem = processTreeSplitItem else { return }

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.2
            context.allowsImplicitAnimation = true
            paneItem.isCollapsed = true
        }

        isProcessTreeVisible = false

        // Return focus to terminal
        window?.makeFirstResponder(terminalViewController.session.terminalView)
    }

    // MARK: - Find

    func showFind() {
        guard let contentView = window?.contentView else { return }

        if findBar == nil {
            let bar = FindBarView()
            bar.translatesAutoresizingMaskIntoConstraints = false
            bar.terminalView = terminalViewController.session.terminalView
            bar.onClose = { [weak self] in
                self?.hideFindBar()
            }

            contentView.addSubview(bar)

            findBarTopConstraint = bar.topAnchor.constraint(equalTo: contentView.topAnchor, constant: -32)

            NSLayoutConstraint.activate([
                findBarTopConstraint!,
                bar.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
                bar.trailingAnchor.constraint(equalTo: contentView.trailingAnchor)
            ])

            findBar = bar
        }

        // Animate in
        findBarTopConstraint?.constant = 0
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.2
            contentView.layoutSubtreeIfNeeded()
        }

        findBar?.focus()
    }

    func hideFindBar() {
        guard let contentView = window?.contentView, findBar != nil else { return }

        findBarTopConstraint?.constant = -32
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.2
            contentView.layoutSubtreeIfNeeded()
        }, completionHandler: { [weak self] in
            self?.findBar?.removeFromSuperview()
            self?.findBar = nil
            self?.window?.makeFirstResponder(self?.terminalViewController.session.terminalView)
        })
    }

    // MARK: - AI Mode

    /// Toggles AI input mode on/off.
    func toggleAIMode() {
        if isAIModeActive {
            hideAIInputBar()
        } else {
            showAIInputBar()
        }
    }

    /// Shows the AI input bar at the bottom of the window.
    func showAIInputBar() {
        guard let contentView = window?.contentView else { return }

        if aiInputBar == nil {
            let bar = AIInputBar()
            bar.translatesAutoresizingMaskIntoConstraints = false
            bar.onSubmit = { [weak self] prompt in
                self?.handleAIPrompt(prompt)
            }
            bar.onCancel = { [weak self] in
                self?.hideAIInputBar()
            }

            contentView.addSubview(bar)

            aiInputBarBottomConstraint = bar.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: 40)

            NSLayoutConstraint.activate([
                aiInputBarBottomConstraint!,
                bar.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
                bar.trailingAnchor.constraint(equalTo: contentView.trailingAnchor)
            ])

            aiInputBar = bar
        }

        aiInputBar?.updateProviderLabel()

        // Animate in
        aiInputBarBottomConstraint?.constant = 0
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.2
            contentView.layoutSubtreeIfNeeded()
        }

        isAIModeActive = true
        aiInputBar?.focus()
    }

    /// Hides the AI input bar.
    func hideAIInputBar() {
        guard let contentView = window?.contentView, aiInputBar != nil else { return }

        aiInputBarBottomConstraint?.constant = 40
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.2
            contentView.layoutSubtreeIfNeeded()
        }, completionHandler: { [weak self] in
            self?.aiInputBar?.removeFromSuperview()
            self?.aiInputBar = nil
            self?.isAIModeActive = false
            self?.window?.makeFirstResponder(self?.terminalViewController.session.terminalView)
        })
    }

    /// Handles an AI prompt submission.
    private func handleAIPrompt(_ prompt: String) {
        guard AIService.shared.isConfigured else {
            showAIError("AI not configured. Please set up an AI provider in Preferences.")
            return
        }

        aiInputBar?.setLoading(true)

        let context = AIContext.current(
            workingDirectory: session.effectiveWorkingDirectory()?.path,
            shell: ProfileStorage.shared.defaultProfile.shellPath
        )

        Task {
            do {
                let command = try await AIService.shared.generateCommand(prompt: prompt, context: context)

                await MainActor.run {
                    aiInputBar?.setLoading(false)
                    aiInputBar?.clear()
                    hideAIInputBar()

                    // Insert the generated command at the prompt
                    session.insertText(command)
                }
            } catch {
                await MainActor.run {
                    aiInputBar?.setLoading(false)
                    showAIError(error.localizedDescription)
                }
            }
        }
    }

    /// Shows an AI error alert.
    private func showAIError(_ message: String) {
        let alert = NSAlert()
        alert.messageText = "AI Error"
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    // MARK: - Window Title

    private func updateWindowTitle() {
        window?.title = terminalViewController.session.title

        if let directory = terminalViewController.session.currentDirectory {
            window?.representedURL = directory
        } else {
            window?.representedURL = nil
        }
    }

    // MARK: - State Persistence

    /// Collects the current state of this window for persistence.
    func collectWindowState(tabIndex: Int) -> WindowState {
        let sessionSnapshot = SessionSnapshot(
            identifier: session.identifier,
            profileName: session.profileName,
            workingDirectory: session.effectiveWorkingDirectory()?.path,
            title: session.title
        )

        return WindowState(
            identifier: UUID(),
            frame: window?.frame ?? .zero,
            tabGroupID: tabGroupID,
            tabIndex: tabIndex,
            sessions: [sessionSnapshot],
            windowTitleOverride: windowTitleOverride
        )
    }

    // MARK: - Title Override

    /// Shows a dialog to set a custom window title.
    func showSetTitleDialog() {
        let alert = NSAlert()
        alert.messageText = "Set Window Title"
        alert.informativeText = "Enter a custom title for this window. Leave empty to use the automatic title."
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")

        let textField = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        textField.stringValue = windowTitleOverride ?? ""
        textField.placeholderString = session.title
        alert.accessoryView = textField

        alert.window.initialFirstResponder = textField

        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            let newTitle = textField.stringValue
            setWindowTitle(override: newTitle.isEmpty ? nil : newTitle)
        }
    }

    /// Sets a custom window title override for this tab group. Pass nil to revert to automatic titles.
    func setWindowTitle(override: String?) {
        // Apply to all windows in the tab group
        guard let window = window else {
            windowTitleOverride = override
            return
        }

        let tabbedWindows = window.tabbedWindows ?? [window]
        for tabbedWindow in tabbedWindows {
            if let controller = tabbedWindow.windowController as? TerminalWindowController {
                // Set directly to avoid triggering didSet recursively
                controller.windowTitleOverride = override
            }
        }
    }

    /// Applies the window title override to all windows in the tab group.
    private func applyWindowTitleToTabGroup() {
        guard let window = window, terminalViewController != nil else { return }

        if let override = windowTitleOverride, !override.isEmpty {
            window.title = override
        } else {
            window.title = session.title
        }
    }
}

// MARK: - TerminalTabViewControllerDelegate

extension TerminalWindowController: TerminalTabViewControllerDelegate {

    func terminalTabDidStart(_ tab: TerminalTabViewController) {
        NotificationCenter.default.post(name: .terminalSessionDidStart, object: self)
    }

    func terminalTab(_ tab: TerminalTabViewController, titleChangedTo title: String) {
        // Always update tab title with shell title
        window?.tab.title = title
        // Only update window title if no override is set for this tab group
        if windowTitleOverride == nil || windowTitleOverride?.isEmpty == true {
            window?.title = title
        }
        // If override is set, keep showing the override (don't change window.title)
    }

    func terminalTab(_ tab: TerminalTabViewController, directoryChangedTo directory: URL?) {
        window?.representedURL = directory
    }

    func terminalTabDidTerminate(_ tab: TerminalTabViewController, exitCode: Int32?) {
        DispatchQueue.main.async { [weak self] in
            self?.window?.close()
            NotificationCenter.default.post(name: .terminalSessionDidEnd, object: self)
        }
    }
}

// MARK: - NSWindowDelegate

extension TerminalWindowController: NSWindowDelegate {

    func windowWillClose(_ notification: Notification) {
        terminalViewController.session.terminate()
        AppDelegate.shared.removeWindowController(self)
    }
}
