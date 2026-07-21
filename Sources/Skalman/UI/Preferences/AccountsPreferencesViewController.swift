import AppKit

/// Accounts preferences: an icon and name for each discovered agent login.
///
/// Accounts themselves are discovered from disk and cannot be added or removed here; this
/// pane only customises how they are presented. It is built from the settings design kit
/// (`SettingsUI`, `SettingsCard`, `FlatButton`) as a card of flat account rows rather than a
/// table, so it reads as one piece with the other preference panes.
final class AccountsPreferencesViewController: NSViewController {

    // MARK: - Properties

    /// Holds the freshly rebuilt page; cleared and repopulated on every `reload()`.
    private let pageContainer = NSView()

    private var accounts: [AgentAccount] = []

    /// The open icon picker, retained so it survives until dismissed.
    private var iconPopover: NSPopover?

    // MARK: - Lifecycle

    override func loadView() {
        view = NSView()
        pageContainer.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(pageContainer)
        NSLayoutConstraint.activate([
            pageContainer.topAnchor.constraint(equalTo: view.topAnchor),
            pageContainer.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            pageContainer.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            pageContainer.trailingAnchor.constraint(equalTo: view.trailingAnchor)
        ])
    }

    override func viewWillAppear() {
        super.viewWillAppear()
        reload()
    }

    // MARK: - Reload

    /// Rebuilds the whole page from the currently discovered accounts.
    private func reload() {
        accounts = AgentKind.allCases
            .filter(\.supportsAccounts)
            .flatMap { AgentAccountDiscovery.accounts(for: $0) }

        pageContainer.subviews.forEach { $0.removeFromSuperview() }

        let rows: [NSView] = accounts.isEmpty
            ? [makeEmptyRow()]
            : accounts.enumerated().map { makeAccountRow(for: $1, row: $0) }

        let card = SettingsCard(rows: rows)

        let page = SettingsUI.page([
            SettingsUI.heading("Accounts"),
            SettingsUI.section("Agent Accounts", card),
            SettingsUI.note(AccountsPreferencesStrings.explanation)
        ])

        page.translatesAutoresizingMaskIntoConstraints = false
        pageContainer.addSubview(page)
        NSLayoutConstraint.activate([
            page.topAnchor.constraint(equalTo: pageContainer.topAnchor),
            page.bottomAnchor.constraint(equalTo: pageContainer.bottomAnchor),
            page.leadingAnchor.constraint(equalTo: pageContainer.leadingAnchor),
            page.trailingAnchor.constraint(equalTo: pageContainer.trailingAnchor)
        ])
    }

    // MARK: - Row Construction

