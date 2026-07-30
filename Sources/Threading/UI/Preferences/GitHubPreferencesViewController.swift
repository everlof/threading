import AppKit

/// GitHub gets a page of its own for the same reason Remote Access does: it is a setup flow
/// with live state, not a behavioural toggle. The page shows the whole credential chain the
/// broker resolves — the app connection the user can create here, the ambient `gh` and git
/// credential helper fallbacks, and what extensions actually get — so "why did that read work"
/// is answerable by looking at one screen.
final class GitHubPreferencesViewController: NSViewController {

    /// Probes are subprocesses, so their results are cached for the app's lifetime rather
    /// than per pane visit; the sources' own retry interval governs re-checks after a miss.
    private static let ghProbe = GhCLITokenSource(shellPath: AgentLauncher.loginShellPath)
    private static let gitProbe = GitCredentialHelperSource(
        shellPath: AgentLauncher.loginShellPath
    )

    // MARK: - Controls

    private let clientIDField = ThemedTextField()
    private let connectionGlyph = NSTextField(labelWithString: "●")
    private let connectionTitle = NSTextField(labelWithString: "")
    private let connectionDetail = NSTextField(wrappingLabelWithString: "")
    private let connectionButton = ThemedButton()
    private let cancelButton = ThemedButton()

    private let userCodeLabel = NSTextField(labelWithString: "")
    private let openGitHubButton = ThemedButton()
    private let copyCodeButton = ThemedButton()

    private var ghSubtitle: NSTextField?
    private var gitSubtitle: NSTextField?

    private var copiedReset: DispatchWorkItem?

    // MARK: - Lifecycle

    override func loadView() {
        view = NSView()
        configureControls()
        buildPage()
        refresh()
    }

    override func viewWillAppear() {
        super.viewWillAppear()
        refresh()
        probeFallbacks()
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    // MARK: - Construction

    private func configureControls() {
        clientIDField.applyFont(.body)
        clientIDField.placeholderString = L10n.string("Iv1.…")
        clientIDField.target = self
        clientIDField.action = #selector(clientIDChanged)
        clientIDField.translatesAutoresizingMaskIntoConstraints = false
        clientIDField.widthAnchor
            .constraint(equalToConstant: SettingsUIDefaults.controlWidth).isActive = true
        clientIDField.setAccessibilityIdentifier("settings.github.client-id")

        connectionGlyph.applyFont(.body)
        connectionGlyph.setContentHuggingPriority(.required, for: .horizontal)
        connectionTitle.applyFont(.body)
        connectionTitle.textColor = Design.Text.label
        connectionTitle.setAccessibilityIdentifier("settings.github.status")
        connectionDetail.applyFont(.subheading)
        connectionDetail.textColor = Design.Text.secondary

        connectionButton.target = self
        connectionButton.action = #selector(connectionAction)
        connectionButton.setAccessibilityIdentifier("settings.github.connect")

        cancelButton.title = L10n.string("Cancel")
        cancelButton.target = self
        cancelButton.action = #selector(cancelAuthorization)
        cancelButton.setAccessibilityIdentifier("settings.github.cancel")

        // The one-time code is what the user carries to another surface: monospaced so the
        // characters are unambiguous, weighted so it reads as the row's subject.
        userCodeLabel.applyFont(.code(weight: .semibold))
        userCodeLabel.textColor = Design.Text.label
        userCodeLabel.setAccessibilityIdentifier("settings.github.user-code")

        openGitHubButton.title = L10n.string("Open GitHub")
        openGitHubButton.target = self
        openGitHubButton.action = #selector(openVerification)
        openGitHubButton.setAccessibilityIdentifier("settings.github.open-verification")

        copyCodeButton.title = L10n.string("Copy Code")
        copyCodeButton.target = self
        copyCodeButton.action = #selector(copyUserCode)
        copyCodeButton.setAccessibilityIdentifier("settings.github.copy-code")

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(connectionStatusDidChange),
            name: GitHubAppConnection.statusDidChange,
            object: nil
        )
    }

    private func buildPage() {
        var ghField: NSTextField?
        var gitField: NSTextField?

        let page = SettingsUI.page([
            SettingsUI.heading("GitHub"),
            SettingsUI.note(
                "Extensions can ask Threading to read from GitHub — check runs today. Threading "
                    + "performs those reads itself with the best credential below; extensions "
                    + "never receive a token."
            ),
            SettingsUI.section("GitHub App", appConnectionCard()),
            SettingsUI.section("Command-Line Fallbacks", SettingsCard(rows: [
                SettingsUI.row(
                    title: "gh CLI",
                    subtitle: "Checking…",
                    control: nil,
                    subtitleField: &ghField
                ),
                SettingsUI.row(
                    title: "Git credential helper",
                    subtitle: "Checking…",
                    control: nil,
                    subtitleField: &gitField
                )
            ])),
            SettingsUI.note(
                "The chain is tried top to bottom: the app connection, then gh, then the "
                    + "credential helper, then anonymously. Reads name which credential "
                    + "answered, so a private repository explains itself instead of failing "
                    + "namelessly."
            )
        ])
        ghSubtitle = ghField
        gitSubtitle = gitField

        page.setAccessibilityIdentifier("settings.github.page")
        page.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(page)
        NSLayoutConstraint.activate([
            page.topAnchor.constraint(equalTo: view.topAnchor),
            page.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            page.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            page.trailingAnchor.constraint(equalTo: view.trailingAnchor)
        ])
    }

    private func appConnectionCard() -> SettingsCard {
        SettingsCard(rows: [
            SettingsUI.row(
                title: "Client ID",
                subtitle: "From your GitHub App's settings page. Device-flow sign-in needs "
                    + "no client secret. Enable “Device flow” on the app, and install it on "
                    + "the repositories it should see.",
                control: clientIDField
            ),
            SettingsUI.fullRow(connectionRow())
        ])
    }

