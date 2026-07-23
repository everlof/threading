import AppKit

// MARK: - Settings UI Kit

/// Building blocks for the settings pages, so every page reads as one slick, consistent form in
/// the app's design language: grouped rounded cards of rows, quiet section captions, flat
/// controls. The modern macOS-Settings shape, expressed in `Design` tokens rather than stock
/// form chrome.
enum SettingsUI {

    /// A whole page: caption+card sections stacked in a flipped scroll view, top-aligned, so a
    /// short page sits at the top and a long one scrolls.
    static func page(_ sections: [NSView]) -> NSView {
        let stack = NSStackView(views: sections)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = Design.Spacing.large
        stack.translatesAutoresizingMaskIntoConstraints = false

        let document = SettingsFlippedView()
        document.addSubview(stack)

        let scrollView = NSScrollView()
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.automaticallyAdjustsContentInsets = false
        scrollView.documentView = document
        document.translatesAutoresizingMaskIntoConstraints = false

        NSLayoutConstraint.activate([
            document.topAnchor.constraint(equalTo: scrollView.contentView.topAnchor),
            document.leadingAnchor.constraint(equalTo: scrollView.contentView.leadingAnchor),
            document.trailingAnchor.constraint(equalTo: scrollView.contentView.trailingAnchor),

            stack.topAnchor.constraint(equalTo: document.topAnchor, constant: Design.Spacing.large),
            stack.leadingAnchor.constraint(equalTo: document.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: document.trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: document.bottomAnchor, constant: -Design.Spacing.large)
        ])

        // Every section fills the column, so cards and their rows share one width — otherwise a
        // card with no stretchy row (a lone field, a full-width preview) hugs its content and
        // sits narrower than the rest.
        for section in sections {
            section.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }

        return scrollView
    }

    /// A titled section: a quiet caption above a card. Pass nil to omit the caption.
    static func section(_ title: String?, _ content: NSView) -> NSView {
        var views: [NSView] = []
        if let title { views.append(caption(title)) }
        views.append(content)

        let stack = NSStackView(views: views)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = Design.Spacing.small
        content.translatesAutoresizingMaskIntoConstraints = false
        content.leadingAnchor.constraint(equalTo: stack.leadingAnchor).isActive = true
        content.trailingAnchor.constraint(equalTo: stack.trailingAnchor).isActive = true
        return stack
    }

    /// The heading for a page — larger than a caption, the one emphasised string.
    static func heading(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = Design.Typography.heading()
        label.textColor = Design.Text.label
        return label
    }

