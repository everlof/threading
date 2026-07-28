import AppKit

// MARK: - Toolbar Item Identifiers

extension NSToolbarItem.Identifier {
    /// App-owned sidebar toggle; the first thing in the toolbar, sitting over the sidebar.
    static let skalmanToggleSidebar = NSToolbarItem.Identifier("SkalmanToggleSidebar")

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

    /// One item, and that is the point.
    ///
    /// Everything else that lived here — the page tab, the `+`, the usage pill, the session's
    /// actions — belongs to the *content pane* and now sits in the pane's own header (see
    /// `TerminalContainerViewController.setupHeader`). A toolbar positions its items relative to
    /// the window, so anything in it that describes a pane drifts away from that pane the moment
    /// a divider moves. The sidebar toggle is the exception because it is genuinely the window's:
    /// it acts on the split, not on either side of it, and it belongs beside the traffic lights.
    public func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.skalmanToggleSidebar]
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
            let button = ThemedIconButton(
                symbolName: "sidebar.leading",
                accessibility: L10n.string("Show or hide sidebar")
            )
            button.toolTip = L10n.string("Show or Hide the Sidebar (⌃⌘S)")
            button.onPress = { [weak self] in self?.toggleSidebar() }
            sidebarToolbarButton = button
            return makeOverlayItem(identifier: itemIdentifier, view: button)

        default:
            return nil
        }
    }

    // MARK: - Pane Header

    /// Everything that names or acts on the session on screen, in one row for the content pane's
    /// own header.
    ///
    /// The window controller builds it because the window controller owns what these do — the
    /// composer, the panes, the session's menu. The pane owns only where the row sits, which is
    /// what makes it move with the pane. Reading across: which page, a way to open another, then
    /// what that page's account has left to spend, then what can be done to it.
    func makePaneHeaderView() -> NSView {
        let newSessionButton = ThemedIconButton(
            symbolName: "plus",
            accessibility: L10n.string("New session")
        )
        newSessionButton.toolTip = L10n.string("New Session (⌘N)")
        newSessionButton.onPress = { [weak self] in self?.newSession() }
        self.newSessionButton = newSessionButton

        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        spacer.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let header = NSStackView(views: [
            pageTabView,
            newSessionButton,
            spacer,
            accountUsageItemView,
            makeSessionActionsGroup()
        ])
        header.orientation = .horizontal
        header.alignment = .centerY
        header.spacing = Design.Spacing.small

        NSLayoutConstraint.activate([
            pageTabView.widthAnchor.constraint(
                greaterThanOrEqualToConstant: SessionTitleDefaults.minWidth
            ),
            pageTabView.widthAnchor.constraint(
                lessThanOrEqualToConstant: SessionTitleDefaults.maxWidth
            )
        ])

        return header
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
        // The protocol says a view *can* be inked; it cannot say which ink it took, because a
        // component that serves both grounds — the page tab, the icon button — conforms either
        // way. So the ground itself is asserted here, where the wrong one would be invisible
        // until someone looked at a light theme over a dark terminal.
        if let inked = view as? InkSourced, inked.inkSource != .backdrop {
            assertionFailure(
                "\(type(of: view)) is in the toolbar but inks from \(inked.inkSource); "
                    + "the toolbar floats over the terminal's palette, not the chrome's"
            )
        }

        let item = NSToolbarItem(itemIdentifier: identifier)
        item.view = view
        // These draw their own surface, or none. The system bezel would double it, and on a
        // label it reads as a button.
        item.isBordered = false
        view.translatesAutoresizingMaskIntoConstraints = false
        return item
    }

    /// The session's three actions, as one group.
    ///
    /// They belong together: each one acts on the session named at the other end of the header,
    /// and two of them toggle a pane of the window. Kept as separate toolbar items they were
    /// spaced as though unrelated — which is what `ToolbarButtonGroupView` exists to fix.
    private func makeSessionActionsGroup() -> ToolbarButtonGroupView {
        ToolbarButtonGroupView(buttons: [
            makeSessionContextButton(),
            makePaneToggleButton(
                symbolName: "rectangle.bottomthird.inset.filled",
                label: "Shell",
                toolTip: "Show or Hide the Shell Drawer (⌃`)",
                store: { [weak self] in self?.shellDrawerToolbarButton = $0 }
            ) { [weak self] in
                self?.toggleShellDrawer()
            },
            makePaneToggleButton(
                symbolName: "sidebar.trailing",
                label: "Panel",
                toolTip: "Show or Hide the Display Panel",
                store: { [weak self] in self?.displayPaneToolbarButton = $0 }
            ) { [weak self] in
                self?.toggleDisplayPane()
            }
        ])
    }

    private func makePaneToggleButton(
        symbolName: String,
        label: String,
        toolTip: String,
        store: (ThemedIconButton) -> Void,
        onPress: @escaping () -> Void
    ) -> ThemedIconButton {
        let button = ThemedIconButton(symbolName: symbolName, accessibility: label)
        button.toolTip = toolTip
        button.onPress = onPress
        store(button)
        return button
    }

    /// The context button: a menu of what applies to the session on screen. Rebuilt on every
    /// open (`menuNeedsUpdate`), because its checkmarks — which theme is chosen — go stale
    /// the moment they are drawn.
    private func makeSessionContextButton() -> ThemedIconButton {
        let button = ThemedIconButton(
            symbolName: "ellipsis",
            accessibility: L10n.string("Session options")
        )
        button.toolTip = L10n.string("Session Options")
        button.onPress = { [weak self, weak button] in
            guard let self, let button else { return }
            self.showSessionContextMenu(from: button)
        }
        sessionContextToolbarButton = button

        sessionContextMenu.delegate = self

        themeMenuBuilder.onEditThemes = { [weak self] in
            self?.showSettingsPage(title: SettingsPages.themesTitle)
        }

        return button
    }

    // MARK: Actions

    private func showSessionContextMenu(from button: ThemedIconButton) {
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
            menu.addItem(.separator())
            let attachments = NSMenuItem(
                title: L10n.string("Attachments"),
                action: #selector(attachmentsClicked),
                keyEquivalent: ""
            )
            attachments.image = NSImage(
                systemSymbolName: "paperclip",
                accessibilityDescription: L10n.string("Attachments")
            )
            attachments.target = self
            menu.addItem(attachments)
        } else {
            let item = NSMenuItem(
                title: L10n.string("Themes…"),
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

    @objc private func attachmentsClicked() {
        showAttachments()
    }
}

// MARK: - Page Tab Defaults

/// How wide the toolbar's page tab is allowed to grow, and what stands in for a page with no
/// mark of its own.
///
/// All that is left of what was once a parallel tab implementation: everything describing what a
/// tab *is* now lives in `ThemedTabItemView`, and these two widths are a property of this
/// particular slot in the toolbar rather than of tabs.
enum SessionTitleDefaults {
    static let minWidth: CGFloat = 120
    static let maxWidth: CGFloat = 360
    static let projectSymbolName = "folder"
}
