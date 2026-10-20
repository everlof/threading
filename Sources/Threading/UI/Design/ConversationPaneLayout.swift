import AppKit

/// The standing transcript, status line, and reply column shared by the Mac and Linux hosts.
/// The host supplies its pane edge anchors and keeps ownership of transient rails and overlays.
@MainActor
enum ConversationPaneLayout {
    static func constraints(
        in root: NSView,
        transcript: NSView,
        status: NSView,
        composer: NSView,
        transcriptTop: NSLayoutConstraint,
        composerBottom: NSLayoutYAxisAnchor,
        columnCap: NSLayoutConstraint,
        columnWidth: NSLayoutConstraint
    ) -> [NSLayoutConstraint] {
        [
            transcriptTop,
            transcript.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            transcript.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            transcript.bottomAnchor.constraint(equalTo: status.topAnchor,
                                               constant: -Design.Spacing.small),
            status.leadingAnchor.constraint(equalTo: composer.leadingAnchor,
                                            constant: Design.Spacing.inset),
            status.trailingAnchor.constraint(equalTo: composer.trailingAnchor,
                                             constant: -Design.Spacing.inset),
            status.bottomAnchor.constraint(equalTo: composer.topAnchor,
                                           constant: -Design.Spacing.small),
            composer.centerXAnchor.constraint(equalTo: root.centerXAnchor),
            columnCap,
            columnWidth,
            composer.leadingAnchor.constraint(greaterThanOrEqualTo: root.leadingAnchor,
                                              constant: Design.Spacing.inset),
            composer.trailingAnchor.constraint(lessThanOrEqualTo: root.trailingAnchor,
                                               constant: -Design.Spacing.inset),
            composer.bottomAnchor.constraint(equalTo: composerBottom,
                                             constant: -Design.Spacing.inset)
        ]
    }
}
