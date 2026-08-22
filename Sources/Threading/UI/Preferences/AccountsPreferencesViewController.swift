import AppKit

/// Accounts preferences: add or reconnect a provider login, then customise every discovered
/// login's presentation and availability.
///
/// Provider CLIs still own credentials and removal. Threading owns the isolated-home setup and
/// verification flow, plus the presentation choices below. It is built from the settings kit
/// (`SettingsUI`, `SettingsCard`, `ThemedButton`) as a card of flat account rows rather than a
/// table, so it reads as one piece with the other preference panes.
final class AccountsPreferencesViewController: NSViewController {

    // MARK: - Properties

    /// Holds the freshly rebuilt page; cleared and repopulated on every `reload()`.
    private let pageContainer = NSView()

    private let accountsProvider: () -> [AgentAccount]
    private let setupController: AccountSetupCardViewController

    private var accounts: [AgentAccount] = []

    /// The open icon picker, retained so it survives until dismissed.
    private var iconPopover: ThemedPopover?

    /// The limits half of the page. Retained across rebuilds because it holds which folds are
    /// open, and a fold that closed every time a rule was added would be the page arguing with
    /// the person using it.
    private let limits: AccountLimitsSectionController

    init(
        accountsProvider: @escaping () -> [AgentAccount] = {
            AgentKind.allCases
                .filter(\.supportsAccounts)
                .flatMap { AgentAccountDiscovery.allAccounts(for: $0) }
        },
        setupCoordinator: AgentAccountSetupCoordinator = AgentAccountSetupCoordinator(),
        limitSettings: CustomLimitSettings? = nil,
        accountStore: AccountPreferencesStore? = nil
    ) {
        self.accountsProvider = accountsProvider
        self.setupController = AccountSetupCardViewController(coordinator: setupCoordinator)
        self.limits = AccountLimitsSectionController(
            settings: limitSettings,
            accountStore: accountStore
        )
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - Lifecycle

    override func loadView() {
        view = NSView()
        addChild(setupController)
        setupController.onAccountReady = { [weak self] _ in
            self?.reload()
            self?.notifyAccountsChanged()
        }
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

    /// Opens the limit folds in the production Accounts page for deterministic rendered evidence.
    func expandLimitsForTesting() {
        limits.expandEverythingForTesting()
    }

    // MARK: - Reload

    /// Rebuilds the whole page from the currently discovered accounts.
    private func reload() {
        // Every discovered login, including the ones switched off: this is the one page where a
        // disabled account has to appear, since it is where it is switched back on.
        accounts = accountsProvider()

        pageContainer.subviews.forEach { $0.removeFromSuperview() }

        let rows: [NSView] = accounts.isEmpty
            ? [makeEmptyRow()]
            : accounts.enumerated().map { makeAccountRow(for: $1, row: $0) }

        let card = SettingsCard(rows: rows)
        limits.onChange = { [weak self] in self?.notifyAccountsChanged() }
        limits.reload(accounts: accounts)

        let page = SettingsUI.page(title: "Accounts", sections: [
            SettingsUI.section("Add or Reconnect", setupController.view),
            SettingsUI.section("Agent Accounts", card),
            SettingsUI.note(AccountsPreferencesStrings.explanation),
            limits.view
        ], hostPage: .accounts)

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

    /// One account row: icon well, name + provenance labels, an explicit presentation restore
    /// action and the switch that takes the account out of use.
    private func makeAccountRow(for account: AgentAccount, row index: Int) -> NSView {
        let icon = makeIconButton(for: account, row: index)
        let labels = makeLabelStack(for: account, row: index)

        let restore = SettingsUI.button(
            AccountsPreferencesStrings.restorePresentationButton,
            target: self,
            action: #selector(restorePresentationClicked(_:)),
            localizes: false
        )
        restore.tag = index
        restore.toolTip = AccountsPreferencesStrings.restorePresentationTooltip
        restore.setContentHuggingPriority(.required, for: .horizontal)

        let reconnect = SettingsUI.button(
            AccountsPreferencesStrings.reconnectButton,
            target: self,
            action: #selector(reconnectClicked(_:)),
            localizes: false
        )
        reconnect.tag = index
        reconnect.toolTip = AccountsPreferencesStrings.reconnectTooltip
        reconnect.setContentHuggingPriority(.required, for: .horizontal)

        let enabled = SettingsUI.toggle(
            isOn: account.isEnabled,
            target: self,
            action: #selector(enabledChanged(_:))
        )
        enabled.tag = index
        enabled.toolTip = AccountsPreferencesStrings.enabledTooltip
        enabled.setAccessibilityLabel(AccountsPreferencesStrings.enabledLabel(account.displayName))

        // A switched-off account is still listed — this is where it is switched back on — so it
        // says so by going quiet rather than by leaving. Everything but the switch dims: the
        // control that undoes the state must not itself look unavailable.
        let dimmed = account.isEnabled ? 1 : AccountsPreferencesLayout.disabledRowAlpha
        icon.alphaValue *= dimmed
        labels.alphaValue = dimmed

        // Keep identity and availability on the first line. The two text actions have their own
        // trailing line so the real 396-point Settings pane does not crush the account name.
        let identitySpacer = NSView()
        identitySpacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        identitySpacer.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let identity = NSStackView(views: [icon, labels, identitySpacer, enabled])
        identity.orientation = .horizontal
        identity.alignment = .centerY
        identity.spacing = Design.Spacing.medium
        labels.setContentHuggingPriority(.defaultHigh, for: .horizontal)

        let actions = SettingsUI.controlGroup(
            [restore, reconnect],
            spacing: Design.Spacing.small
        )
        let actionSpacer = NSView()
        actionSpacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        actionSpacer.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let actionLine = NSStackView(views: [actionSpacer, actions])
        actionLine.orientation = .horizontal
        actionLine.alignment = .centerY

        let stack = NSStackView(views: [identity, actionLine])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = Design.Spacing.small
        identity.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        actionLine.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true

        return padded(stack)
    }

    /// A round-ish clickable well showing the account's icon; clicking it opens the picker.
    /// The fallback icon is dimmed, so an unset account still hints at what the well is for.
    private func makeIconButton(for account: AgentAccount, row index: Int) -> ThemedButton {
        let button = ThemedButton(
            title: account.emoji ?? account.provider.fallbackIcon,
            target: self,
            action: #selector(iconClicked(_:))
        )
        button.isBordered = false
        button.applyFont(.accountEmoji)
        button.tag = index
        button.alphaValue = account.emoji == nil ? AccountsPreferencesLayout.unsetIconAlpha : 1
        button.toolTip = AccountsPreferencesStrings.iconWellTooltip
        button.translatesAutoresizingMaskIntoConstraints = false
        button.applySurface(
            fill: Design.Surface.controlResting,
            radius: .pill(height: AccountsPreferencesLayout.iconWellSize)
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
        let field = ThemedTextField(string: account.displayName)
        field.applyFont(.body)
        field.textColor = Design.Text.label
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
        caption.applyFont(.subheading)
        caption.textColor = Design.Text.secondary
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
        label.applyFont(.body)
        label.textColor = Design.Text.secondary
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
    @objc private func iconClicked(_ sender: ThemedButton) {
        guard let account = account(at: sender.tag) else { return }

        let picker = EmojiPickerViewController(showsRemove: account.emoji != nil)
        picker.onPick = { [weak self] emoji in
            AccountPreferencesStore.shared.setEmoji(emoji, for: account.id)
            self?.iconPopover?.close()
            self?.iconPopover = nil
            self?.reload()
            self?.notifyAccountsChanged()
        }

        let popover = HostPopoverFactory.make(.settingsAccountIconPicker)
        // Semi-transient, not transient: the system Emoji & Symbols picker opens as its own
        // panel, and a transient popover would close the moment it appears — taking the field
        // that panel inserts into with it. Semi-transient survives that and still dismisses on
        // a click back in the main window.
        popover.behavior = .semitransient
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

    @objc private func restorePresentationClicked(_ sender: ThemedButton) {
        guard let account = account(at: sender.tag) else { return }

        AccountPreferencesStore.shared.clearPresentation(for: account.id)
        reload()
        notifyAccountsChanged()
    }

    /// Runs the provider-owned browser login again under this account's existing config home.
    /// Credentials and transcripts remain provider-owned; no directory is removed or replaced.
    @objc private func reconnectClicked(_ sender: ThemedButton) {
        guard let account = account(at: sender.tag) else { return }
        setupController.reconnect(account)
        setupController.view.scrollToVisible(setupController.view.bounds)
    }

    /// Takes an account out of use, or puts it back.
    ///
    /// Nothing on disk is touched: the config directory stays, its conversations stay, and the
    /// sessions already running on it keep resolving to it. What changes is that the login stops
    /// being offered — the composer's account chip, the sidebar's new-session menus, the usage
    /// readings and the import list all draw from the accounts a provider *offers*.
    @objc private func enabledChanged(_ sender: ThemedToggle) {
        guard let account = account(at: sender.tag) else { return }

        AccountPreferencesStore.shared.setEnabled(sender.state == .on, for: account.id)
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
        NotificationCenter.default.post(ProjectsDidChange())
    }
}

// MARK: - Agent Kind Fallback Icon

extension AgentKind {

    /// Emoji shown as the placeholder when no icon has been chosen.
    var fallbackIcon: String {
        switch self {
        case .claude: return "✳️"
        case .codex: return "🌀"
        case .grok: return "𝕏"
        case .openCode: return "{}"
        case .cursor: return "➤"
        }
    }
}

// MARK: - Accounts Preferences Layout

enum AccountsPreferencesLayout {
    static let emojiFontSize: CGFloat = 16
    static let iconWellSize: CGFloat = 30
    /// Dims the fallback icon in a well with no chosen emoji.
    static let unsetIconAlpha: CGFloat = 0.35
    /// Dims a switched-off account, which stays listed so it can be switched back on.
    static let disabledRowAlpha: CGFloat = 0.4
}

// MARK: - Accounts Preferences Strings

enum AccountsPreferencesStrings {
    static var explanation: String {
        L10n.string("""
            Add and reconnect logins with the provider's own secure browser flow; Threading \
            stores only the isolated config location, never a credential. Existing Claude and \
            Codex config directories are still found automatically. Click an icon or rename a \
            login to tell them apart. Switch one off to stop offering it for new sessions — \
            nothing is deleted, and sessions already running on it keep working.
            """)
    }
    static var iconWellTooltip: String { L10n.string("Choose an icon") }
    static var restorePresentationButton: String {
        L10n.string("Restore Name & Icon")
    }
    static var restorePresentationTooltip: String {
        L10n.string("Restore this account's detected name and provider icon")
    }
    static var enabledTooltip: String {
        L10n.string("Offer this account for new sessions")
    }
    static var reconnectButton: String { L10n.string("Reconnect") }
    static var reconnectTooltip: String {
        L10n.string("Run this provider's secure sign-in again")
    }
    static var emptyMessage: String {
        L10n.string("No agent accounts yet. Set up one to get started.")
    }

    static func enabledLabel(_ accountName: String) -> String {
        L10n.format("Use %@ for new sessions", accountName)
    }
}
