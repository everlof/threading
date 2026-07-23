import AppKit

// MARK: - Toolbar Item Identifiers

extension NSToolbarItem.Identifier {
    /// App-owned sidebar toggle; kept beside the system tracking separator.
    static let skalmanToggleSidebar = NSToolbarItem.Identifier("SkalmanToggleSidebar")

    /// Names the project and session currently shown.
    static let sessionTitle = NSToolbarItem.Identifier("SkalmanSessionTitle")

    /// Opens the session composer, placed directly after the active page tab.
    static let newSessionPage = NSToolbarItem.Identifier("SkalmanNewSessionPage")

    /// Shows the current account's rate-limit usage, at the trailing edge of the centre pane.
    static let accountUsage = NSToolbarItem.Identifier("SkalmanAccountUsage")

    /// A second divider-aligned gap, bound to the display pane's divider, so the pane toggles
    /// sit over the pane they control — and the usage pill stays over the centre pane rather
    /// than drifting out over the panel when it opens.
    static let displayTrackingSeparator = NSToolbarItem.Identifier("SkalmanDisplayTrackingSeparator")

    /// The context menu for the session on screen — theme so far, more to come.
    static let sessionContext = NSToolbarItem.Identifier("SkalmanSessionContext")

    /// Toggles the shell drawer under the session.
    static let toggleShellDrawer = NSToolbarItem.Identifier("SkalmanToggleShellDrawer")

    /// Toggles the display panel, so it can be opened without an agent putting content in it.
    static let toggleDisplayPane = NSToolbarItem.Identifier("SkalmanToggleDisplayPane")
}

// MARK: - NSToolbarDelegate

extension MainWindowController: NSToolbarDelegate {

    /// Builds the window's toolbar.
    ///
    /// A real toolbar is what keeps the sidebar control pinned beside the traffic lights in
    /// both states. The button is app-owned; `.sidebarTrackingSeparator` remains a system item
    /// because it is the one primitive that follows a moving split divider.
    func makeToolbar() -> NSToolbar {
        let toolbar = NSToolbar(identifier: MainWindowDefaults.toolbarIdentifier)
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = false
        toolbar.showsBaselineSeparator = false

        return toolbar
    }

    // MARK: Delegate

