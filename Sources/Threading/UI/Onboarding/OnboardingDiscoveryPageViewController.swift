import AppKit

/// The walkthrough's second page: who is already signed in, a complete path to adding another
/// login, and whether the CLIs those logins belong to are actually reachable.
///
/// The provider still owns authentication. Threading scopes its official CLI to a new config
/// home, waits for the browser flow, verifies it, and only then lets discovery offer the login.
final class OnboardingDiscoveryPageViewController: NSViewController, OnboardingPage {

    private enum Layout {
        static let contentWidth: CGFloat = 560
        static let iconSide: CGFloat = 20
    }

    var pageTitle: String { L10n.string("Accounts") }

    private let accountsCardHost = NSView()
    private let cliCardHost = NSView()
    private let accountsProvider: () -> [AgentAccount]
    private let setupController: AccountSetupCardViewController
    private var probeSpinner: ThemedSpinner?
    private var cliResults: [AgentCLIProbe.Result]?
    /// The accounts the rows were built from, so a toggle's tag maps back to its account.
    private var shownAccounts: [AgentAccount] = []
    private let appEvents = AppEventObservations()

    init(
        accountsProvider: @escaping () -> [AgentAccount] = {
            AgentAccountDiscovery.allAccounts(for: .claude)
                + AgentAccountDiscovery.allAccounts(for: .codex)
        },
        cliResults: [AgentCLIProbe.Result]? = nil,
        setupCoordinator: AgentAccountSetupCoordinator = AgentAccountSetupCoordinator()
    ) {
        self.accountsProvider = accountsProvider
        self.cliResults = cliResults
        self.setupController = AccountSetupCardViewController(coordinator: setupCoordinator)
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func loadView() {
        view = NSView()
        addChild(setupController)
        setupController.onAccountReady = { [weak self] _ in
            self?.rebuildAccountRows()
        }
        setupViews()

        // Person names fill in as the email probe answers; re-render then.
        appEvents.observe(AccountPreferencesDidChange.self) { [weak self] _ in
            self?.rebuildAccountRows()
        }
    }

    func pageWillAppear() {
        rebuildAccountRows()
        AccountEmailProbe.prefetch(AgentAccountDiscovery.accounts(for: .claude)) {
            NotificationCenter.default.post(AccountPreferencesDidChange())
        }

        guard cliResults == nil else { return }
        AgentCLIProbe.resolve(
            executables: AgentKind.allCases.map(\.executableName)
        ) { [weak self] results in
            self?.cliResults = results
            self?.rebuildCLIRows()
        }
    }

    private func setupViews() {
        let heading = NSTextField(labelWithString: L10n.string("Set up your agent logins"))
        heading.applyFont(.heading)
        heading.textColor = Design.Text.label
        heading.alignment = .center

        let caption = NSTextField(
            wrappingLabelWithString: L10n.string(
                "Use a login already on this Mac, or add one here. The provider's own CLI "
                    + "handles the secure browser sign-in and keeps the credential."
            )
        )
        caption.applyFont(.body)
        caption.textColor = Design.Text.secondary
        caption.alignment = .center

        accountsCardHost.translatesAutoresizingMaskIntoConstraints = false
        cliCardHost.translatesAutoresizingMaskIntoConstraints = false

        let cliHeading = NSTextField(labelWithString: L10n.string("Command-line tools"))
        cliHeading.applyFont(.emphasizedBody)
        cliHeading.textColor = Design.Text.label

        let accountsHeading = NSTextField(labelWithString: L10n.string("Available logins"))
        accountsHeading.applyFont(.emphasizedBody)
        accountsHeading.textColor = Design.Text.label

        let setupHeading = NSTextField(labelWithString: L10n.string("Add a login"))
        setupHeading.applyFont(.emphasizedBody)
        setupHeading.textColor = Design.Text.label

        let setupView = setupController.view
        setupView.translatesAutoresizingMaskIntoConstraints = false

        let stack = NSStackView(views: [
            heading,
            caption,
            setupHeading,
            setupView,
            accountsHeading,
            accountsCardHost,
            cliHeading,
            cliCardHost
        ])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = Design.Spacing.inset
        stack.setCustomSpacing(Design.Spacing.large, after: caption)
        stack.setCustomSpacing(Design.Spacing.small, after: setupHeading)
        stack.setCustomSpacing(Design.Spacing.large, after: setupView)
        stack.setCustomSpacing(Design.Spacing.small, after: accountsHeading)
        stack.setCustomSpacing(Design.Spacing.large, after: accountsCardHost)
        stack.setCustomSpacing(Design.Spacing.small, after: cliHeading)
        stack.translatesAutoresizingMaskIntoConstraints = false

        let document = SettingsFlippedView()
        document.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(stack)

        let scroll = ThemedScrollView()
        scroll.hasVerticalScroller = true
        scroll.automaticallyAdjustsContentInsets = false
        scroll.documentView = document
        scroll.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(scroll)

        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: view.topAnchor),
            scroll.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            scroll.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: view.trailingAnchor),

