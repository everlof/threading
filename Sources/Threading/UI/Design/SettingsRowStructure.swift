import AppKit

/// The ordinary Settings row on both desktop hosts. The caller supplies state and actions;
/// this component owns the label column, adaptive control placement, and card insets.
@MainActor
enum SettingsRowStructure {
    static func make(title: String, subtitle: String?, control: NSView?,
                     helpButton: NSView? = nil) -> NSView {
        if let control, control.accessibilityLabel()?.isEmpty != false {
            control.setAccessibilityLabel(title)
        }
        let name = NSTextField(labelWithString: title)
        name.applyFont(.body)
        name.textColor = Design.Text.label
        name.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        name.lineBreakMode = .byTruncatingTail

        var labels: [NSView] = [helpButton.map { titleLine(name, helpButton: $0) } ?? name]
        if let subtitle { labels.append(wrappingSubtitle(subtitle)) }
        return assemble(labels, control: control)
    }

    static func titleLine(_ title: NSView, helpButton: NSView) -> NSView {
        let line = NSStackView(views: [title, helpButton])
        line.orientation = .horizontal
        line.alignment = .centerY
        line.distribution = .fill
        let inset = (helpButton as? OpticalInsetProviding)?.opticalHorizontalInset ?? 0
        line.spacing = max(0, Design.Spacing.small - inset)
        title.setContentHuggingPriority(.defaultLow, for: .horizontal)
        return line
    }

    static func assemble(_ labelViews: [NSView], highlighted: [NSView] = [],
                         control: NSView?) -> NSView {
        let labels = NSStackView(views: labelViews)
        labels.orientation = .vertical
        labels.alignment = .leading
        labels.spacing = Design.Spacing.hairline
        fill(labels)
        labels.setContentHuggingPriority(.defaultLow, for: .horizontal)
        for view in highlighted {
            view.trailingAnchor.constraint(lessThanOrEqualTo: labels.trailingAnchor).isActive = true
        }

        guard let control else {
            let row = NSStackView(views: [labels])
            row.orientation = .horizontal
            row.distribution = .fill
            return padded(row)
        }
        holdsItsWidth(control)
        return padded(SettingsAdaptiveControlRow(labels: labels, control: control))
    }

    static func wrappingSubtitle(_ text: String) -> NSTextField {
        let label = NSTextField(wrappingLabelWithString: text)
        label.applyFont(.subheading)
        label.textColor = Design.Text.secondary
        label.setContentHuggingPriority(.init(1), for: .horizontal)
        return label
    }

    static func fill(_ labels: NSStackView) {
        for view in labels.arrangedSubviews {
            guard let field = view as? NSTextField, field.cell?.wraps == true else { continue }
            let pin = field.widthAnchor.constraint(equalTo: labels.widthAnchor)
            pin.priority = NSLayoutConstraint.Priority(
                NSLayoutConstraint.Priority.defaultLow.rawValue + 1
            )
            let floor = field.widthAnchor.constraint(
                greaterThanOrEqualToConstant: SettingsAdaptiveControlMetrics.minimumTextWidth
            )
            floor.priority = .defaultHigh
            NSLayoutConstraint.activate([pin, floor])
        }
    }

    static func holdsItsWidth(_ control: NSView) {
        control.setContentHuggingPriority(.required, for: .horizontal)
        (control as? NSStackView)?.setHuggingPriority(.required, for: .horizontal)
    }

    static func padded(_ content: NSView) -> NSView {
        let container = NSView()
        content.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(content)
        let sideMargins = [
            content.leadingAnchor.constraint(equalTo: container.leadingAnchor,
                                             constant: Design.Spacing.inset),
            content.trailingAnchor.constraint(equalTo: container.trailingAnchor,
                                              constant: -Design.Spacing.inset)
        ]
        NSLayoutConstraint.activate(sideMargins + [
            content.topAnchor.constraint(equalTo: container.topAnchor,
                                           constant: Design.Spacing.medium),
            content.bottomAnchor.constraint(equalTo: container.bottomAnchor,
                                              constant: -Design.Spacing.medium),
            container.heightAnchor.constraint(greaterThanOrEqualToConstant: 44)
        ])
        container.holdAtContentInset(sideMargins)
        return container
    }
}
