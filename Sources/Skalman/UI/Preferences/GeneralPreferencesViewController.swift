import AppKit
import CoreImage.CIFilterBuiltins

/// General preferences: which agent new sessions use, startup behaviour, and the shell.
final class GeneralPreferencesViewController: NSViewController {

    // MARK: - Controls

    private let defaultAgentPopUp = ThemedPopUp()
    private let terminalTitleToggle = ThemedToggle()
    private let branchGroupingToggle = ThemedToggle()
    private let projectIconToggle = ThemedToggle()
    private let accountAvatarToggle = ThemedToggle()
    private let claudeAttachmentToggle = ThemedToggle()
    private let codexAttachmentToggle = ThemedToggle()
    private let restoreSessionToggle = ThemedToggle()
    private let confirmCloseToggle = ThemedToggle()
    private let codexHookToggle = ThemedToggle()
    private let codexHookTrustToggle = ThemedToggle()
    private let remoteAccessToggle = ThemedToggle()
    private let remoteOpenButton = ThemedButton()
    private let remotePairButton = ThemedButton()
    private var remoteStatusField: NSTextField?
    private let shellField = ThemedTextField()

    // MARK: - Lifecycle

    override func loadView() {
        view = NSView()
        setupControls()
        setupLayout()
    }

    // MARK: - Setup

