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
    private var pageView: NSView?
    private let groupOverride: [MCPToolGroup]?
    private let browserAccessStore: BrowserAccessStore
    private var persistentOriginKeys: [String] = []

    convenience init(groups: [MCPToolGroup]? = nil) {
        self.init(groups: groups, browserAccessStore: BrowserAccessStore())
    }

    init(groups: [MCPToolGroup]?, browserAccessStore: BrowserAccessStore) {
        groupOverride = groups
        self.browserAccessStore = browserAccessStore
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

    // MARK: - Setup

    private func render() {
        guard isViewLoaded else { return }
        pageView?.removeFromSuperview()

        var sections: [NSView] = [
            SettingsUI.note(
                "Threading exposes these tools to the Claude and Codex sessions it launches, so an "
                + "agent can reach the app it is running inside. Turn a group off to hide its "
                + "tools from agents. Changes apply to sessions started afterwards."
            )
        ]

        for (index, group) in displayedGroups.enumerated() {
            sections.append(groupSection(group, index: index))
        }
        sections.append(websiteAccessSection())

        let enabled = displayedGroups.filter { MCPToolCatalog.isEnabled($0) }.count
        let page = SettingsUI.page(
            title: "Tools",
            summary: L10n.format(
                "%lld of %lld tool groups enabled",
                Int64(enabled),
                Int64(displayedGroups.count)
            ),
            sections: sections,
            hostPage: .tools
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

    /// One group, folded: the switch and the group's size on the header, the per-tool
    /// documentation as detail rows only while unfolded.
    private func groupSection(_ group: MCPToolGroup, index: Int) -> NSView {
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
        var detailRows: [NSView] = []
        if expanded {
            detailRows = group.tools.map { tool in
                let content = toolRow(tool)
                // The tools stay listed when the group is off — the page is documentation
                // too — but read as inactive.
                content.alphaValue = enabled && available
                    ? 1
                    : ToolsPreferencesDefaults.disabledAlpha
                return SettingsUI.fullRow(content)
            }
        }

        let groupID = group.id
        return SettingsUI.disclosureCard(
            title: group.title,
            subtitle: group.summary,
            summary: toolCount(group.tools.count),
            control: toggle,
            isExpanded: expanded,
            accessibilityIdentifier: "settings.tools.group.\(groupID)",
            onToggle: { [weak self] nowExpanded in
                guard let self else { return }
                if nowExpanded {
                    self.expandedGroups.insert(groupID)
                } else {
                    self.expandedGroups.remove(groupID)
                }
                self.render()
            },
            detailRows: detailRows
        )
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
        let group = displayedGroups[sender.tag]
        AppSettings.shared.setToolGroup(group.id, enabled: sender.state == .on)
        // Rebuilt rather than dimmed in place: the header's count line and the page summary
        // both state enablement, and a wholesale rebuild is the page's one update path.
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

// MARK: - Tools Preferences Defaults

enum ToolsPreferencesDefaults {
    static let iconWidth: CGFloat = 20
    static let toolNameFontSize: CGFloat = 10.5
    static let disabledAlpha: CGFloat = 0.45
}
