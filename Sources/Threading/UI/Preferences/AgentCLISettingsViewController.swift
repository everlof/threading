import AppKit

/// An on-demand check, retained with General Settings. The fixed runtime inventory bounds both
/// work and views; no accounts, sessions or transcripts are scanned to populate these rows.
@MainActor
final class AgentCLISettingsViewController: NSViewController {
    typealias Check = @Sendable () async -> AgentCLIUpdateReport
    typealias Prepare = @Sendable ([AgentCLIUpdate], String) async -> AgentCLIUpdateExecutionPlan
    var runUpdates: (@MainActor (AgentCLIUpdateExecutionPlan) -> Bool)?

    private let check: Check
    private let prepare: Prepare
    private let openURL: @MainActor (URL) -> Void
    private var task: Task<Void, Never>?
    private var report: AgentCLIUpdateReport?
    private var isWorking = false
    private var isPreparingUpdate = false
    private var actionFailure = false
    private var card: SettingsCard?

    init(check: Check? = nil, prepare: @escaping Prepare = { updates, shell in
        await AgentCLIUpdateExecutionPlan.prepare(updates: updates, shell: shell)
    }, openURL: @escaping @MainActor (URL) -> Void = {
        NSWorkspace.shared.open($0)
    }) {
        let checker = AgentCLIUpdateChecker.live(shell: AgentLauncher.loginShellPath)
        self.check = check ?? { await checker.check() }
        self.prepare = prepare
        self.openURL = openURL
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    deinit { task?.cancel() }

    override func loadView() {
        view = NSView()
        render()
    }

    /// Also accepts an already completed check without running providers again.
    func show(_ report: AgentCLIUpdateReport) {
        self.report = report
        isWorking = false
        actionFailure = false
        if isViewLoaded { render() }
    }

    @objc private func checkNow() {
        guard task == nil else { return }
        isWorking = true
        actionFailure = false
        render()
        let check = self.check
        task = Task { [weak self] in
            let report = await check()
            guard !Task.isCancelled, let self else { return }
            task = nil
            show(report)
        }
    }

    private func render() {
        let checkButton = SettingsUI.button(
            isPreparingUpdate ? "Preparing…" : isWorking ? "Checking…" : "Check Now",
            target: self, action: #selector(checkNow)
        )
        checkButton.isEnabled = !isWorking
        checkButton.setAccessibilityIdentifier("settings.general.agent-tools.check")
        var rows = [SettingsUI.row(
            title: "Agent tools",
            subtitle: "Installed versions, updates and installation guides.",
            help: SettingsUI.help(
                "Agent tools",
                "Checks the tools on your login shell’s PATH and their official release sources. "
                    + "You can check here even when automatic updates are off.",
                "New models may require a newer agent tool. Updates run in a visible terminal "
                    + "when you choose Update. Restart the agent in your chat after updating; "
                    + "already running agents keep their old version. Package-manager installs "
                    + "may need their package manager’s update command; see Installation Guide."
            ),
            control: checkButton
        )]
        if let report {
            rows += AgentKind.allCases.map { toolRow($0, report: report) }
            if let claude = report.installed.first(where: { $0.id == AgentKind.claude.rawValue }) {
                let requirements = AgentCLIModelRequirement.unmet(by: claude.version)
                let detail = requirements.isEmpty
                    ? L10n.string("Model availability also depends on your account and provider.")
                    : L10n.format("Newer Claude Code versions are required for %@.",
                                  requirements.map(\.model).joined(separator: ", "))
                let minimums = AgentCLIModelRequirement.claude.map {
                    L10n.format("%@ requires Claude Code %@ or later", $0.model, $0.minimumVersion)
                }.joined(separator: "\n")
                rows.append(SettingsUI.row(
                    title: L10n.string("Model support"), subtitle: detail,
                    help: HelpTopic(title: L10n.string("Model support"), paragraphs: [
                        minimums, L10n.string("Model availability also depends on your account and provider.")
                    ]),
                    control: SettingsUI.button("Model Requirements", target: self,
                                               action: #selector(openModelRequirements)),
                    localizes: false
                ))
            }
        }
        if actionFailure {
            rows.append(SettingsUI.fullRow(SettingsUI.note(
                "Threading couldn’t open the update terminal. Use the Installation Guide to update."
            )))
        }
        card?.removeFromSuperview()
        let replacement = SettingsCard(rows: rows)
        replacement.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(replacement)
        NSLayoutConstraint.activate([
            replacement.topAnchor.constraint(equalTo: view.topAnchor),
            replacement.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            replacement.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            replacement.trailingAnchor.constraint(equalTo: view.trailingAnchor)
        ])
        card = replacement
    }

    private func toolRow(_ kind: AgentKind, report: AgentCLIUpdateReport) -> NSView {
        let installed = report.installed.first { $0.id == kind.rawValue }
        let update = report.updates.first { $0.id == kind.rawValue }
        let failure = report.failures.first { $0.toolID == kind.rawValue }
        let detail: String
        if failure != nil {
            detail = installed.map {
                L10n.format("Installed %@ · Couldn’t check for updates", $0.version)
            } ?? L10n.string("Couldn’t read the installed version")
        } else if let update {
            detail = L10n.format("Installed %@ · Latest %@", update.installedVersion, update.latestVersion)
        } else if let installed {
            detail = L10n.format("Installed %@ · Up to date", installed.version)
        } else {
            detail = L10n.string("Not found on your login shell’s PATH")
        }

        let guide = SettingsUI.button("Installation Guide", target: self, action: #selector(openGuide(_:)))
        guide.identifier = NSUserInterfaceItemIdentifier(kind.rawValue)
        guide.setAccessibilityIdentifier("settings.general.agent-tools.\(kind.rawValue).guide")
        var controls: [NSView] = [guide]
        if update != nil {
            let button = SettingsUI.button("Update", target: self, action: #selector(updateTool(_:)))
            button.identifier = NSUserInterfaceItemIdentifier(kind.rawValue)
            button.setAccessibilityIdentifier("settings.general.agent-tools.\(kind.rawValue).update")
            button.isEnabled = !isWorking
            controls.append(button)
        }
        let help = installed?.executablePath.map { path in
            HelpTopic(title: kind.displayName, paragraphs: [
                L10n.format("Executable used for new sessions: %@", path),
                L10n.string("Restart the agent in your chat after updating. Already running agents keep their old version.")
            ])
        }
        return SettingsUI.row(title: kind.displayName, subtitle: detail, help: help,
                              control: SettingsUI.controlGroup(controls), localizes: false)
    }

    @objc private func openGuide(_ sender: ThemedButton) {
        guard let identifier = sender.identifier, let kind = AgentKind(rawValue: identifier.rawValue) else { return }
        openURL(kind.cliInstallationGuide)
    }

    @objc private func openModelRequirements() {
        openURL(AgentCLIModelRequirement.claudeDocumentation)
    }

    @objc private func updateTool(_ sender: ThemedButton) {
        guard task == nil, let identifier = sender.identifier,
              let update = report?.updates.first(where: { $0.id == identifier.rawValue }) else { return }
        isWorking = true
        isPreparingUpdate = true
        render()
        let shell = AgentLauncher.loginShellPath
        let prepare = self.prepare
        task = Task { [weak self] in
            let plan = await prepare([update], shell)
            guard !Task.isCancelled, let self else { return }
            task = nil
            isWorking = false
            isPreparingUpdate = false
            actionFailure = runUpdates?(plan) != true
            render()
        }
    }
}
