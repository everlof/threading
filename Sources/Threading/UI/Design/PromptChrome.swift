import AppKit

/// The prompt's shared anatomy. Hosts own the draft, attachments and submission policy;
/// this boundary owns the surface, footer, submit affordance and bounded text-height policy.
@MainActor
enum PromptChrome {
    nonisolated static let openingContentWidth: CGFloat = 720
    nonisolated static let openingMinimumHeight: CGFloat = 116
    static let openingColumnMeasurePriority = NSLayoutConstraint.Priority(240)
    static let openingColumnHuggingPriority = NSLayoutConstraint.Priority(1)
    nonisolated static let submitSize = Design.Size.compactSubmitHeight
    nonisolated static let restingLines: CGFloat = 2
    nonisolated static let verticalInset: CGFloat = 13
    nonisolated static let footerVerticalInset: CGFloat = Design.Spacing.medium
    nonisolated static let spacerPriority = NSLayoutConstraint.Priority(1)

    static func configureFooter(_ row: NSStackView, spacer: NSView) {
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = Design.Spacing.small
        row.detachesHiddenViews = true
        row.translatesAutoresizingMaskIntoConstraints = false
        spacer.translatesAutoresizingMaskIntoConstraints = false
        // The gap yields before any real control, including a compressible usage reading.
        spacer.setContentHuggingPriority(spacerPriority, for: .horizontal)
        spacer.setContentCompressionResistancePriority(spacerPriority, for: .horizontal)
        row.addArrangedSubview(spacer)
    }

    static func configureContentStack(_ stack: NSStackView, views: [NSView]) {
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = Design.Spacing.medium
        stack.detachesHiddenViews = true
        stack.translatesAutoresizingMaskIntoConstraints = false
        for view in views { stack.addArrangedSubview(view) }
    }

    static func contentSizingConstraints(stack: NSStackView, attachments: NSView,
                                         editor: NSView, footer: NSView) -> [NSLayoutConstraint] {
        [
            attachments.widthAnchor.constraint(equalTo: stack.widthAnchor),
            attachments.heightAnchor.constraint(
                equalToConstant: Design.Size.promptAttachmentThumbnail),
            editor.widthAnchor.constraint(equalTo: stack.widthAnchor),
            footer.widthAnchor.constraint(equalTo: stack.widthAnchor),
            footer.heightAnchor.constraint(equalToConstant: Design.Size.chipHeight)
        ]
    }

    /// Both opening hosts mount this same choice row and vertical content stack. The hosts
    /// supply controls and optional rows; the Design component owns their arrangement.
    static func configureOpeningChoices(_ row: NSStackView, choices: [NSView], spacer: NSView) {
        // The spacer yields below every control, taking any spare width instead of the chips.
        spacer.setContentHuggingPriority(spacerPriority, for: .horizontal)
        spacer.setContentCompressionResistancePriority(spacerPriority, for: .horizontal)
        row.setViews(choices + [spacer], in: .leading)
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = Design.Spacing.small
        row.translatesAutoresizingMaskIntoConstraints = false
    }

    static func configureOpeningColumn(_ column: NSStackView, choices: NSView,
                                       beforePrompt: [NSView] = [], prompt: NSView,
                                       actionRow: NSView) {
        column.setViews([choices] + beforePrompt + [prompt, actionRow], in: .leading)
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = Design.Spacing.medium
        column.translatesAutoresizingMaskIntoConstraints = false
    }

    /// Mount the opening column with the same edge and width constraints in both products.
    @discardableResult
    static func mountOpeningColumn(_ column: NSStackView, in root: NSView,
                                   prompt: NSView, actionRow: NSView) -> NSLayoutConstraint {
        root.addSubview(column)
        return constrainOpeningColumn(column, in: root,
                                      prompt: prompt, actionRow: actionRow)
    }

