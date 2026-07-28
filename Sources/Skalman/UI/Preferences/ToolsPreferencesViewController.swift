import AppKit

/// The Tools page: what Skalman exposes to the agents it launches over MCP, grouped, with a
/// switch per group.
///
/// The switch is per group rather than per tool on purpose — several tools only make sense as a
/// set (clicking a page you never opened, activating a tab you never listed) — and each group
/// lists the tools it carries so the page doubles as documentation of what an agent can reach.
@MainActor
final class ToolsPreferencesViewController: NSViewController {

    // MARK: - Properties

    /// The tool rows of each group, kept so toggling the group can dim them together.
    private var toolRowsByGroup: [String: [NSView]] = [:]
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
        toolRowsByGroup.removeAll()

        var sections: [NSView] = [
            SettingsUI.heading("Tools"),
            SettingsUI.note(
                "Skalman exposes these tools to the Claude and Codex sessions it launches, so an "
                + "agent can reach the app it is running inside. Turn a group off to hide its "
                + "tools from agents. Changes apply to sessions started afterwards."
            )
        ]

        for (index, group) in displayedGroups.enumerated() {
            sections.append(groupSection(group, index: index))
        }
        sections.append(websiteAccessSection())

        let page = SettingsUI.page(sections, hostPage: .tools)
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

    private func groupSection(_ group: MCPToolGroup, index: Int) -> NSView {
        let enabled = MCPToolCatalog.isEnabled(group)
        let available = MCPToolCatalog.isAvailable(group)

        let toggle = ThemedToggle()
        toggle.state = enabled ? .on : .off
        toggle.isEnabled = available
        toggle.tag = index
        toggle.target = self
        toggle.action = #selector(groupToggled(_:))

        var rows: [NSView] = [
            SettingsUI.row(title: "Enabled", subtitle: group.summary, control: toggle)
        ]

        var toolViews: [NSView] = []
        for tool in group.tools {
            let content = toolRow(tool)
            toolViews.append(content)
            rows.append(SettingsUI.fullRow(content))
        }

        toolRowsByGroup[group.id] = toolViews
        applyEnabled(enabled && available, to: toolViews)

        return SettingsUI.section(group.title, SettingsCard(rows: rows))
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

        let detail = NSTextField(labelWithString: tool.detail)
        detail.applyFont(.subheading)
        detail.textColor = Design.Text.secondary
        detail.lineBreakMode = .byTruncatingTail

        let labels = NSStackView(views: [title, detail])
        labels.orientation = .vertical
        labels.alignment = .leading
        labels.spacing = Design.Spacing.hairline

        let name = NSTextField(labelWithString: tool.name)
        name.applyFont(.compactToolName)
        name.textColor = Design.Text.tertiary
        name.setContentHuggingPriority(.required, for: .horizontal)
        name.setContentCompressionResistancePriority(.required, for: .horizontal)

        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let row = NSStackView(views: [icon, labels, spacer, name])
        row.orientation = .horizontal
        row.alignment = .centerY
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
                subtitle: "Agents may use this origin in Skalman's signed-in browser.",
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
        let enabled = sender.state == .on
        AppSettings.shared.setToolGroup(group.id, enabled: enabled)
        applyEnabled(enabled, to: toolRowsByGroup[group.id] ?? [])
    }

    @objc private func revokeWebsiteAccess(_ sender: ThemedButton) {
        guard persistentOriginKeys.indices.contains(sender.tag) else { return }
        browserAccessStore.revoke(key: persistentOriginKeys[sender.tag])
        render()
    }

    @objc private func revokeAllWebsiteAccess() {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = L10n.string("Revoke Persistent Website Access?")
        alert.informativeText = L10n.string("""
            Agents will need to ask again before using these websites in Skalman's signed-in \
            browser. One-time grants are unaffected.
            """)
        alert.addButton(withTitle: L10n.string("Revoke All"))
        alert.addButton(withTitle: L10n.string("Cancel"))

        let decided: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            guard response == .alertFirstButtonReturn else { return }
            self?.browserAccessStore.revokeAll()
            self?.render()
        }
        if let window = view.window {
            alert.beginSheetModal(for: window, completionHandler: decided)
        } else {
            decided(alert.runModal())
        }
    }

    /// Dims a group's tool rows when it is off — the tools are still listed, since the page is
    /// documentation too, but read as inactive.
    private func applyEnabled(_ enabled: Bool, to views: [NSView]) {
        for view in views {
            view.alphaValue = enabled ? 1 : ToolsPreferencesDefaults.disabledAlpha
        }
    }
}

// MARK: - Tools Preferences Defaults

enum ToolsPreferencesDefaults {
    static let iconWidth: CGFloat = 20
    static let toolNameFontSize: CGFloat = 10.5
    static let disabledAlpha: CGFloat = 0.45
}