            document.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
            document.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
            document.trailingAnchor.constraint(equalTo: scroll.contentView.trailingAnchor),
            stack.topAnchor.constraint(equalTo: document.topAnchor, constant: Design.Spacing.pane),
            stack.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            stack.bottomAnchor.constraint(
                equalTo: document.bottomAnchor,
                constant: -Design.Spacing.pane
            ),
            caption.widthAnchor.constraint(lessThanOrEqualToConstant: Layout.contentWidth),
            accountsHeading.widthAnchor.constraint(equalToConstant: Layout.contentWidth),
            accountsCardHost.widthAnchor.constraint(equalToConstant: Layout.contentWidth),
            setupHeading.widthAnchor.constraint(equalToConstant: Layout.contentWidth),
            setupView.widthAnchor.constraint(equalToConstant: Layout.contentWidth),
            cliCardHost.widthAnchor.constraint(equalToConstant: Layout.contentWidth),
            cliHeading.widthAnchor.constraint(equalToConstant: Layout.contentWidth)
        ])

        rebuildAccountRows()
        rebuildCLIRows()
    }

    // MARK: - Accounts

    private func rebuildAccountRows() {
        let accounts = accountsProvider()
        shownAccounts = accounts

        let rows: [NSView]
        if accounts.isEmpty {
            let empty = NSTextField(
                wrappingLabelWithString: L10n.string(
                    "No agent logins yet. Set up Claude Code or Codex, then finish the "
                        + "provider's secure browser sign-in."
                )
            )
            empty.applyFont(.body)
            empty.textColor = Design.Text.secondary
            rows = [SettingsUI.fullRow(empty)]
        } else {
            rows = accounts.enumerated().map { row(for: $0.element, at: $0.offset) }
        }

        install(SettingsCard(rows: rows), in: accountsCardHost)
    }

    private func row(for account: AgentAccount, at index: Int) -> NSView {
        let icon = NSImageView()
        icon.image = account.provider.icon
        icon.imageScaling = .scaleProportionallyDown
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.setAccessibilityElement(false)
        NSLayoutConstraint.activate([
            icon.widthAnchor.constraint(equalToConstant: Layout.iconSide),
            icon.heightAnchor.constraint(equalToConstant: Layout.iconSide)
        ])

        var name = AccountName.display(for: account)
        if let emoji = account.emoji {
            name = "\(emoji)  \(name)"
        }
        let title = NSTextField(labelWithString: name)
        title.applyFont(.body)
        title.textColor = Design.Text.label

        let path = NSTextField(
            labelWithString: (account.configPath as NSString).abbreviatingWithTildeInPath
        )
        path.applyFont(.caption)
        path.textColor = Design.Text.tertiary
        path.lineBreakMode = .byTruncatingMiddle

        let labels = NSStackView(views: [title, path])
        labels.orientation = .vertical
        labels.alignment = .leading
        labels.spacing = Design.Spacing.hairline
        labels.setContentHuggingPriority(.defaultLow, for: .horizontal)

        // The same switch the Accounts settings page carries, so a login the user does not
        // want offered never has to be visited later: off here is off there.
        let enabled = SettingsUI.toggle(
            isOn: account.isEnabled,
            target: self,
            action: #selector(accountEnabledChanged(_:))
        )
        enabled.tag = index
        enabled.toolTip = AccountsPreferencesStrings.enabledTooltip
        enabled.setAccessibilityLabel(
            AccountsPreferencesStrings.enabledLabel(account.displayName)
        )

        // A switched-off login stays listed and goes quiet; the switch that brings it back
        // keeps full ink — the Accounts settings page's rule.
        let dimmed = account.isEnabled ? 1 : AccountsPreferencesLayout.disabledRowAlpha
        icon.alphaValue = dimmed
        labels.alphaValue = dimmed

        let content = NSStackView(views: [icon, labels, enabled])
        content.orientation = .horizontal
        content.alignment = .centerY
        content.spacing = Design.Spacing.small
        // `.gravityAreas` leaves the row's slack unassigned; `.fill` hands it to the label
        // column, which is what keeps the switch on the trailing edge of every row.
        content.distribution = .fill

        return SettingsUI.fullRow(content)
    }

    @objc private func accountEnabledChanged(_ sender: ThemedToggle) {
        guard sender.tag >= 0, sender.tag < shownAccounts.count else { return }
        let account = shownAccounts[sender.tag]

        AccountPreferencesStore.shared.setEnabled(sender.state == .on, for: account.id)
        rebuildAccountRows()
        // The sidebar and composer draw from the accounts a provider offers — same signal the
        // Accounts settings page sends.
        NotificationCenter.default.post(ProjectsDidChange())
    }

    // MARK: - CLI health

    private func rebuildCLIRows() {
        guard let results = cliResults else {
            let spinner = ThemedSpinner()
            spinner.isAnimating = true
            probeSpinner = spinner
            let checking = NSTextField(
                labelWithString: L10n.string("Checking your shell's PATH…")
            )
            checking.applyFont(.body)
            checking.textColor = Design.Text.secondary
            let content = NSStackView(views: [spinner, checking])
            content.orientation = .horizontal
            content.alignment = .centerY
            content.spacing = Design.Spacing.small
            install(SettingsCard(rows: [SettingsUI.fullRow(content)]), in: cliCardHost)
            return
        }

        probeSpinner = nil
        install(SettingsCard(rows: results.map { cliRow(for: $0) }), in: cliCardHost)
    }

    private func cliRow(for result: AgentCLIProbe.Result) -> NSView {
        let title = NSTextField(labelWithString: result.executable)
        title.applyFont(.code())
        title.textColor = Design.Text.label

        let detail: NSTextField
        if let path = result.resolvedPath {
            detail = NSTextField(labelWithString: path)
            detail.applyFont(.caption)
            detail.textColor = Design.Text.secondary
            detail.lineBreakMode = .byTruncatingMiddle
        } else {
            detail = NSTextField(
                wrappingLabelWithString: L10n.format(
                    "Not on your shell's PATH, so sessions cannot launch. Install: %@",
                    OnboardingCLIDefaults.installCommand(for: result.executable)
                )
            )
            detail.applyFont(.caption)
            detail.textColor = Design.Text.secondary
        }

        let status = NSTextField(
            labelWithString: result.isInstalled
                ? L10n.string("Found")
                : L10n.string("Not found")
        )
        status.applyFont(.caption)
        status.textColor = result.isInstalled
            ? Design.Status.positive
            : Design.Status.warning

        let labels = NSStackView(views: [title, detail])
        labels.orientation = .vertical
        labels.alignment = .leading
        labels.spacing = Design.Spacing.hairline
        labels.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let content = NSStackView(views: [labels, status])
        content.orientation = .horizontal
        content.alignment = .centerY
        content.spacing = Design.Spacing.medium
        // `.fill` gives the row's slack to the low-hugging label column, so the status reads
        // as a trailing-aligned column rather than trailing each row's own text.
        content.distribution = .fill

        return SettingsUI.fullRow(content)
    }

    // MARK: - Card installation

    private func install(_ card: NSView, in host: NSView) {
        host.subviews.forEach { $0.removeFromSuperview() }
        card.translatesAutoresizingMaskIntoConstraints = false
        host.addSubview(card)
        NSLayoutConstraint.activate([
            card.topAnchor.constraint(equalTo: host.topAnchor),
            card.bottomAnchor.constraint(equalTo: host.bottomAnchor),
            card.leadingAnchor.constraint(equalTo: host.leadingAnchor),
            card.trailingAnchor.constraint(equalTo: host.trailingAnchor)
        ])
    }
}

// MARK: - Defaults

enum OnboardingCLIDefaults {
    /// The install hint per executable — the `ProjectStatsPopover` shape: what is absent, the
    /// command that fixes it, and the promise that nothing else is needed.
    static func installCommand(for executable: String) -> String {
        switch executable {
        case AgentDefaults.codexExecutable:
            return "npm install -g @openai/codex"
        case AgentDefaults.grokExecutable:
            return "npm install -g @xai-official/grok"
        case AgentDefaults.openCodeExecutable:
            return "npm install -g opencode-ai"
        default:
            return "npm install -g @anthropic-ai/claude-code"
        }
    }
}
