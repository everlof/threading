import AppKit

/// The prompt's shared anatomy. Hosts own the draft, attachments and submission policy;
/// this boundary owns the surface, footer, submit affordance and bounded text-height policy.
@MainActor
enum PromptChrome {
    nonisolated static let openingContentWidth: CGFloat = 720
    nonisolated static let openingMinimumHeight: CGFloat = 116
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

    static func contentInset(showsFooter: Bool) -> CGFloat {
        showsFooter ? footerVerticalInset : verticalInset
    }

    /// Frame-based hosts use the same text/footer anatomy as PromptView's content stack.
    static func contentFrames(in bounds: CGRect) -> (editor: CGRect, footer: CGRect) {
        let inset = min(footerVerticalInset, bounds.height / 4)
        let width = max(1, bounds.width - Design.Spacing.inset * 2)
        let available = max(1, bounds.height - inset * 2)
        let footerHeight = min(Design.Size.chipHeight, max(0, available - 1))
        let gap = min(Design.Spacing.medium, max(0, available - footerHeight - 1))
        let footer = CGRect(x: Design.Spacing.inset, y: inset, width: width, height: footerHeight)
        let editor = CGRect(x: Design.Spacing.inset, y: footer.maxY + gap,
            width: width, height: max(1, available - footerHeight - gap))
        return (editor, footer)
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