    public func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [
            .skalmanToggleSidebar, .sidebarTrackingSeparator,
            .sessionTitle, .newSessionPage, .flexibleSpace, .accountUsage,
            .displayTrackingSeparator, .sessionContext, .toggleShellDrawer, .toggleDisplayPane
        ]
    }

    public func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarDefaultItemIdentifiers(toolbar)
    }

    public func toolbar(
        _ toolbar: NSToolbar,
        itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier,
        willBeInsertedIntoToolbar flag: Bool
    ) -> NSToolbarItem? {
        switch itemIdentifier {
        case .skalmanToggleSidebar:
            let button = ToolbarButtonView(
                symbolName: "sidebar.leading",
                accessibility: "Show or hide sidebar"
            )
            button.toolTip = "Show or Hide the Sidebar (⌃⌘S)"
            button.onPress = { [weak self] in self?.toggleSidebar() }
            sidebarToolbarButton = button
            return makeOverlayItem(identifier: itemIdentifier, view: button)

        case .sidebarTrackingSeparator:
            return NSTrackingSeparatorToolbarItem(
                identifier: itemIdentifier,
                splitView: splitViewController.splitView,
                dividerIndex: 0
            )

        case .displayTrackingSeparator:
            // The display item is added at launch and only ever collapses, so divider 1
            // always exists; a collapsed pane hides the separator and merges the sections.
            return NSTrackingSeparatorToolbarItem(
                identifier: itemIdentifier,
                splitView: splitViewController.splitView,
                dividerIndex: 1
            )

        case .sessionTitle:
            return makeSessionTitleItem(identifier: itemIdentifier)

        case .newSessionPage:
            let button = ToolbarButtonView(
                symbolName: "plus",
                accessibility: "New session"
            )
            button.toolTip = "New Session (⌘N)"
            button.onPress = { [weak self] in self?.newSession() }
            return makeOverlayItem(identifier: itemIdentifier, view: button)

        case .accountUsage:
            return makeAccountUsageItem(identifier: itemIdentifier)

        case .sessionContext:
            return makeSessionContextItem(identifier: itemIdentifier)

        case .toggleShellDrawer:
            return makePaneToggleItem(
                identifier: itemIdentifier,
                symbolName: "rectangle.bottomthird.inset.filled",
                label: "Shell",
                toolTip: "Show or Hide the Shell Drawer (⌃`)"
            ) { [weak self] in
                self?.toggleShellDrawer()
            }

        case .toggleDisplayPane:
            return makePaneToggleItem(
                identifier: itemIdentifier,
                symbolName: "sidebar.trailing",
                label: "Panel",
                toolTip: "Show or Hide the Display Panel"
            ) { [weak self] in
                self?.toggleDisplayPane()
            }

        default:
            // Flexible space is supplied by the system.
            return nil
        }
    }

    // MARK: Item Construction

    /// The one way a custom view reaches the toolbar.
    ///
    /// It takes `BackdropOverlayContent` on purpose, and that is the whole enforcement: the
    /// toolbar floats over the *terminal palette's* background rather than the chrome's ground,
    /// so a view placed here that colours itself from `Design.Text` is wrong. Requiring the
    /// protocol means a new passive view or interactive control cannot be added without being
    /// handed the right ink, and the compiler says so rather than a screenshot three weeks later.
    ///
    /// System tracking separators are the exception because their job is to follow AppKit's
    /// moving split dividers; every app-owned action goes through this path.
    private func makeOverlayItem(
        identifier: NSToolbarItem.Identifier,
        view: NSView & BackdropOverlayContent
    ) -> NSToolbarItem {
        let item = NSToolbarItem(itemIdentifier: identifier)
        item.view = view
        // These draw their own surface, or none. The system bezel would double it, and on a
        // label it reads as a button.
        item.isBordered = false
        view.translatesAutoresizingMaskIntoConstraints = false
        return item
    }

    private func makeSessionTitleItem(identifier: NSToolbarItem.Identifier) -> NSToolbarItem {
        let item = makeOverlayItem(identifier: identifier, view: sessionTitleItemView)
        item.visibilityPriority = .high

        NSLayoutConstraint.activate([
            sessionTitleItemView.widthAnchor.constraint(
                greaterThanOrEqualToConstant: SessionTitleDefaults.minWidth
            ),
            sessionTitleItemView.widthAnchor.constraint(
                lessThanOrEqualToConstant: SessionTitleDefaults.maxWidth
            )
        ])

        return item
    }

    private func makeAccountUsageItem(identifier: NSToolbarItem.Identifier) -> NSToolbarItem {
        makeOverlayItem(identifier: identifier, view: accountUsageItemView)
    }

    private func makePaneToggleItem(
        identifier: NSToolbarItem.Identifier,
        symbolName: String,
        label: String,
        toolTip: String,
        onPress: @escaping () -> Void
    ) -> NSToolbarItem {
        let button = ToolbarButtonView(symbolName: symbolName, accessibility: label)
        button.toolTip = toolTip
        button.onPress = onPress

        if identifier == .toggleShellDrawer {
            shellDrawerToolbarButton = button
        } else if identifier == .toggleDisplayPane {
            displayPaneToolbarButton = button
        }

        return makeOverlayItem(identifier: identifier, view: button)
    }

    /// The context button: a menu of what applies to the session on screen. Rebuilt on every
    /// open (`menuNeedsUpdate`), because its checkmarks — which theme is chosen — go stale
    /// the moment they are drawn.
    private func makeSessionContextItem(identifier: NSToolbarItem.Identifier) -> NSToolbarItem {
        let button = ToolbarButtonView(symbolName: "ellipsis", accessibility: "Session options")
        button.toolTip = "Session Options"
        button.onPress = { [weak self, weak button] in
            guard let self, let button else { return }
            self.showSessionContextMenu(from: button)
        }
        sessionContextToolbarButton = button

        sessionContextMenu.delegate = self

        themeMenuBuilder.onEditThemes = { [weak self] in
            self?.showSettingsPage(title: SettingsPages.themesTitle)
        }

        return makeOverlayItem(identifier: identifier, view: button)
    }

    // MARK: Actions

    private func showSessionContextMenu(from button: ToolbarButtonView) {
        menuNeedsUpdate(sessionContextMenu)
        sessionContextMenu.popUp(
            positioning: nil,
            at: NSPoint(x: button.bounds.minX, y: button.bounds.minY),
            in: button
        )
    }
}

// MARK: - NSMenuDelegate

extension MainWindowController: NSMenuDelegate {

    public func menuNeedsUpdate(_ menu: NSMenu) {
        guard menu === sessionContextMenu else { return }
        menu.removeAllItems()

        // Theme, scoped to the session on screen. With none there is still a door to the
        // themes page, so the button never opens onto nothing.
        if let sessionID = currentSessionID {
            menu.addItem(themeMenuBuilder.sessionThemeItem(for: sessionID))
        } else {
            let item = NSMenuItem(
                title: "Themes…",
                action: #selector(themeSettingsClicked),
                keyEquivalent: ""
            )
            item.target = self
            menu.addItem(item)
        }
    }

    @objc private func themeSettingsClicked() {
        showSettingsPage(title: SettingsPages.themesTitle)
    }
}
