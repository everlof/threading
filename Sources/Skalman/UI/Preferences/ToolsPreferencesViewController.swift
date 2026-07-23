import AppKit

/// The Tools page: what Skalman exposes to the agents it launches over MCP, grouped, with a
/// switch per group.
///
/// The switch is per group rather than per tool on purpose — several tools only make sense as a
/// set (clicking a page you never opened, activating a tab you never listed) — and each group
/// lists the tools it carries so the page doubles as documentation of what an agent can reach.
final class ToolsPreferencesViewController: NSViewController {

    // MARK: - Properties

    /// The tool rows of each group, kept so toggling the group can dim them together.
    private var toolRowsByGroup: [String: [NSView]] = [:]

    // MARK: - Lifecycle

    override func loadView() {
        view = NSView()
        setupLayout()
    }

    // MARK: - Setup

    private func setupLayout() {
        var sections: [NSView] = [
            SettingsUI.heading("Tools"),
            SettingsUI.note(
                "Skalman exposes these tools to the Claude and Codex sessions it launches, so an "
                + "agent can reach the app it is running inside. Turn a group off to hide its "
                + "tools from agents. Changes apply to sessions started afterwards."
            )
        ]

        for (index, group) in MCPToolCatalog.groups.enumerated() {
            sections.append(groupSection(group, index: index))
        }

        let page = SettingsUI.page(sections)
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

        let toggle = ThemedToggle()
        toggle.state = enabled ? .on : .off
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
        applyEnabled(enabled, to: toolViews)

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
        title.font = Design.Typography.body()
        title.textColor = Design.Text.label

        let detail = NSTextField(labelWithString: tool.detail)
        detail.font = Design.Typography.subheading()
        detail.textColor = Design.Text.secondary
        detail.lineBreakMode = .byTruncatingTail

        let labels = NSStackView(views: [title, detail])
        labels.orientation = .vertical
        labels.alignment = .leading
        labels.spacing = Design.Spacing.hairline

        let name = NSTextField(labelWithString: tool.name)
        name.font = Design.Typography.compactToolName()
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

    // MARK: - Actions

    @objc private func groupToggled(_ sender: ThemedToggle) {
        let group = MCPToolCatalog.groups[sender.tag]
        let enabled = sender.state == .on
        AppSettings.shared.setToolGroup(group.id, enabled: enabled)
        applyEnabled(enabled, to: toolRowsByGroup[group.id] ?? [])
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
