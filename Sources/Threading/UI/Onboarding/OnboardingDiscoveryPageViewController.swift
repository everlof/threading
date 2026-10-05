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

    var pageTitle: String { L10n.string("Agents & Accounts") }

    private let accountsCardHost = NSView()
    private let cliCardHost = NSView()
    private let accountsProvider: () -> [AgentAccount]
    private let setupController: AccountSetupCardViewController
    private var probeSpinner: ThemedSpinner?
    /// The shared installed-CLI answer — the same one the composer defaults from and refuses
    /// sends on, so this page cannot call a runtime installed that a chat then cannot start.
    private let availability: AgentCLIAvailability
    /// Whether a probe has come back since the page appeared, so a shell that could not be read
    /// says so instead of spinning forever.
    private var probeFinished = false
    /// The accounts the rows were built from, so a toggle's tag maps back to its account.
    private var shownAccounts: [AgentAccount] = []
    private let appEvents = AppEventObservations()

    init(
        accountsProvider: @escaping () -> [AgentAccount] = {
            AgentAccountDiscovery.allAccounts(for: .claude)
                + AgentAccountDiscovery.allAccounts(for: .codex)
        },
        availability: AgentCLIAvailability = .shared,
        setupCoordinator: AgentAccountSetupCoordinator = AgentAccountSetupCoordinator()
    ) {
        self.accountsProvider = accountsProvider
        self.availability = availability
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
        // An install finishing in the sheet, or in another terminal before the app came back to
        // the front, lands here without a button to press.
        appEvents.observe(AgentCLIAvailabilityDidChange.self) { [weak self] _ in
            self?.rebuildCLIRows()
        }
    }

    func pageWillAppear() {
        rebuildAccountRows()
        AccountEmailProbe.prefetch(AgentAccountDiscovery.accounts(for: .claude)) {
            NotificationCenter.default.post(AccountPreferencesDidChange())
        }

        availability.refresh { [weak self] in
            self?.probeFinished = true
            self?.rebuildCLIRows()
        }
    }

    private func setupViews() {
        let heading = NSTextField(labelWithString: L10n.string("Connect your coding agents"))
        heading.applyFont(.heading)
        heading.textColor = Design.Text.label
        heading.alignment = .center

        let caption = NSTextField(
            wrappingLabelWithString: L10n.string(
                "Threading supports Claude Code, Codex, Grok, Cursor, and OpenCode. Add and "
                    + "switch Claude Code or Codex logins here; the others keep sign-in in "
                    + "their own tools."
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

        let accountsHeading = NSTextField(labelWithString: L10n.string("Managed accounts"))
        accountsHeading.applyFont(.emphasizedBody)
        accountsHeading.textColor = Design.Text.label

        let setupHeading = NSTextField(labelWithString: L10n.string("Supported agents"))
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
                    "No managed logins yet. Add Claude Code or Codex here, or continue and "
                        + "sign in with another supported agent when you launch it."
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
        icon.image = AccountBadge.mark(for: account, surface: .details)
        icon.imageScaling = .scaleProportionallyDown
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.setAccessibilityElement(false)
        NSLayoutConstraint.activate([
            icon.widthAnchor.constraint(equalToConstant: Layout.iconSide),
            icon.heightAnchor.constraint(equalToConstant: Layout.iconSide)
        ])

        let name = account.presentation().visibleName
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

        // The same switch the Agents & Accounts settings page carries, so a login the user does not
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
        // keeps full ink — the Agents & Accounts settings page's rule.
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
        // Agents & Accounts settings page sends.
        NotificationCenter.default.post(ProjectsDidChange())
    }

    // MARK: - CLI health

    /// One row per runtime, with the install a click away. The page used to show five "Not
    /// found" warnings and a command to paste elsewhere, which on a fresh Mac read as five
    /// faults; one installed agent is all a chat needs, and the summary line says so.
    private func rebuildCLIRows() {
        guard availability.snapshot != nil else {
            let text = probeFinished
                ? L10n.string("Couldn't read your login shell's PATH. Agents are checked again when you start a chat.")
                : L10n.string("Checking your shell's PATH…")
            var views: [NSView] = []
            if !probeFinished {
                let spinner = ThemedSpinner()
                spinner.isAnimating = true
                probeSpinner = spinner
                views.append(spinner)
            }
            let checking = NSTextField(wrappingLabelWithString: text)
            checking.applyFont(.body)
            checking.textColor = Design.Text.secondary
            views.append(checking)
            let content = NSStackView(views: views)
            content.orientation = .horizontal
            content.alignment = .centerY
            content.spacing = Design.Spacing.small
            install(SettingsCard(rows: [SettingsUI.fullRow(content)]), in: cliCardHost)
            return
        }

        probeSpinner = nil
        var rows: [NSView] = []
        if let summary = cliSummary() {
            rows.append(SettingsUI.fullRow(summary))
        }
        rows += AgentKind.allCases.enumerated().map { cliRow(for: $0.element, at: $0.offset) }
        install(SettingsCard(rows: rows), in: cliCardHost)
    }

    /// Nothing to say when everything is installed; otherwise what a person with none or some
    /// actually needs to hear.
    private func cliSummary() -> NSView? {
        let installed = availability.installedKinds
        guard installed.count < AgentKind.allCases.count else { return nil }
        let text = installed.isEmpty
            ? L10n.string("Threading runs each agent's own command-line tool. Install at least one to start a chat — Install runs its official installer in a terminal you can watch.")
            : L10n.string("One agent is enough to start chatting. Install the others whenever you like.")
        let label = NSTextField(wrappingLabelWithString: text)
        label.applyFont(.body)
        label.textColor = installed.isEmpty ? Design.Text.label : Design.Text.secondary
        label.setAccessibilityIdentifier("onboarding.cli.summary")
        return label
    }

    private func cliRow(for kind: AgentKind, at index: Int) -> NSView {
        let title = NSTextField(labelWithString: kind.displayName)
        title.applyFont(.body)
        title.textColor = Design.Text.label

        let detail: NSTextField
        let trailing: NSView
        switch availability.state(for: kind) {
        case .installed(let path):
            detail = NSTextField(labelWithString: path)
            detail.lineBreakMode = .byTruncatingMiddle
            let found = NSTextField(labelWithString: L10n.string("Found"))
            found.applyFont(.caption)
            found.textColor = Design.Status.positive
            trailing = found
        case .missing, .unknown:
            detail = NSTextField(wrappingLabelWithString: missingDetail(for: kind))
            let button = SettingsUI.button("Install…", target: self, action: #selector(installClicked(_:)))
            button.tag = index
            button.setAccessibilityLabel(L10n.format("Install %@", kind.displayName))
            button.setAccessibilityIdentifier("onboarding.cli.install.\(kind.rawValue)")
            trailing = button
        }
        // The roster card above sets its row details in `.subheading`; the same role here keeps
        // the two cards reading as one page.
        detail.applyFont(.subheading)
        detail.textColor = Design.Text.secondary

        let labels = NSStackView(views: [title, detail])
        labels.orientation = .vertical
        labels.alignment = .leading
        labels.spacing = Design.Spacing.hairline
        labels.setContentHuggingPriority(.defaultLow, for: .horizontal)
        labels.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let content = NSStackView(views: [labels, trailing])
        content.orientation = .horizontal
        content.alignment = .centerY
        content.spacing = Design.Spacing.medium
        // `.fill` gives the row's slack to the low-hugging label column, so the status reads
        // as a trailing-aligned column rather than trailing each row's own text.
        content.distribution = .fill

        return SettingsUI.fullRow(content)
    }

    /// Why a runtime is not available, in the order the cures go: a PATH fix beats a reinstall,
    /// and a missing prerequisite is said before the install that would trip on it.
    private func missingDetail(for kind: AgentKind) -> String {
        if availability.isInstalledOffPath(kind) {
            return L10n.string("Installed in ~/.local/bin, which your login shell's PATH doesn't include.")
        }
        if !availability.canRunInstaller(for: kind) {
            return L10n.string("Not installed. Installs with npm, which comes with Node.js.")
        }
        return L10n.format("Not installed — %@ isn't on your login shell's PATH.", kind.executableName)
    }

    @objc private func installClicked(_ sender: ThemedButton) {
        guard AgentKind.allCases.indices.contains(sender.tag) else { return }
        AgentCLIInstallViewController.present(AgentKind.allCases[sender.tag], from: self) { [weak self] _ in
            self?.rebuildCLIRows()
        }
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
        let kind = AgentKind.allCases.first { $0.executableName == executable } ?? .claude
        return AgentCLIInstallRecipe.recipe(for: kind).command
    }
}