    /// One account row: icon well, name + provenance labels, and a Reset action.
    private func makeAccountRow(for account: AgentAccount, row index: Int) -> NSView {
        let icon = makeIconButton(for: account, row: index)
        let labels = makeLabelStack(for: account, row: index)

        let reset = SettingsUI.button("Reset", target: self, action: #selector(resetClicked(_:)))
        reset.tag = index
        reset.toolTip = AccountsPreferencesStrings.resetTooltip
        reset.setContentHuggingPriority(.required, for: .horizontal)

        // A dedicated spacer takes all the slack, so Reset sits at the trailing edge of every
        // row rather than trailing whatever width the labels happen to be.
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        spacer.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let stack = NSStackView(views: [icon, labels, spacer, reset])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = Design.Spacing.medium
        labels.setContentHuggingPriority(.defaultHigh, for: .horizontal)

        return padded(stack)
    }

    /// A round-ish clickable well showing the account's icon; clicking it opens the picker.
    /// The fallback icon is dimmed, so an unset account still hints at what the well is for.
    private func makeIconButton(for account: AgentAccount, row index: Int) -> NSButton {
        let button = NSButton(
            title: account.emoji ?? account.provider.fallbackIcon,
            target: self,
            action: #selector(iconClicked(_:))
        )
        button.isBordered = false
        button.bezelStyle = .inline
        button.font = .systemFont(ofSize: AccountsPreferencesLayout.emojiFontSize)
        button.tag = index
        button.alphaValue = account.emoji == nil ? AccountsPreferencesLayout.unsetIconAlpha : 1
        button.toolTip = AccountsPreferencesStrings.iconWellTooltip
        button.translatesAutoresizingMaskIntoConstraints = false
        button.applySurface(
            fill: Design.Surface.controlResting,
            radius: Design.Radius.pill(height: AccountsPreferencesLayout.iconWellSize)
        )
        button.setContentHuggingPriority(.required, for: .horizontal)
        NSLayoutConstraint.activate([
            button.widthAnchor.constraint(equalToConstant: AccountsPreferencesLayout.iconWellSize),
            button.heightAnchor.constraint(equalToConstant: AccountsPreferencesLayout.iconWellSize)
        ])
        return button
    }

    /// The editable name over a quiet caption naming the provider and its config directory.
    private func makeLabelStack(for account: AgentAccount, row index: Int) -> NSView {
        let field = NSTextField(string: account.displayName)
        field.font = Design.Typography.body()
        field.textColor = .labelColor
        field.isBordered = false
        field.isBezeled = false
        field.drawsBackground = false
        field.isEditable = true
        field.isSelectable = true
        field.focusRingType = .none
        field.lineBreakMode = .byTruncatingTail
        field.tag = index
        field.target = self
        field.action = #selector(nameChanged(_:))
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let caption = NSTextField(labelWithString:
            "\(account.provider.displayName) · \(abbreviated(account.configPath))")
        caption.font = Design.Typography.subheading()
        caption.textColor = .secondaryLabelColor
        caption.lineBreakMode = .byTruncatingMiddle
        caption.setContentHuggingPriority(.defaultLow, for: .horizontal)
        caption.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let stack = NSStackView(views: [field, caption])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = Design.Spacing.hairline
        return stack
    }

    /// Shown when no logins are found, so the empty card is not a blank panel.
    private func makeEmptyRow() -> NSView {
        let label = NSTextField(labelWithString: AccountsPreferencesStrings.emptyMessage)
        label.font = Design.Typography.body()
        label.textColor = .secondaryLabelColor
        return padded(label)
    }

    /// Wraps row content with the kit's row padding and a minimum row height.
    private func padded(_ content: NSView) -> NSView {
        let container = NSView()
        content.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(content)
        NSLayoutConstraint.activate([
            content.topAnchor.constraint(equalTo: container.topAnchor, constant: Design.Spacing.medium),
            content.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -Design.Spacing.medium),
            content.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: Design.Spacing.inset),
            content.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -Design.Spacing.inset),
            container.heightAnchor.constraint(greaterThanOrEqualToConstant: SettingsUIDefaults.rowHeight)
        ])
        return container
    }

    // MARK: - Actions

    /// Opens the emoji picker beneath the clicked icon well.
    @objc private func iconClicked(_ sender: NSButton) {
        guard let account = account(at: sender.tag) else { return }

        let picker = EmojiPickerViewController(showsRemove: account.emoji != nil)
        picker.onPick = { [weak self] emoji in
            AccountPreferencesStore.shared.setEmoji(emoji, for: account.id)
            self?.iconPopover?.close()
            self?.iconPopover = nil
            self?.reload()
            self?.notifyAccountsChanged()
        }

        let popover = NSPopover()
        popover.behavior = .transient
        popover.contentViewController = picker
        popover.show(relativeTo: sender.bounds, of: sender, preferredEdge: .maxY)
        iconPopover = popover
    }

    @objc private func nameChanged(_ sender: NSTextField) {
        guard let account = account(at: sender.tag) else { return }

        AccountPreferencesStore.shared.setDisplayNameOverride(sender.stringValue, for: account.id)
        reload()
        notifyAccountsChanged()
    }

    @objc private func resetClicked(_ sender: NSButton) {
        guard let account = account(at: sender.tag) else { return }

        AccountPreferencesStore.shared.clear(accountID: account.id)
        reload()
        notifyAccountsChanged()
    }

    // MARK: - Private Methods

    /// Maps a control's row tag back to its account.
    private func account(at index: Int) -> AgentAccount? {
        guard index >= 0, index < accounts.count else { return nil }
        return accounts[index]
    }

    private func abbreviated(_ path: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        guard path.hasPrefix(home) else { return path }
        return "~" + path.dropFirst(home.count)
    }

    /// Sidebar rows show account icons and names, so they refresh alongside this pane.
    private func notifyAccountsChanged() {
        NotificationCenter.default.post(name: .projectsDidChange, object: self)
    }
}

// MARK: - Agent Kind Fallback Icon

extension AgentKind {

    /// Emoji shown as the placeholder when no icon has been chosen.
    var fallbackIcon: String {
        switch self {
        case .claude: return "✳️"
        case .codex: return "🌀"
        case .shell: return "▶️"
        }
    }
}

// MARK: - Accounts Preferences Layout

enum AccountsPreferencesLayout {
    static let emojiFontSize: CGFloat = 16
    static let iconWellSize: CGFloat = 30
    /// Dims the fallback icon in a well with no chosen emoji.
    static let unsetIconAlpha: CGFloat = 0.35
}

// MARK: - Accounts Preferences Strings

enum AccountsPreferencesStrings {
    static let explanation = """
        Accounts are found automatically from your Claude and Codex config directories. \
        Click an icon to pick an emoji, or rename an account to tell them apart in the \
        sidebar. Clearing a name restores the one from your shell alias.
        """
    static let iconWellTooltip = "Choose an icon"
    static let resetTooltip = "Restore this account's default icon and name"
    static let emptyMessage = "No agent accounts found."
}
