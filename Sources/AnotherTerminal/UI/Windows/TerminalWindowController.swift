import AppKit
import SwiftTerm

final class TerminalWindowController: NSWindowController {

    // MARK: - Properties

    private var tabViewController: NSTabViewController!
    private var tabs: [TerminalTabViewController] = []
    private var findBar: FindBarView?
    private var findBarTopConstraint: NSLayoutConstraint?

    private var currentTab: TerminalTabViewController? {
        guard tabViewController.selectedTabViewItemIndex >= 0,
              tabViewController.selectedTabViewItemIndex < tabs.count else {
            return nil
        }
        return tabs[tabViewController.selectedTabViewItemIndex]
    }

    // MARK: - Initialization

    convenience init() {
        let window = Self.createWindow()
        self.init(window: window)
        setupTabViewController()
        addNewTab()
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
        window.tabbingMode = .disallowed  // Use our own tab management

        return window
    }

    // MARK: - Tab View Setup

    private func setupTabViewController() {
        tabViewController = NSTabViewController()
        tabViewController.tabStyle = .segmentedControlOnTop  // Show tab bar

        window?.contentViewController = tabViewController
    }

    // MARK: - Tab Management

    func openNewTab() {
        addNewTab()
    }

    private func addNewTab() {
        let tabVC = TerminalTabViewController()
        tabVC.delegate = self

        let tabItem = NSTabViewItem(viewController: tabVC)
        tabItem.label = TerminalDefaults.defaultShell

        tabs.append(tabVC)
        tabViewController.addTabViewItem(tabItem)
        tabViewController.selectedTabViewItemIndex = tabs.count - 1

        tabVC.startShell()

        updateWindowTitle()
        window?.makeFirstResponder(tabVC.session.terminalView)
    }

    func closeCurrentTab() {
        guard let currentTab = currentTab,
              let index = tabs.firstIndex(where: { $0 === currentTab }) else {
            return
        }

        closeTab(at: index)
    }

    private func closeTab(at index: Int) {
        guard index >= 0, index < tabs.count else { return }

        tabs.remove(at: index)
        tabViewController.removeTabViewItem(tabViewController.tabViewItems[index])

        if tabs.isEmpty {
            window?.close()
        } else {
            let newIndex = min(index, tabs.count - 1)
            tabViewController.selectedTabViewItemIndex = newIndex
            updateWindowTitle()
            window?.makeFirstResponder(currentTab?.session.terminalView)
        }
    }

    func selectNextTab() {
        let count = tabs.count
        guard count > 1 else { return }

        let currentIndex = tabViewController.selectedTabViewItemIndex
        let nextIndex = (currentIndex + 1) % count
        tabViewController.selectedTabViewItemIndex = nextIndex
        updateWindowTitle()
        window?.makeFirstResponder(currentTab?.session.terminalView)
    }

    func selectPreviousTab() {
        let count = tabs.count
        guard count > 1 else { return }

        let currentIndex = tabViewController.selectedTabViewItemIndex
        let previousIndex = (currentIndex - 1 + count) % count
        tabViewController.selectedTabViewItemIndex = previousIndex
        updateWindowTitle()
        window?.makeFirstResponder(currentTab?.session.terminalView)
    }

    func selectTab(at index: Int) {
        guard index >= 0, index < tabs.count else { return }
        tabViewController.selectedTabViewItemIndex = index
        updateWindowTitle()
        window?.makeFirstResponder(currentTab?.session.terminalView)
    }

    // MARK: - Window Title

    private func updateWindowTitle() {
        guard let currentTab = currentTab else { return }
        window?.title = currentTab.session.title

        if let directory = currentTab.session.currentDirectory {
            window?.representedURL = directory
        } else {
            window?.representedURL = nil
        }
    }

    // MARK: - Font Management

    func increaseFontSize() {
        currentTab?.increaseFontSize()
    }

    func decreaseFontSize() {
        currentTab?.decreaseFontSize()
    }

    // MARK: - Find

    func showFind() {
        guard let contentView = window?.contentView else { return }

        if findBar == nil {
            let bar = FindBarView()
            bar.translatesAutoresizingMaskIntoConstraints = false
            bar.terminalView = currentTab?.session.terminalView
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
            self?.window?.makeFirstResponder(self?.currentTab?.session.terminalView)
        })
    }
}

// MARK: - TerminalTabViewControllerDelegate

extension TerminalWindowController: TerminalTabViewControllerDelegate {

    func terminalTabDidStart(_ tab: TerminalTabViewController) {
        NotificationCenter.default.post(name: .terminalSessionDidStart, object: self)
    }

    func terminalTab(_ tab: TerminalTabViewController, titleChangedTo title: String) {
        if let index = tabs.firstIndex(where: { $0 === tab }) {
            tabViewController.tabViewItems[index].label = title
        }

        if tab === currentTab {
            updateWindowTitle()
        }
    }

    func terminalTab(_ tab: TerminalTabViewController, directoryChangedTo directory: URL?) {
        if tab === currentTab {
            window?.representedURL = directory
        }
    }

    func terminalTabDidTerminate(_ tab: TerminalTabViewController, exitCode: Int32?) {
        guard let index = tabs.firstIndex(where: { $0 === tab }) else { return }

        DispatchQueue.main.async { [weak self] in
            self?.closeTab(at: index)
            NotificationCenter.default.post(name: .terminalSessionDidEnd, object: self)
        }
    }
}

// MARK: - NSWindowDelegate

extension TerminalWindowController: NSWindowDelegate {

    func windowWillClose(_ notification: Notification) {
        for tab in tabs {
            tab.session.terminate()
        }
        tabs.removeAll()
    }
}
