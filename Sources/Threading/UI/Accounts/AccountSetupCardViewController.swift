import AppKit

/// The reusable, host-owned account setup surface used by onboarding and Settings.
///
/// It presents provider identity, naming, progress, failure, and success. Authentication itself
/// remains provider-owned: the installed CLI opens its secure browser flow and stores the
/// credential in its isolated home; this controller never receives one.
final class AccountSetupCardViewController: NSViewController, NSTextFieldDelegate {

    var onAccountReady: ((AgentAccount) -> Void)?

    /// Seams for the two things the link row does outside this process. Tests take them so a
    /// suite never writes the developer's pasteboard or opens their browser; production leaves
    /// them nil and the row does the ordinary thing.
    var onCopySignInLink: ((URL) -> Void)?
    var onOpenSignInLink: ((URL) -> Void)?

    private enum Layout {
        static let providerIconSide: CGFloat = 22
        static let statusIconSide: CGFloat = 20
    }

    private let coordinator: AgentAccountSetupCoordinator
    private var nameField: ThemedTextField?
    private var signInButton: ThemedButton?
    private var codeField: ThemedTextField?

    init(coordinator: AgentAccountSetupCoordinator = AgentAccountSetupCoordinator()) {
        self.coordinator = coordinator
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func loadView() {
        view = NSView()
        coordinator.onStateChange = { [weak self] state in
            self?.render(state)
        }
        coordinator.onAccountReady = { [weak self] account in
            self?.onAccountReady?(account)
        }
        render(coordinator.state)
    }

    func reconnect(_ account: AgentAccount) {
        _ = view
        coordinator.reconnect(account)
    }

    private func render(_ state: AgentAccountSetupState) {
        nameField = nil
        signInButton = nil
        codeField = nil
        view.subviews.forEach { $0.removeFromSuperview() }

        let card = SettingsCard(rows: rows(for: state))
        card.setAccessibilityIdentifier(AccountSetupStrings.cardIdentifier(for: state))
        card.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(card)
        NSLayoutConstraint.activate([
            card.topAnchor.constraint(equalTo: view.topAnchor),
            card.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            card.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            card.trailingAnchor.constraint(equalTo: view.trailingAnchor)
        ])
    }

    private func rows(for state: AgentAccountSetupState) -> [NSView] {
        switch state {
        case .choice:
            // AgentKind is a fixed five-case product schema, not provider-sized data. Keeping
            // the complete roster here makes this card the honest answer to "what does
            // Threading support?" while the two real buttons remain limited to the login
            // adapters whose isolated-home routing has been measured.
            return AgentKind.allCases.map(agentRow)
        case .naming(let provider):
            return namingRows(provider: provider)
        case let .running(context, prompt):
            return runningRows(context: context, prompt: prompt)
        case let .failed(provider, attemptedName, _, failure):
            return failureRows(
                provider: provider,
                attemptedName: attemptedName,
                failure: failure
            )
        case .succeeded(let account):
            return successRows(account: account)
        }
    }

    private func agentRow(_ kind: AgentKind) -> NSView {
        if let provider = AgentAccountSetupProvider(kind: kind) {
            let button = ThemedButton(
                title: AccountSetupStrings.addLogin,
                target: self,
                action: #selector(providerClicked(_:))
            )
            button.emphasis = .secondary
            button.tag = AgentAccountSetupProvider.allCases.firstIndex(of: provider) ?? 0
            button.setAccessibilityIdentifier("account-setup.choose.\(provider.rawValue)")

            return agentIdentityRow(
                kind: kind,
                title: kind.displayName,
                detail: kind.accountAccessDetail,
                control: button
            )
        }

        let ownership = NSTextField(labelWithString: kind.accountAccessOwner)
        ownership.applyFont(.caption)
        ownership.textColor = Design.Text.tertiary
        ownership.alignment = .right
        ownership.setContentHuggingPriority(.required, for: .horizontal)
        ownership.setAccessibilityLabel(
            L10n.format("%@ sign-in: %@", kind.displayName, kind.accountAccessOwner)
        )

        return agentIdentityRow(
            kind: kind,
            title: kind.displayName,
            detail: kind.accountAccessDetail,
            control: ownership
        )
    }

    private func namingRows(provider: AgentAccountSetupProvider) -> [NSView] {
        let identity = agentIdentityRow(
            kind: provider.kind,
            title: L10n.format("Add %@", provider.kind.displayName),
            detail: AccountSetupStrings.namingDetail(provider),
            control: nil
        )

        let field = ThemedTextField(string: "")
        field.placeholderString = AccountSetupStrings.namePlaceholder
        field.delegate = self
        field.setAccessibilityLabel(AccountSetupStrings.loginName)
        field.setAccessibilityIdentifier("account-setup.name")
        SettingsUI.preferControlWidth(field)
        nameField = field

        let name = SettingsUI.row(
            title: AccountSetupStrings.loginName,
            subtitle: AccountSetupStrings.nameDetail,
            control: field,
            localizes: false
        )

        let cancel = ThemedButton(
            title: AccountSetupStrings.cancel,
            target: self,
            action: #selector(cancelClicked)
        )
        cancel.emphasis = .secondary

        let signIn = ThemedButton(
            title: AccountSetupStrings.signIn,
            target: self,
            action: #selector(signInClicked)
        )
        signIn.emphasis = .primary
        signIn.isEnabled = false
        signIn.setAccessibilityIdentifier("account-setup.sign-in")
        signInButton = signIn

        return [identity, name, actionRow([cancel, signIn])]
    }

    private func runningRows(
        context: AgentAccountSetupContext,
        prompt: AgentAccountSignInPrompt?
    ) -> [NSView] {
        let spinner = ThemedSpinner()
        spinner.isAnimating = true
        spinner.setAccessibilityLabel(AccountSetupStrings.signingIn)

        let status = statusRow(
            mark: spinner,
            title: AccountSetupStrings.finishInBrowser,
            detail: context.isReconnect
                ? AccountSetupStrings.reconnectProgress(context.provider)
                : AccountSetupStrings.setupProgress(context.provider),
            ink: Design.Text.label
        )

        let cancel = ThemedButton(
            title: AccountSetupStrings.cancel,
            target: self,
            action: #selector(cancelClicked)
        )
        cancel.emphasis = .secondary
        cancel.setAccessibilityIdentifier("account-setup.cancel")

        var rows: [NSView] = [status, signInLinkRow(prompt)]
        if let prompt, prompt.acceptsPastedCode {
            rows.append(contentsOf: pastedCodeRows(prompt))
        }
        rows.append(actionRow([cancel]))
        return rows
    }

    /// The link the CLI printed, so a sign-in can be finished in a private window, a second
    /// profile, or a browser that is not this Mac's default.
    ///
    /// It occupies the row before the URL arrives as well. The CLI takes a moment to print it,
    /// and a row that appears late moves everything under it — including the Cancel button the
    /// person may be reaching for.
    private func signInLinkRow(_ prompt: AgentAccountSignInPrompt?) -> NSView {
        let mark = NSImageView(image: SettingsUI.symbolImage("link"))
        mark.contentTintColor = Design.Text.tertiary
        mark.setAccessibilityElement(false)
        constrain(mark, side: Layout.statusIconSide)

        let titleField = NSTextField(labelWithString: AccountSetupStrings.signInLink)
        titleField.applyFont(.emphasizedBody)
        titleField.textColor = Design.Text.label

        let detailField = NSTextField(wrappingLabelWithString: AccountSetupStrings.signInLinkDetail)
        detailField.applyFont(.body)
        detailField.textColor = Design.Text.secondary

        let labels = NSStackView(views: [titleField, detailField, linkContent(prompt)])
        labels.orientation = .vertical
        labels.alignment = .leading
        labels.spacing = Design.Spacing.small
        labels.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let row = NSStackView(views: [mark, labels])
        row.orientation = .horizontal
        row.alignment = .top
        row.spacing = Design.Spacing.medium
        row.distribution = .fill
        return SettingsUI.fullRow(row)
    }

    /// The URL itself with its two actions, or the one line that says it has not arrived yet.
    private func linkContent(_ prompt: AgentAccountSignInPrompt?) -> NSView {
        guard let prompt else {
            let waiting = NSTextField(labelWithString: AccountSetupStrings.waitingForLink)
            waiting.applyFont(.subheading)
            waiting.textColor = Design.Text.tertiary
            waiting.setAccessibilityIdentifier("account-setup.link-pending")
            return waiting
        }

        // Selectable rather than editable: the whole URL is here to be read and copied, and the
        // middle is what truncates because both ends identify it.
        let link = NSTextField(labelWithString: prompt.url.absoluteString)
        link.applyFont(.subheading)
        link.textColor = Design.Text.secondary
        link.lineBreakMode = .byTruncatingMiddle
        link.isSelectable = true
        link.allowsDefaultTighteningForTruncation = true
        link.toolTip = prompt.url.absoluteString
        link.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        link.setAccessibilityIdentifier("account-setup.sign-in-link")

        let copy = ThemedButton(
            title: AccountSetupStrings.copyLink,
            target: self,
            action: #selector(copyLinkClicked)
        )
        copy.emphasis = .secondary
        copy.setAccessibilityIdentifier("account-setup.copy-link")
        copy.setAccessibilityLabel(AccountSetupStrings.copyLinkAccessibility)
        copy.setContentHuggingPriority(.required, for: .horizontal)

        let open = ThemedButton(
            title: AccountSetupStrings.openLink,
            target: self,
            action: #selector(openLinkClicked)
        )
        open.emphasis = .secondary
        open.setAccessibilityIdentifier("account-setup.open-link")
        open.setAccessibilityLabel(AccountSetupStrings.openLinkAccessibility)
        open.setContentHuggingPriority(.required, for: .horizontal)

        let actions = NSStackView(views: [copy, open])
        actions.orientation = .horizontal
        actions.alignment = .centerY
        actions.spacing = Design.Spacing.small

        let stack = NSStackView(views: [link, actions])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = Design.Spacing.small
        return stack
    }

    /// Where the code goes for a provider whose printed link ends on a page that displays one.
    private func pastedCodeRows(_ prompt: AgentAccountSignInPrompt) -> [NSView] {
        let field = ThemedTextField(string: "")
        field.placeholderString = AccountSetupStrings.codePlaceholder
        field.delegate = self
        field.target = self
        field.action = #selector(submitCodeClicked)
        field.setAccessibilityLabel(AccountSetupStrings.pasteCode)
        field.setAccessibilityIdentifier("account-setup.code")
        codeField = field

        let submit = ThemedButton(
            title: AccountSetupStrings.sendCode,
            target: self,
            action: #selector(submitCodeClicked)
        )
        submit.emphasis = .secondary
        submit.setAccessibilityIdentifier("account-setup.submit-code")
        submit.setContentHuggingPriority(.required, for: .horizontal)

        // Field and button as one control rather than a row each. The onboarding flow already
        // owns a Continue in its footer, and a second one a card away is the kind of pair
        // somebody presses the wrong half of.
        let control = NSStackView(views: [field, submit])
        control.orientation = .horizontal
        control.alignment = .centerY
        control.spacing = Design.Spacing.small

        return [SettingsUI.row(
            title: AccountSetupStrings.pasteCode,
            subtitle: prompt.hasSentCode
                ? AccountSetupStrings.codeSent
                : AccountSetupStrings.pasteCodeDetail,
            control: control,
            localizes: false
        )]
    }

    private func failureRows(
        provider: AgentAccountSetupProvider,
        attemptedName: String,
        failure: AgentAccountSetupFailure
    ) -> [NSView] {
        let mark = NSImageView(image: SettingsUI.symbolImage("exclamationmark.triangle.fill"))
        mark.contentTintColor = Design.Status.warning
        mark.setAccessibilityElement(false)
        constrain(mark, side: Layout.statusIconSide)

        let status = statusRow(
            mark: mark,
            title: AccountSetupStrings.couldNotFinish,
            detail: AccountSetupStrings.failureDetail(
                failure,
                provider: provider,
                attemptedName: attemptedName
            ),
            ink: Design.Status.warning
        )

        let cancel = ThemedButton(
            title: AccountSetupStrings.cancel,
            target: self,
            action: #selector(cancelClicked)
        )
        cancel.emphasis = .secondary

        var actions: [NSView] = [cancel]
        if failure == .cliMissing {
            let guide = ThemedButton(
                title: AccountSetupStrings.installationGuide,
                target: self,
                action: #selector(installationGuideClicked)
            )
            guide.emphasis = .secondary
            actions.append(guide)
        }

        let retry = ThemedButton(
            title: AccountSetupStrings.tryAgain,
            target: self,
            action: #selector(retryClicked)
        )
        retry.emphasis = .primary
        retry.setAccessibilityIdentifier("account-setup.retry")
        actions.append(retry)
        return [status, actionRow(actions)]
    }

    private func successRows(account: AgentAccount) -> [NSView] {
        let mark = NSImageView(image: SettingsUI.symbolImage("checkmark.circle.fill"))
        mark.contentTintColor = Design.Status.positive
        mark.setAccessibilityElement(false)
        constrain(mark, side: Layout.statusIconSide)

        let status = statusRow(
            mark: mark,
            title: L10n.format("%@ is ready", account.displayName),
            detail: AccountSetupStrings.successDetail(account.provider),
            ink: Design.Status.positive
        )
        let done = ThemedButton(
            title: AccountSetupStrings.done,
            target: self,
            action: #selector(doneClicked)
        )
        done.emphasis = .primary
        done.setAccessibilityIdentifier("account-setup.done")
        return [status, actionRow([done])]
    }

    private func agentIdentityRow(
        kind: AgentKind,
        title: String,
        detail: String,
        control: NSView?
    ) -> NSView {
        let icon = NSImageView()
        icon.image = kind.icon
        icon.imageScaling = .scaleProportionallyDown
        icon.setAccessibilityElement(false)
        constrain(icon, side: Layout.providerIconSide)

        let titleField = NSTextField(labelWithString: title)
        titleField.applyFont(.body)
        titleField.textColor = Design.Text.label

        let detailField = NSTextField(wrappingLabelWithString: detail)
        detailField.applyFont(.subheading)
        detailField.textColor = Design.Text.secondary

        let labels = NSStackView(views: [titleField, detailField])
        labels.orientation = .vertical
        labels.alignment = .leading
        labels.spacing = Design.Spacing.hairline
        labels.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let row = NSStackView(views: [icon, labels])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = Design.Spacing.medium
        row.distribution = .fill
        if let control {
            control.setContentHuggingPriority(.required, for: .horizontal)
            row.addArrangedSubview(control)
        }
        return SettingsUI.fullRow(row)
    }

    private func statusRow(
        mark: NSView,
        title: String,
        detail: String,
        ink: NSColor
    ) -> NSView {
        let titleField = NSTextField(labelWithString: title)
        titleField.applyFont(.emphasizedBody)
        titleField.textColor = ink

        let detailField = NSTextField(wrappingLabelWithString: detail)
        detailField.applyFont(.body)
        detailField.textColor = Design.Text.secondary

        let labels = NSStackView(views: [titleField, detailField])
        labels.orientation = .vertical
        labels.alignment = .leading
        labels.spacing = Design.Spacing.small
        labels.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let row = NSStackView(views: [mark, labels])
        row.orientation = .horizontal
        row.alignment = .top
        row.spacing = Design.Spacing.medium
        row.distribution = .fill
        return SettingsUI.fullRow(row)
    }

    private func actionRow(_ actions: [NSView]) -> NSView {
        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        spacer.setContentCompressionResistancePriority(.init(1), for: .horizontal)
        let row = NSStackView(views: [spacer] + actions)
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = Design.Spacing.small
        return SettingsUI.fullRow(row)
    }

    private func constrain(_ view: NSView, side: CGFloat) {
        view.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            view.widthAnchor.constraint(equalToConstant: side),
            view.heightAnchor.constraint(equalToConstant: side)
        ])
    }

    func controlTextDidChange(_ obj: Notification) {
        // The card shows one editable field at a time, but they belong to different states, so
        // the naming state's rule must not be applied to the code field's keystrokes.
        guard obj.object as AnyObject? !== codeField else { return }
        let hasName = nameField?.stringValue
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .isEmpty == false
        signInButton?.isEnabled = hasName
    }

    @objc private func providerClicked(_ sender: ThemedButton) {
        guard sender.tag >= 0, sender.tag < AgentAccountSetupProvider.allCases.count else { return }
        coordinator.choose(AgentAccountSetupProvider.allCases[sender.tag])
    }

    @objc private func signInClicked() {
        guard case .naming(let provider) = coordinator.state else { return }
        coordinator.start(provider: provider, displayName: nameField?.stringValue ?? "")
    }

    @objc private func cancelClicked() {
        coordinator.cancel()
    }

    @objc private func retryClicked() {
        coordinator.retry()
    }

    @objc private func doneClicked() {
        coordinator.finish()
    }

    @objc private func installationGuideClicked() {
        guard case .failed(let provider, _, _, _) = coordinator.state else { return }
        NSWorkspace.shared.open(provider.installationGuide)
    }

    @objc private func copyLinkClicked() {
        guard let url = signInLink else { return }
        if let onCopySignInLink {
            onCopySignInLink(url)
            return
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(url.absoluteString, forType: .string)
    }

    /// Opens the link the ordinary way, which is still worth having beside Copy: the CLI's own
    /// attempt may have failed silently, and this one is a click rather than a paste.
    @objc private func openLinkClicked() {
        guard let url = signInLink else { return }
        if let onOpenSignInLink {
            onOpenSignInLink(url)
            return
        }
        NSWorkspace.shared.open(url)
    }

    @objc private func submitCodeClicked() {
        guard let code = codeField?.stringValue else { return }
        coordinator.submitPastedCode(code)
    }

    private var signInLink: URL? {
        guard case let .running(_, prompt) = coordinator.state else { return nil }
        return prompt?.url
    }
}

