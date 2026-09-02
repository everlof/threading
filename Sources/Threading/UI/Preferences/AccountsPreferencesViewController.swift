import AppKit

/// Accounts preferences: add or reconnect a provider login, then customise every discovered
/// login's presentation and availability.
///
/// Provider CLIs still own credentials and removal. Threading owns the isolated-home setup and
/// verification flow, plus the presentation choices below. It is built from the settings kit
/// (`SettingsUI`, `ThemedGroupedTableView`, `ThemedButton`) as virtual card rows: the complete
/// account and limit ordering is cheap value state, while AppKit owns only the viewport.
final class AccountsPreferencesViewController: NSViewController {

    private enum PresentationRow {
        case setup
        case accountCaption
        case emptyAccount
        case account(Int)
        case accountNote
        case limit(AccountLimitsSectionController.PresentationRow)
        case extensionCaption(Int)
        case extensionField(section: Int, field: Int)
    }

    // MARK: - Properties

    private let accountsProvider: () -> [AgentAccount]
    private let setupController: AccountSetupCardViewController
    private let accountStore: AccountPreferencesStore

    private var accounts: [AgentAccount] = []
    private var extensionSections: [ExtensionSettingsSectionModel] = []
    private var presentationRows: [PresentationRow] = []

    /// The name field currently holding AppKit's shared field editor. Retained weakly so closing
    /// Settings can settle its text before the virtual row and controller disappear.
    private weak var editingNameField: ThemedTextField?

    /// The open icon picker, retained so it survives until dismissed.
    private var iconPopover: ThemedPopover?

    /// The limits half of the page. Retained across rebuilds because it holds which folds are
    /// open, and a fold that closed every time a rule was added would be the page arguing with
    /// the person using it.
    private let limits: AccountLimitsSectionController

    private lazy var tableView: ThemedGroupedTableView = {
        let table = ThemedGroupedTableView()
        let column = NSTableColumn(
            identifier: NSUserInterfaceItemIdentifier("AccountsSettingsContent")
        )
        column.resizingMask = .autoresizingMask
        table.addTableColumn(column)
        table.headerView = nil
        table.style = .plain
        table.selectionHighlightStyle = .none
        table.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        table.intercellSpacing = .zero
        table.rowHeight = AccountsPreferencesLayout.estimatedRowHeight
        table.usesAutomaticRowHeights = true
        table.autoresizingMask = [.width]
        table.delegate = self
        table.dataSource = self
        return table
    }()

    private lazy var scrollView: ThemedScrollView = {
        let scroll = ThemedScrollView()
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.automaticallyAdjustsContentInsets = false
        scroll.documentView = tableView
        return scroll
    }()

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
        let accountStore = accountStore ?? AccountPreferencesStore.shared
        self.accountsProvider = accountsProvider
        self.setupController = AccountSetupCardViewController(coordinator: setupCoordinator)
        self.accountStore = accountStore
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
        limits.onChange = { [weak self] in self?.notifyAccountsChanged() }
        limits.onPresentationChange = { [weak self] in self?.reloadPresentationRows() }

