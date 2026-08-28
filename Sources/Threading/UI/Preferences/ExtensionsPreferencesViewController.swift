import AppKit
import ThreadingExtensionKit

/// Installed extension packages, their desired enablement, and their supervised runtime state.
///
/// Each package is a **collapsed card**: name, short runtime state and the enable switch on the
/// header, the manifest detail (type, provenance, contributions, services, capabilities,
/// companions) and the action row unfolding on demand. Fully unfolded, every extension was up
/// to ten rows — a page with four installed read as a wall in which the one decision per
/// extension, the switch, was somewhere in the middle.
final class ExtensionsPreferencesViewController: NSViewController {
    private enum Action {
        case toggle
        case reload
        case update
        case reveal
        case remove
        case installFirstParty
        case updateFirstParty
        case openFirstPartySource
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

    private enum PackageDetailRow {
        case type
        case status
        case packageOrigin
        case contributions
        case services
        case serviceDependencies
        case capabilities
        case companions
        case actions
    }

    /// Cheap ordering state for the whole page. Package snapshots and extension fields are values;
    /// AppKit creates controls only for rows intersecting the viewport.
    private enum PresentationRow {
        case note
        case firstPartyProblem
        case firstPartyCaption
        case firstPartyEntry(Int)
        case installedCaption
        case identityResolvers
        case inventoryProblem
        case emptyInventory
        case packageHeader(Int)
        case packageDetail(package: Int, detail: PackageDetailRow)
        case extensionCaption(Int)
        case extensionField(section: Int, field: Int)
    }

    private let manager: ExtensionManager
    private let firstPartyCatalog: FirstPartyExtensionCatalog
    private let identityRegistry: ExtensionIdentityResolverRegistry
    private let componentRegistry: ComponentCustomizationRegistry?
    private let appEvents = AppEventObservations()
    private var pageView: SettingsPageView?
    private var controlActions: [ObjectIdentifier: ControlAction] = [:]
    private var identityMenus: [ObjectIdentifier: IdentityFamily] = [:]
    private var isImporting = false
    private var firstPartyOperationIdentifier: String?
    private var firstPartyExtensions: [FirstPartyExtensionCatalog.Entry] = []
    private var installedExtensions: [InstalledExtensionSnapshot] = []
    private var installedNames: [String: String] = [:]
    private var inventoryProblem: String?
    private var providerCandidates: [String] = []
    private var accountCandidates: [String] = []
    private var sessionCandidates: [String] = []
    private var extensionSections: [ExtensionSettingsSectionModel] = []
    private var presentationRows: [PresentationRow] = []

    private lazy var importButton: ThemedButton = {
        let button = SettingsUI.button(
            "Import…",
            target: self,
            action: #selector(importExtension)
        )
        button.setAccessibilityIdentifier("settings.extensions.import")
        return button
    }()

    private lazy var tableView: ThemedGroupedTableView = {
        let table = ThemedGroupedTableView()
        let column = NSTableColumn(
            identifier: NSUserInterfaceItemIdentifier("ExtensionsSettingsContent")
        )
        column.resizingMask = .autoresizingMask
        table.addTableColumn(column)
        table.headerView = nil
        table.style = .plain
        table.selectionHighlightStyle = .none
        table.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        table.intercellSpacing = .zero
        table.rowHeight = ExtensionsPreferencesDefaults.estimatedRowHeight
        table.usesAutomaticRowHeights = true
        table.autoresizingMask = [.width]
        table.delegate = self
        table.dataSource = self
        return table
    }()

    private lazy var scrollView: ThemedScrollView = {
        let scroll = ThemedScrollView()
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.automaticallyAdjustsContentInsets = false
        scroll.documentView = tableView
        return scroll
    }()

    /// The packages whose manifest detail the user has unfolded, by identifier. A view state,
    /// kept for the session only.
    private var expandedExtensions: Set<String> = []

