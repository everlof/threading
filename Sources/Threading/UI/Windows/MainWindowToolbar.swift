import AppKit

// MARK: - Toolbar Item Identifiers

extension NSToolbarItem.Identifier {
    /// App-owned sidebar toggle; the first thing in the toolbar, sitting over the sidebar.
    static let threadingToggleSidebar = NSToolbarItem.Identifier("ThreadingToggleSidebar")

    /// Back and forward through the window's selection history, as one grouped item beside
    /// the sidebar toggle.
    static let threadingNavigation = NSToolbarItem.Identifier("ThreadingNavigation")
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

    /// Only what acts on the window itself, and that is the point.
    ///
    /// Everything else that lived here — the page tab, the `+`, the usage pill, the session's
    /// actions — belongs to the *content pane* and now sits in the pane's own header (see
    /// `TerminalContainerViewController.setupHeader`). A toolbar positions its items relative to
    /// the window, so anything in it that describes a pane drifts away from that pane the moment
    /// a divider moves. The two exceptions are genuinely the window's: the sidebar toggle acts
    /// on the split, not on either side of it, and the history buttons retrace the *window's*
    /// page selection — both belong beside the traffic lights. Anything added here must also be
    /// measured by `updateHeaderInset`, which clears the pane header past the trailing-most
    /// toolbar control when the sidebar is collapsed.
    public func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.threadingToggleSidebar, .threadingNavigation]
    }

    public func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarDefaultItemIdentifiers(toolbar)
    }

    public func toolbar(
        _ toolbar: NSToolbar,
        itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier,
        willBeInsertedIntoToolbar flag: Bool
    ) -> NSToolbarItem? {
        let constructionStarted = DispatchTime.now().uptimeNanoseconds
        defer {
            recordStartupToolbarItemConstruction(
                DispatchTime.now().uptimeNanoseconds - constructionStarted
            )
        }

        switch itemIdentifier {
        case .threadingToggleSidebar:
            let button = ThemedIconButton(
                symbolName: "sidebar.leading",
                accessibility: L10n.string("Show or hide sidebar")
            )
            button.toolTip = L10n.string("Show or Hide the Sidebar (⌃⌘S)")
            button.onPress = { [weak self] in self?.toggleSidebar() }
            sidebarToolbarButton = button
            return makeOverlayItem(identifier: itemIdentifier, view: button)

        case .threadingNavigation:
            let back = ThemedIconButton(
                symbolName: "chevron.left",
                accessibility: L10n.string("Go back")
            )
            back.toolTip = L10n.string("Go Back (⌃⌘←)")
            back.onPress = { [weak self] in self?.goBack() }
            back.isEnabled = false
            navBackToolbarButton = back

            let forward = ThemedIconButton(
                symbolName: "chevron.right",
                accessibility: L10n.string("Go forward")
            )
            forward.toolTip = L10n.string("Go Forward (⌃⌘→)")
            forward.onPress = { [weak self] in self?.goForward() }
            forward.isEnabled = false
            navForwardToolbarButton = forward

            return makeOverlayItem(
                identifier: itemIdentifier,
                view: ToolbarButtonGroupView(buttons: [back, forward])
            )

        default:
            return nil
        }
    }

    // MARK: - Pane Header

    /// Everything that names or acts on the page on screen, in one row for the content pane's
    /// own header.
    ///
    /// The window controller builds it because the window controller owns what these do — the
    /// composer, the panes, the session's menu. The pane owns only where the row sits, which is
    /// what makes it move with the pane. Reading across: which page and what can be done to it,
    /// then what that page's account has left to spend, then which surfaces are on screen.
    /// Settings swaps the page's name for a plain mode label and Done action; its categories are
    /// destinations in the sidebar, not documents in this row.
    ///
    /// **The two halves answer different questions**, which is why the `⋯` sits against the name
    /// rather than in the group at the far end: everything trailing is "what is on screen"
    /// — an editor to leave for, an account's budget, four surfaces to show or hide — while the
    /// menu acts on the page the header just named. Held at the other end of a wide pane it read
    /// as a fifth pane toggle, and the thing it acts on was 1,200pt away.
    func makePaneHeaderView() -> NSView {
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        spacer.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let openIn = makeOpenInControl()
        var headerItems: [NSView] = [
            settingsModeHeaderView,
            spacer,
            openIn,
            makeSessionActionsGroup(),
            settingsModeDoneButton
        ]
        if let materializedPageTitleView {
            headerItems.insert(materializedPageTitleView, at: 0)
        }
        if let materializedAccountUsageItemView,
           let openInIndex = headerItems.firstIndex(where: { $0 === openIn }) {
            headerItems.insert(materializedAccountUsageItemView, at: openInIndex)
        }

        let header = NSStackView(views: headerItems)
        header.orientation = .horizontal
        header.alignment = .centerY
        header.spacing = Design.Spacing.small
        paneHeaderStackView = header

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

    /// The way out of Threading and into an editor, as one split control: the app's own icon
    /// opens the checkout in whichever app was reached for last, and the chevron beside it
    /// chooses a different one.
    ///
    /// **Its own group, beside the session's actions rather than inside them.** The four buttons
    /// to its right act on the pane — its menu, its renderer, its two drawers — while this one
    /// leaves for somewhere else entirely, and a run of six identical squares would have said
    /// those were the same kind of thing. It is also why the primary button carries the target
    /// app's *icon* rather than a symbol: the one question it has to answer at a glance is
    /// "where will this send me", and only Xcode's own hammer answers that without being read.
    ///
    /// A press is one click because that is the whole point of the control — the chevron exists
    /// for the day the answer is different, not for every day. The chosen app becomes the new
    /// preference, so the two halves converge on one press for anybody who uses one editor.
    ///
    /// **One plate, two halves** (`SplitIconButtonView`), rather than two buttons spaced as
    /// siblings. The group beside it holds four actions that act on four different things; these
    /// two act on one, and read as two unrelated marks — an app icon, and a chevron floating next
    /// to it — until they share a silhouette. Hover is where the old arrangement gave itself
    /// away: each half raised its own rounded rect, and pointing at the control cut it in two.
    private func makeOpenInControl() -> SplitIconButtonView {
        let open = ThemedIconButton(
            symbolName: OpenInToolbarDefaults.fallbackSymbol,
            accessibility: L10n.string("Open in external app"),
            glyphMaterialization: .deferred
        )
        open.onPress = { [weak self] in self?.openInPreferredApp() }
        openInToolbarButton = open

        let choose = ThemedIconButton(
            symbolName: DesignSymbols.chevron,
            accessibility: L10n.string("Choose an app to open in"),
            target: .splitMenu,
            glyphMaterialization: .deferred
        )
        // Names what the chevron adds rather than repeating the button beside it: the press
        // already says where it goes, and this is the way to somewhere else.
        choose.toolTip = L10n.string("Choose an app to open in")
        choose.presentsMenu = true
        choose.onPress = { [weak self, weak choose] in
            guard let self, let choose else { return }
            self.presentOpenInMenu(from: choose)
        }
        openInMenuToolbarButton = choose

        let control = SplitIconButtonView(action: open, chevron: choose)
        openInSplitControl = control
        return control
    }

    /// The pane's four surface controls, as one group.
    ///
    /// They belong together: each one decides what this pane shows — which renderer, and which
    /// of its three attachable surfaces are on screen. Kept as separate toolbar items they were
    /// spaced as though unrelated — which is what `ToolbarButtonGroupView` exists to fix. The
    /// session's *menu* is deliberately not among them; see `makePaneHeaderView`.
    private func makeSessionActionsGroup() -> ToolbarButtonGroupView {
        let group = ToolbarButtonGroupView(buttons: [
            makeSurfaceToggleButton(),
            // Beside the two drawers rather than off on its own: all three answer "is this
            // surface on screen", and the card is the one of the three that floats *over* the
            // session rather than beside it — which is exactly why it needs a way off.
            makePaneToggleButton(
                symbolName: "rectangle.inset.topright.filled",
                label: "Status card",
                toolTip: "Show or Hide the Status Card",
                store: { [weak self] in self?.statusCardToolbarButton = $0 }
            ) { [weak self] in
                self?.toggleStatusCard()
            },
            makePaneToggleButton(
                symbolName: "rectangle.bottomthird.inset.filled",
                label: "Shell",
                toolTip: "Show or Hide the Shell Drawer (⌃`)",
                store: { [weak self] in self?.shellDrawerToolbarButton = $0 }
            ) { [weak self] in
                self?.toggleShellDrawer()
            },
            // The panel's toggle is *one* control with two homes: this group, and the panel's own
            // corner while the panel is open — same glyph, same size, same distance from the
            // window's trailing edge. `updatePaneToggleSelection` moves this very view between
            // them rather than swapping in a second one, which is what keeps a run of clicks
            // working. See `DisplayPanelToggle`.
            makePaneToggleButton(
                symbolName: DisplayPanelToggle.symbolName,
                label: DisplayPanelToggle.accessibility,
                toolTip: DisplayPanelToggle.toolTip,
                store: { [weak self] in self?.displayPaneToolbarButton = $0 }
            ) { [weak self] in
                self?.toggleDisplayPane()
            }
        ])
        sessionActionsGroup = group
        return group
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

    /// A one-click surface switch. Its glyph and accessible name are updated from the visible
    /// session: a terminal session points at native conversation rendering, and a native
    /// session points back at the agent's own terminal UI.
    private func makeSurfaceToggleButton() -> ThemedIconButton {
        let button = ThemedIconButton(
            symbolName: SessionSurfaceTogglePresentation.nativeSymbol,
            accessibility: L10n.string("Switch session interface"),
            glyphMaterialization: .deferred
        )
        button.onPress = { [weak self] in
            self?.toggleCurrentSessionSurface()
        }
        surfaceToggleToolbarButton = button
        return button
    }

    // MARK: Actions

    /// Opens the visible page's checkout in the app used last. Also the ⌘O command's whole body.
    func openInPreferredApp() {
        guard let folder = currentFolderURL else {
            NSSound.beep()
            return
        }

        ExternalAppLauncher.shared.openInPreferredApp(.folder(folder))
        updateOpenInControls()
    }

    /// The dropdown of installed apps, opened from the chevron.
    ///
    /// `refresh()` first: this is the one moment the list is about to be read, and an app
    /// installed since launch should be in it. The choice made here becomes the button's own,
    /// which is what keeps the two halves of the control agreeing.
    private func presentOpenInMenu(from source: ThemedIconButton) {
        ThemedMenuPresenter.dismiss(openInMenuSession)
        ExternalAppLauncher.shared.refresh()

        guard let folder = currentFolderURL else {
            NSSound.beep()
            return
        }

        let target = ExternalAppTarget.folder(folder)
        let entries = OpenInMenu.entries(for: target) { [weak self] app in
            ExternalAppLauncher.shared.open(target, in: app)
            self?.updateOpenInControls()
        }

        let preferred = ExternalAppLauncher.shared.preferred(for: target)
        let selected = ExternalAppLauncher.shared.installed(for: target)
            .firstIndex { $0.id == preferred?.id }

        openInMenuSession = ThemedMenuPresenter.present(
            ThemedMenuPresentation(entries: entries, minimumWidth: OpenInMenuDefaults.menuWidth),
            from: source,
            selectedEntryIndex: selected,
            onChoose: { _, item in item.onChoose?() },
            onDismiss: { [weak self] in self?.openInMenuSession = nil }
        )
    }

    /// Points the control at the app a press would use, or hides it where there is nothing to
    /// open — Settings carries no checkout, and a Mac with none of these apps installed carries
    /// no answer at all.
    func updateOpenInControls() {
        let launcher = ExternalAppLauncher.shared
        let app = currentFolderURL.flatMap { launcher.preferred(for: .folder($0)) }

        // The plate goes with them: hiding the halves alone would leave an empty surface sitting
        // in the header, which is a control that says there is something here to press.
        openInSplitControl?.isHidden = app == nil

        guard let app else { return }

        let title = L10n.format("Open in %@", app.name)
        openInToolbarButton?.setImage(launcher.icon(for: app), accessibility: title)
        openInToolbarButton?.toolTip = OpenInToolbarDefaults.tooltip(opening: app)
    }

    /// The same menu as the session row, rebuilt on every open so live checkmarks, runtime
    /// actions, accounts, and extension commands cannot drift. Opened by the `⋯` the page's name
    /// carries — see `PageTitleView`.
    func showSessionContextMenu(from button: ThemedIconButton) {
        // Settings has no session row to mirror, but the context button remains its door to
        // theme editing instead of opening an empty menu.
        let entries = visibleSessionActionEntries() ?? [
            .item(ThemedMenuItem(
                title: L10n.string("Themes…"),
                onChoose: { [weak self] in self?.themeSettingsClicked() }
            ))
        ]

        sessionContextMenuSession = ThemedMenuPresenter.present(
            ThemedMenuPresentation(
                entries: entries,
                minimumWidth: SidebarDefaults.menuWidth
            ),
            from: button,
            selectedEntryIndex: nil,
            onChoose: { _, item in item.onChoose?() },
            onDismiss: { [weak self] in self?.sessionContextMenuSession = nil }
        )
    }

    @objc private func themeSettingsClicked() {
        showSettingsPage(title: SettingsPages.themesTitle)
    }
}

// MARK: - Page Tab Defaults

/// How wide the page's name is allowed to grow, and what stands in for a page with no mark of
/// its own.
///
/// A cap and no floor. The floor existed to keep a *tab* from changing width around every
/// session name — a plate that resized itself as pages changed reads as chrome twitching — and
/// with the plate gone there is nothing to hold open: a plain name hugs its own line the way the
/// header's other labels do, and only the cap still has a job.
enum SessionTitleDefaults {
    static let maxWidth: CGFloat = 360
    static let projectSymbolName = "folder"
}

// MARK: - Open In Defaults

/// What the header's "Open in" control shows before it knows which app it points at.
enum OpenInToolbarDefaults {
    /// Stands in for one press only: the control is hidden whenever no app was resolved, so
    /// this is what the button is *built* with, not what it settles at.
    static let fallbackSymbol = "arrow.up.forward.app"

    /// The tooltip names the app *and* the chord, read from the command table rather than
    /// written down — ⌘O is rebindable, and a tooltip promising a chord the user has changed is
    /// worse than one that promises none.
    @MainActor
    static func tooltip(opening app: ExternalApp) -> String {
        let title = L10n.format("Open in %@", app.name)
        guard let shortcut = ShortcutOverrideStore.shared.shortcut(forID: AppCommands.ID.openIn) else {
            return title
        }
        return "\(title) (\(shortcut.displayString))"
    }
}