// MARK: - Copy

enum AccountSetupStrings {
    static var addLogin: String { L10n.string("Add Login") }
    static var loginName: String { L10n.string("Login name") }
    static var namePlaceholder: String { L10n.string("Work or Personal") }
    static var nameDetail: String {
        L10n.string("A local label for menus and the isolated provider folder.")
    }
    static var signIn: String { L10n.string("Sign In") }
    static var signingIn: String { L10n.string("Signing in") }
    static var cancel: String { L10n.string("Cancel") }
    static var finishInBrowser: String { L10n.string("Complete sign-in in your browser") }
    static var signInLink: String { L10n.string("Sign-in link") }
    static var signInLinkDetail: String {
        L10n.string(
            "The same link the agent opened. Use it in another browser, a private window, or a different profile."
        )
    }
    static var waitingForLink: String { L10n.string("Waiting for the agent to print its link…") }
    static var copyLink: String { L10n.string("Copy Link") }
    static var copyLinkAccessibility: String { L10n.string("Copy this sign-in link") }
    static var openLink: String { L10n.string("Open") }
    static var openLinkAccessibility: String { L10n.string("Open this sign-in link in your browser") }
    static var pasteCode: String { L10n.string("Authorization code") }
    static var pasteCodeDetail: String {
        L10n.string("Paste the code that page shows. Threading passes it straight to the agent.")
    }
    static var codePlaceholder: String { L10n.string("Paste code") }
    static var codeSent: String {
        L10n.string("Sent to the agent. Paste it again if the sign-in did not finish.")
    }
    static var sendCode: String { L10n.string("Send Code") }
    static var couldNotFinish: String { L10n.string("Sign-in did not finish") }
    static var installationGuide: String { L10n.string("Installation Guide") }
    static var tryAgain: String { L10n.string("Try Again") }
    static var done: String { L10n.string("Done") }

