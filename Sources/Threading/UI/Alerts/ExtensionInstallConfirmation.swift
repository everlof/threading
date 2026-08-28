import AppKit

/// The one shipping confirmation built from an inspected extension package.
///
/// Settings imports and agent-assisted authoring deliberately share this builder so neither can
/// omit a disclosure that the other presents. The prompt remains call-site-owned because the two
/// entry points have distinct suppression policy identities.
@MainActor
enum ExtensionInstallConfirmation {
    static func request(
        for proposal: ExtensionInstallProposal,
        prompt: ConfirmationPrompt
    ) -> ConfirmationRequest {
        ConfirmationRequest(
            prompt: prompt,
            title: proposal.title,
            message: proposal.message,
            confirmTitle: proposal.acceptTitle,
            style: .informational,
            accessory: agentToolDisclosure(for: proposal)
        )
    }

    /// Every accepted declaration remains visible without making the alert itself screen-tall.
    /// The SDK bounds the complete document; the viewport bounds the sheet.
    private static func agentToolDisclosure(
        for proposal: ExtensionInstallProposal
    ) -> NSView? {
        guard !proposal.mcpTools.isEmpty else { return nil }

        let preview = ThemedSurfaceView()
        preview.frame = NSRect(x: 0, y: 0, width: 500, height: 140)
        preview.applySurface(
            fill: Design.Surface.controlResting,
            radius: .control,
            border: Design.Surface.border
        )

        let scroll = ThemedTextView.scrolling()
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.verticalScrollElasticity = .none
        preview.addSubview(scroll)

        let text = scroll.textView
        text.string = proposal.mcpToolDisclosure
        text.isEditable = false
        text.isSelectable = true
        text.isRichText = false
        text.importsGraphics = false
        text.allowsUndo = false
        text.applyFont(.body)
        text.textContainerInset = NSSize(
            width: Design.Spacing.small,
            height: Design.Spacing.small
        )
        text.setAccessibilityLabel(L10n.string("Agent tools"))

        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: preview.topAnchor, constant: Design.Spacing.tight),
            scroll.bottomAnchor.constraint(
                equalTo: preview.bottomAnchor,
                constant: -Design.Spacing.tight
            ),
            scroll.leadingAnchor.constraint(
                equalTo: preview.leadingAnchor,
                constant: Design.Spacing.tight
            ),
            scroll.trailingAnchor.constraint(
                equalTo: preview.trailingAnchor,
                constant: -Design.Spacing.tight
            )
        ])
        return preview
    }
}