    /// The opening composer has the same bounded column in both hosts. Keep the optional
    /// pane-width measurement below the split view's holding priority, and the stack's own
    /// hugging below that measurement so its widest child cannot narrow the prompt.
    @discardableResult
    static func constrainOpeningColumn(_ column: NSStackView, in root: NSView,
                                       prompt: NSView, actionRow: NSView) -> NSLayoutConstraint {
        let measure = column.widthAnchor.constraint(
            equalTo: root.widthAnchor, constant: -2 * Design.Spacing.pane)
        measure.priority = openingColumnMeasurePriority
        column.setHuggingPriority(openingColumnHuggingPriority, for: .horizontal)
        let bottom = column.bottomAnchor.constraint(
            equalTo: root.bottomAnchor, constant: -Design.Spacing.pane)
        NSLayoutConstraint.activate([
            column.centerXAnchor.constraint(equalTo: root.centerXAnchor),
            bottom,
            measure,
            column.widthAnchor.constraint(lessThanOrEqualToConstant: openingContentWidth),
            column.leadingAnchor.constraint(greaterThanOrEqualTo: root.leadingAnchor,
                                            constant: Design.Spacing.pane),
            column.trailingAnchor.constraint(lessThanOrEqualTo: root.trailingAnchor,
                                             constant: -Design.Spacing.pane),
            prompt.widthAnchor.constraint(equalTo: column.widthAnchor),
            actionRow.widthAnchor.constraint(equalTo: column.widthAnchor)
        ])
        return bottom
    }

    static func contentInset(showsFooter: Bool) -> CGFloat {
        showsFooter ? footerVerticalInset : verticalInset
    }

    static func restingHeight(minimum: CGFloat, lineHeight: CGFloat, showsFooter: Bool,
                              spacing: CGFloat = Design.Spacing.medium) -> CGFloat {
        guard showsFooter else { return minimum }
        let text = (lineHeight * restingLines).rounded()
        return max(minimum, text + footerVerticalInset * 2 + Design.Size.chipHeight + spacing)
    }

    static func fittedHeight(textHeight: CGFloat, restingHeight: CGFloat, showsFooter: Bool,
                             spacing: CGFloat = Design.Spacing.medium,
                             attachmentHeight: CGFloat = 0, contextHeight: CGFloat = 0)
        -> (height: CGFloat, scrolls: Bool) {
        let chrome = contentInset(showsFooter: showsFooter) * 2
        let footer = showsFooter ? Design.Size.chipHeight + spacing : 0
        // The footer is already included in the resting height and ceiling. Attachments are
        // user content outside that allowance, so adding them never shrinks the text viewport.
        let textFloor = max(0, restingHeight - footer)
        let cap = max(Design.Size.inputMaxHeight - footer, textFloor)
        let fitted = min(max(textHeight + chrome, textFloor), cap)
        return (fitted + attachmentHeight + contextHeight + footer, fitted >= cap)
    }

    static func updateSubmit(_ button: ThemedButton, canSubmit: Bool, isStop: Bool) {
        button.image = NSImage(systemSymbolName: isStop ? DesignSymbols.stop : DesignSymbols.submit,
            accessibilityDescription: isStop ? L10n.string("Stop") : L10n.string("Start session"))
        button.isEnabled = isStop || canSubmit
        button.contentTintColor = isStop || canSubmit ? Design.Surface.accent : Design.Text.tertiary
    }

    static func applySurface(to view: NSView, fill: NSColor, emphasized: Bool) {
        if AppThemePalette.current.material(for: view.effectiveAppearance).fieldStyle == .outlined {
            view.applySurface(fill: fill, radius: .panel, border: Design.Surface.accent,
                borderWidth: emphasized ? Design.Accessibility.focusRingWidth + 1 : OutlinedField.borderWidth,
                glow: true, bevel: .none)
            return
        }
        view.applySurface(fill: fill, radius: .panel,
            border: emphasized ? Design.Surface.accent : Design.Surface.border,
            borderWidth: emphasized ? Design.Accessibility.focusRingWidth : Design.Radius.border,
            glow: true, bevel: .sunken)
    }
}