    init(
        manager: ExtensionManager? = nil,
        firstPartyCatalog: FirstPartyExtensionCatalog? = nil,
        identityRegistry: ExtensionIdentityResolverRegistry? = nil,
        componentRegistry: ComponentCustomizationRegistry? = nil
    ) {
        self.manager = manager ?? .shared
        self.firstPartyCatalog = firstPartyCatalog ?? .appOwned()
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
        appEvents.observe(ExtensionSettingsRegistryDidChange.self) { [weak self] _ in
            self?.render()
        }
        appEvents.observe(ComponentCustomizationDidChange.self) { [weak self] event in
            guard event.targets == nil || event.targets?.contains(where: {
                $0.component == .sidebarSessionIdentity
            }) == true else { return }
            self?.render()
        }
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        let width = tableView.tableColumns.first?.width ?? tableView.bounds.width
        tableView.enumerateAvailableRowViews { rowView, _ in
            for cell in rowView.subviews {
                (cell as? ThemedVirtualTableCell)?.setColumnWidth(width)
            }
        }
    }

    private func render() {
        guard isViewLoaded else { return }
        controlActions.removeAll()
        identityMenus.removeAll()
        installedExtensions = manager.installedExtensions
        firstPartyExtensions = firstPartyCatalog.entries
        installedNames = Dictionary(
            uniqueKeysWithValues: installedExtensions.map { ($0.identifier, $0.name) }
        )
        inventoryProblem = manager.inventoryErrorDescription
        providerCandidates = identityRegistry.providerCandidates()
        accountCandidates = identityRegistry.accountCandidates()
        sessionCandidates = componentRegistry?.replacementCandidates(
            for: .sidebarSessionIdentity
        ) ?? []
        extensionSections = ExtensionSettingsRenderer.hostSectionModels(for: .extensions)
        expandedExtensions.formIntersection(installedExtensions.map(\.identifier))
        presentationRows = makePresentationRows()
        updateCardDecorations()

        importButton.title = L10n.string(isImporting ? "Importing…" : "Import…")
        importButton.isEnabled = !isImporting && firstPartyOperationIdentifier == nil

        if let pageView {
            pageView.updateSummary(installedSummary(installedExtensions.count))
            tableView.reloadData()
            return
        }

        let page = SettingsUI.listPage(
            title: "Extensions",
            summary: installedSummary(installedExtensions.count),
            actions: [importButton],
            body: scrollView
        )
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

    private func makePresentationRows() -> [PresentationRow] {
        var rows: [PresentationRow] = [.note]
        if firstPartyCatalog.problem != nil {
            rows.append(.firstPartyProblem)
        }
        if !firstPartyExtensions.isEmpty {
            rows.append(.firstPartyCaption)
            rows.append(contentsOf: firstPartyExtensions.indices.map {
                .firstPartyEntry($0)
            })
        }
        if providerCandidates.count > 1
            || accountCandidates.count > 1
            || sessionCandidates.count > 1 {
            rows.append(.identityResolvers)
        }
        if inventoryProblem != nil {
            rows.append(.inventoryProblem)
        }
        if installedExtensions.isEmpty, inventoryProblem == nil {
            rows.append(.emptyInventory)
        } else {
            if !installedExtensions.isEmpty {
                rows.append(.installedCaption)
            }
            for (packageIndex, item) in installedExtensions.enumerated() {
                rows.append(.packageHeader(packageIndex))
                if expandedExtensions.contains(item.identifier) {
                    rows.append(contentsOf: packageDetailRows(for: item).map {
                        .packageDetail(package: packageIndex, detail: $0)
                    })
                }
            }
        }
        for (sectionIndex, section) in extensionSections.enumerated() {
            if section.visibleTitle != nil {
                rows.append(.extensionCaption(sectionIndex))
            }
            rows.append(contentsOf: section.fields.indices.map {
                .extensionField(section: sectionIndex, field: $0)
            })
        }
        return rows
    }

    private func identityResolverSection() -> NSView? {
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
        let menu = SettingsUI.popUp(
            target: self,
            action: #selector(identityResolverChanged(_:))
        )
        menu.addItem(ThemedMenuItem(title: L10n.string("No extension"), representedValue: ""))
        for identifier in candidates {
            menu.addItem(ThemedMenuItem(
                title: installedNames[identifier] ?? identifier,
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

    private func installedSummary(_ count: Int) -> String {
        switch count {
        case 0: L10n.string("No extensions installed")
        case 1: L10n.string("1 extension installed")
        default: L10n.format("%lld extensions installed", Int64(count))
        }
    }

    /// The one word the header states about a package's runtime, coloured the way the full
    /// status row colours its sentence; the sentence itself stays in the unfolded detail.
    private func shortStatus(_ status: InstalledExtensionStatus) -> (label: String, color: NSColor) {
        switch status {
        case .running: (L10n.string("Running"), Design.Status.positive)
        case .failed: (L10n.string("Failed"), Design.Status.negative)
        case .invalid: (L10n.string("Invalid"), Design.Status.negative)
        case .starting: (L10n.string("Starting"), Design.Status.warning)
        case .updating: (L10n.string("Updating"), Design.Status.warning)
        case .disabled: (L10n.string("Disabled"), Design.Text.secondary)
        }
    }

    private func extensionHeader(_ item: InstalledExtensionSnapshot) -> NSView {
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
        toggle.setAccessibilityLabel(item.name)
        remember(toggle, action: .toggle, identifier: item.identifier)

        let version = item.version.map {
            L10n.format("Version %@ · %@", $0, item.identifier)
        }
            ?? item.identifier

        let identifier = item.identifier
        let status = shortStatus(item.status)
        return SettingsUI.disclosureHeader(
            title: item.name,
            subtitle: version,
            summary: status.label,
            summaryColor: status.color,
            control: toggle,
            isExpanded: expandedExtensions.contains(identifier),
            localizes: false,
            accessibilityIdentifier: "settings.extensions.card.\(identifier)",
            onToggle: { [weak self] nowExpanded in
                self?.setExtension(identifier, expanded: nowExpanded)
            }
        )
    }

    private enum FirstPartyEntryState {
        case available
        case updateAvailable
        case installed
    }

    private func firstPartyState(
        for entry: FirstPartyExtensionCatalog.Entry
    ) -> FirstPartyEntryState {
        guard let installed = installedExtensions.first(where: {
            $0.identifier == entry.identifier
        }) else {
            return .available
        }
        guard let installedVersion = installed.version else { return .installed }
        return ExtensionVersion(entry.version).compared(to: ExtensionVersion(installedVersion))
            == .newer
            ? .updateAvailable
            : .installed
    }

    private func firstPartyRow(_ entry: FirstPartyExtensionCatalog.Entry) -> NSView {
        let source = SettingsUI.button(
            "Source",
            target: self,
            action: #selector(openFirstPartySource(_:))
        )
        source.setAccessibilityIdentifier(
            "settings.extensions.first-party.source.\(entry.identifier)"
        )
        remember(source, action: .openFirstPartySource, identifier: entry.identifier)

        let state = firstPartyState(for: entry)
        let operation = SettingsUI.button(
            state == .available
                ? "Install…"
                : state == .updateAvailable ? "Update…" : "Installed",
            target: self,
            action: state == .updateAvailable
                ? #selector(updateFirstPartyExtension(_:))
                : #selector(installFirstPartyExtension(_:))
        )
        let packageExists = FileManager.default.fileExists(atPath: entry.packageURL.path)
        operation.isEnabled = state != .installed
            && packageExists
            && firstPartyOperationIdentifier == nil
        if firstPartyOperationIdentifier == entry.identifier {
            operation.title = L10n.string(
                state == .updateAvailable ? "Updating…" : "Installing…"
            )
        }
        operation.setAccessibilityIdentifier(
            "settings.extensions.first-party."
                + "\(state == .updateAvailable ? "update" : "install").\(entry.identifier)"
        )
        remember(
            operation,
            action: state == .updateAvailable ? .updateFirstParty : .installFirstParty,
            identifier: entry.identifier
        )

        let versionLine: String
        if !packageExists {
            versionLine = L10n.format("Version %@ · Unavailable in this build", entry.version)
        } else {
            switch state {
            case .available:
                versionLine = L10n.format("Version %@ · Available from Threading", entry.version)
            case .updateAvailable:
                versionLine = L10n.format("Version %@ · Update available", entry.version)
            case .installed:
                versionLine = L10n.format("Version %@ · Installed", entry.version)
            }
        }
        return SettingsUI.row(
            title: entry.name,
            subtitle: entry.summary + "\n" + versionLine,
            control: SettingsUI.controlGroup(
                [source, operation],
                spacing: Design.Spacing.small
            ),
            localizes: false
        )
    }

    private func packageDetailRows(
        for item: InstalledExtensionSnapshot
    ) -> [PackageDetailRow] {
        var rows: [PackageDetailRow] = [.type, .status, .packageOrigin]
        if !item.contributionKinds.isEmpty { rows.append(.contributions) }
        if !item.services.isEmpty { rows.append(.services) }
        if !item.serviceDependencies.isEmpty { rows.append(.serviceDependencies) }
        if !item.capabilities.isEmpty { rows.append(.capabilities) }
        if !item.companions.isEmpty { rows.append(.companions) }
        rows.append(.actions)
        return rows
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
        case .navigator: L10n.string("Navigator extension")
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
        case .workspaceNavigation: L10n.string("Workspace navigator")
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
            || firstPartyOperationIdentifier == item.identifier
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

    private func firstPartyEntry(
        for control: NSControl,
        action: Action
    ) -> FirstPartyExtensionCatalog.Entry? {
        guard let identifier = identifier(for: control, action: action) else { return nil }
        return firstPartyExtensions.first { $0.identifier == identifier }
    }

    @objc private func openFirstPartySource(_ sender: ThemedButton) {
        guard let entry = firstPartyEntry(
            for: sender,
            action: .openFirstPartySource
        ) else { return }
        NSWorkspace.shared.open(entry.repositoryURL)
    }

    @objc private func installFirstPartyExtension(_ sender: ThemedButton) {
        guard !isImporting,
              firstPartyOperationIdentifier == nil,
              let entry = firstPartyEntry(for: sender, action: .installFirstParty) else {
            return
        }
        firstPartyOperationIdentifier = entry.identifier
        render()
        reviewAndInstall(
            from: entry.packageURL,
            installSource: entry.installSource,
            expectedEntry: entry
        )
    }

    @objc private func updateFirstPartyExtension(_ sender: ThemedButton) {
        guard !isImporting,
              firstPartyOperationIdentifier == nil,
              let entry = firstPartyEntry(for: sender, action: .updateFirstParty),
              let installed = installedExtensions.first(where: {
                  $0.identifier == entry.identifier
              }) else {
            return
        }
        firstPartyOperationIdentifier = entry.identifier
        render()
        manager.updatePlan(from: entry.packageURL) { [weak self] result in
            guard let self else { return }
            switch result {
            case .failure(let error):
                self.finishFirstPartyOperation()
                self.present(error: error)
            case .success(let plan):
                do {
                    try entry.validate(plan)
                } catch {
                    self.finishFirstPartyOperation()
                    self.present(error: error)
                    return
                }
                self.confirmAndApply(
                    plan,
                    name: installed.name,
                    source: entry.packageURL,
                    installSource: entry.installSource,
                    onFinish: { [weak self] in self?.finishFirstPartyOperation() }
                )
            }
        }
    }

    private func finishFirstPartyOperation() {
        firstPartyOperationIdentifier = nil
        render()
    }

    @objc private func importExtension() {
        guard firstPartyOperationIdentifier == nil, let window = view.window else { return }

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
    private func reviewAndInstall(
        from source: URL,
        installSource: ExtensionInstallSource = .localImport,
        expectedEntry: FirstPartyExtensionCatalog.Entry? = nil
    ) {
        DispatchQueue.global(qos: .userInitiated).async {
            let inspection = Result {
                let bundle = try ExtensionBundleInspector.inspect(at: source)
                try expectedEntry?.validate(bundle)
                return bundle
            }
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                switch inspection {
                case .failure(let error):
                    self.isImporting = false
                    if expectedEntry != nil {
                        self.firstPartyOperationIdentifier = nil
                    }
                    self.render()
                    self.present(error: error)
                case .success(let bundle):
                    self.presentInstallProposal(
                        ExtensionInstallProposal(bundle: bundle, source: installSource),
                        source: source,
                        installSource: installSource,
                        isFirstParty: expectedEntry != nil
                    )
                }
            }
        }
    }

    private func presentInstallProposal(
        _ proposal: ExtensionInstallProposal,
        source: URL,
        installSource: ExtensionInstallSource,
        isFirstParty: Bool
    ) {
        let request = ExtensionInstallConfirmation.request(
            for: proposal,
            prompt: .installUnsignedExtension
        )

        ConfirmationAlert.ask(request, in: view.window) { [weak self] approved in
            guard let self else { return }
            guard approved else {
                self.isImporting = false
                if isFirstParty {
                    self.firstPartyOperationIdentifier = nil
                }
                self.render()
                return
            }
            self.manager.install(from: source, source: installSource) { [weak self] result in
                guard let self else { return }
                self.isImporting = false
                if isFirstParty {
                    self.firstPartyOperationIdentifier = nil
                }
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
        source: URL,
        installSource: ExtensionInstallSource = .localImport,
        onFinish: (@MainActor @Sendable () -> Void)? = nil
    ) {
        let confirmation = plan.confirmation(name: name)
        let request = ConfirmationRequest(
            prompt: .updateExtensionCapabilities,
            title: confirmation.title,
            message: confirmation.message,
            confirmTitle: confirmation.acceptTitle,
            style: plan.requiresApproval ? .warning : .informational
        )
        guard ConfirmationAlert.ask(request) else {
            onFinish?()
            return
        }

        manager.update(
            from: source,
            approving: plan,
            source: installSource
        ) { [weak self] result in
            guard let self else { return }
            onFinish?()
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
        let alert = ThemedAlert(error: error)
        if let window = view.window {
            alert.beginSheetModal(for: window)
        } else {
            alert.runModal()
        }
    }

    private func presentAlert(title: String, message: String) {
        let alert = ThemedAlert()
        alert.messageText = title
        alert.informativeText = message
        if let window = view.window {
            alert.beginSheetModal(for: window)
        } else {
            alert.runModal()
        }
    }

    /// Stress-fixture observability: the cheap complete model versus the live AppKit viewport.
    var virtualRowCountForTesting: Int { presentationRows.count }

    var materializedRowCountForTesting: Int {
        var count = 0
        tableView.enumerateAvailableRowViews { _, _ in count += 1 }
        return count
    }
}

// MARK: - Virtualized Page

extension ExtensionsPreferencesViewController: NSTableViewDataSource, NSTableViewDelegate {
    func numberOfRows(in tableView: NSTableView) -> Int {
        presentationRows.count
    }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
        false
    }

    func tableView(
        _ tableView: NSTableView,
        viewFor tableColumn: NSTableColumn?,
        row tableRow: Int
    ) -> NSView? {
        guard presentationRows.indices.contains(tableRow) else { return nil }
        let identifier = NSUserInterfaceItemIdentifier("ExtensionsSettingsVirtualRow")
        let host = tableView.makeView(
            withIdentifier: identifier,
            owner: self
        ) as? ThemedVirtualTableCell ?? ThemedVirtualTableCell()
        host.identifier = identifier
        host.install(
            content(for: presentationRows[tableRow]),
            columnWidth: tableView.tableColumns.first?.width ?? tableView.bounds.width,
            horizontalInset: Design.Size.glowGutter,
            topInset: topInset(for: presentationRows[tableRow]),
            bottomInset: bottomInset(forRowAt: tableRow)
        )
        return host
    }

    private func content(for row: PresentationRow) -> NSView {
        switch row {
        case .note:
            return SettingsUI.note(
                "Install an extension included with Threading, or import a "
                    + ".threadingextension package or unpacked development directory. Every "
                    + "package is reviewed before it is copied and remains disabled until you "
                    + "enable it; Git source links are for inspection, never cloned or built."
            )
        case .firstPartyProblem:
            return SettingsUI.section(
                "From Threading",
                SettingsCard(rows: [
                    SettingsUI.row(
                        title: "Included extensions could not be read",
                        subtitle: firstPartyCatalog.problem ?? ""
                    )
                ])
            )
        case .firstPartyCaption:
            return SettingsUI.caption("From Threading")
        case .firstPartyEntry(let entryIndex):
            guard firstPartyExtensions.indices.contains(entryIndex) else { return NSView() }
            return firstPartyRow(firstPartyExtensions[entryIndex])
        case .installedCaption:
            return SettingsUI.caption("Installed")
        case .identityResolvers:
            return identityResolverSection() ?? NSView()
        case .inventoryProblem:
            return SettingsUI.section(
                "Installed",
                SettingsCard(rows: [
                    SettingsUI.row(
                        title: "Extensions could not be read",
                        subtitle: inventoryProblem ?? ""
                    )
                ])
            )
        case .emptyInventory:
            return SettingsUI.section(
                "Installed",
                SettingsCard(rows: [
                    SettingsUI.row(
                        title: "No extensions installed",
                        subtitle: "Imported packages appear here with their permissions and runtime state."
                    )
                ])
            )
        case .packageHeader(let packageIndex):
            guard installedExtensions.indices.contains(packageIndex) else { return NSView() }
            return extensionHeader(installedExtensions[packageIndex])
        case .packageDetail(let packageIndex, let detail):
            guard installedExtensions.indices.contains(packageIndex) else { return NSView() }
            return packageDetail(detail, for: installedExtensions[packageIndex])
        case .extensionCaption(let sectionIndex):
            guard extensionSections.indices.contains(sectionIndex),
                  let title = extensionSections[sectionIndex].visibleTitle else { return NSView() }
            let caption = SettingsUI.caption(title, localizes: false)
            caption.setAccessibilityIdentifier(
                extensionSections[sectionIndex].accessibilityIdentifier
            )
            return caption
        case .extensionField(let sectionIndex, let fieldIndex):
            guard extensionSections.indices.contains(sectionIndex) else { return NSView() }
            return ExtensionSettingsRenderer.fieldRow(
                in: extensionSections[sectionIndex],
                fieldIndex: fieldIndex
            )
        }
    }

    private func packageDetail(
        _ detail: PackageDetailRow,
        for item: InstalledExtensionSnapshot
    ) -> NSView {
        switch detail {
        case .type:
            return SettingsUI.row(
                title: "Type",
                subtitle: localizedName(item.profile)
            )
        case .status:
            return statusRow(item.status)
        case .packageOrigin:
            return SettingsUI.row(
                title: "Package",
                subtitle: item.provenance?.presentation
                    ?? L10n.string("Origin not recorded · containment still enforced")
            )
        case .contributions:
            return SettingsUI.row(
                title: "Provides",
                subtitle: item.contributionKinds.map(localizedName).joined(separator: ", ")
            )
        case .services:
            return SettingsUI.row(
                title: "Provides services",
                subtitle: item.services
                    .sorted { ($0.title, $0.version) < ($1.title, $1.version) }
                    .map { "\($0.title) v\($0.version)" }
                    .joined(separator: ", ")
            )
        case .serviceDependencies:
            return SettingsUI.row(
                title: "Uses services",
                subtitle: item.serviceDependencies
                    .sorted {
                        ($0.providerIdentifier, $0.serviceID, $0.version)
                            < ($1.providerIdentifier, $1.serviceID, $1.version)
                    }
                    .map { dependency in
                        let provider = installedNames[dependency.providerIdentifier]
                            ?? dependency.providerIdentifier
                        let availability = manager.isServiceAvailable(dependency)
                            ? L10n.string("available")
                            : dependency.required
                                ? L10n.string("required · unavailable")
                                : L10n.string("unavailable")
                        return "\(provider) / \(dependency.serviceID) "
                            + "v\(dependency.version) · \(availability)"
                    }
                    .joined(separator: "\n")
            )
        case .capabilities:
            return SettingsUI.row(
                title: "Declared capabilities",
                subtitle: item.capabilities.joined(separator: ", ")
            )
        case .companions:
            return SettingsUI.row(
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
        case .actions:
            return SettingsUI.fullRow(actionRow(for: item))
        }
    }

    /// Inserts or removes only one package's cheap detail identities. Visible cells outside that
    /// run retain their controls and the clip view retains its momentum and exact origin.
    private func setExtension(_ identifier: String, expanded: Bool) {
        guard let packageIndex = installedExtensions.firstIndex(where: {
            $0.identifier == identifier
        }), let header = presentationRows.firstIndex(where: {
            if case .packageHeader(let index) = $0 { return index == packageIndex }
            return false
        }) else { return }

        let wasExpanded = expandedExtensions.contains(identifier)
        guard wasExpanded != expanded else { return }
        if expanded {
            expandedExtensions.insert(identifier)
            let details = packageDetailRows(for: installedExtensions[packageIndex])
            presentationRows.insert(
                contentsOf: details.map {
                    .packageDetail(package: packageIndex, detail: $0)
                },
                at: header + 1
            )
            if !details.isEmpty {
                tableView.insertRows(
                    at: IndexSet(integersIn: (header + 1)..<(header + 1 + details.count)),
                    withAnimation: []
                )
            }
        } else {
            expandedExtensions.remove(identifier)
            var end = header + 1
            while presentationRows.indices.contains(end) {
                guard case .packageDetail(let index, _) = presentationRows[end],
                      index == packageIndex else { break }
                end += 1
            }
            if end > header + 1 {
                let range = (header + 1)..<end
                presentationRows.removeSubrange(range)
                tableView.removeRows(at: IndexSet(integersIn: range), withAnimation: [])
            }
        }

        updateCardDecorations()
        tableView.reloadData(
            forRowIndexes: IndexSet(integer: header),
            columnIndexes: IndexSet(integer: 0)
        )
    }

    private func updateCardDecorations() {
        var packageBounds: [Int: (first: Int, last: Int)] = [:]
        var extensionBounds: [Int: (first: Int, last: Int)] = [:]
        var firstPartyBounds: (first: Int, last: Int)?
        for (rowIndex, row) in presentationRows.enumerated() {
            switch row {
            case .firstPartyEntry:
                if var bounds = firstPartyBounds {
                    bounds.last = rowIndex
                    firstPartyBounds = bounds
                } else {
                    firstPartyBounds = (rowIndex, rowIndex)
                }
            case .packageHeader(let packageIndex):
                packageBounds[packageIndex] = (rowIndex, rowIndex)
            case .packageDetail(let packageIndex, _):
                if var bounds = packageBounds[packageIndex] {
                    bounds.last = rowIndex
                    packageBounds[packageIndex] = bounds
                }
            case .extensionField(let sectionIndex, _):
                if var bounds = extensionBounds[sectionIndex] {
                    bounds.last = rowIndex
                    extensionBounds[sectionIndex] = bounds
                } else {
                    extensionBounds[sectionIndex] = (rowIndex, rowIndex)
                }
            case .note, .firstPartyProblem, .firstPartyCaption, .installedCaption,
                 .identityResolvers,
                 .inventoryProblem, .emptyInventory, .extensionCaption:
                break
            }
        }

        var decorations: [ThemedTableCardDecoration] = []
        if let firstPartyBounds {
            decorations.append(ThemedTableCardDecoration(
                rows: firstPartyBounds.first...firstPartyBounds.last,
                topInset: 0,
                bottomInset: firstPartyBounds.last == presentationRows.count - 1
                    ? Design.Spacing.large
                    : 0
            ))
        }
        decorations.append(contentsOf: packageBounds.sorted { $0.key < $1.key }.map {
            ThemedTableCardDecoration(
                rows: $0.value.first...$0.value.last,
                topInset: Design.Spacing.large,
                bottomInset: $0.value.last == presentationRows.count - 1
                    ? Design.Spacing.large
                    : 0
            )
        })
        decorations.append(contentsOf: extensionBounds.sorted { $0.key < $1.key }.map {
            let section = extensionSections[$0.key]
            return ThemedTableCardDecoration(
                rows: $0.value.first...$0.value.last,
                topInset: section.visibleTitle == nil ? Design.Spacing.large : 0,
                bottomInset: $0.value.last == presentationRows.count - 1
                    ? Design.Spacing.large
                    : 0
            )
        })
        tableView.cardDecorations = decorations
    }

    private func topInset(for row: PresentationRow) -> CGFloat {
        switch row {
        case .packageDetail, .firstPartyEntry:
            return 0
        case .extensionField(let sectionIndex, let fieldIndex):
            guard fieldIndex == 0, extensionSections.indices.contains(sectionIndex) else {
                return 0
            }
            return extensionSections[sectionIndex].visibleTitle == nil
                ? Design.Spacing.large
                : 0
        case .note, .firstPartyProblem, .firstPartyCaption, .installedCaption,
             .identityResolvers, .inventoryProblem, .emptyInventory, .packageHeader,
             .extensionCaption:
            return Design.Spacing.large
        }
    }

    private func bottomInset(forRowAt row: Int) -> CGFloat {
        guard presentationRows.indices.contains(row) else { return 0 }
        if case .extensionCaption = presentationRows[row] {
            return Design.Spacing.small
        }
        if case .firstPartyCaption = presentationRows[row] {
            return Design.Spacing.small
        }
        if case .installedCaption = presentationRows[row] {
            return Design.Spacing.small
        }
        return row == presentationRows.count - 1 ? Design.Spacing.large : 0
    }
}

private enum ExtensionsPreferencesDefaults {
    static let estimatedRowHeight: CGFloat = 64
}