    private func connectionRow() -> NSView {
        let labels = NSStackView(views: [connectionTitle, connectionDetail])
        labels.orientation = .vertical
        labels.alignment = .leading
        labels.spacing = Design.Spacing.hairline
        labels.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let statusRow = NSStackView(views: [
            connectionGlyph, labels, cancelButton, connectionButton
        ])
        statusRow.orientation = .horizontal
        statusRow.alignment = .centerY
        statusRow.spacing = Design.Spacing.medium

        let codeRow = NSStackView(views: [userCodeLabel, copyCodeButton, openGitHubButton])
        codeRow.orientation = .horizontal
        codeRow.alignment = .centerY
        codeRow.spacing = Design.Spacing.medium

        let column = NSStackView(views: [statusRow, codeRow])
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = Design.Spacing.small
        NSLayoutConstraint.activate([
            statusRow.widthAnchor.constraint(equalTo: column.widthAnchor)
        ])
        return column
    }

    // MARK: - State

    @objc private func connectionStatusDidChange(_ notification: Notification) {
        refresh()
    }

    private func refresh() {
        copiedReset?.cancel()
        copiedReset = nil

        let settings = AppSettings.shared
        if clientIDField.stringValue != settings.githubAppClientID,
           view.window?.firstResponder !== clientIDField.currentEditor() {
            clientIDField.stringValue = settings.githubAppClientID
        }

        let connection = GitHubAppConnection.shared
        cancelButton.isHidden = true
        setCode(nil)

        switch connection.status {
        case .disconnected:
            updateConnection(
                title: L10n.string("Not connected"),
                detail: L10n.string(
                    "Connect to read private repositories with scopes you chose on GitHub."
                ),
                color: Design.Text.tertiary
            )
            connectionButton.title = L10n.string("Connect GitHub…")
            connectionButton.isProminent = !settings.githubAppClientID.isEmpty
            connectionButton.isEnabled = true

        case .awaitingAuthorization(let userCode, _):
            updateConnection(
                title: L10n.string("Waiting for GitHub"),
                detail: L10n.string("Enter this code on GitHub to approve the connection."),
                color: Design.Status.warning
            )
            setCode(userCode)
            cancelButton.isHidden = false
            connectionButton.title = L10n.string("Connecting…")
            connectionButton.isProminent = false
            connectionButton.isEnabled = false

        case .connected(let login):
            updateConnection(
                title: login.map { L10n.format("Connected as %@", $0) }
                    ?? L10n.string("Connected"),
                detail: L10n.string(
                    "Brokered reads use this connection first. Manage or revoke it on "
                        + "GitHub under Settings ▸ Applications."
                ),
                color: Design.Status.positive
            )
            connectionButton.title = L10n.string("Disconnect")
            connectionButton.isProminent = false
            connectionButton.isEnabled = true

        case .failed(let message):
            updateConnection(
                title: L10n.string("Couldn’t connect"),
                detail: message,
                color: Design.Status.negative
            )
            connectionButton.title = L10n.string("Try Again")
            connectionButton.isProminent = true
            connectionButton.isEnabled = true
        }
    }

    private func updateConnection(title: String, detail: String, color: NSColor) {
        connectionTitle.stringValue = title
        connectionDetail.stringValue = detail
        connectionGlyph.textColor = color
    }

    private func setCode(_ code: String?) {
        userCodeLabel.stringValue = code ?? ""
        userCodeLabel.isHidden = code == nil
        copyCodeButton.isHidden = code == nil
        openGitHubButton.isHidden = code == nil
        openGitHubButton.isProminent = code != nil
    }

    private func probeFallbacks() {
        let ghSubtitle = ghSubtitle
        let gitSubtitle = gitSubtitle
        Task { [weak self] in
            let ghToken = await Self.ghProbe.token()
            let gitToken = await Self.gitProbe.token()
            guard self != nil else { return }
            ghSubtitle?.stringValue = ghToken != nil
                ? L10n.string("Signed in — used when no app connection answers.")
                : L10n.string("Not signed in, or gh is not installed.")
            gitSubtitle?.stringValue = gitToken != nil
                ? L10n.string("Holds a github.com credential — the quiet fallback.")
                : L10n.string("No github.com credential configured.")
        }
    }

    // MARK: - Actions

    @objc private func clientIDChanged() {
        AppSettings.shared.githubAppClientID = clientIDField.stringValue
            .trimmingCharacters(in: .whitespacesAndNewlines)
        refresh()
    }

    @objc private func connectionAction() {
        let connection = GitHubAppConnection.shared
        switch connection.status {
        case .connected:
            connection.disconnect()
        case .disconnected, .failed:
            clientIDChanged()
            connection.beginAuthorization(clientID: AppSettings.shared.githubAppClientID)
        case .awaitingAuthorization:
            break
        }
        refresh()
    }

    @objc private func cancelAuthorization() {
        GitHubAppConnection.shared.cancelAuthorization()
        refresh()
    }

    @objc private func openVerification() {
        guard case .awaitingAuthorization(_, let url) =
                GitHubAppConnection.shared.status else { return }
        NSWorkspace.shared.open(url)
    }

    @objc private func copyUserCode() {
        guard case .awaitingAuthorization(let code, _) =
                GitHubAppConnection.shared.status else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(code, forType: .string)
        copyCodeButton.title = L10n.string("Copied")
        let reset = DispatchWorkItem { [weak self] in
            self?.copyCodeButton.title = L10n.string("Copy Code")
        }
        copiedReset = reset
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.4, execute: reset)
    }
}
