import AppKit

/// The Accounts page's one-year sign-in card: which logins sign in with a long-lived token, and
/// the place to give one a token or take it away.
///
/// Owned by `AccountsPreferencesViewController`, which places these rows in its virtual table the
/// same way it places the limits section. The decision-shaping caveat — a token runs models only —
/// is said where the choice is made (the sheet) and stays visible under the card; the mechanics
/// are the card's "?". See [`accounts.md`](../../../../docs/architecture/accounts.md).
@MainActor
final class AccountTokenSectionController: NSObject {

    /// Called when a row's content changed and the page should re-install it.
    var onRowsChange: (() -> Void)?

    private let vault: AgentAccountTokenVault
    private let now: () -> Date
    private var accounts: [AgentAccount] = []

    init(vault: AgentAccountTokenVault = .shared, now: @escaping () -> Date = Date.init) {
        self.vault = vault
        self.now = now
        super.init()
    }

    // MARK: - Model

    /// The logins this card lists: every one whose runtime takes a long-lived token, switched off
    /// or not, in the page's own order.
    func eligibleIndices(in accounts: [AgentAccount]) -> [Int] {
        self.accounts = accounts
        return accounts.indices.filter { accounts[$0].provider.longLivedToken != nil }
    }

    /// Reads the listed logins' entries off the main actor, then asks the page to restamp. The
    /// rows answer from memory meanwhile, and startup has normally read them already.
    func prepare(_ accounts: [AgentAccount]) {
        let ids = accounts.filter { $0.provider.longLivedToken != nil }.map(\.id)
        guard !ids.isEmpty else { return }
        vault.prepare(ids) { [weak self] in
            Task { @MainActor in self?.onRowsChange?() }
        }
    }

    // MARK: - Content

    func captionContent() -> NSView {
        SettingsUI.caption(
            "One-year sign-in",
            help: SettingsUI.help(
                "One-year sign-in",
                """
                A one-year token signs a Claude login in without the browser sign-in that has to \
                be repeated about every month. Make one by running claude setup-token in a \
                terminal and approving it in the browser as that login's account.
                """,
                """
                A token can only run models. Remote Control and claude.ai connectors, such as \
                Gmail or Google Drive, stop working on that login. MCP servers you set up \
                yourself keep working.
                """,
                """
                Threading keeps the token in your Keychain and gives it only to that login's \
                sessions, through their environment rather than their command line. Remove takes \
                it away, as does Reset Everything. The year is counted from when you save it, and \
                the row says when it is about to run out.
                """
            )
        )
    }

    func noteContent() -> NSView {
        SettingsUI.note(AccountTokenStrings.caveat)
    }

