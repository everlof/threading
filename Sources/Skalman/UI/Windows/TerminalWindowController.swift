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

    /// Identifier for grouping tabbed windows together for state persistence.
    private(set) var tabGroupID: UUID = UUID()

    /// Whether the process tree pane is currently visible.
    private(set) var isProcessTreeVisible: Bool = false

    var session: TerminalSession {
        terminalViewController.session
    }

    // MARK: - Initialization

    convenience init() {
        let window = Self.createWindow()
        self.init(window: window)
        setupSplitViewController()
        window.delegate = self
    }

    /// Initialize with a specific tab group ID (for restoring tabbed windows).
    convenience init(tabGroupID: UUID) {
        self.init()
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
    }

    // MARK: - Tab Management

    func openNewTab() {
        guard let currentWindow = window else { return }

        let newWindowController = TerminalWindowController(tabGroupID: tabGroupID)
        guard let newWindow = newWindowController.window else { return }

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
            sessions: [sessionSnapshot]
        )
    }
}

// MARK: - TerminalTabViewControllerDelegate

extension TerminalWindowController: TerminalTabViewControllerDelegate {

    func terminalTabDidStart(_ tab: TerminalTabViewController) {
        NotificationCenter.default.post(name: .terminalSessionDidStart, object: self)
    }

    func terminalTab(_ tab: TerminalTabViewController, titleChangedTo title: String) {
        window?.title = title
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