    static func caption(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text.uppercased())
        label.font = Design.Typography.caption()
        label.textColor = Design.Text.tertiary
        return label
    }

    /// Explanatory text beneath a card, in the secondary colour.
    static func note(_ text: String) -> NSTextField {
        let label = NSTextField(wrappingLabelWithString: text)
        label.font = Design.Typography.subheading()
        label.textColor = Design.Text.secondary
        return label
    }

    // MARK: - Rows

    /// A row inside a card: a title (with optional secondary line) leading, a control trailing.
    ///
    /// `subtitleField` hands back the secondary label so a caller whose subtitle changes — the
    /// App theme card, whose line describes the chosen theme — can update it in place rather
    /// than rebuild the row.
    static func row(
        title: String,
        subtitle: String? = nil,
        control: NSView? = nil,
        subtitleField: inout NSTextField?
    ) -> NSView {
        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.font = Design.Typography.body()
        titleLabel.textColor = Design.Text.label

        var labelViews: [NSView] = [titleLabel]
        if let subtitle {
            let sub = NSTextField(wrappingLabelWithString: subtitle)
            sub.font = Design.Typography.subheading()
            sub.textColor = Design.Text.secondary
            labelViews.append(sub)
            subtitleField = sub
        }

        let labels = NSStackView(views: labelViews)
        labels.orientation = .vertical
        labels.alignment = .leading
        labels.spacing = Design.Spacing.hairline

        let row = NSStackView()
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = Design.Spacing.medium
        row.addArrangedSubview(labels)

        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        row.addArrangedSubview(spacer)

        if let control {
            control.setContentHuggingPriority(.required, for: .horizontal)
            row.addArrangedSubview(control)
        }

        return padded(row)
    }

    /// The common case — no caller needs the subtitle back.
    static func row(title: String, subtitle: String? = nil, control: NSView? = nil) -> NSView {
        var ignored: NSTextField?
        return row(title: title, subtitle: subtitle, control: control, subtitleField: &ignored)
    }

    /// A control that spans the row's full width, such as a text field with a Choose button.
    static func fullRow(_ content: NSView) -> NSView {
        padded(content)
    }

    private static func padded(_ content: NSView) -> NSView {
        let container = NSView()
        content.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(content)

        NSLayoutConstraint.activate([
            content.topAnchor.constraint(equalTo: container.topAnchor, constant: Design.Spacing.medium),
            content.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -Design.Spacing.medium),
            content.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: Design.Spacing.inset),
            content.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -Design.Spacing.inset),
            container.heightAnchor.constraint(greaterThanOrEqualToConstant: SettingsUIDefaults.rowHeight)
        ])

        return container
    }

    // MARK: - Controls

    static func toggle(isOn: Bool, target: AnyObject, action: Selector) -> ThemedToggle {
        let control = ThemedToggle()
        control.state = isOn ? .on : .off
        control.target = target
        control.action = action
        return control
    }

    static func popUp(target: AnyObject, action: Selector, width: CGFloat = SettingsUIDefaults.controlWidth) -> ThemedPopUp {
        let popUp = ThemedPopUp()
        popUp.target = target
        popUp.action = action
        popUp.translatesAutoresizingMaskIntoConstraints = false
        popUp.widthAnchor.constraint(equalToConstant: width).isActive = true
        return popUp
    }

    static func textField(target: AnyObject, action: Selector, width: CGFloat = SettingsUIDefaults.controlWidth) -> ThemedTextField {
        let field = ThemedTextField()
        field.font = Design.Typography.body()
        field.target = target
        field.action = action
        field.translatesAutoresizingMaskIntoConstraints = false
        field.widthAnchor.constraint(equalToConstant: width).isActive = true
        return field
    }

    /// A quiet push button in the app's flat style.
    static func button(_ title: String, target: AnyObject, action: Selector) -> ThemedButton {
        let button = ThemedButton(title: title, target: target, action: action)
        button.translatesAutoresizingMaskIntoConstraints = false
        return button
    }
}

// MARK: - Settings Card

/// A rounded panel that stacks rows with hairline dividers between them — the container every
/// group of settings sits in.
final class SettingsCard: NSView {

    init(rows: [NSView]) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        applySurface(
            fill: Design.Surface.panel,
            radius: Design.Radius.panel,
            border: Design.Surface.border,
            glow: true
        )

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 0
        stack.translatesAutoresizingMaskIntoConstraints = false

        // The stack goes in first, so every anchor below shares an ancestor at activation —
        // constraining a view before it is in the hierarchy raises an exception AppKit swallows,
        // leaving the card silently unbuilt.
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor)
        ])

        for (index, row) in rows.enumerated() {
            if index > 0 {
                let divider = NSView()
                divider.wantsLayer = true
                divider.layer?.backgroundColor = Design.Surface.border.cgColor
                divider.translatesAutoresizingMaskIntoConstraints = false
                stack.addArrangedSubview(divider)
                NSLayoutConstraint.activate([
                    divider.heightAnchor.constraint(equalToConstant: 1),
                    divider.leadingAnchor.constraint(equalTo: stack.leadingAnchor, constant: Design.Spacing.inset),
                    divider.trailingAnchor.constraint(equalTo: stack.trailingAnchor)
                ])
            }

            row.translatesAutoresizingMaskIntoConstraints = false
            stack.addArrangedSubview(row)
            NSLayoutConstraint.activate([
                row.leadingAnchor.constraint(equalTo: stack.leadingAnchor),
                row.trailingAnchor.constraint(equalTo: stack.trailingAnchor)
            ])
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}

// MARK: - Flipped View

/// Top-left origin, so a short page anchors to the top of a tall scroll view.
final class SettingsFlippedView: NSView {
    override var isFlipped: Bool { true }
}

// MARK: - Settings UI Defaults

enum SettingsUIDefaults {
    static let rowHeight: CGFloat = 44
    static let controlWidth: CGFloat = 220
}
