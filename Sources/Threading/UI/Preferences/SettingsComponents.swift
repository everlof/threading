import AppKit
import ThreadingExtensionKit

// MARK: - Settings UI Kit

/// Building blocks for the settings pages, so every page reads as one slick, consistent form in
/// the app's design language: grouped rounded cards of rows, quiet section captions, flat
/// controls. The modern macOS-Settings shape, expressed in `Design` tokens rather than stock
/// form chrome.
@MainActor
enum SettingsUI {

    /// A whole page: caption+card sections stacked in a flipped scroll view, top-aligned, so a
    /// short page sits at the top and a long one scrolls.
    @MainActor
    static func page(
        _ sections: [NSView],
        hostPage: ExtensionHostSettingsPage? = nil
    ) -> NSView {
        let allSections = sections + (hostPage.map {
            ExtensionSettingsRenderer.hostSections(for: $0)
        } ?? [])
        let stack = NSStackView(views: allSections)
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

            // The column keeps `Design.Size.glowGutter` clear of the scroll view's edges: a
            // card's halo is a layer shadow, and the scroll view clips at its own bounds, so
            // a card pinned flush to them loses its glow on that side — cut off flat, while
            // the vertical spill survives in the section spacing. The top and bottom padding
            // double as the gutter for the first and last card.
            stack.topAnchor.constraint(equalTo: document.topAnchor, constant: Design.Spacing.large),
            stack.leadingAnchor.constraint(equalTo: document.leadingAnchor, constant: Design.Size.glowGutter),
            stack.trailingAnchor.constraint(equalTo: document.trailingAnchor, constant: -Design.Size.glowGutter),
            stack.bottomAnchor.constraint(equalTo: document.bottomAnchor, constant: -Design.Spacing.large)
        ])

        // Every section fills the column, so cards and their rows share one width — otherwise a
        // card with no stretchy row (a lone field, a full-width preview) hugs its content and
        // sits narrower than the rest.
        for section in allSections {
            section.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }

        return scrollView
    }

    /// A page under a fixed header: the title, an optional one-line summary and the page-level
    /// actions stay put while the sections scroll beneath them.
    ///
    /// Every page used to draw its title as the first row *inside* the scroll, so the one line
    /// saying where you are was the first thing to leave the screen — on the pages long enough
    /// to need it most. The header also gives a page's primary action (Import…, Rescan) a seat
    /// that does not scroll away with the content it acts on.
    @MainActor
    static func page(
        title: String,
        summary: String? = nil,
        actions: [NSView] = [],
        sections: [NSView],
        hostPage: ExtensionHostSettingsPage? = nil,
        localizes: Bool = true
    ) -> NSView {
        let container = NSView()
        container.translatesAutoresizingMaskIntoConstraints = false

        let header = pageHeader(
            title: title,
            summary: summary,
            actions: actions,
            localizes: localizes
        )
        let separator = SeparatorView()
        let scroll = page(sections, hostPage: hostPage)

        for view in [header, separator, scroll] {
            view.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(view)
        }

        NSLayoutConstraint.activate([
            header.topAnchor.constraint(
                equalTo: container.topAnchor,
                constant: Design.Spacing.large
            ),
            // The header's text lines up with the cards' own edge: the scroll column holds
            // `glowGutter` clear on either side, so the header holds the same.
            header.leadingAnchor.constraint(
                equalTo: container.leadingAnchor,
                constant: Design.Size.glowGutter
            ),
            header.trailingAnchor.constraint(
                equalTo: container.trailingAnchor,
                constant: -Design.Size.glowGutter
            ),

            separator.topAnchor.constraint(
                equalTo: header.bottomAnchor,
                constant: Design.Spacing.medium
            ),
            separator.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: container.trailingAnchor),

            scroll.topAnchor.constraint(equalTo: separator.bottomAnchor),
            scroll.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: container.bottomAnchor)
        ])

        return container
    }

    /// The fixed band above a page's scroll: title leading, actions trailing, the optional
    /// summary under the title in the secondary colour.
    private static func pageHeader(
        title: String,
        summary: String?,
        actions: [NSView],
        localizes: Bool
    ) -> NSView {
        var labelViews: [NSView] = [heading(title, localizes: localizes)]
        if let summary {
            let line = NSTextField(labelWithString: localized(summary, if: localizes))
            line.applyFont(.subheading)
            line.textColor = Design.Text.secondary
            line.lineBreakMode = .byTruncatingTail
            labelViews.append(line)
        }

        let labels = NSStackView(views: labelViews)
        labels.orientation = .vertical
        labels.alignment = .leading
        labels.spacing = Design.Spacing.hairline
        labels.setContentHuggingPriority(.defaultLow, for: .horizontal)

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

        return row
    }

    /// A collapsible card: a disclosure header carrying the section's name, an optional
    /// trailing summary, and one decision-level control, with the detail rows built in only
    /// while expanded.
    ///
    /// The caller keeps the expansion state (a view state, not a preference — Storage's fold
    /// set the pattern) and rebuilds its page on toggle, which is the idiom every settings page
    /// already follows for its own events.
    @MainActor
    static func disclosureCard(
        title: String,
        subtitle: String? = nil,
        summary: String? = nil,
        summaryColor: NSColor? = nil,
        control: NSView? = nil,
        isExpanded: Bool,
        localizes: Bool = true,
        accessibilityIdentifier: String? = nil,
        onToggle: @escaping (Bool) -> Void,
        detailRows: [NSView] = []
    ) -> NSView {
        let titleLabel = NSTextField(labelWithString: localized(title, if: localizes))
        titleLabel.applyFont(.body)
        titleLabel.textColor = Design.Text.label

        var labelViews: [NSView] = [titleLabel]
        if let subtitle {
            let sub = NSTextField(
                wrappingLabelWithString: localized(subtitle, if: localizes)
            )
            sub.applyFont(.subheading)
            sub.textColor = Design.Text.secondary
            labelViews.append(sub)
        }

        let labels = NSStackView(views: labelViews)
        labels.orientation = .vertical
        labels.alignment = .leading
        labels.spacing = Design.Spacing.hairline
        labels.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let content = NSStackView()
        content.orientation = .horizontal
        content.alignment = .centerY
        content.distribution = .fill
        content.spacing = Design.Spacing.medium
        content.addArrangedSubview(labels)

        if let summary {
            let trailing = NSTextField(labelWithString: localized(summary, if: localizes))
            trailing.applyFont(.subheading)
            trailing.textColor = summaryColor ?? Design.Text.secondary
            trailing.setContentHuggingPriority(.required, for: .horizontal)
            trailing.setContentCompressionResistancePriority(.required, for: .horizontal)
            content.addArrangedSubview(trailing)
        }

        let disclosure = ThemedDisclosureRow(content: content, isExpanded: isExpanded)
        disclosure.onToggle = onToggle
        disclosure.setAccessibilityLabel(localized(title, if: localizes))
        if let accessibilityIdentifier {
            disclosure.setAccessibilityIdentifier(accessibilityIdentifier)
        }

        let header: NSView
        if let control {
            let row = NSStackView()
            row.orientation = .horizontal
            row.alignment = .centerY
            row.distribution = .fill
            row.spacing = Design.Spacing.medium
            row.edgeInsets = NSEdgeInsets(
                top: 0, left: 0, bottom: 0, right: Design.Spacing.inset
            )
            disclosure.setContentHuggingPriority(.defaultLow, for: .horizontal)
            control.setContentHuggingPriority(.required, for: .horizontal)
            row.addArrangedSubview(disclosure)
            row.addArrangedSubview(control)
            header = row
        } else {
            header = disclosure
        }

        return SettingsCard(rows: [header] + (isExpanded ? detailRows : []))
    }

    /// A titled section: a quiet caption above a card. Pass nil to omit the caption.
    static func section(
        _ title: String?,
        _ content: NSView,
        localizesTitle: Bool = true
    ) -> NSView {
        var views: [NSView] = []
        if let title { views.append(caption(title, localizes: localizesTitle)) }
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
    static func heading(_ text: String, localizes: Bool = true) -> NSTextField {
        let label = NSTextField(labelWithString: localized(text, if: localizes))
        label.applyFont(.heading)
        label.textColor = Design.Text.label
        return label
    }

    static func caption(_ text: String, localizes: Bool = true) -> NSTextField {
        let label = NSTextField(
            labelWithString: localized(text, if: localizes).localizedUppercase
        )
        label.applyFont(.caption)
        label.textColor = Design.Text.tertiary
        return label
    }

    /// Explanatory text beneath a card, in the secondary colour.
    static func note(_ text: String, localizes: Bool = true) -> NSTextField {
        let label = NSTextField(
            wrappingLabelWithString: localized(text, if: localizes)
        )
        label.applyFont(.subheading)
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
        subtitleField: inout NSTextField?,
        localizes: Bool = true,
        highlighting query: String? = nil
    ) -> NSView {
        // A blank query is not a search, and neither is a whitespace one: both have to leave the
        // row exactly the plain row it would otherwise have been, or every ordinary settings page
        // pays for a highlight nobody asked for.
        let trimmed = query?.trimmingCharacters(in: .whitespacesAndNewlines)
        let query = (trimmed?.isEmpty == false) ? trimmed : nil

        let titleLabel = label(
            localized(title, if: localizes),
            role: .body,
            ink: { Design.Text.label },
            highlighting: query
        )

        var labelViews: [NSView] = [titleLabel]
        var highlighted: [NSView] = query == nil ? [] : [titleLabel]
        if let subtitle {
            let text = localized(subtitle, if: localizes)
            if let query {
                let sub = label(
                    text,
                    role: .subheading,
                    ink: { Design.Text.secondary },
                    highlighting: query
                )
                labelViews.append(sub)
                highlighted.append(sub)
            } else {
                let sub = NSTextField(wrappingLabelWithString: text)
                sub.applyFont(.subheading)
                sub.textColor = Design.Text.secondary
                labelViews.append(sub)
                subtitleField = sub
            }
        }

        return assemble(labelViews, highlighted, control: control)
    }

    /// One of a row's two lines: a plain label, or a `SearchMatchLabel` when the row is being
    /// shown as a search result and has to say which of its words the query accounts for.
    ///
    /// The highlighted line does not wrap where the plain subtitle does, and the difference is
    /// the content rather than an oversight: a settings page's subtitle is a sentence explaining
    /// a control, while a result's is a short list of the terms that matched. A list is better
    /// truncated than run onto a second line under a row the reader is scanning past.
    private static func label(
        _ text: String,
        role: Design.FontRole,
        ink: @escaping () -> NSColor,
        highlighting query: String?
    ) -> NSView {
        guard let query else {
            let label = NSTextField(labelWithString: text)
            label.applyFont(role)
            label.textColor = ink()
            return label
        }

        let label = SearchMatchLabel(role: role, ink: ink)
        label.show(text, matching: query)
        return label
    }

    /// The row's geometry, shared by both paths above so a highlighted row and a plain one
    /// cannot drift apart.
    private static func assemble(
        _ labelViews: [NSView],
        _ highlighted: [NSView],
        control: NSView?
    ) -> NSView {
        let labels = NSStackView(views: labelViews)
        labels.orientation = .vertical
        labels.alignment = .leading
        labels.spacing = Design.Spacing.hairline

        // The labels take the row's slack, rather than a spacer taking it.
        //
        // A wrapping subtitle has no intrinsic *width* — the trap this project has already hit
        // once — so it cannot argue for any. Against a spacer that was willing to grow, it lost
        // every time and collapsed to its narrowest wrap: measured, the App theme row's
        // description wrapped to the same six lines at 420pt and at 620pt, with most of the row
        // empty beside it. The control still sits trailing, because the row fills its width
        // either way; what changed is which view absorbs what is left over.
        labels.setContentHuggingPriority(.defaultLow, for: .horizontal)

        // A highlighted line is single-line where the plain subtitle wraps, so it *has* an
        // intrinsic width and will happily claim more of the row than there is. Capping it at the
        // label column turns that claim back into a truncation — the same slack, spent the same
        // way, whether or not a search is running.
        for view in highlighted {
            view.trailingAnchor.constraint(lessThanOrEqualTo: labels.trailingAnchor).isActive = true
        }

        let row = NSStackView()
        row.orientation = .horizontal
        row.alignment = .centerY
        // `.gravityAreas` (the default) may leave unused room after the arranged views. That
        // is invisible with a long subtitle, whose fitting width happens to consume the row,
        // but a short title beside a fixed-width control clusters at the leading edge and wraps
        // its subtitle one word per line. `.fill` makes the low-hugging label column absorb the
        // row's slack and keeps the control on the trailing edge.
        row.distribution = .fill
        row.spacing = Design.Spacing.medium
        row.addArrangedSubview(labels)

        if let control {
            control.setContentHuggingPriority(.required, for: .horizontal)
            row.addArrangedSubview(control)
        }

        return padded(row)
    }

    /// The common case — no caller needs the subtitle back.
    static func row(
        title: String,
        subtitle: String? = nil,
        control: NSView? = nil,
        localizes: Bool = true,
        highlighting query: String? = nil
    ) -> NSView {
        var ignored: NSTextField?
        return row(
            title: title,
            subtitle: subtitle,
            control: control,
            subtitleField: &ignored,
            localizes: localizes,
            highlighting: query
        )
    }

    /// A control that spans the row's full width, such as a text field with a Choose button.
    static func fullRow(_ content: NSView) -> NSView {
        padded(content)
    }

    /// An explanatory row: a symbol, a title, and a wrapping detail line. No control.
    ///
    /// Two pages had grown their own copy of this — Remote Access's "Sharing & Security" and
    /// Privacy's attribution notes — and both copies carried the same layout bug, because the
    /// bug is in the shape rather than in either call site. A horizontal stack left on
    /// `.gravityAreas` does not assign its leftover width, and a wrapping label has no intrinsic
    /// width to claim it with; whether the row filled the card came down to whether the detail
    /// string happened to be long enough. Rendered side by side, two rows in one card wrapped
    /// into a third of the width while their neighbours spanned it.
    ///
    /// `.fill` plus the label column's low hugging names the view that absorbs the slack, which
    /// is the same fix `row(title:subtitle:control:)` documents one screen up.
    static func detailRow(
        symbol name: String,
        title: String,
        detail: String,
        localizes: Bool = true
    ) -> NSView {
        let image = NSImageView(image: symbolImage(name))
        image.imageScaling = .scaleProportionallyDown
        image.contentTintColor = Design.Text.secondary
        image.translatesAutoresizingMaskIntoConstraints = false

        let titleField = NSTextField(labelWithString: localized(title, if: localizes))
        titleField.applyFont(.body)
        titleField.textColor = Design.Text.label

        let detailField = NSTextField(
            wrappingLabelWithString: localized(detail, if: localizes)
        )
        detailField.applyFont(.subheading)
        detailField.textColor = Design.Text.secondary

        let labels = NSStackView(views: [titleField, detailField])
        labels.orientation = .vertical
        labels.alignment = .leading
        labels.spacing = Design.Spacing.hairline
        labels.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let row = NSStackView(views: [image, labels])
        row.orientation = .horizontal
        row.alignment = .top
        row.distribution = .fill
        row.spacing = Design.Spacing.medium

        NSLayoutConstraint.activate([
            image.widthAnchor.constraint(equalToConstant: Design.Symbol.control + 2),
            image.heightAnchor.constraint(equalTo: image.widthAnchor)
        ])
        return padded(row)
    }

    /// The settings pages' symbol, at the shared control size.
    static func symbolImage(_ name: String) -> NSImage {
        NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(Design.Symbol.configuration(Design.Symbol.control))
            ?? NSImage()
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
        field.applyFont(.body)
        field.target = target
        field.action = action
        field.translatesAutoresizingMaskIntoConstraints = false
        field.widthAnchor.constraint(equalToConstant: width).isActive = true
        return field
    }

    /// A quiet push button in the app's flat style.
    static func button(
        _ title: String,
        target: AnyObject,
        action: Selector,
        localizes: Bool = true
    ) -> ThemedButton {
        let button = ThemedButton(
            title: localized(title, if: localizes),
            target: target,
            action: action
        )
        button.translatesAutoresizingMaskIntoConstraints = false
        return button
    }

    private static func localized(_ text: String, if localizes: Bool) -> String {
        localizes ? L10n.string(text) : text
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
            radius: .panel,
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
                divider.applyLayerBackground(Design.Surface.border)
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
    static let wideSegmentedControlWidth: CGFloat = 380

    /// The width a settings page asks its pane for: the readable measure the cards keep,
    /// plus the halo gutter `SettingsUI.page` holds clear on either side. Stated here so the
    /// pane that caps the page and the render tests that draw it read one number.
    static var pageWidth: CGFloat { Design.Size.readableWidth + Design.Size.glowGutter * 2 }
}
