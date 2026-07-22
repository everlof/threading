import AppKit

/// General preferences: which agent new sessions use, startup behaviour, and the shell.
final class GeneralPreferencesViewController: NSViewController {

    // MARK: - Controls

    private let defaultAgentPopUp = NSPopUpButton()
    private let terminalTitleToggle = NSSwitch()
    private let branchGroupingToggle = NSSwitch()
    private let projectIconToggle = NSSwitch()
    private let accountAvatarToggle = NSSwitch()
    private let restoreSessionToggle = NSSwitch()
    private let confirmCloseToggle = NSSwitch()
    private let shellField = NSTextField()

    // MARK: - Lifecycle

    override func loadView() {
        view = NSView()
        setupControls()
        setupLayout()
    }

    // MARK: - Setup

    private func setupControls() {
        for kind in AgentKind.allCases {
            defaultAgentPopUp.addItem(withTitle: kind.displayName)
            defaultAgentPopUp.lastItem?.representedObject = kind
        }
        defaultAgentPopUp.selectItem(at: AgentKind.allCases.firstIndex(of: AppSettings.shared.defaultAgentKind) ?? 0)
        defaultAgentPopUp.target = self
        defaultAgentPopUp.action = #selector(defaultAgentChanged)
        defaultAgentPopUp.translatesAutoresizingMaskIntoConstraints = false
        defaultAgentPopUp.widthAnchor.constraint(equalToConstant: SettingsUIDefaults.controlWidth).isActive = true

        configure(terminalTitleToggle, isOn: AppSettings.shared.usesTerminalTitleInSidebar, action: #selector(terminalTitleChanged))
        configure(branchGroupingToggle,
                  isOn: AppSettings.shared.groupsSessionsByBranch,
                  action: #selector(branchGroupingChanged))
        configure(projectIconToggle,
                  isOn: AppSettings.shared.discoversProjectIcons,
                  action: #selector(projectIconChanged))
        configure(accountAvatarToggle,
                  isOn: AppSettings.shared.discoversAccountAvatars,
                  action: #selector(accountAvatarChanged))
        configure(restoreSessionToggle, isOn: AppSettings.shared.restoresLastSession, action: #selector(restoreSessionChanged))
        configure(confirmCloseToggle, isOn: AppSettings.shared.confirmsBeforeClosingRunningSession, action: #selector(confirmCloseChanged))

        shellField.font = Design.Typography.body()
        shellField.placeholderString = TerminalDefaults.defaultShell
        shellField.stringValue = ProfileStorage.shared.defaultProfile.shellPath
        shellField.target = self
        shellField.action = #selector(shellPathChanged)
    }

    private func configure(_ toggle: NSSwitch, isOn: Bool, action: Selector) {
        toggle.state = isOn ? .on : .off
        toggle.target = self
        toggle.action = action
    }

    private func setupLayout() {
        let sessions = SettingsCard(rows: [
            SettingsUI.row(title: "New sessions use",
                           subtitle: "Used by New Session (⌘N). Other agents stay available from the Project menu.",
                           control: defaultAgentPopUp),
            SettingsUI.row(title: "Name sessions after the terminal title",
                           subtitle: "Agents report progress through the terminal title. Renaming a session keeps your name.",
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
            SettingsUI.section("Startup", startup),
            SettingsUI.section("Closing", closing),
            SettingsUI.section("Shell", shell),
            SettingsUI.note("Shell path is used by shell sessions. Agent sessions launch through your login shell regardless.")
        ])

        page.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(page)
        NSLayoutConstraint.activate([
            page.topAnchor.constraint(equalTo: view.topAnchor),
            page.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            page.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            page.trailingAnchor.constraint(equalTo: view.trailingAnchor)
        ])
    }

    /// The shell field with its Choose button, filling the row.
    private func shellRow() -> NSView {
        let label = NSTextField(labelWithString: "Shell path")
        label.font = Design.Typography.body()
        label.textColor = .labelColor
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
        guard let kind = defaultAgentPopUp.selectedItem?.representedObject as? AgentKind else { return }
        AppSettings.shared.defaultAgentKind = kind
    }

    @objc private func restoreSessionChanged() {
        AppSettings.shared.restoresLastSession = restoreSessionToggle.state == .on
    }

    @objc private func confirmCloseChanged() {
        AppSettings.shared.confirmsBeforeClosingRunningSession = confirmCloseToggle.state == .on
    }

    @objc private func terminalTitleChanged() {
        AppSettings.shared.usesTerminalTitleInSidebar = terminalTitleToggle.state == .on
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

    @objc private func branchGroupingChanged() {
        AppSettings.shared.groupsSessionsByBranch = branchGroupingToggle.state == .on
        // The sidebar rebuilds its tree on this, which is what adds or removes the level.
        NotificationCenter.default.post(ProjectsDidChange())
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