    private func setupControls() {
        for kind in AgentKind.allCases {
            defaultAgentPopUp.addItem(
                ThemedMenuItem(title: kind.displayName, representedValue: kind)
            )
        }
        defaultAgentPopUp.selectItem(at: AgentKind.allCases.firstIndex(of: AppSettings.shared.defaultAgentKind) ?? 0)
        defaultAgentPopUp.target = self
        defaultAgentPopUp.action = #selector(defaultAgentChanged)
        defaultAgentPopUp.translatesAutoresizingMaskIntoConstraints = false
        defaultAgentPopUp.widthAnchor.constraint(equalToConstant: SettingsUIDefaults.controlWidth).isActive = true

        configure(terminalTitleToggle, isOn: AppSettings.shared.usesAgentTitleInSidebar, action: #selector(terminalTitleChanged))
        configure(branchGroupingToggle,
                  isOn: AppSettings.shared.groupsSessionsByBranch,
                  action: #selector(branchGroupingChanged))
        configure(projectIconToggle,
                  isOn: AppSettings.shared.discoversProjectIcons,
                  action: #selector(projectIconChanged))
        configure(accountAvatarToggle,
                  isOn: AppSettings.shared.discoversAccountAvatars,
                  action: #selector(accountAvatarChanged))
        configure(
            claudeAttachmentToggle,
            isOn: AppSettings.shared.detectsAttachmentReferences(for: .claude),
            action: #selector(claudeAttachmentDetectionChanged)
        )
        configure(
            codexAttachmentToggle,
            isOn: AppSettings.shared.detectsAttachmentReferences(for: .codex),
            action: #selector(codexAttachmentDetectionChanged)
        )
        configure(restoreSessionToggle, isOn: AppSettings.shared.restoresLastSession, action: #selector(restoreSessionChanged))
        configure(confirmCloseToggle, isOn: AppSettings.shared.confirmsBeforeClosingRunningSession, action: #selector(confirmCloseChanged))
        configure(codexHookToggle,
                  isOn: AppSettings.shared.installsCodexHooks,
                  action: #selector(codexHookChanged))
        configure(codexHookTrustToggle,
                  isOn: AppSettings.shared.bypassesCodexHookTrust,
                  action: #selector(codexHookTrustChanged))
        codexHookTrustToggle.isEnabled = AppSettings.shared.installsCodexHooks
        configure(
            remoteAccessToggle,
            isOn: AppSettings.shared.remoteAccessEnabled,
            action: #selector(remoteAccessChanged)
        )

        remoteOpenButton.title = "Open Locally"
        remoteOpenButton.target = self
        remoteOpenButton.action = #selector(openRemoteAccess)
        remotePairButton.title = "Pair iPhone…"
        remotePairButton.target = self
        remotePairButton.action = #selector(pairRemoteAccess)

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(remoteAccessStatusDidChange),
            name: RemoteAccessCoordinator.statusDidChange,
            object: nil
        )

        shellField.font = Design.Typography.body()
        shellField.placeholderString = TerminalDefaults.defaultShell
        shellField.stringValue = ProfileStorage.shared.defaultProfile.shellPath
        shellField.target = self
        shellField.action = #selector(shellPathChanged)
    }

    private func configure(_ toggle: ThemedToggle, isOn: Bool, action: Selector) {
        toggle.state = isOn ? .on : .off
        toggle.target = self
        toggle.action = action
    }

    private func setupLayout() {
        let sessions = SettingsCard(rows: [
            SettingsUI.row(title: "New sessions use",
                           subtitle: "Used by New Session (⌘N). Other agents stay available from the Project menu.",
                           control: defaultAgentPopUp),
            SettingsUI.row(title: "Name sessions after the agent's own title",
                           subtitle: "Agents name the conversation as it develops. Renaming a session keeps your name.",
                           control: terminalTitleToggle),
            SettingsUI.row(
                title: "Group sessions by branch",
                subtitle: "Sessions that ran on the same branch gather under it, "
                    + "when a branch has more than one.",
                control: branchGroupingToggle
            ),
            SettingsUI.row(
                title: "Discover project icons",
                subtitle: "Projects without an icon use their own favicon or app icon, "
                    + "else their GitHub avatar or homepage favicon.",
                control: projectIconToggle
            ),
            SettingsUI.row(
                title: "Discover account avatars",
                subtitle: "Sessions show their account's Gravatar or GitHub avatar, "
                    + "found by its login email. A chosen emoji still wins.",
                control: accountAvatarToggle
            )
        ])

        let startup = SettingsCard(rows: [
            SettingsUI.row(title: "Reopen the last session at launch", control: restoreSessionToggle)
        ])

        let closing = SettingsCard(rows: [
            SettingsUI.row(title: "Ask before closing a running session",
                           subtitle: "Closing a session ends its agent but keeps it in the sidebar so it can be resumed.",
                           control: confirmCloseToggle)
        ])

        let shell = SettingsCard(rows: [
            SettingsUI.fullRow(shellRow())
        ])

        let page = SettingsUI.page([
            SettingsUI.heading("General"),
            SettingsUI.section("Sessions", sessions),
            SettingsUI.section("Attachments", attachmentDetectionCard()),
            SettingsUI.section("Startup", startup),
            SettingsUI.section("Closing", closing),
            SettingsUI.section("Remote Access", remoteAccessCard()),
            SettingsUI.section("Codex Hooks", codexHooksCard()),
            SettingsUI.section("Shell", shell),
            SettingsUI.note("Shell path is used by shell sessions. Agent sessions launch through your login shell regardless.")
        ], hostPage: .general)

        page.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(page)
        NSLayoutConstraint.activate([
            page.topAnchor.constraint(equalTo: view.topAnchor),
            page.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            page.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            page.trailingAnchor.constraint(equalTo: view.trailingAnchor)
        ])

        refreshRemoteAccessStatus()
    }

    private func attachmentDetectionCard() -> SettingsCard {
        SettingsCard(rows: [
            SettingsUI.row(
                title: "Detect attachments from Claude Code",
                subtitle: "Scans Claude's terminal output and Native replies for image and PDF paths. "
                    + "Turn this off if a Claude update changes how paths are rendered.",
                control: claudeAttachmentToggle
            ),
            SettingsUI.row(
                title: "Detect attachments from Codex",
                subtitle: "Scans Codex's terminal output and Native replies for image and PDF paths. "
                    + "Turn this off if a Codex update changes how paths are rendered.",
                control: codexAttachmentToggle
            )
        ])
    }

    private func remoteAccessCard() -> SettingsCard {
        let actions = NSStackView(views: [remoteOpenButton, remotePairButton])
        actions.orientation = .horizontal
        actions.alignment = .centerY
        actions.spacing = Design.Spacing.small

        let statusRow = SettingsUI.row(
            title: "Private connection link (Beta)",
            subtitle: "Off",
            control: actions,
            subtitleField: &remoteStatusField
        )

        return SettingsCard(rows: [
            SettingsUI.row(
                title: "Allow remote access",
                subtitle: "Publishes only Skalman's authenticated remote surface through a "
                    + "temporary Cloudflare HTTPS relay; MCP and extension services stay local. "
                    + "Pairing is for your own trusted devices. Share an individual chat from "
                    + "its ⋯ menu when someone else should see it.",
                control: remoteAccessToggle
            ),
            statusRow
        ])
    }

    /// The two Codex hook settings.
    ///
    /// Two switches rather than one, because they are separate decisions and only the second
    /// has a security cost: installing writes entries to a file the user owns, while skipping
    /// review un-gates every hook in that folder rather than only ours.
    private func codexHooksCard() -> SettingsCard {
        SettingsCard(rows: [
            SettingsUI.row(
                title: "Report Codex turn boundaries",
                subtitle: "Adds Skalman's entries to each Codex account's hooks.json, "
                    + "so sessions show exact activity instead of guessing from output. "
                    + "Your existing entries are kept.",
                control: codexHookToggle
            ),
            SettingsUI.row(
                title: "Skip Codex hook review",
                subtitle: "Codex will not run a hook until you approve its text once. "
                    + "Skipping that runs every hook in the config folder unreviewed, "
                    + "including any an agent adds later. Leave off and approve once in Codex.",
                control: codexHookTrustToggle
            )
        ])
    }

    /// The shell field with its Choose button, filling the row.
    private func shellRow() -> NSView {
        let label = NSTextField(labelWithString: "Shell path")
        label.font = Design.Typography.body()
        label.textColor = Design.Text.label
        label.setContentHuggingPriority(.required, for: .horizontal)

        let choose = SettingsUI.button("Choose…", target: self, action: #selector(browseForShell))

        let row = NSStackView(views: [label, shellField, choose])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = Design.Spacing.medium
        shellField.setContentHuggingPriority(.defaultLow, for: .horizontal)
        return row
    }

    // MARK: - Actions

    @objc private func defaultAgentChanged() {
        guard let kind = defaultAgentPopUp.selectedItem?.representedValue as? AgentKind else { return }
        AppSettings.shared.defaultAgentKind = kind
    }

    @objc private func restoreSessionChanged() {
        AppSettings.shared.restoresLastSession = restoreSessionToggle.state == .on
    }

    @objc private func confirmCloseChanged() {
        AppSettings.shared.confirmsBeforeClosingRunningSession = confirmCloseToggle.state == .on
    }

    @objc private func terminalTitleChanged() {
        AppSettings.shared.usesAgentTitleInSidebar = terminalTitleToggle.state == .on
        NotificationCenter.default.post(ProjectsDidChange())
    }

    @objc private func projectIconChanged() {
        AppSettings.shared.discoversProjectIcons = projectIconToggle.state == .on
        // Sweeps immediately, so switching this on does not wait for a relaunch.
        ProjectIconDiscovery.shared.retryAll()
    }

    @objc private func accountAvatarChanged() {
        AppSettings.shared.discoversAccountAvatars = accountAvatarToggle.state == .on
        // Forgotten attempts plus a sidebar rebuild, so re-enabling acts immediately —
        // rows re-prime lookups as they reconfigure.
        AccountAvatarStore.retryAll()
        NotificationCenter.default.post(ProjectsDidChange())
    }

    @objc private func claudeAttachmentDetectionChanged() {
        AppSettings.shared.setAttachmentReferenceDetection(
            for: .claude,
            enabled: claudeAttachmentToggle.state == .on
        )
    }

    @objc private func codexAttachmentDetectionChanged() {
        AppSettings.shared.setAttachmentReferenceDetection(
            for: .codex,
            enabled: codexAttachmentToggle.state == .on
        )
    }

    @objc private func branchGroupingChanged() {
        AppSettings.shared.groupsSessionsByBranch = branchGroupingToggle.state == .on
        // The sidebar rebuilds its tree on this, which is what adds or removes the level.
        NotificationCenter.default.post(ProjectsDidChange())
    }

    /// Switching off also removes what was installed, rather than leaving inert entries in a
    /// file the user owns — an off switch that leaves its traces behind is not off.
    @objc private func codexHookChanged() {
        let isOn = codexHookToggle.state == .on
        AppSettings.shared.installsCodexHooks = isOn
        codexHookTrustToggle.isEnabled = isOn

        for account in AgentAccountDiscovery.accounts(for: .codex) {
            if isOn {
                CodexHookInstaller.install(inCodexHome: account.configPath)
            } else {
                CodexHookInstaller.uninstall(fromCodexHome: account.configPath)
            }
        }
    }

    @objc private func codexHookTrustChanged() {
        AppSettings.shared.bypassesCodexHookTrust = codexHookTrustToggle.state == .on
    }

    @objc private func remoteAccessChanged() {
        RemoteAccessCoordinator.shared.setEnabled(remoteAccessToggle.state == .on)
        refreshRemoteAccessStatus()
    }

    @objc private func remoteAccessStatusDidChange(_ notification: Notification) {
        refreshRemoteAccessStatus()
    }

    private func refreshRemoteAccessStatus() {
        let coordinator = RemoteAccessCoordinator.shared
        remoteAccessToggle.state = AppSettings.shared.remoteAccessEnabled ? .on : .off

        switch coordinator.status {
        case .disabled:
            remoteStatusField?.stringValue = "Off. Turning this on creates a fresh private link."
        case .starting:
            remoteStatusField?.stringValue = "Starting the private listener…"
        case .listening(let port):
            switch coordinator.relayStatus {
            case .inactive, .starting:
                remoteStatusField?.stringValue = "Local mirror ready on 127.0.0.1:\(port); "
                    + "connecting the secure relay…"
            case .connected(let url):
                remoteStatusField?.stringValue = "Ready for iPhone and web at \(url.host ?? "the secure relay"). "
                    + "Turning access off immediately invalidates the link."
            case .unavailable(let reason):
                remoteStatusField?.stringValue = "Local browser access is ready. \(reason)"
            }
        case .failed:
            remoteStatusField?.stringValue = "Could not start the private listener. "
                + "Turn access off and on to retry."
        }

        remoteOpenButton.isEnabled = coordinator.localURL != nil
        remotePairButton.isEnabled = coordinator.remoteURL != nil
    }

    @objc private func openRemoteAccess() {
        guard let url = RemoteAccessCoordinator.shared.localURL else { return }
        NSWorkspace.shared.open(url)
    }

    @objc private func pairRemoteAccess() {
        guard let url = RemoteAccessCoordinator.shared.remoteURL,
              let image = qrCode(for: url.absoluteString) else {
            return
        }

        let imageView = NSImageView(image: image)
        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.translatesAutoresizingMaskIntoConstraints = false

        let note = NSTextField(wrappingLabelWithString:
            "Open Skalman on iPhone, choose Add Connection, and scan this code. "
            + "This is an owner-device code: it can access your chats and approve permission requests. "
            + "Only scan it on a device you control."
        )
        note.font = Design.Typography.body()
        note.textColor = Design.Text.secondary
        note.alignment = .center

        let stack = NSStackView(views: [imageView, note])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = Design.Spacing.medium
        stack.edgeInsets = NSEdgeInsets(
            top: Design.Spacing.small,
            left: Design.Spacing.medium,
            bottom: Design.Spacing.small,
            right: Design.Spacing.medium
        )
        stack.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            imageView.widthAnchor.constraint(equalToConstant: 240),
            imageView.heightAnchor.constraint(equalToConstant: 240),
            note.widthAnchor.constraint(equalToConstant: 320)
        ])

        let alert = NSAlert()
        alert.messageText = "Pair Skalman on iPhone"
        alert.informativeText = "The relay and pairing code are new for this Skalman launch."
        alert.accessoryView = stack
        alert.addButton(withTitle: "Done")
        alert.addButton(withTitle: "Copy Pairing Link")
        if alert.runModal() == .alertSecondButtonReturn {
            copyRemoteURL(url)
        }
    }

    private func copyRemoteURL(_ url: URL) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(url.absoluteString, forType: .string)

    }

    private func qrCode(for text: String) -> NSImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(text.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage else { return nil }

        let scaled = output.transformed(by: CGAffineTransform(scaleX: 10, y: 10))
        let representation = NSCIImageRep(ciImage: scaled)
        let image = NSImage(size: representation.size)
        image.addRepresentation(representation)
        return image
    }

    @objc private func shellPathChanged() {
        var profile = ProfileStorage.shared.defaultProfile
        profile.shellPath = shellField.stringValue
        ProfileStorage.shared.defaultProfile = profile
    }

    @objc private func browseForShell() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = URL(fileURLWithPath: GeneralPreferencesDefaults.shellBrowseDirectory)
        panel.message = "Select a shell executable"

        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url, let self else { return }
            self.shellField.stringValue = url.path
            self.shellPathChanged()
        }
    }
}

// MARK: - General Preferences Defaults

enum GeneralPreferencesDefaults {
    static let shellBrowseDirectory = "/bin"
}