    func rowContent(forAccountAt index: Int) -> NSView {
        guard accounts.indices.contains(index) else { return NSView() }
        let account = accounts[index]
        let token = vault.cachedToken(for: account.id)

        let controls: [NSView]
        if token == nil {
            controls = [button(AccountTokenStrings.useButton, #selector(useClicked(_:)), index)]
        } else {
            controls = [
                button(AccountTokenStrings.replaceButton, #selector(useClicked(_:)), index),
                button(AccountTokenStrings.removeButton, #selector(removeClicked(_:)), index)
            ]
        }
        let row = SettingsUI.row(
            title: account.displayName,
            subtitle: Self.status(of: token, at: now()),
            control: SettingsUI.controlGroup(controls, spacing: Design.Spacing.small),
            localizes: false
        )
        row.alphaValue = account.isEnabled ? 1 : AccountsPreferencesLayout.disabledRowAlpha
        return row
    }

    /// The command that mints a token, run as this login: its config folder set, or the
    /// default's unset. `setup-token` saves no credential either way — it only prints one — but
    /// the folder supplies the login's own settings, such as an organization it is pinned to.
    /// It does not choose the account: that is whichever claude.ai account the browser approves
    /// as, which is why the sheet names it.
    static func mintCommand(for account: AgentAccount, spec: AgentLongLivedTokenSpec) -> String {
        guard !account.isDefault, let key = account.provider.accountEnvironmentKey else {
            return spec.mintCommand
        }
        return "\(key)=\(shellWord(account.configPath)) \(spec.mintCommand)"
    }

    /// A path as one word a person can paste: bare when it needs no quoting, else single-quoted.
    private static func shellWord(_ value: String) -> String {
        let plain = value.unicodeScalars.allSatisfy {
            CharacterSet.alphanumerics.contains($0) || "/._-+@:%".unicodeScalars.contains($0)
        }
        return plain ? value : "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// The row's one line: how this login signs in, and when that ends.
    static func status(of token: AgentAccountToken?, at now: Date) -> String {
        guard let token else { return AccountTokenStrings.browserSignIn }
        let date = token.expiresAt.formatted(date: .abbreviated, time: .omitted)
        if now >= token.expiresAt { return AccountTokenStrings.expired(date) }
        if token.isNearExpiry(at: now) { return AccountTokenStrings.expiresSoon(date) }
        return AccountTokenStrings.active(date)
    }

    private func button(_ title: String, _ action: Selector, _ index: Int) -> ThemedButton {
        let button = SettingsUI.button(title, target: self, action: action, localizes: false)
        button.tag = index
        button.setContentHuggingPriority(.required, for: .horizontal)
        return button
    }

    // MARK: - Actions

    @objc private func useClicked(_ sender: ThemedButton) {
        guard accounts.indices.contains(sender.tag),
              let window = sender.window,
              let spec = accounts[sender.tag].provider.longLivedToken else { return }
        let account = accounts[sender.tag]

        let field = ThemedSecureField()
        field.placeholderString = spec.prefix + "…"
        field.translatesAutoresizingMaskIntoConstraints = false
        field.widthAnchor.constraint(equalToConstant: AccountTokenLayout.fieldWidth).isActive = true

        let mint = Self.mintCommand(for: account, spec: spec)
        let command = NSTextField(wrappingLabelWithString: mint)
        command.applyFont(.code())
        command.textColor = Design.Text.label
        command.translatesAutoresizingMaskIntoConstraints = false
        command.widthAnchor.constraint(equalToConstant: AccountTokenLayout.fieldWidth).isActive = true
        let copy = SettingsUI.button(AccountTokenStrings.copyCommand, target: self,
                                     action: #selector(copyCommandClicked(_:)), localizes: false)
        copy.toolTip = mint

        let accessory = NSStackView(views: [command, copy, field])
        accessory.orientation = .vertical
        accessory.alignment = .leading
        accessory.spacing = Design.Spacing.medium

        let request = ConfirmationRequest(
            prompt: .storeAccountToken,
            title: AccountTokenStrings.sheetTitle(account.displayName),
            message: AccountTokenStrings.sheetMessage(
                approvingAs: AccountAvatarStore.cachedEmail(for: account)
                    ?? AccountEmailProbe.cachedEmail(for: account)
            ),
            confirmTitle: AccountTokenStrings.confirmButton,
            accessory: accessory
        )
        ConfirmationAlert.ask(request, in: window) { [weak self] confirmed in
            guard let self, confirmed else { return }
            self.save(field.stringValue, for: account, in: window)
        }
    }

    @objc private func copyCommandClicked(_ sender: ThemedButton) {
        guard let command = sender.toolTip else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(command, forType: .string)
    }

    @objc private func removeClicked(_ sender: ThemedButton) {
        guard accounts.indices.contains(sender.tag) else { return }
        vault.remove(for: accounts[sender.tag].id) { [weak self] _ in
            self?.onRowsChange?()
        }
    }

    private func save(_ raw: String, for account: AgentAccount, in window: NSWindow) {
        vault.save(raw, for: account.id) { [weak self, weak window] result in
            switch result {
            case .success:
                self?.onRowsChange?()
            case .failure(let error):
                // States an outcome and asks nothing, so a plain themed alert rather than a
                // registered prompt.
                let alert = ThemedAlert()
                alert.alertStyle = .warning
                alert.messageText = AccountTokenStrings.notSavedTitle
                alert.informativeText = AccountTokenStrings.reason(for: error)
                alert.addButton(withTitle: L10n.string("OK"))
                if let window { alert.beginSheetModal(for: window) }
            }
        }
    }
}

// MARK: - Layout

enum AccountTokenLayout {
    static let fieldWidth: CGFloat = 320
}

// MARK: - Strings

enum AccountTokenStrings {
    static var caveat: String {
        L10n.string("""
            A token runs models only: Remote Control and claude.ai connectors stop working on \
            that login.
            """)
    }
    static var browserSignIn: String { L10n.string("Signs in through the browser") }
    static func active(_ date: String) -> String { L10n.format("One-year token until %@", date) }
    static func expiresSoon(_ date: String) -> String {
        L10n.format("Token runs out %@. Replace it soon.", date)
    }
    static func expired(_ date: String) -> String {
        L10n.format("Token ran out %@. Replace it.", date)
    }
    static var useButton: String { L10n.string("Use Token…") }
    static var replaceButton: String { L10n.string("Replace…") }
    static var removeButton: String { L10n.string("Remove") }
    static var copyCommand: String { L10n.string("Copy Command") }
    static var confirmButton: String { L10n.string("Use Token") }
    static func sheetTitle(_ name: String) -> String {
        L10n.format("Use a one-year token for %@?", name)
    }
    /// The browser decides which account a token belongs to, so the sheet names the one to
    /// approve as whenever the login's address is known.
    static func sheetMessage(approvingAs email: String?) -> String {
        guard let email else {
            return L10n.string("""
                Run this command in a terminal, approve it in the browser as this login's account, \
                and paste the token it prints. Sessions on this login then sign in with the token. \
                A token runs models only: Remote Control and claude.ai connectors stop working on \
                this login.
                """)
        }
        return L10n.format("""
            Run this command in a terminal, approve it in the browser signed in as %@, and paste \
            the token it prints. Sessions on this login then sign in with the token. A token runs \
            models only: Remote Control and claude.ai connectors stop working on this login.
            """, email)
    }
    static var notSavedTitle: String { L10n.string("The token was not saved") }

    static func reason(for error: AgentAccountTokenVault.SaveError) -> String {
        switch error {
        case .format(.empty):
            return L10n.string("Paste the token claude setup-token printed.")
        case .format(.notThisRuntimesToken):
            return L10n.string("That is not a Claude setup token. It starts with sk-ant-oat01-.")
        case .format(.malformed):
            return L10n.string("""
                That token looks incomplete. Copy the whole token claude setup-token printed and \
                try again.
                """)
        case .keychain:
            return L10n.string("Threading could not write to your Keychain.")
        case .unsupported:
            return L10n.string("This login does not take a one-year token.")
        }
    }
}