    static func namingDetail(_ provider: AgentAccountSetupProvider) -> String {
        L10n.format(
            "%@ opens its own secure browser sign-in. Threading never sees the credential.",
            provider.kind.displayName
        )
    }

    static func setupProgress(_ provider: AgentAccountSetupProvider) -> String {
        L10n.format(
            "Complete %@'s sign-in there. Threading will verify this login when the browser flow returns.",
            provider.kind.displayName
        )
    }

    static func reconnectProgress(_ provider: AgentAccountSetupProvider) -> String {
        L10n.format(
            "Complete %@'s sign-in there to reconnect this login.",
            provider.kind.displayName
        )
    }

    static func successDetail(_ provider: AgentKind) -> String {
        L10n.format(
            "%@ verified the login. It is now available for new sessions.",
            provider.displayName
        )
    }

    static func failureDetail(
        _ failure: AgentAccountSetupFailure,
        provider: AgentAccountSetupProvider,
        attemptedName: String
    ) -> String {
        switch failure {
        case .invalidName:
            return L10n.string("Enter a name containing at least one letter or number.")
        case .locationAlreadyExists:
            return L10n.format(
                "A login named %@ already exists. Reconnect it from Settings ▸ Agents & Accounts, or choose another name.",
                attemptedName
            )
        case .couldNotPrepareLocation:
            return L10n.string("Threading could not prepare an isolated provider folder for this login.")
        case .cliMissing:
            return L10n.format(
                "%@ is not available on your login shell's PATH. Install it, then try again.",
                provider.kind.executableName
            )
        case .couldNotStart:
            return L10n.format("Threading could not start %@.", provider.kind.displayName)
        case .signInFailed:
            return L10n.format(
                "%@ closed before confirming the login. Nothing was registered.",
                provider.kind.displayName
            )
        case .timedOut:
            return L10n.string("The browser sign-in timed out. Nothing was registered.")
        case .verificationFailed:
            return L10n.format(
                "%@ could not verify this login. Try the browser flow again.",
                provider.kind.displayName
            )
        }
    }

    static func cardIdentifier(for state: AgentAccountSetupState) -> String {
        switch state {
        case .choice: return "account-setup.choice"
        case .naming: return "account-setup.naming"
        case .running: return "account-setup.running"
        case .failed: return "account-setup.failed"
        case .succeeded: return "account-setup.succeeded"
        }
    }
}
