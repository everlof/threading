import AppKit

/// An on-demand check, retained with General Settings. The fixed runtime inventory bounds both
/// work and views; no accounts, sessions or transcripts are scanned to populate these rows.
@MainActor
final class AgentCLISettingsViewController: NSViewController {
    typealias Check = @Sendable () async -> AgentCLIUpdateReport
    typealias Prepare = @Sendable ([AgentCLIUpdate], String) async -> AgentCLIUpdateExecutionPlan
    var runUpdates: (@MainActor (AgentCLIUpdateExecutionPlan) -> Bool)?

    private let runtimes: ManagedAgentRuntimeStore?
    private var menuSession: AnyObject?
    private var managedFailure: String?
    private let check: Check
    private let prepare: Prepare
    private let openURL: @MainActor (URL) -> Void
    private var task: Task<Void, Never>?
    private var report: AgentCLIUpdateReport?
    private var isWorking = false
    private var isPreparingUpdate = false
    private var actionFailure = false
    private var card: SettingsCard?

    init(check: Check? = nil, runtimes: ManagedAgentRuntimeStore? = AgentLocalLaunch.store, prepare: @escaping Prepare = { updates, shell in
        await AgentCLIUpdateExecutionPlan.prepare(updates: updates, shell: shell)
    }, openURL: @escaping @MainActor (URL) -> Void = {
        NSWorkspace.shared.open($0)
    }) {
        let checker = AgentCLIUpdateChecker.live(shell: AgentLauncher.loginShellPath)
        self.check = check ?? { await checker.check() }
        self.runtimes = runtimes
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
            subtitle: "Managed installations, selected versions and updates.",
            help: SettingsUI.help(
                "Agent tools",
                "Threading installs verified client releases in its own folder. Account logins and conversations stay in their existing locations.",
                "Managed updates use the release tested with this app. Running agents keep their version. Choose Options to use your own executable or restore the previous installation."
            ),
            control: checkButton
        )]
        if let runtimes {
            rows += AgentKind.allCases.map { managedToolRow($0, store: runtimes) }
        }
        if let report {
            if runtimes == nil { rows += AgentKind.allCases.map { toolRow($0, report: report) } }
            if let claude = report.installed.first(where: { $0.id == AgentKind.claude.rawValue }) {
                let selected = runtimes?.selection(for: .claude)
                let version = selected?.managed == true ? selected?.version ?? claude.version : claude.version
                let requirements = AgentCLIModelRequirement.unmet(by: version)
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
        if let managedFailure {
            rows.append(SettingsUI.fullRow(SettingsUI.note(managedFailure, localizes: false)))
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

    private func managedToolRow(_ kind: AgentKind, store: ManagedAgentRuntimeStore) -> NSView {
        let selected = store.selection(for: kind)
        let release = ManagedAgentCatalog.release(for: kind)
        var detail: String
        if selected.managed {
            detail = selected.version.map { L10n.format("Managed by Threading · %@", $0) }
                ?? L10n.string("Managed by Threading · Not installed")
        } else {
            detail = L10n.format("Your installation · %@", selected.executable)
        }
        if let report, report.failures.contains(where: { $0.toolID == kind.rawValue && $0.stage == .installedVersion }) {
            detail += " · " + L10n.string("Couldn’t run the selected client")
        } else if let report, (selected.version != nil || !selected.managed),
                  !report.installed.contains(where: { $0.id == kind.rawValue }),
                  !report.failures.contains(where: { $0.toolID == kind.rawValue }) {
            detail += " · " + L10n.string("Selected executable is missing")
        }
        let externalUpdate = !selected.managed && report?.updates.contains(where: { $0.id == kind.rawValue }) == true
        let install = SettingsUI.button(externalUpdate ? "Update" : !selected.managed ? "Install Managed…"
            : selected.version == nil ? "Install…"
            : selected.managed && selected.version != release.version ? "Update" : "Reinstall…",
            target: self, action: externalUpdate ? #selector(updateTool(_:)) : #selector(installTool(_:)))
        install.identifier = NSUserInterfaceItemIdentifier(kind.rawValue)
        install.setAccessibilityIdentifier("settings.general.agent-tools.\(kind.rawValue).install")
        install.isEnabled = !isWorking
        let options = SettingsUI.button("Options…", target: self, action: #selector(managedOptions(_:)))
        options.identifier = install.identifier
        options.setAccessibilityIdentifier("settings.general.agent-tools.\(kind.rawValue).options")
        options.isEnabled = !isWorking
        let help = HelpTopic(title: kind.displayName, paragraphs: [
            L10n.format("Executable used for new sessions: %@", selected.executable),
            L10n.format("Tested release: %@", release.version)
        ])
        return SettingsUI.row(title: kind.displayName, subtitle: store.failure(for: kind) ?? detail,
                              help: help, control: SettingsUI.controlGroup([install, options]), localizes: false)
    }

    @objc private func managedOptions(_ sender: ThemedButton) {
        guard let value = sender.identifier?.rawValue, let kind = AgentKind(rawValue: value),
              let runtimes else { return }
        var entries: [ThemedMenuEntry] = [.item(ThemedMenuItem(
            title: L10n.string("Use My Installation…"), onChoose: { [weak self] in self?.chooseExternal(kind) }
        ))]
        if !runtimes.isManaged(kind) {
            entries.append(.item(ThemedMenuItem(title: L10n.string("Install Managed…"), onChoose: { [weak self] in
                self?.installManaged(kind)
            })))
        }
        if !runtimes.isManaged(kind), runtimes.receipt(for: kind) != nil {
            entries.append(.item(ThemedMenuItem(title: L10n.string("Use Managed Installation"), onChoose: { [weak self] in
                runtimes.selectExternal(nil, for: kind)
                AgentCLIAvailability.shared.refresh()
                self?.render()
            })))
        }
        if runtimes.receipt(for: kind)?.previous != nil {
            entries.append(.item(ThemedMenuItem(title: L10n.string("Restore Previous Version"), onChoose: { [weak self] in
                self?.rollback(kind)
            })))
        }
        if runtimes.receipt(for: kind) != nil {
            entries.append(.item(ThemedMenuItem(title: L10n.string("Show Installation Folder"), onChoose: { [weak self] in
                self?.openURL(runtimes.providerRoot(kind))
            })))
        }
        entries.append(.item(ThemedMenuItem(title: L10n.string("Installation Guide"), onChoose: { [weak self] in
            self?.openURL(kind.cliInstallationGuide)
        })))
        menuSession = ThemedMenuPresenter.present(ThemedMenuPresentation(entries: entries, minimumWidth: 260), from: sender,
            selectedEntryIndex: nil, onChoose: { _, item in item.onChoose?() },
            onDismiss: { [weak self] in self?.menuSession = nil })
    }

    private func chooseExternal(_ kind: AgentKind) {
        guard let runtimes else { return }
        AgentExecutablePicker.choose { [weak self] url in
            guard let self, let url else { return }
            isWorking = true
            managedFailure = nil
            render()
            task = Task { [weak self] in
                do {
                    try await Task.detached(priority: .utility) {
                        try ManagedAgentInstaller.verifyExecutable(url, version: nil, kind: kind,
                                                                    path: runtimes.effectivePATH, managed: false)
                        runtimes.selectExternal(url.path, for: kind)
                    }.value
                    AgentCLIAvailability.shared.refresh()
                } catch { self?.managedFailure = error.localizedDescription }
                self?.task = nil
                self?.isWorking = false
                self?.render()
            }
        }
    }

    private func rollback(_ kind: AgentKind) {
        guard let runtimes, task == nil else { return }
        isWorking = true
        managedFailure = nil
        render()
        task = Task { [weak self] in
            do {
                try await ManagedAgentInstaller(store: runtimes).rollback(kind)
                AgentCLIAvailability.shared.refresh()
            } catch { self?.managedFailure = error.localizedDescription }
            self?.task = nil
            self?.isWorking = false
            self?.render()
        }
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
        if installed == nil, failure == nil {
            // The same sheet onboarding and the launch-failure screen open: the official
            // installer, run on this click in a terminal the person can watch.
            let install = SettingsUI.button("Install…", target: self, action: #selector(installTool(_:)))
            install.identifier = NSUserInterfaceItemIdentifier(kind.rawValue)
            install.setAccessibilityIdentifier("settings.general.agent-tools.\(kind.rawValue).install")
            install.isEnabled = !isWorking
            controls.append(install)
        }
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

    @objc private func installTool(_ sender: ThemedButton) {
        guard let identifier = sender.identifier, let kind = AgentKind(rawValue: identifier.rawValue) else { return }
        installManaged(kind)
    }

    private func installManaged(_ kind: AgentKind) {
        AgentCLIInstallViewController.present(kind, from: self) { [weak self] installed in
            guard installed else { return }
            self?.checkNow()
        }
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
