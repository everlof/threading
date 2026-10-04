import AppKit

/// One reusable editor row. The host supplies reviewed values; this cell owns only presentation.
@MainActor
final class AppearancePackMemberCell: NSTableCellView {
    let toggle = ThemedToggle()
    private let title = NSTextField(labelWithString: "")
    private let detail = NSTextField(labelWithString: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        title.applyFont(.body)
        title.textColor = Design.Text.label
        detail.applyFont(.caption)
        detail.textColor = Design.Text.secondary
        title.lineBreakMode = .byTruncatingTail
        detail.lineBreakMode = .byTruncatingTail
        let labels = NSStackView(views: [title, detail])
        labels.orientation = .vertical
        labels.alignment = .leading
        labels.spacing = Design.Spacing.small
        for view in [labels, toggle] { view.translatesAutoresizingMaskIntoConstraints = false; addSubview(view) }
        NSLayoutConstraint.activate([
            labels.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Design.Spacing.small),
            labels.centerYAnchor.constraint(equalTo: centerYAnchor),
            labels.trailingAnchor.constraint(lessThanOrEqualTo: toggle.leadingAnchor, constant: -Design.Spacing.medium),
            toggle.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Design.Spacing.small),
            toggle.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configure(name: String, detail: String, selected: Bool, enabled: Bool) {
        title.stringValue = name
        self.detail.stringValue = detail
        self.detail.toolTip = detail
        toggle.state = selected ? .on : .off
        toggle.isEnabled = enabled || selected
        toggle.setAccessibilityLabel(L10n.format("Include %@ in pack", name))
    }
}
