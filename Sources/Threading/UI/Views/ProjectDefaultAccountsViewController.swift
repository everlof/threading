import AppKit

/// Edits one project's ordered default logins, in a popover from its sidebar row.
///
/// Two groups, the shape the app-wide account order is planned to take too: **In order** — the
/// logins a new chat here may start on, first to last — and **Other accounts**, which are never
/// chosen for this project on the user's behalf. Reordering is by buttons rather than by drag,
/// so every move is a press VoiceOver and the keyboard reach the same way a pointer does.
///
/// Each change is saved as it is made. There is no Done: the list is short, each step is
/// undoable by the opposite press, and a popover that loses its edits on an outside click would
/// be the one surprise this surface could cause.
final class ProjectDefaultAccountsViewController: NSViewController {

    // MARK: - Properties

    let projectID: ProjectID
    private let store: ProjectStore
    private let accountsProvider: () -> [AgentAccount]

    /// Called when the store refused a write, so the sidebar can say so in its own voice.
    var onSaveFailure: (() -> Void)?

    private let content = NSStackView()
    private let appEvents = AppEventObservations()

    /// The list as it stands, read back from the store after every write.
    private(set) var list: [AccountID] = []

    // MARK: - Initialization

    init(
        projectID: ProjectID,
        store: ProjectStore = .shared,
        accountsProvider: @escaping () -> [AgentAccount] = {
            AgentKind.allCases
                .filter(\.supportsAccounts)
                .flatMap { AgentAccountDiscovery.allAccounts(for: $0) }
        }
    ) {
        self.projectID = projectID
        self.store = store
        self.accountsProvider = accountsProvider
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - Lifecycle

    override func loadView() {
        view = NSView()
        content.orientation = .vertical
        content.alignment = .leading
        content.spacing = Design.Spacing.medium
        content.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(content)
        NSLayoutConstraint.activate([
            content.topAnchor.constraint(equalTo: view.topAnchor, constant: Design.Spacing.large),
            content.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: Design.Spacing.large),
            content.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -Design.Spacing.large),
            content.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -Design.Spacing.large),
            view.widthAnchor.constraint(equalToConstant: ProjectDefaultAccountsEditorDefaults.width)
        ])

        appEvents.observe(AppThemeDidChange.self) { [weak self] _ in self?.rebuild() }
        appEvents.observe(AccountUsageDidChange.self) { [weak self] _ in self?.rebuild() }
        appEvents.observe(AccountPreferencesDidChange.self) { [weak self] _ in self?.rebuild() }
        rebuild()
    }

    // MARK: - Public Methods

    /// Moves the login at `index` one place towards the top (`-1`) or the bottom (`+1`).
    func move(at index: Int, by offset: Int) {
        let target = index + offset
        guard list.indices.contains(index), list.indices.contains(target) else { return }
        var reordered = list
        reordered.swapAt(index, target)
        save(reordered)
    }

    /// Takes a login out of the order. It joins the other accounts and is no longer chosen here.
    func remove(at index: Int) {
        guard list.indices.contains(index) else { return }
        var reordered = list
        reordered.remove(at: index)
        save(reordered)
    }

    /// Puts a login at the end of the order.
    func add(_ accountID: AccountID) {
        guard !list.contains(accountID) else { return }
        save(list + [accountID])
    }

    /// Restates every row from the store and the current readings.
    func rebuild() {
        list = store.project(withID: projectID)?.defaultAccounts ?? []
        let accounts = accountsProvider()
        let byID = Dictionary(accounts.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let states = Dictionary(
            ProjectDefaultAccounts.candidates(list, accounts: byID).map {
                ($0.accountID, ProjectAccountOrder.state(of: $0))
            },
            uniquingKeysWith: { first, _ in first }
        )

        content.arrangedSubviews.forEach { $0.removeFromSuperview() }
        content.addArrangedSubview(SettingsUI.heading("Default Accounts"))
        content.addArrangedSubview(SettingsUI.note(
            "New chats in this project start on the first account here that has usage left."
        ))

        let ordered = NSStackView()
        ordered.orientation = .vertical
        ordered.alignment = .leading
        ordered.spacing = Design.Spacing.small
        if list.isEmpty {
            ordered.addArrangedSubview(SettingsUI.note(
                "None yet. New chats follow the app's own choice."
            ))
        }
        for (index, accountID) in list.enumerated() {
            let account = accounts.first { $0.id == accountID }
            ordered.addArrangedSubview(listedRow(
                index: index,
                accountID: accountID,
                account: account,
                state: states[accountID] ?? .unavailable(.missing)
            ))
        }
        content.addArrangedSubview(SettingsUI.section("In order", ordered))

        let others = accounts.filter { $0.isEnabled && !list.contains($0.id) }
        guard !others.isEmpty else { return }
        let available = NSStackView()
        available.orientation = .vertical
        available.alignment = .leading
        available.spacing = Design.Spacing.small
        for account in others {
            available.addArrangedSubview(otherRow(account))
        }
        content.addArrangedSubview(SettingsUI.section(
            "Other accounts",
            available,
            help: SettingsUI.help(
                "Other accounts",
                "An account that is not in the order is never chosen for this project on your behalf. You can still pick it for one chat in the composer.",
                "An account counts as out when a window that meters the chat's model is at 92% of its limit — or of your own limit, when you set a tighter one. An account whose usage is not known yet keeps its place."
            )
        ))
    }

    // MARK: - Private Methods

    private func save(_ accounts: [AccountID]) {
        let result = store.setDefaultAccounts(accounts, forProjectID: projectID)
        if !result.succeeded { onSaveFailure?() }
        rebuild()
    }

    private func listedRow(
        index: Int,
        accountID: AccountID,
        account: AgentAccount?,
        state: ProjectAccountOrder.State
    ) -> NSView {
        let name = account?.presentation(in: .chooser).visibleName
            ?? ProjectDefaultAccountsPresentation.name(of: accountID)
        let up = button(
            symbol: "chevron.up",
            accessibility: L10n.format("Move %@ up", name),
            identifier: "project-default-accounts.up.\(index)"
        ) { [weak self] in self?.move(at: index, by: -1) }
        up.isEnabled = index > 0
        let down = button(
            symbol: "chevron.down",
            accessibility: L10n.format("Move %@ down", name),
            identifier: "project-default-accounts.down.\(index)"
        ) { [weak self] in self?.move(at: index, by: 1) }
        down.isEnabled = index < list.count - 1
        let remove = button(
            symbol: "minus.circle",
            accessibility: L10n.format("Remove %@ from the order", name),
            identifier: "project-default-accounts.remove.\(index)"
        ) { [weak self] in self?.remove(at: index) }

        return row(
            title: "\(index + 1). \(name)",
            subtitle: ProjectDefaultAccountsPresentation.stateLine(state),
            mark: mark(for: accountID, account: account),
            controls: [up, down, remove]
        )
    }

    private func otherRow(_ account: AgentAccount) -> NSView {
        let name = account.presentation(in: .chooser).visibleName
        let add = button(
            symbol: "plus.circle",
            accessibility: L10n.format("Add %@ to the order", name),
            identifier: "project-default-accounts.add.\(account.id.rawValue)"
        ) { [weak self] in self?.add(account.id) }
        return row(
            title: name,
            subtitle: account.provider.displayName,
            mark: mark(for: account.id, account: account),
            controls: [add]
        )
    }

    private func row(title: String, subtitle: String, mark: NSImage?, controls: [NSView]) -> NSView {
        let image = NSImageView()
        image.image = mark
        image.imageScaling = .scaleProportionallyDown
        image.translatesAutoresizingMaskIntoConstraints = false
        image.widthAnchor.constraint(equalToConstant: Design.Size.tabIconSlot).isActive = true
        image.heightAnchor.constraint(equalTo: image.widthAnchor).isActive = true

        let group = NSStackView(views: controls)
        group.spacing = Design.Spacing.tight
        let settingsRow = SettingsUI.row(
            title: title,
            subtitle: subtitle,
            control: group,
            localizes: false
        )
        let line = NSStackView(views: [image, settingsRow])
        line.spacing = Design.Spacing.small
        line.alignment = .centerY
        line.translatesAutoresizingMaskIntoConstraints = false
        line.widthAnchor.constraint(
            equalToConstant: ProjectDefaultAccountsEditorDefaults.width - 2 * Design.Spacing.large
        ).isActive = true
        return line
    }

    private func mark(for accountID: AccountID, account: AgentAccount?) -> NSImage? {
        AccountMarkImage.make(
            for: accountID.provider,
            usage: AccountUsageService.shared.usage(for: accountID),
            metering: ProjectDefaultAccounts.defaultModel(for: account)
        )
    }

    private func button(
        symbol: String,
        accessibility: String,
        identifier: String,
        action: @escaping () -> Void
    ) -> ThemedIconButton {
        let button = ThemedIconButton(
            symbolName: symbol,
            accessibility: accessibility,
            target: .inline
        )
        button.toolTip = accessibility
        button.setAccessibilityIdentifier(identifier)
        button.onPress = action
        return button
    }
}

// MARK: - Defaults

enum ProjectDefaultAccountsEditorDefaults {
    static let width: CGFloat = 380
}

private extension AccountUsageService {
    func usage(for accountID: AccountID) -> AccountUsage? {
        reading(for: accountID).usage
    }
}
