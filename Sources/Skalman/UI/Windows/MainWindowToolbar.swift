import AppKit

// MARK: - Toolbar Item Identifiers

extension NSToolbarItem.Identifier {
    /// Names the project and session currently shown.
    static let sessionTitle = NSToolbarItem.Identifier("SkalmanSessionTitle")

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
    /// both states. `.toggleSidebar` and `.sidebarTrackingSeparator` are system items: the
    /// first drives the split view's first item, the second keeps a divider aligned with the
    /// split position as it moves.
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
            .toggleSidebar, .sidebarTrackingSeparator,
            .sessionTitle, .flexibleSpace, .accountUsage,
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

        case .accountUsage:
            return makeAccountUsageItem(identifier: itemIdentifier)

        case .sessionContext:
            return makeSessionContextItem(identifier: itemIdentifier)

        case .toggleShellDrawer:
            return makePaneToggleItem(
                identifier: itemIdentifier,
                symbolName: "rectangle.bottomthird.inset.filled",
                label: "Shell",
                toolTip: "Show or Hide the Shell Drawer (⌃`)",
                action: #selector(toggleShellDrawerClicked)
            )

        case .toggleDisplayPane:
            return makePaneToggleItem(
                identifier: itemIdentifier,
                symbolName: "sidebar.trailing",
                label: "Panel",
                toolTip: "Show or Hide the Display Panel",
                action: #selector(toggleDisplayPaneClicked)
            )

        default:
            // .toggleSidebar and the spacers are supplied by the system.
            return nil
        }
    }

    // MARK: Item Construction

    /// The one way a custom view reaches the toolbar.
    ///
    /// It takes a `BackdropOverlay` on purpose, and that is the whole enforcement: the toolbar
    /// floats over the *terminal palette's* background rather than the chrome's ground, so a view
    /// placed here that colours itself from `Design.Text` is wrong. Requiring the type means a
    /// new button cannot be added without being handed the right ink, and the compiler says so
    /// rather than a screenshot three weeks later.
    ///
    /// System-drawn items — the bordered pane toggles, the tracking separators — are not this:
    /// AppKit draws them in its own vibrant material, which adapts to whatever is behind it.
    private func makeOverlayItem(
        identifier: NSToolbarItem.Identifier,
        view: BackdropOverlay
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
        action: Selector
    ) -> NSToolbarItem {
        let item = NSToolbarItem(itemIdentifier: identifier)
        item.image = NSImage(systemSymbolName: symbolName, accessibilityDescription: label)
        item.label = label
        item.toolTip = toolTip
        item.target = self
        item.action = action
        item.isBordered = true
        return item
    }

    /// The context button: a menu of what applies to the session on screen. Rebuilt on every
    /// open (`menuNeedsUpdate`), because its checkmarks — which theme is chosen — go stale
    /// the moment they are drawn.
    private func makeSessionContextItem(identifier: NSToolbarItem.Identifier) -> NSToolbarItem {
        let item = NSMenuToolbarItem(itemIdentifier: identifier)
        item.image = NSImage(systemSymbolName: "ellipsis.circle", accessibilityDescription: "Context")
        item.label = "Context"
        item.toolTip = "Session Options"
        item.isBordered = true
        item.showsIndicator = false

        sessionContextMenu.delegate = self
        item.menu = sessionContextMenu

        themeMenuBuilder.onEditThemes = { [weak self] in
            self?.showSettingsPage(title: SettingsPages.themesTitle)
        }

        return item
    }

    // MARK: Actions

    @objc private func toggleShellDrawerClicked() {
        toggleShellDrawer()
    }

    @objc private func toggleDisplayPaneClicked() {
        toggleDisplayPane()
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
