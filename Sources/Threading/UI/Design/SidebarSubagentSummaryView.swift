import AppKit

final class SidebarSubagentSummaryView: NSView, ThemedComponent {
    private let label = NSTextField(labelWithString: "")

    init() {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        label.applyFont(.caption)
        label.textColor = Design.Text.secondary
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor),
            label.trailingAnchor.constraint(equalTo: trailingAnchor),
            label.topAnchor.constraint(equalTo: topAnchor),
            label.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
        setContentCompressionResistancePriority(.required, for: .horizontal)
        setAccessibilityIdentifier("sidebar.session.subagent-summary")
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func applyInk(on ground: NSColor) { label.textColor = Design.Text.on(ground).secondary }

    func configure(count: Int, working: Int, attention: Int, collapsed: Bool) {
        let countText = count == 1 ? L10n.string("1 subagent") : L10n.format("%lld subagents", Int64(count))
        let activity = attention > 0 ? L10n.format("%lld waiting", Int64(attention))
            : working > 0 ? L10n.format("%lld working", Int64(working)) : ""
        label.stringValue = collapsed && !activity.isEmpty ? activity : countText
        label.toolTip = [countText, activity].filter { !$0.isEmpty }.joined(separator: " · ")
        label.setAccessibilityLabel(label.toolTip)
    }
}
