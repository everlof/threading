import AppKit

/// The Tools page: what Threading exposes to the agents it launches over MCP, grouped, with a
/// switch per group.
///
/// The switch is per group rather than per tool on purpose — several tools only make sense as a
/// set (clicking a page you never opened, activating a tab you never listed) — and each group
/// lists the tools it carries so the page doubles as documentation of what an agent can reach.
///
/// Each group is a **collapsed card**: the decision (the switch) and the group's size sit on
/// the header, the per-tool documentation unfolds on demand. Fully unfolded, ten groups listed
/// seventy-odd tool rows and the browser group alone was a screen and a half — the page read
/// as a wall, and Website Access at its foot was effectively unreachable.
@MainActor
final class ToolsPreferencesViewController: NSViewController {

    // MARK: - Properties

    /// The groups whose tool documentation the user has unfolded, by group id. A view state,
    /// not a preference — the same session-only fold Storage keeps for its checkouts.
    private var expandedGroups: Set<String> = []
    private let appEvents = AppEventObservations()
    private var pageView: SettingsPageView?
    private let groupOverride: [MCPToolGroup]?
    private let browserAccessStore: BrowserAccessStore
    private let chromeAutomationProfile: ChromeAutomationProfile
    private var persistentOriginKeys: [String] = []
    private let credentialStore: BrowserCredentialStore
    private var storedCredentials: [BrowserCredentialIdentity] = []
    private var onePasswordItems: [BrowserCredentialIdentity] = []
    private var exemptSubmissionOrigins: [String] = []
    private var extensionSections: [ExtensionSettingsSectionModel] = []

    /// The complete page ordering is cheap value state. AppKit owns only the cells around the
    /// viewport, so an expanded Browser group no longer leaves hundreds of views and constraints
    /// alive after it scrolls away.
    private enum PresentationRow {
        case note
        case group(Int)
        case tool(group: Int, tool: Int)
        case browserSignIn
        case chromeAutomation
        case websiteAccess
        case extensionCaption(Int)
        case extensionField(section: Int, field: Int)
    }

    private var presentationRows: [PresentationRow] = []

