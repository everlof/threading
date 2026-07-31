import AppKit
import ThreadingExtensionKit

/// Installed extension packages, their desired enablement, and their supervised runtime state.
final class ExtensionsPreferencesViewController: NSViewController {
    private enum Action {
        case toggle
        case reload
        case update
        case reveal
        case remove
    }

    private struct ControlAction {
        let action: Action
        let identifier: String
    }

    private enum IdentityFamily {
        case provider
        case account
        case session
    }

    private let manager: ExtensionManager
    private let identityRegistry: ExtensionIdentityResolverRegistry
    private let componentRegistry: ComponentCustomizationRegistry?
    private let appEvents = AppEventObservations()
    private var pageView: NSView?
    private var controlActions: [ObjectIdentifier: ControlAction] = [:]
    private var identityMenus: [ObjectIdentifier: IdentityFamily] = [:]
    private var isImporting = false

    init(
        manager: ExtensionManager? = nil,
        identityRegistry: ExtensionIdentityResolverRegistry? = nil,
        componentRegistry: ComponentCustomizationRegistry? = nil
    ) {
        self.manager = manager ?? .shared
        self.identityRegistry = identityRegistry ?? .shared
        self.componentRegistry = componentRegistry
            ?? ComponentCustomizationProviderSlot.shared.provider
                as? ComponentCustomizationRegistry
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func loadView() {
        view = NSView()
        render()
        appEvents.observe(ExtensionsDidChange.self) { [weak self] _ in
            self?.render()
        }
        appEvents.observe(ExtensionIdentityResolversDidChange.self) { [weak self] _ in
            self?.render()
        }
        appEvents.observe(ComponentCustomizationDidChange.self) { [weak self] event in
            guard event.targets == nil || event.targets?.contains(where: {
                $0.component == .sidebarSessionIdentity
            }) == true else { return }
            self?.render()
        }
    }

    private func render() {
        guard isViewLoaded else { return }
        pageView?.removeFromSuperview()
        controlActions.removeAll()
        identityMenus.removeAll()

        let importButton = SettingsUI.button(
            isImporting ? "Importing…" : "Import…",
            target: self,
            action: #selector(importExtension)
        )
        importButton.isEnabled = !isImporting
        importButton.setAccessibilityIdentifier("settings.extensions.import")

        var sections: [NSView] = [
            SettingsUI.heading("Extensions"),
            SettingsUI.note(
                "Extensions are copied into Threading before they can run. Importing leaves one "
                    + "disabled; enabling it starts a supervised process with the capabilities "
                    + "declared in its manifest."
            ),
            SettingsUI.section(
                "Install",
                SettingsCard(rows: [
                    SettingsUI.row(
                        title: "Extension package",
                        subtitle: "Choose a .threadingextension package or an unpacked development directory.",
                        control: importButton
                    )
                ])
            )
        ]

        if let identitySection = identityResolverSection() {
            sections.append(identitySection)
        }

        if let problem = manager.inventoryErrorDescription {
            sections.append(
                SettingsUI.section(
                    "Installed",
                    SettingsCard(rows: [
                        SettingsUI.row(
                            title: "Extensions could not be read",
                            subtitle: problem
                        )
                    ])
                )
            )
        }

        let installed = manager.installedExtensions
        if installed.isEmpty, manager.inventoryErrorDescription == nil {
            sections.append(
                SettingsUI.section(
                    "Installed",
                    SettingsCard(rows: [
                        SettingsUI.row(
                            title: "No extensions installed",
                            subtitle: "Imported packages appear here with their permissions and runtime state."
                        )
                    ])
                )
            )
        } else {
            sections.append(contentsOf: installed.map(extensionSection))
        }

        let page = SettingsUI.page(sections, hostPage: .extensions)
        page.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(page)
        NSLayoutConstraint.activate([
            page.topAnchor.constraint(equalTo: view.topAnchor),
            page.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            page.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            page.trailingAnchor.constraint(equalTo: view.trailingAnchor)
        ])
        pageView = page
    }

    private func identityResolverSection() -> NSView? {
        let providerCandidates = identityRegistry.providerCandidates()
        let accountCandidates = identityRegistry.accountCandidates()
        let sessionCandidates = componentRegistry?.replacementCandidates(
            for: .sidebarSessionIdentity
        ) ?? []
        guard providerCandidates.count > 1
                || accountCandidates.count > 1
                || sessionCandidates.count > 1 else {
            return nil
        }

        var rows: [NSView] = []
        if providerCandidates.count > 1 {
            rows.append(SettingsUI.row(
                title: "Provider icons",
                subtitle: "Choose which extension replaces agent provider marks.",
                control: identityMenu(
                    candidates: providerCandidates,
                    selected: identityRegistry.selectedProviderExtensionIdentifier,
                    family: .provider
                )
            ))
        }
        if accountCandidates.count > 1 {
            rows.append(SettingsUI.row(
                title: "Account icons",
                subtitle: "User-selected account images always remain above this resolver.",
                control: identityMenu(
                    candidates: accountCandidates,
                    selected: identityRegistry.selectedAccountExtensionIdentifier,
                    family: .account
                )
            ))
        }
        if sessionCandidates.count > 1 {
            rows.append(SettingsUI.row(
                title: "Session identity",
                subtitle: "Choose which extension composes the resolved provider and account images.",
                control: identityMenu(
                    candidates: sessionCandidates,
                    selected: componentRegistry?
                        .selectedReplacementExtensionIdentifier(
                            for: .sidebarSessionIdentity
                        ),
                    family: .session
                )
            ))
        }
        return SettingsUI.section("Identity rendering", SettingsCard(rows: rows))
    }

    private func identityMenu(
        candidates: [String],
        selected: String?,
        family: IdentityFamily
    ) -> ThemedPopUp {
        let names = Dictionary(
            uniqueKeysWithValues: manager.installedExtensions.map {
                ($0.identifier, $0.name)
            }
        )
        let menu = SettingsUI.popUp(
            target: self,
            action: #selector(identityResolverChanged(_:))
        )
        menu.addItem(ThemedMenuItem(title: L10n.string("No extension"), representedValue: ""))
        for identifier in candidates {
            menu.addItem(ThemedMenuItem(
                title: names[identifier] ?? identifier,
                representedValue: identifier
            ))
        }
        if let selected,
           let selectedIndex = (0..<menu.numberOfItems).first(where: {
               menu.item(at: $0)?.representedValue as? String == selected
           }) {
            menu.selectItem(at: selectedIndex)
        } else {
            menu.selectItem(at: 0)
        }
        menu.setAccessibilityIdentifier(
            family == .provider
                ? "settings.extensions.identity.provider"
                : family == .account
                    ? "settings.extensions.identity.account"
                    : "settings.extensions.identity.session"
        )
        identityMenus[ObjectIdentifier(menu)] = family
        return menu
    }

    @objc private func identityResolverChanged(_ sender: ThemedPopUp) {
        guard let family = identityMenus[ObjectIdentifier(sender)] else { return }
        let value = sender.selectedItem?.representedValue as? String
        let identifier = value.flatMap { $0.isEmpty ? nil : $0 }
        switch family {
        case .provider:
            identityRegistry.selectProviderExtension(identifier)
        case .account:
            identityRegistry.selectAccountExtension(identifier)
        case .session:
            componentRegistry?.selectReplacementExtension(
                identifier,
                for: .sidebarSessionIdentity
            )
        }
    }

    private func extensionSection(_ item: InstalledExtensionSnapshot) -> NSView {
        let toggle = SettingsUI.toggle(
            isOn: item.isEnabled,
            target: self,
            action: #selector(extensionToggled(_:))
        )
        toggle.isEnabled = {
            if case .updating = item.status { return false }
            if case .invalid = item.status { return item.isEnabled }
            return true
        }()
        toggle.setAccessibilityIdentifier("settings.extensions.enabled.\(item.identifier)")
        remember(toggle, action: .toggle, identifier: item.identifier)

        let version = item.version.map {
            L10n.format("Version %@ · %@", $0, item.identifier)
        }
            ?? item.identifier

        var rows: [NSView] = [
            SettingsUI.row(
                title: "Enabled",
                subtitle: version,
                control: toggle
            ),
            SettingsUI.row(
                title: "Type",
                subtitle: localizedName(item.profile)
            ),
            statusRow(item.status)
        ]
        rows.append(
            SettingsUI.row(
                title: "Package",
                subtitle: item.provenance?.presentation
                    ?? L10n.string("Origin not recorded · containment still enforced")
            )
        )

        if !item.contributionKinds.isEmpty {
            rows.append(
                SettingsUI.row(
                    title: "Provides",
                    subtitle: item.contributionKinds
                        .map(localizedName)
                        .joined(separator: ", ")
                )
            )
        }
        if !item.services.isEmpty {
            rows.append(
                SettingsUI.row(
                    title: "Provides services",
                    subtitle: item.services
                        .sorted {
                            ($0.title, $0.version) < ($1.title, $1.version)
                        }
                        .map { "\($0.title) v\($0.version)" }
                        .joined(separator: ", ")
                )
            )
        }
        if !item.serviceDependencies.isEmpty {
            let names = Dictionary(
                uniqueKeysWithValues: manager.installedExtensions.map {
                    ($0.identifier, $0.name)
                }
            )
            rows.append(
                SettingsUI.row(
                    title: "Uses services",
                    subtitle: item.serviceDependencies
                        .sorted {
                            ($0.providerIdentifier, $0.serviceID, $0.version)
                                < ($1.providerIdentifier, $1.serviceID, $1.version)
                        }
                        .map { dependency in
                            let provider = names[dependency.providerIdentifier]
                                ?? dependency.providerIdentifier
                            let availability = manager.isServiceAvailable(dependency)
                                ? L10n.string("available")
                                : dependency.required
                                    ? L10n.string("required · unavailable")
                                    : L10n.string("unavailable")
                            return "\(provider) / \(dependency.serviceID) v\(dependency.version) · \(availability)"
                        }
                        .joined(separator: "\n")
                )
            )
        }
        if !item.capabilities.isEmpty {
            rows.append(
                SettingsUI.row(
                    title: "Declared capabilities",
                    subtitle: item.capabilities.joined(separator: ", ")
                )
            )
        }
        if !item.companions.isEmpty {
            rows.append(
                SettingsUI.row(
                    title: "Advanced companions",
                    subtitle: item.companions.map { companion in
                        let activation = companion.activation == .onDemand
                            ? L10n.string("on demand")
                            : L10n.string("while enabled")
                        let capabilities = companion.capabilities.isEmpty
                            ? L10n.string("no OS-facing capabilities")
                            : companion.capabilities
                                .map(\.rawValue)
                                .sorted()
                                .joined(separator: ", ")
                        let status = item.companionStatuses[companion.id]?.summary
                            ?? L10n.string("unknown")
                        let operations = companion.operations.isEmpty
                            ? L10n.string("no operations")
                            : companion.operations.map(\.id).sorted().joined(separator: ", ")
                        let surfaces = companion.surfaces.isEmpty
                            ? L10n.string("no surfaces")
                            : companion.surfaces.map(\.id).sorted().joined(separator: ", ")
                        return "\(companion.id) · \(activation) · \(status) · "
                            + "\(capabilities) · \(operations) · \(surfaces)"
                    }
                    .joined(separator: "\n")
                )
            )
        }
        rows.append(SettingsUI.fullRow(actionRow(for: item)))

        return SettingsUI.section(item.name, SettingsCard(rows: rows))
    }

    private func localizedName(_ profile: ExtensionProfile) -> String {
        switch profile {
        case .runtime: L10n.string("Runtime extension")
        case .command: L10n.string("Command extension")
        case .panel: L10n.string("Panel extension")
        case .agentTool: L10n.string("Agent-tool extension")
        case .settings: L10n.string("Settings extension")
        case .service: L10n.string("Service extension")
        case .component: L10n.string("Component extension")
        case .hybrid: L10n.string("Hybrid extension")
        }
    }

    private func localizedName(_ kind: ExtensionContributionKind) -> String {
        switch kind {
        case .commands: L10n.string("Commands")
        case .panels: L10n.string("Panels")
        case .agentTools: L10n.string("Agent tools")
        case .settings: L10n.string("Settings")
        case .services: L10n.string("Services")
        case .componentCustomization: L10n.string("Component customization")
        case .providerIcons: L10n.string("Provider icons")
        case .accountIcons: L10n.string("Account icons")
        case .sessionIdentity: L10n.string("Session identity")
        }
    }

    private func statusRow(_ status: InstalledExtensionStatus) -> NSView {
        let value = NSTextField(wrappingLabelWithString: status.summary)
        value.applyFont(.subheading)
        switch status {
        case .running:
            value.textColor = Design.Status.positive
        case .failed, .invalid:
            value.textColor = Design.Status.negative
        case .starting, .updating:
            value.textColor = Design.Status.warning
        case .disabled:
            value.textColor = Design.Text.secondary
        }
        value.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let title = NSTextField(labelWithString: L10n.string("Status"))
        title.applyFont(.body)
        title.textColor = Design.Text.label
        title.setContentHuggingPriority(.required, for: .horizontal)

        let row = NSStackView(views: [title, value])
        row.orientation = .horizontal
        row.alignment = .firstBaseline
        row.spacing = Design.Spacing.medium
        return SettingsUI.fullRow(row)
    }

    private func actionRow(for item: InstalledExtensionSnapshot) -> NSView {
        let isUpdating = item.status == .updating
        let reload = SettingsUI.button("Reload", target: self, action: #selector(reloadExtension(_:)))
        reload.isEnabled = item.isEnabled && !isUpdating
        reload.setAccessibilityIdentifier("settings.extensions.reload.\(item.identifier)")
        remember(reload, action: .reload, identifier: item.identifier)

        let update = SettingsUI.button("Update…", target: self, action: #selector(updateExtension(_:)))
        update.isEnabled = !isUpdating
        update.setAccessibilityIdentifier("settings.extensions.update.\(item.identifier)")
        remember(update, action: .update, identifier: item.identifier)

        let reveal = SettingsUI.button("Reveal", target: self, action: #selector(revealExtension(_:)))
        reveal.setAccessibilityIdentifier("settings.extensions.reveal.\(item.identifier)")
        remember(reveal, action: .reveal, identifier: item.identifier)

        let remove = SettingsUI.button("Remove…", target: self, action: #selector(removeExtension(_:)))
        remove.isEnabled = !isUpdating
        remove.setAccessibilityIdentifier("settings.extensions.remove.\(item.identifier)")
        remember(remove, action: .remove, identifier: item.identifier)

        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let row = NSStackView(views: [spacer, reload, update, reveal, remove])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = Design.Spacing.small
        return row
    }

    private func remember(_ control: NSControl, action: Action, identifier: String) {
        controlActions[ObjectIdentifier(control)] = ControlAction(
            action: action,
            identifier: identifier
        )
    }

    private func identifier(for control: NSControl, action: Action) -> String? {
        guard let remembered = controlActions[ObjectIdentifier(control)],
              remembered.action == action else {
            return nil
        }
        return remembered.identifier
    }

    @objc private func importExtension() {
        guard let window = view.window else { return }

        let panel = NSOpenPanel()
        panel.title = L10n.string("Import Threading Extension")
        panel.message = L10n.string(
            "Choose a .threadingextension package or an unpacked extension directory."
        )
        panel.prompt = L10n.string("Import")
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false

        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let source = panel.url, let self else { return }
            self.isImporting = true
            self.render()
            self.reviewAndInstall(from: source)
        }
    }

    /// Reads the static package before copying it and makes the requested authority the decision.
    ///
    /// This is intentionally the same `ExtensionInstallProposal` used by the MCP authoring flow:
    /// an extension cannot receive a quieter install path merely because it came through a file
    /// picker instead of an agent proposal.
    private func reviewAndInstall(from source: URL) {
        DispatchQueue.global(qos: .userInitiated).async {
            let inspection = Result {
                try ExtensionBundleInspector.inspect(at: source)
            }
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                switch inspection {
                case .failure(let error):
                    self.isImporting = false
                    self.render()
                    self.present(error: error)
                case .success(let bundle):
                    self.presentInstallProposal(
                        ExtensionInstallProposal(bundle: bundle),
                        source: source
                    )
                }
            }
        }
    }

    private func presentInstallProposal(
        _ proposal: ExtensionInstallProposal,
        source: URL
    ) {
        let request = ConfirmationRequest(
            prompt: .installUnsignedExtension,
            title: proposal.title,
            message: proposal.message,
            confirmTitle: proposal.acceptTitle,
            style: .informational
        )

        ConfirmationAlert.ask(request, in: view.window) { [weak self] approved in
            guard let self else { return }
            guard approved else {
                self.isImporting = false
                self.render()
                return
            }
            self.manager.install(from: source) { [weak self] result in
                guard let self else { return }
                self.isImporting = false
                self.render()
                switch result {
                case .success(let installed):
                    self.presentAlert(
                        title: L10n.string("Extension Installed"),
                        message: L10n.format(
                            "“%@” was copied into Threading and is disabled until you enable it.",
                            installed.name
                        )
                    )
                case .failure(let error):
                    self.present(error: error)
                }
            }
        }
    }

    @objc private func extensionToggled(_ sender: ThemedToggle) {
        guard let identifier = identifier(for: sender, action: .toggle) else { return }
        do {
            try manager.setEnabled(sender.state == .on, identifier: identifier)
        } catch {
            sender.state = sender.state == .on ? .off : .on
            present(error: error)
        }
    }

    @objc private func reloadExtension(_ sender: ThemedButton) {
        guard let identifier = identifier(for: sender, action: .reload) else { return }
        manager.reload(identifier: identifier)
    }

    /// Replaces an installed extension, showing what changes before anything is replaced.
    ///
    /// The plan is computed from the chosen source and put to the user *before* the update
    /// runs, because the capability delta is the whole point: an extension approved last month
    /// as a panel may now want `network.client` and `storage.secrets`. Approving passes the
    /// plan back to the manager, which re-checks that it still holds — so a source that changes
    /// between this sheet and the replacement is refused rather than silently granted.
    @objc private func updateExtension(_ sender: ThemedButton) {
        guard let identifier = identifier(for: sender, action: .update),
              let item = manager.installedExtensions.first(where: {
                  $0.identifier == identifier
              }),
              let window = view.window else {
            return
        }

        let panel = NSOpenPanel()
        panel.title = L10n.string("Update Threading Extension")
        panel.message = L10n.format("Choose the new version of “%@”.", item.name)
        panel.prompt = L10n.string("Choose")
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false

        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let source = panel.url, let self else { return }
            self.manager.updatePlan(from: source) { [weak self] result in
                guard let self else { return }
                switch result {
                case .failure(let error):
                    self.present(error: error)
                case .success(let plan):
                    guard plan.identifier == identifier else {
                        self.presentAlert(
                            title: L10n.string("Different Extension"),
                            message: L10n.format(
                                "That package is “%@”, not “%@”. Import it separately instead "
                                    + "of updating this one.",
                                plan.identifier,
                                identifier
                            )
                        )
                        return
                    }
                    self.confirmAndApply(plan, name: item.name, source: source)
                }
            }
        }
    }

    private func confirmAndApply(
        _ plan: ExtensionUpdatePlan,
        name: String,
        source: URL
    ) {
        let confirmation = plan.confirmation(name: name)
        let request = ConfirmationRequest(
            prompt: .updateExtensionCapabilities,
            title: confirmation.title,
            message: confirmation.message,
            confirmTitle: confirmation.acceptTitle,
            style: plan.requiresApproval ? .warning : .informational
        )
        guard ConfirmationAlert.ask(request) else { return }

        manager.update(from: source, approving: plan) { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let updated):
                self.presentAlert(
                    title: L10n.string("Extension Updated"),
                    message: L10n.format(
                        "“%@” is now version %@.",
                        updated.name,
                        plan.candidateVersion
                    )
                )
            case .failure(let error):
                self.present(error: error)
            }
        }
    }