        let page = SettingsUI.listPage(
            title: "Agents & Accounts",
            body: scrollView
        )
        page.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(page)
        NSLayoutConstraint.activate([
            page.topAnchor.constraint(equalTo: view.topAnchor),
            page.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            page.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            page.trailingAnchor.constraint(equalTo: view.trailingAnchor)
        ])
    }

    override func viewWillAppear() {
        super.viewWillAppear()
        reload()
    }

    override func viewWillDisappear() {
        // Ending editing is normally delivered by the field delegate. Closing the Settings
        // window can remove this page first, so settle the active field explicitly as the final
        // path out. The later delegate callback is harmless because the durable value now
        // matches.
        if let editingNameField {
            self.editingNameField = nil
            commitNameEdit(in: editingNameField, reloadAfterCommit: false)
        }
        super.viewWillDisappear()
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        let width = tableView.tableColumns.first?.width ?? tableView.bounds.width
        tableView.enumerateAvailableRowViews { rowView, _ in
            for cell in rowView.subviews {
                (cell as? ThemedVirtualTableCell)?.setColumnWidth(width)
            }
        }
    }

    /// Opens the limit folds in the production Accounts page for deterministic rendered evidence.
    func expandLimitsForTesting() {
        limits.expandEverythingForTesting()
    }

    // MARK: - Reload

    /// Refreshes the complete cheap model. The fixed page and scroll owner survive, and AppKit
    /// recycles only cells intersecting the viewport.
    private func reload() {
        // Every discovered login, including the ones switched off: this is the one page where a
        // disabled account has to appear, since it is where it is switched back on.
        accounts = accountsProvider()
        limits.reload(accounts: accounts)
        extensionSections = ExtensionSettingsRenderer.hostSectionModels(for: .accounts)
        reloadPresentationRows()
    }

    private func reloadPresentationRows() {
        var rows: [PresentationRow] = [.setup, .accountCaption]
        if accounts.isEmpty {
            rows.append(.emptyAccount)
        } else {
            rows.append(contentsOf: accounts.indices.map(PresentationRow.account))
        }
        rows.append(.accountNote)
        rows.append(contentsOf: limits.presentationRows.map(PresentationRow.limit))
        for (sectionIndex, section) in extensionSections.enumerated() {
            if section.visibleTitle != nil {
                rows.append(.extensionCaption(sectionIndex))
            }
            rows.append(contentsOf: section.fields.indices.map {
                .extensionField(section: sectionIndex, field: $0)
            })
        }
        presentationRows = rows
        updateCardDecorations()
        tableView.reloadData()
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
        field.delegate = self
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
            guard let self else { return }
            self.accountStore.setEmoji(emoji, for: account.id)
            self.iconPopover?.close()
            self.iconPopover = nil
            self.reload()
            self.notifyAccountsChanged()
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

    @objc private func restorePresentationClicked(_ sender: ThemedButton) {
        guard let account = account(at: sender.tag) else { return }

        accountStore.clearPresentation(for: account.id)
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

        accountStore.setEnabled(sender.state == .on, for: account.id)
        reload()
        notifyAccountsChanged()
    }

    // MARK: - Private Methods

    /// Maps a control's row tag back to its account.
    private func account(at index: Int) -> AgentAccount? {
        guard index >= 0, index < accounts.count else { return nil }
        return accounts[index]
    }

    private func commitNameEdit(
        in field: ThemedTextField,
        reloadAfterCommit: Bool
    ) {
        guard let account = account(at: field.tag) else { return }
        let previous = accountStore.displayNameOverride(for: account.id)
        accountStore.setDisplayNameOverride(field.stringValue, for: account.id)
        let current = accountStore.displayNameOverride(for: account.id)

        guard current != previous else { return }
        if reloadAfterCommit {
            // Rebuild from discovery so clearing the field immediately restores its automatic
            // name, and trimming is reflected in the standing value.
            reload()
        }
        notifyAccountsChanged()
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

    /// Stress-fixture observability: complete value rows versus live viewport cells.
    var virtualRowCountForTesting: Int { presentationRows.count }

    var materializedRowCountForTesting: Int {
        var count = 0
        tableView.enumerateAvailableRowViews { _, _ in count += 1 }
        return count
    }
}

// MARK: - Account Name Editing

extension AccountsPreferencesViewController: NSTextFieldDelegate {
    func controlTextDidBeginEditing(_ notification: Notification) {
        guard let field = notification.object as? ThemedTextField else { return }
        editingNameField = field
    }

    func controlTextDidEndEditing(_ notification: Notification) {
        guard let field = notification.object as? ThemedTextField else { return }
        if editingNameField === field {
            editingNameField = nil
        }
        commitNameEdit(in: field, reloadAfterCommit: true)
    }
}

// MARK: - Virtualized Page

extension AccountsPreferencesViewController: NSTableViewDataSource, NSTableViewDelegate {
    func numberOfRows(in _: NSTableView) -> Int {
        presentationRows.count
    }

    func tableView(_: NSTableView, shouldSelectRow _: Int) -> Bool {
        false
    }

    func tableView(
        _ tableView: NSTableView,
        viewFor _: NSTableColumn?,
        row tableRow: Int
    ) -> NSView? {
        guard presentationRows.indices.contains(tableRow) else { return nil }
        let identifier = NSUserInterfaceItemIdentifier("AccountsSettingsVirtualRow")
        let host = tableView.makeView(
            withIdentifier: identifier,
            owner: self
        ) as? ThemedVirtualTableCell ?? ThemedVirtualTableCell()
        host.identifier = identifier
        host.install(
            content(for: presentationRows[tableRow]),
            columnWidth: tableView.tableColumns.first?.width ?? tableView.bounds.width,
            horizontalInset: Design.Size.glowGutter,
            topInset: topInset(forRowAt: tableRow),
            bottomInset: bottomInset(forRowAt: tableRow)
        )
        return host
    }

    private func content(for row: PresentationRow) -> NSView {
        switch row {
        case .setup:
            return SettingsUI.section("Supported agents", setupController.view)
        case .accountCaption:
            return SettingsUI.caption("Managed accounts")
        case .emptyAccount:
            return makeEmptyRow()
        case .account(let index):
            guard accounts.indices.contains(index) else { return NSView() }
            return makeAccountRow(for: accounts[index], row: index)
        case .accountNote:
            return SettingsUI.note(AccountsPreferencesStrings.explanation)
        case .limit(let row):
            return limits.content(for: row)
        case .extensionCaption(let sectionIndex):
            guard extensionSections.indices.contains(sectionIndex),
                  let title = extensionSections[sectionIndex].visibleTitle else { return NSView() }
            let caption = SettingsUI.caption(title, localizes: false)
            caption.setAccessibilityIdentifier(
                extensionSections[sectionIndex].accessibilityIdentifier
            )
            return caption
        case .extensionField(let sectionIndex, let fieldIndex):
            guard extensionSections.indices.contains(sectionIndex) else { return NSView() }
            return ExtensionSettingsRenderer.fieldRow(
                in: extensionSections[sectionIndex],
                fieldIndex: fieldIndex
            )
        }
    }

    private func topInset(forRowAt index: Int) -> CGFloat {
        guard presentationRows.indices.contains(index) else { return 0 }
        switch presentationRows[index] {
        case .setup, .accountCaption, .accountNote:
            return Design.Spacing.large
        case .emptyAccount, .account:
            return Design.Spacing.small
        case .limit(let row):
            switch row {
            case .alertsSection, .scopeHeader, .note:
                return Design.Spacing.large
            case .rule, .empty, .add:
                return 0
            }
        case .extensionCaption:
            return Design.Spacing.large
        case .extensionField(let sectionIndex, let fieldIndex):
            guard fieldIndex == 0, extensionSections.indices.contains(sectionIndex) else {
                return 0
            }
            return extensionSections[sectionIndex].visibleTitle == nil
                ? Design.Spacing.large
                : Design.Spacing.small
        }
    }

    private func bottomInset(forRowAt index: Int) -> CGFloat {
        guard presentationRows.indices.contains(index) else { return 0 }
        switch presentationRows[index] {
        case .accountCaption, .extensionCaption:
            return Design.Spacing.small
        default:
            return index == presentationRows.count - 1 ? Design.Spacing.large : 0
        }
    }

    private func updateCardDecorations() {
        var accountBounds: (first: Int, last: Int)?
        var limitBounds: [Int: (first: Int, last: Int)] = [:]
        var extensionBounds: [Int: (first: Int, last: Int)] = [:]

        for (index, row) in presentationRows.enumerated() {
            switch row {
            case .emptyAccount, .account:
                if var bounds = accountBounds {
                    bounds.last = index
                    accountBounds = bounds
                } else {
                    accountBounds = (index, index)
                }
            case .limit(let limitRow):
                guard let scopeIndex = limits.cardScopeIndex(for: limitRow) else { continue }
                if var bounds = limitBounds[scopeIndex] {
                    bounds.last = index
                    limitBounds[scopeIndex] = bounds
                } else {
                    limitBounds[scopeIndex] = (index, index)
                }
            case .extensionField(let sectionIndex, _):
                if var bounds = extensionBounds[sectionIndex] {
                    bounds.last = index
                    extensionBounds[sectionIndex] = bounds
                } else {
                    extensionBounds[sectionIndex] = (index, index)
                }
            case .setup, .accountCaption, .accountNote, .extensionCaption:
                break
            }
        }

        var decorations: [ThemedTableCardDecoration] = []
        if let accountBounds {
            decorations.append(ThemedTableCardDecoration(
                rows: accountBounds.first...accountBounds.last,
                topInset: Design.Spacing.small
            ))
        }
        decorations.append(contentsOf: limitBounds.sorted { $0.key < $1.key }.map {
            ThemedTableCardDecoration(
                rows: $0.value.first...$0.value.last,
                topInset: Design.Spacing.large
            )
        })
        decorations.append(contentsOf: extensionBounds.sorted { $0.key < $1.key }.map {
            let section = extensionSections[$0.key]
            return ThemedTableCardDecoration(
                rows: $0.value.first...$0.value.last,
                topInset: section.visibleTitle == nil
                    ? Design.Spacing.large
                    : Design.Spacing.small,
                bottomInset: $0.value.last == presentationRows.count - 1
                    ? Design.Spacing.large
                    : 0
            )
        })
        tableView.cardDecorations = decorations
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
    static let estimatedRowHeight: CGFloat = 72
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
            Threading can add, reconnect, and switch between Claude Code and Codex logins. The \
            provider owns the secure browser flow and credential; Threading stores only the \
            isolated config location. Grok, Cursor, and OpenCode keep sign-in in their own \
            tools, as shown above. Rename a managed login or choose an icon to tell it apart, \
            or switch it off without deleting it.
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
        L10n.string("No managed accounts yet. Add a Claude Code or Codex login above.")
    }

    static func enabledLabel(_ accountName: String) -> String {
        L10n.format("Use %@ for new sessions", accountName)
    }
}