    private lazy var tableView: ThemedGroupedTableView = {
        let table = ThemedGroupedTableView()
        let column = NSTableColumn(
            identifier: NSUserInterfaceItemIdentifier("ToolsSettingsContent")
        )
        column.resizingMask = .autoresizingMask
        table.addTableColumn(column)
        table.headerView = nil
        table.style = .plain
        table.selectionHighlightStyle = .none
        table.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        table.intercellSpacing = .zero
        table.rowHeight = ToolsPreferencesDefaults.estimatedRowHeight
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

    /// Hosts whose accounts are worth more than a vault without a biometric gate protects.
    ///
    /// Deliberately short and honestly incomplete: it catches the mistake someone makes while
    /// hurrying, not a determined user, and a long list would imply a completeness it cannot have.
    static let wellKnownIdentityHosts = [
        "google.com", "apple.com", "icloud.com", "github.com", "gitlab.com",
        "microsoftonline.com", "live.com", "okta.com", "amazon.com", "facebook.com"
    ]

    convenience init(groups: [MCPToolGroup]? = nil) {
        self.init(groups: groups, browserAccessStore: BrowserAccessStore())
    }

    init(
        groups: [MCPToolGroup]?,
        browserAccessStore: BrowserAccessStore,
        chromeAutomationProfile: ChromeAutomationProfile = .shared,
        credentialStore: BrowserCredentialStore = BrowserCredentialStore()
    ) {
        groupOverride = groups
        self.browserAccessStore = browserAccessStore
        self.chromeAutomationProfile = chromeAutomationProfile
        self.credentialStore = credentialStore
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private var displayedGroups: [MCPToolGroup] {
        groupOverride ?? MCPToolCatalog.allGroups
    }

    // MARK: - Lifecycle

    override func loadView() {
        view = NSView()
        render()
        appEvents.observe(MCPExternalToolsDidChange.self) { [weak self] _ in
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

    // MARK: - Setup

    private func render() {
        guard isViewLoaded else { return }
        extensionSections = ExtensionSettingsRenderer.hostSectionModels(for: .tools)
        presentationRows = makePresentationRows()
        updateCardDecorations()

        if let pageView {
            pageView.updateSummary(enabledSummary)
            tableView.reloadData()
            return
        }

        let page = SettingsUI.listPage(
            title: "Tools",
            summary: enabledSummary,
            body: scrollView
        )
        pageView = page
        page.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(page)
        NSLayoutConstraint.activate([
            page.topAnchor.constraint(equalTo: view.topAnchor),
            page.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            page.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            page.trailingAnchor.constraint(equalTo: view.trailingAnchor)
        ])
    }

    private var enabledSummary: String {
        let enabled = displayedGroups.filter { MCPToolCatalog.isEnabled($0) }.count
        return L10n.format(
            "%lld of %lld tool groups enabled",
            Int64(enabled),
            Int64(displayedGroups.count)
        )
    }

    private func makePresentationRows() -> [PresentationRow] {
        var rows: [PresentationRow] = [.note]
        for (groupIndex, group) in displayedGroups.enumerated() {
            rows.append(.group(groupIndex))
            if expandedGroups.contains(group.id) {
                rows.append(contentsOf: group.tools.indices.map {
                    .tool(group: groupIndex, tool: $0)
                })
            }
        }
        rows.append(contentsOf: [.browserSignIn, .chromeAutomation, .websiteAccess])
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

    private func updateCardDecorations() {
        var decorations: [ThemedTableCardDecoration] = presentationRows.indices.compactMap { index in
            guard case .group(let groupIndex) = presentationRows[index],
                  displayedGroups.indices.contains(groupIndex) else { return nil }
            let toolRows = expandedGroups.contains(displayedGroups[groupIndex].id)
                ? displayedGroups[groupIndex].tools.count
                : 0
            return ThemedTableCardDecoration(
                rows: index...(index + toolRows),
                topInset: Design.Spacing.large
            )
        }
        var extensionBounds: [Int: (first: Int, last: Int)] = [:]
        for (rowIndex, row) in presentationRows.enumerated() {
            guard case .extensionField(let sectionIndex, _) = row else { continue }
            if var bounds = extensionBounds[sectionIndex] {
                bounds.last = rowIndex
                extensionBounds[sectionIndex] = bounds
            } else {
                extensionBounds[sectionIndex] = (rowIndex, rowIndex)
            }
        }
        decorations.append(contentsOf: extensionBounds.sorted { $0.key < $1.key }.map {
            let section = extensionSections[$0.key]
            return ThemedTableCardDecoration(
                rows: $0.value.first...$0.value.last,
                topInset: section.visibleTitle == nil ? Design.Spacing.large : 0
            )
        })
        tableView.cardDecorations = decorations
    }

    /// One group, folded: the switch and the group's size on the header, the per-tool
    /// documentation as detail rows only while unfolded.
    private func groupHeader(_ group: MCPToolGroup, index: Int) -> NSView {
        let enabled = MCPToolCatalog.isEnabled(group)
        let available = MCPToolCatalog.isAvailable(group)

        let toggle = ThemedToggle()
        toggle.state = enabled ? .on : .off
        toggle.isEnabled = available
        toggle.tag = index
        toggle.target = self
        toggle.action = #selector(groupToggled(_:))
        toggle.setAccessibilityLabel(group.title)

        let expanded = expandedGroups.contains(group.id)
        let groupID = group.id
        return SettingsUI.disclosureHeader(
            title: group.title,
            subtitle: group.summary,
            summary: toolCount(group.tools.count),
            control: toggle,
            isExpanded: expanded,
            accessibilityIdentifier: "settings.tools.group.\(groupID)",
            onToggle: { [weak self] nowExpanded in
                self?.setGroup(groupID, expanded: nowExpanded)
            }
        )
    }

    /// Inserts or removes only this group's tool rows. The table keeps the scroll position and
    /// every unrelated visible control in place; an offscreen group changes as model state only.
    func setGroup(_ groupID: String, expanded: Bool) {
        guard let header = presentationRows.firstIndex(where: {
            guard case .group(let index) = $0,
                  displayedGroups.indices.contains(index) else { return false }
            return displayedGroups[index].id == groupID
        }), case .group(let groupIndex) = presentationRows[header] else { return }

        let group = displayedGroups[groupIndex]
        let wasExpanded = expandedGroups.contains(groupID)
        guard wasExpanded != expanded else { return }

        if expanded {
            expandedGroups.insert(groupID)
            if !group.tools.isEmpty {
                let range = (header + 1)..<(header + 1 + group.tools.count)
                presentationRows.insert(
                    contentsOf: group.tools.indices.map { .tool(group: groupIndex, tool: $0) },
                    at: header + 1
                )
                tableView.insertRows(at: IndexSet(integersIn: range), withAnimation: [])
            }
        } else {
            expandedGroups.remove(groupID)
            if !group.tools.isEmpty {
                let range = (header + 1)..<(header + 1 + group.tools.count)
                presentationRows.removeSubrange(range)
                tableView.removeRows(at: IndexSet(integersIn: range), withAnimation: [])
            }
        }

        updateCardDecorations()
        tableView.reloadData(forRowIndexes: IndexSet(integer: header), columnIndexes: IndexSet(integer: 0))
    }

    private func toolCount(_ count: Int) -> String {
        count == 1
            ? L10n.string("1 tool")
            : L10n.format("%lld tools", Int64(count))
    }

    /// One tool: its glyph, its name and one-line description, and the raw tool name an agent
    /// actually calls, in monospace on the trailing edge.
    private func toolRow(_ tool: MCPToolInfo) -> NSView {
        let icon = NSImageView()
        icon.image = NSImage(systemSymbolName: tool.symbol, accessibilityDescription: nil)
        icon.contentTintColor = Design.Text.secondary
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.setContentHuggingPriority(.required, for: .horizontal)
        icon.widthAnchor.constraint(equalToConstant: ToolsPreferencesDefaults.iconWidth).isActive = true

        let title = NSTextField(labelWithString: tool.title)
        title.applyFont(.body)
        title.textColor = Design.Text.label

        // Wrapping, not a truncating single line: a non-wrapping label's full width is a
        // demand the stack passes outward, and under a monospace theme the longest detail
        // pushed the whole page 126pt past its pane — the pane's own pins were what broke.
        let detail = NSTextField(wrappingLabelWithString: tool.detail)
        detail.applyFont(.subheading)
        detail.textColor = Design.Text.secondary

        let labels = NSStackView(views: [title, detail])
        labels.orientation = .vertical
        labels.alignment = .leading
        labels.spacing = Design.Spacing.hairline
        // The labels take the row's slack, not a spacer: a wrapping detail has no intrinsic
        // width to argue with, and against a spacer willing to grow it collapsed to its
        // narrowest wrap — five short lines in a row that was mostly empty. The same fix
        // `SettingsUI.row` documents.
        labels.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let name = NSTextField(labelWithString: tool.name)
        name.applyFont(.compactToolName)
        name.textColor = Design.Text.tertiary
        name.setContentHuggingPriority(.required, for: .horizontal)
        name.setContentCompressionResistancePriority(.required, for: .horizontal)

        let row = NSStackView(views: [icon, labels, name])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.distribution = .fill
        row.spacing = Design.Spacing.medium
        return row
    }

    /// The one place the signed-in Chrome profile can be created, because creating it is the one
    /// part of that feature an agent must not be able to do.
    ///
    /// It sits on Tools rather than on Privacy: what it grants is not a permission Threading
    /// holds, it is a browser an agent can be pointed at — the same question the switches above
    /// and Website Access below answer.
    private func chromeAutomationSection() -> NSView {
        let profile = chromeAutomationProfile
        let row: NSView
        switch profile.state {
        case .chromeMissing:
            row = SettingsUI.row(
                title: "Google Chrome is not installed",
                subtitle: """
                    Agents can still use Threading's own browser and the isolated test browser. \
                    A signed-in automation profile needs real Chrome.
                    """
            )
        case .notSetUp:
            row = SettingsUI.row(
                title: "Not set up",
                subtitle: """
                    Opens a separate Chrome on a profile of Threading's own. Sign in to the sites \
                    you want agents to reach and install your password manager's extension there. \
                    Threading never reads a password, a cookie, or a Keychain item.
                    """,
                control: SettingsUI.button(
                    "Set Up Automation Profile",
                    target: self,
                    action: #selector(setUpChromeAutomationProfile)
                )
            )
        case .ready:
            row = SettingsUI.row(
                title: "Ready",
                subtitle: """
                    Agents may use this profile only for websites you allow, one run at a time, \
                    and it opens visibly so you can see what it does. Sign in to another site by \
                    opening it again.
                    """,
                control: SettingsUI.button(
                    "Open Automation Profile",
                    target: self,
                    action: #selector(setUpChromeAutomationProfile)
                )
            )
        }
        return SettingsUI.section(
            "Signed-in Chrome",
            SettingsCard(rows: [row])
        )
    }

    /// Where an agent's sign-in values come from, and the test accounts it may use.
    ///
    /// Called **Browser Sign-In** and its entries **test credentials**, never "password manager".
    /// The naming is a guardrail, not decoration: the dominant failure mode of a deliberately
    /// weaker vault is people putting real credentials in it because it was convenient, and what
    /// the screen calls itself is most of what prevents that.
    private func browserSignInSection() -> NSView {
        let picker = SettingsUI.popUp(target: self, action: #selector(credentialProviderChanged(_:)))
        for provider in BrowserCredentialProvider.allCases {
            picker.addItem(withTitle: Self.providerTitle(provider))
        }
        picker.selectItem(at: BrowserCredentialProvider.allCases.firstIndex(
            of: BrowserCredentialPreference.provider
        ) ?? 0)

        var rows: [NSView] = [
            SettingsUI.row(
                title: "Sign-in values come from",
                subtitle: Self.providerExplanation(BrowserCredentialPreference.provider),
                control: picker
            )
        ]

        if BrowserCredentialPreference.provider == .onePassword, OnePasswordCLI.isInstalled {
            onePasswordItems = OnePasswordItemStore.identities()
            if onePasswordItems.isEmpty {
                rows.append(SettingsUI.row(
                    title: "No 1Password items linked",
                    subtitle: """
                        Point an origin at a 1Password item and agents can sign in to it without \
                        you typing anything.
                        """,
                    control: SettingsUI.button(
                        "Link…",
                        target: self,
                        action: #selector(addOnePasswordItem)
                    )
                ))
            } else {
                rows.append(contentsOf: onePasswordItems.enumerated().map { index, identity in
                    let remove = SettingsUI.button(
                        "Remove",
                        target: self,
                        action: #selector(removeOnePasswordItem(_:))
                    )
                    remove.tag = index
                    return SettingsUI.row(
                        title: "\(identity.label) — \(identity.originKey)",
                        subtitle: OnePasswordItemStore.reference(for: identity) ?? "",
                        control: remove,
                        localizes: false
                    )
                })
                rows.append(SettingsUI.row(
                    title: "Another 1Password item",
                    subtitle: "Threading stores the reference only. 1Password holds the value.",
                    control: SettingsUI.button(
                        "Link…",
                        target: self,
                        action: #selector(addOnePasswordItem)
                    )
                ))
            }
        }

        if BrowserCredentialPreference.provider == .threadingVault {
            storedCredentials = credentialStore.identities()
            if storedCredentials.isEmpty {
                rows.append(SettingsUI.row(
                    title: "No test credentials stored",
                    subtitle: """
                        Add a throwaway account and agents can sign in to that exact origin \
                        without you typing it. Never store a real account here.
                        """,
                    control: SettingsUI.button(
                        "Add…",
                        target: self,
                        action: #selector(addTestCredential)
                    )
                ))
            } else {
                rows.append(contentsOf: storedCredentials.enumerated().map { index, identity in
                    let remove = SettingsUI.button(
                        "Remove",
                        target: self,
                        action: #selector(removeTestCredential(_:))
                    )
                    remove.tag = index
                    return SettingsUI.row(
                        title: "\(identity.label) — \(identity.originKey)",
                        subtitle: "Agents may fill this account on this exact origin.",
                        control: remove
                    )
                })
                rows.append(SettingsUI.row(
                    title: L10n.string("Another test account"),
                    subtitle: BrowserCredentialStore.isShellReachable
                        ? L10n.string("""
                            Stored in your login Keychain, and removed by Reset Everything. This \
                            build cannot use the protected Keychain, so a command line on this \
                            Mac — including an agent's — could add or delete entries here.
                            """)
                        : L10n.string("""
                            Stored in your protected Keychain, out of reach of the command line, \
                            and removed by Reset Everything.
                            """),
                    control: SettingsUI.button(
                        "Add…",
                        target: self,
                        action: #selector(addTestCredential)
                    ),
                    localizes: false
                ))
            }
        }

        exemptSubmissionOrigins = BrowserSubmissionExemptions.shared.exemptOriginKeys
        rows.append(contentsOf: exemptSubmissionOrigins.enumerated().map { index, origin in
            let revoke = SettingsUI.button(
                "Ask Again",
                target: self,
                action: #selector(revokeSubmissionExemption(_:))
            )
            revoke.tag = index
            return SettingsUI.row(
                title: origin,
                subtitle: L10n.string("""
                    Forms submit here without asking. This lasts until you quit Threading and is \
                    never written to disk.
                    """),
                control: revoke,
                localizes: false
            )
        })

        return SettingsUI.section("Browser Sign-In", SettingsCard(rows: rows))
    }

    private static func providerTitle(_ provider: BrowserCredentialProvider) -> String {
        switch provider {
        case .systemAutoFill: return L10n.string("macOS AutoFill and password managers")
        case .threadingVault: return L10n.string("Threading test credentials")
        case .onePassword: return L10n.string("1Password")
        }
    }

    private static func providerExplanation(_ provider: BrowserCredentialProvider) -> String {
        switch provider {
        case .systemAutoFill:
            return L10n.string("""
                Threading never sees a password. When an agent reaches a sign-in field the \
                browser is revealed with that field focused, and you complete it.
                """)
        case .threadingVault:
            return L10n.string("""
                Agents may fill test accounts you store below, without asking, on the exact \
                origin each is stored for. Deliberately less protected than a password manager: \
                store only throwaway accounts. Everything else still asks.
                """)
        case .onePassword:
            return OnePasswordCLI.isInstalled
                ? L10n.string("""
                    Agents may fill the 1Password items you point at below, on the exact origin \
                    each is stored for. 1Password still authorizes every read, so it may ask you \
                    to unlock. Threading stores only the item reference, never the value.
                    """)
                : L10n.string("""
                    The 1Password command line (op) is not installed, so sign-in falls back to \
                    revealing the field for you. Install it from 1Password's developer settings.
                    """)
        }
    }

    private func websiteAccessSection() -> NSView {
        persistentOriginKeys = browserAccessStore.allowedOrigins.sorted()
        guard !persistentOriginKeys.isEmpty else {
            return SettingsUI.section(
                "Website Access",
                SettingsCard(rows: [
                    SettingsUI.row(
                        title: "No websites always allowed",
                        subtitle: """
                            Agents can still ask for one-time access. Persistent website grants \
                            will appear here.
                            """
                    )
                ])
            )
        }

        var rows = persistentOriginKeys.enumerated().map { index, origin -> NSView in
            let revoke = SettingsUI.button(
                "Revoke",
                target: self,
                action: #selector(revokeWebsiteAccess(_:))
            )
            revoke.tag = index
            return SettingsUI.row(
                title: origin,
                subtitle: "Agents may use this origin in Threading's signed-in browser.",
                control: revoke
            )
        }
        rows.append(SettingsUI.row(
            title: "All persistent access",
            subtitle: "One-time grants end with the running app and are not listed here.",
            control: SettingsUI.button(
                "Revoke All…",
                target: self,
                action: #selector(revokeAllWebsiteAccess)
            )
        ))
        return SettingsUI.section("Website Access", SettingsCard(rows: rows))
    }

    // MARK: - Actions

    @objc private func groupToggled(_ sender: ThemedToggle) {
        guard displayedGroups.indices.contains(sender.tag) else { return }
        let group = displayedGroups[sender.tag]
        AppSettings.shared.setToolGroup(group.id, enabled: sender.state == .on)
        pageView?.updateSummary(enabledSummary)

        guard let header = presentationRows.firstIndex(where: {
            if case .group(let index) = $0 { return index == sender.tag }
            return false
        }) else { return }
        let end = expandedGroups.contains(group.id)
            ? min(header + group.tools.count, presentationRows.count - 1)
            : header
        tableView.reloadData(
            forRowIndexes: IndexSet(integersIn: header...end),
            columnIndexes: IndexSet(integer: 0)
        )
    }

    @objc private func setUpChromeAutomationProfile() {
        chromeAutomationProfile.openForSetup()
        // Chrome writes its profile the moment it opens, so the page's own state line is stale
        // as soon as the window appears. Rebuilding is this page's one update path.
        render()
    }

    @objc private func credentialProviderChanged(_ sender: ThemedPopUp) {
        let providers = BrowserCredentialProvider.allCases
        guard providers.indices.contains(sender.indexOfSelectedItem) else { return }
        BrowserCredentialPreference.provider = providers[sender.indexOfSelectedItem]
        render()
    }

    /// Adds one test credential.
    ///
    /// The origin is typed by the user and parsed through `BrowserOrigin`, so what is stored is
    /// the same key the fill compares against — a host typed with a path or a trailing slash
    /// cannot become an entry that never matches anything.
    ///
    /// A non-loopback origin needs the throwaway acknowledgement ticked. Loopback does not,
    /// because `localhost:3000` is the case this feature exists for and asking there would train
    /// people to tick it everywhere.
    @objc private func addTestCredential() {
        guard let window = view.window else { return }

        let originField = ThemedTextField()
        originField.placeholderString = L10n.string("http://localhost:3000")
        let labelField = ThemedTextField()
        labelField.placeholderString = L10n.string("admin")
        let usernameField = ThemedTextField()
        usernameField.placeholderString = L10n.string("Username or email (optional)")
        let passwordField = ThemedSecureField()
        passwordField.placeholderString = L10n.string("Test account password")

        let acknowledgement = ThemedCheckbox(
            title: L10n.string("This is a throwaway test account"),
            changed: { _ in }
        )

        let fields = NSStackView(views: [
            originField, labelField, usernameField, passwordField, acknowledgement
        ] as [NSView])
        fields.orientation = .vertical
        fields.alignment = .leading
        fields.spacing = Design.Spacing.small
        for field in [originField, labelField, usernameField, passwordField] {
            field.translatesAutoresizingMaskIntoConstraints = false
            field.widthAnchor.constraint(equalToConstant: ToolsPreferencesDefaults.sheetFieldWidth)
                .isActive = true
        }

        // Through `ConfirmationAlert` rather than a bare `ThemedAlert`: this asks a question
        // whose answer grants a capability, and the registry is what states that it may never be
        // switched off.
        let request = ConfirmationRequest(
            prompt: .storeTestCredential,
            title: L10n.string("Add a Test Credential"),
            message: L10n.string("""
                Agents may fill this account, without asking, on this exact origin only. \
                Threading stores it in your Keychain without a Touch ID prompt, which is what \
                makes unattended filling possible — so store only an account you would not mind \
                losing.
                """),
            confirmTitle: L10n.string("Add"),
            accessory: fields
        )

        ConfirmationAlert.ask(request, in: window) { [weak self] confirmed in
            guard let self, confirmed else { return }
            self.saveTestCredential(
                origin: originField.stringValue,
                label: labelField.stringValue,
                username: usernameField.stringValue,
                password: passwordField.stringValue,
                acknowledged: acknowledgement.state == .on
            )
        }
    }

    private func saveTestCredential(
        origin rawOrigin: String,
        label rawLabel: String,
        username: String,
        password: String,
        acknowledged: Bool
    ) {
        let label = rawLabel.trimmingCharacters(in: .whitespacesAndNewlines)
        func refuse(_ reason: String) {
            // A plain themed alert, not a `ConfirmationRequest`: this states an outcome and
            // asks nothing, so it reads no response and needs no registered prompt.
            let alert = ThemedAlert()
            alert.alertStyle = .warning
            alert.messageText = L10n.string("The test credential was not added")
            alert.informativeText = reason
            alert.addButton(withTitle: L10n.string("OK"))
            if let window = view.window { alert.beginSheetModal(for: window) }
        }

        guard let url = URL(string: rawOrigin.trimmingCharacters(in: .whitespacesAndNewlines)),
              let origin = BrowserOrigin(url: url), !origin.host.isEmpty else {
            refuse(L10n.string("""
                Enter the origin as a full URL, for example http://localhost:3000 or \
                https://staging.example.com.
                """))
            return
        }
        guard !label.isEmpty else {
            refuse(L10n.string("Give the account a name so an agent can ask for it by name."))
            return
        }
        guard !password.isEmpty else {
            refuse(L10n.string("A test credential needs a password."))
            return
        }
        guard origin.isLocal || acknowledged else {
            refuse(L10n.format("""
                %@ is not on this machine. Tick “This is a throwaway test account” to store a \
                credential for it.
                """, origin.displayName))
            return
        }
        if Self.wellKnownIdentityHosts.contains(where: {
            origin.host == $0 || origin.host.hasSuffix("." + $0)
        }) {
            refuse(L10n.format("""
                %@ looks like a real account provider. Threading's test credentials are stored \
                without a Touch ID prompt so agents can use them unattended, which is not safe \
                for an account you care about.
                """, origin.displayName))
            return
        }

        do {
            try credentialStore.save(
                username: username.trimmingCharacters(in: .whitespacesAndNewlines),
                password: password,
                for: BrowserCredentialIdentity(originKey: origin.key, label: label)
            )
            render()
        } catch {
            refuse(error.localizedDescription)
        }
    }

    /// Links one origin to a 1Password item.
    ///
    /// The reference is validated before it is stored, so a typo is a settings error now rather
    /// than a sign-in that quietly hands back to the user weeks later.
    @objc private func addOnePasswordItem() {
        guard let window = view.window else { return }

        let originField = ThemedTextField()
        originField.placeholderString = L10n.string("http://localhost:3000")
        let labelField = ThemedTextField()
        labelField.placeholderString = L10n.string("admin")
        let referenceField = ThemedTextField()
        referenceField.placeholderString = L10n.string("op://Private/staging-admin")

        let fields = NSStackView(views: [originField, labelField, referenceField] as [NSView])
        fields.orientation = .vertical
        fields.alignment = .leading
        fields.spacing = Design.Spacing.small
        for field in [originField, labelField, referenceField] {
            field.translatesAutoresizingMaskIntoConstraints = false
            field.widthAnchor.constraint(equalToConstant: ToolsPreferencesDefaults.sheetFieldWidth)
                .isActive = true
        }

        let request = ConfirmationRequest(
            prompt: .storeTestCredential,
            title: L10n.string("Link a 1Password Item"),
            message: L10n.string("""
                Agents may sign in with this item on this exact origin. Threading stores only the \
                reference — 1Password keeps the value and authorizes every read, so it may ask \
                you to unlock.
                """),
            confirmTitle: L10n.string("Link"),
            accessory: fields
        )

        ConfirmationAlert.ask(request, in: window) { [weak self] confirmed in
            guard let self, confirmed else { return }
            self.saveOnePasswordItem(
                origin: originField.stringValue,
                label: labelField.stringValue,
                reference: referenceField.stringValue
            )
        }
    }

    private func saveOnePasswordItem(origin rawOrigin: String, label rawLabel: String, reference: String) {
        let label = rawLabel.trimmingCharacters(in: .whitespacesAndNewlines)
        func refuse(_ reason: String) {
            let alert = ThemedAlert()
            alert.alertStyle = .warning
            alert.messageText = L10n.string("The 1Password item was not linked")
            alert.informativeText = reason
            alert.addButton(withTitle: L10n.string("OK"))
            if let window = view.window { alert.beginSheetModal(for: window) }
        }

        guard let url = URL(string: rawOrigin.trimmingCharacters(in: .whitespacesAndNewlines)),
              let origin = BrowserOrigin(url: url), !origin.host.isEmpty else {
            refuse(L10n.string("""
                Enter the origin as a full URL, for example http://localhost:3000 or \
                https://staging.example.com.
                """))
            return
        }
        guard !label.isEmpty else {
            refuse(L10n.string("Give the account a name so an agent can ask for it by name."))
            return
        }
        guard OnePasswordCLI.isValidItemReference(reference) else {
            refuse(L10n.string("""
                A 1Password reference names a vault and an item, like op://Private/staging-admin. \
                Do not include a field.
                """))
            return
        }

        OnePasswordItemStore.setReference(
            reference,
            for: BrowserCredentialIdentity(originKey: origin.key, label: label)
        )
        render()
    }

    @objc private func revokeSubmissionExemption(_ sender: ThemedButton) {
        guard exemptSubmissionOrigins.indices.contains(sender.tag) else { return }
        BrowserSubmissionExemptions.shared.revoke(key: exemptSubmissionOrigins[sender.tag])
        render()
    }

    @objc private func removeOnePasswordItem(_ sender: ThemedButton) {
        guard onePasswordItems.indices.contains(sender.tag) else { return }
        OnePasswordItemStore.remove(onePasswordItems[sender.tag])
        render()
    }

    @objc private func removeTestCredential(_ sender: ThemedButton) {
        guard storedCredentials.indices.contains(sender.tag) else { return }
        try? credentialStore.delete(storedCredentials[sender.tag])
        render()
    }

    @objc private func revokeWebsiteAccess(_ sender: ThemedButton) {
        guard persistentOriginKeys.indices.contains(sender.tag) else { return }
        browserAccessStore.revoke(key: persistentOriginKeys[sender.tag])
        render()
    }

    @objc private func revokeAllWebsiteAccess() {
        let request = ConfirmationRequest(
            prompt: .revokeAllWebsiteAccess,
            title: L10n.string("Revoke Persistent Website Access?"),
            message: L10n.string("""
                Agents will need to ask again before using these websites in Threading's signed-in \
                browser. One-time grants are unaffected.
                """),
            confirmTitle: L10n.string("Revoke All")
        )
        ConfirmationAlert.ask(request, in: view.window) { [weak self] confirmed in
            guard confirmed else { return }
            self?.browserAccessStore.revokeAll()
            self?.render()
        }
    }

}

// MARK: - Virtualized Page

extension ToolsPreferencesViewController: NSTableViewDataSource, NSTableViewDelegate {
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
        let identifier = NSUserInterfaceItemIdentifier("ToolsSettingsVirtualRow")
        let host = tableView.makeView(
            withIdentifier: identifier,
            owner: self
        ) as? ThemedVirtualTableCell ?? ThemedVirtualTableCell()
        host.identifier = identifier

        let content = content(for: presentationRows[tableRow])
        host.install(
            content,
            columnWidth: tableView.tableColumns.first?.width ?? tableView.bounds.width,
            horizontalInset: Design.Size.glowGutter,
            topInset: topInset(for: presentationRows[tableRow]),
            bottomInset: bottomInset(forRowAt: tableRow)
        )
        return host
    }

    private func bottomInset(forRowAt row: Int) -> CGFloat {
        guard presentationRows.indices.contains(row) else { return 0 }
        if case .extensionCaption = presentationRows[row] {
            return Design.Spacing.small
        }
        return row == presentationRows.count - 1 ? Design.Spacing.large : 0
    }

    private func topInset(for row: PresentationRow) -> CGFloat {
        switch row {
        case .tool:
            return 0
        case .note, .group, .browserSignIn, .chromeAutomation, .websiteAccess,
             .extensionCaption:
            return Design.Spacing.large
        case .extensionField(let sectionIndex, let fieldIndex):
            guard fieldIndex == 0, extensionSections.indices.contains(sectionIndex) else {
                return 0
            }
            return extensionSections[sectionIndex].visibleTitle == nil ? Design.Spacing.large : 0
        }
    }

    private func content(for row: PresentationRow) -> NSView {
        switch row {
        case .note:
            return SettingsUI.note(
                "Threading exposes these tools to the Claude and Codex sessions it launches, so an "
                    + "agent can reach the app it is running inside. Turn a group off to hide its "
                    + "tools from agents. Changes apply to sessions started afterwards."
            )
        case .group(let groupIndex):
            guard displayedGroups.indices.contains(groupIndex) else { return NSView() }
            return groupHeader(displayedGroups[groupIndex], index: groupIndex)
        case .tool(let groupIndex, let toolIndex):
            guard displayedGroups.indices.contains(groupIndex),
                  displayedGroups[groupIndex].tools.indices.contains(toolIndex) else {
                return NSView()
            }
            let group = displayedGroups[groupIndex]
            let content = toolRow(group.tools[toolIndex])
            content.alphaValue = MCPToolCatalog.isEnabled(group) && MCPToolCatalog.isAvailable(group)
                ? 1
                : ToolsPreferencesDefaults.disabledAlpha
            return SettingsUI.fullRow(content)
        case .browserSignIn:
            return browserSignInSection()
        case .chromeAutomation:
            return chromeAutomationSection()
        case .websiteAccess:
            return websiteAccessSection()
        case .extensionCaption(let index):
            guard extensionSections.indices.contains(index),
                  let title = extensionSections[index].visibleTitle else { return NSView() }
            let caption = SettingsUI.caption(title, localizes: false)
            caption.setAccessibilityIdentifier(extensionSections[index].accessibilityIdentifier)
            return caption
        case .extensionField(let sectionIndex, let fieldIndex):
            guard extensionSections.indices.contains(sectionIndex) else { return NSView() }
            return ExtensionSettingsRenderer.fieldRow(
                in: extensionSections[sectionIndex],
                fieldIndex: fieldIndex
            )
        }
    }

    /// Values used by the command-line stress fixture to assert that expansion grows the cheap
    /// model without retaining the whole expanded page as views.
    var virtualRowCount: Int { presentationRows.count }

    var materializedRowCount: Int {
        var count = 0
        tableView.enumerateAvailableRowViews { _, _ in count += 1 }
        return count
    }
}

// MARK: - Tools Preferences Defaults

enum ToolsPreferencesDefaults {
    static let iconWidth: CGFloat = 20
    static let toolNameFontSize: CGFloat = 10.5
    static let disabledAlpha: CGFloat = 0.45
    static let sheetFieldWidth: CGFloat = 260
    static let estimatedRowHeight: CGFloat = 64
}
