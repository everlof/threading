import AppKit

/// One Settings page hierarchy for the macOS host and the Linux AppKit shim.
@MainActor
enum SettingsPageStructure {
    static func scrolling(_ sections: [NSView]) -> NSView {
        let stack = NSStackView(views: sections)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = Design.Spacing.large
        stack.translatesAutoresizingMaskIntoConstraints = false

        let document = SettingsFlippedView()
        document.addSubview(stack)

        let scrollView = ThemedScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.automaticallyAdjustsContentInsets = false
        scrollView.documentView = document
        document.translatesAutoresizingMaskIntoConstraints = false

        NSLayoutConstraint.activate([
            document.topAnchor.constraint(equalTo: scrollView.contentView.topAnchor),
            document.leadingAnchor.constraint(equalTo: scrollView.contentView.leadingAnchor),
            document.trailingAnchor.constraint(equalTo: scrollView.contentView.trailingAnchor),
            stack.topAnchor.constraint(equalTo: document.topAnchor,
                                       constant: Design.Spacing.large),
            stack.leadingAnchor.constraint(equalTo: document.leadingAnchor,
                                           constant: Design.Size.glowGutter),
            stack.trailingAnchor.constraint(equalTo: document.trailingAnchor,
                                            constant: -Design.Size.glowGutter),
            stack.bottomAnchor.constraint(equalTo: document.bottomAnchor,
                                          constant: -Design.Spacing.large)
        ])
        for section in sections {
            section.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
        return scrollView
    }

    static func section(caption: NSView?, content: NSView) -> NSView {
        let views = (caption.map { [$0] } ?? []) + [content]
        let stack = NSStackView(views: views)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = Design.Spacing.small
        content.translatesAutoresizingMaskIntoConstraints = false
        content.leadingAnchor.constraint(equalTo: stack.leadingAnchor).isActive = true
        content.trailingAnchor.constraint(equalTo: stack.trailingAnchor).isActive = true
        return stack
    }

    static func caption(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text.localizedUppercase)
        label.applyFont(.caption)
        label.textColor = Design.Text.tertiary
        return label
    }

    static func header(title: String, summary: String?, actions: [NSView])
        -> (view: NSView, summaryField: NSTextField?) {
        let heading = NSTextField(labelWithString: title)
        heading.applyFont(.heading)
        heading.textColor = Design.Text.label
        heading.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        var labelViews: [NSView] = [heading]
        var summaryField: NSTextField?
        if let summary {
            let line = NSTextField(labelWithString: summary)
            line.applyFont(.subheading)
            line.textColor = Design.Text.secondary
            line.lineBreakMode = .byTruncatingTail
            line.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            labelViews.append(line)
            summaryField = line
        }

        let labels = NSStackView(views: labelViews)
        labels.orientation = .vertical
        labels.alignment = .leading
        labels.spacing = Design.Spacing.hairline
        labels.setContentHuggingPriority(.defaultLow, for: .horizontal)
        labels.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let row = NSStackView()
        row.orientation = .horizontal
        row.alignment = .centerY
        row.distribution = .fill
        row.spacing = Design.Spacing.medium
        row.addArrangedSubview(labels)
        for action in actions {
            action.setContentHuggingPriority(.required, for: .horizontal)
            row.addArrangedSubview(action)
        }
        return (row, summaryField)
    }
}

/// The fixed title band above the scrolling Settings body.
final class SettingsPageView: NSView {
    private let summaryField: NSTextField?

    init(header: NSView, summaryField: NSTextField?, body: NSView) {
        self.summaryField = summaryField
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false

        let separator = SeparatorView()
        for child in [header, separator, body] {
            child.translatesAutoresizingMaskIntoConstraints = false
            addSubview(child)
        }

        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: topAnchor, constant: Design.Spacing.large),
            header.leadingAnchor.constraint(equalTo: leadingAnchor,
                                                   constant: Design.Size.glowGutter),
            header.trailingAnchor.constraint(equalTo: trailingAnchor,
                                                    constant: -Design.Size.glowGutter),
            separator.topAnchor.constraint(equalTo: header.bottomAnchor,
                                           constant: Design.Spacing.medium),
            separator.leadingAnchor.constraint(equalTo: leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: trailingAnchor),
            body.topAnchor.constraint(equalTo: separator.bottomAnchor),
            body.leadingAnchor.constraint(equalTo: leadingAnchor),
            body.trailingAnchor.constraint(equalTo: trailingAnchor),
            body.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
    }

    func updateSummary(_ text: String) {
        summaryField?.stringValue = text
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}

/// Top-left origin so a short Settings page remains at the top of its scroll view.
final class SettingsFlippedView: NSView {
    override var isFlipped: Bool { true }
}