    @objc private func revealExtension(_ sender: ThemedButton) {
        guard let identifier = identifier(for: sender, action: .reveal),
              let item = manager.installedExtensions.first(where: {
                  $0.identifier == identifier
              }) else {
            return
        }
        NSWorkspace.shared.activateFileViewerSelecting([item.packageURL])
    }

    @objc private func removeExtension(_ sender: ThemedButton) {
        guard let identifier = identifier(for: sender, action: .remove),
              let item = manager.installedExtensions.first(where: {
                  $0.identifier == identifier
              }) else {
            return
        }

        let request = ConfirmationRequest(
            prompt: .removeExtension,
            title: L10n.format("Remove “%@”?", item.name),
            message: L10n.string(
                "Its process will stop. The package, settings, key-value data, cache, and "
                    + "provenance move to Threading’s recoverable Removed directory. Keychain "
                    + "secrets remain under the extension identifier for an intentional reinstall; "
                    + "remove them from the extension before uninstalling if they should not be retained."
            ),
            confirmTitle: L10n.string("Remove")
        )
        guard ConfirmationAlert.ask(request) else { return }

        do {
            let recoveredAt = try manager.uninstall(identifier: identifier)
            presentAlert(
                title: L10n.string("Extension Removed"),
                message: L10n.format(
                    "The package was moved to %@ and can be recovered from there.",
                    recoveredAt.path
                )
            )
        } catch {
            present(error: error)
        }
    }

    private func present(error: Error) {
        let alert = NSAlert(error: error)
        if let window = view.window {
            alert.beginSheetModal(for: window)
        } else {
            alert.runModal()
        }
    }

    private func presentAlert(title: String, message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        if let window = view.window {
            alert.beginSheetModal(for: window)
        } else {
            alert.runModal()
        }
    }
}
