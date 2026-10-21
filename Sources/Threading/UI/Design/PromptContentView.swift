import AppKit

/// The editor, attachment rail, and controls inside a prompt on both desktop hosts.
/// The host chooses those children; this view owns their order and sizing constraints.
@MainActor
final class PromptContentView: NSStackView {
    init(views: [NSView], attachments: NSView, editor: NSView, footer: NSView) {
        super.init(frame: .zero)
        PromptChrome.configureContentStack(self, views: views)
        NSLayoutConstraint.activate(PromptChrome.contentSizingConstraints(
            stack: self, attachments: attachments, editor: editor, footer: footer))
    }

    /// A prompt whose content reaches both horizontal insets. `PromptView` uses its own
    /// trailing anchor because an inline submit control can occupy that edge instead.
    func mount(in surface: NSView, verticalInset: CGFloat = PromptChrome.footerVerticalInset) {
        surface.addSubview(self)
        NSLayoutConstraint.activate([
            topAnchor.constraint(equalTo: surface.topAnchor, constant: verticalInset),
            bottomAnchor.constraint(equalTo: surface.bottomAnchor, constant: -verticalInset),
            leadingAnchor.constraint(equalTo: surface.leadingAnchor,
                                     constant: Design.Spacing.inset),
            trailingAnchor.constraint(equalTo: surface.trailingAnchor,
                                      constant: -Design.Spacing.inset)
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}
