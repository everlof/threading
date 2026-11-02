import AppKit

/// The standing transcript, status line, and reply column shared by the Mac and Linux hosts.
/// The host supplies its pane edge anchors and keeps ownership of transient rails and overlays.
@MainActor
enum ConversationPaneLayout {
    /// The reply box includes the prompt's padding around the transcript reading column.
    static var composerWidth: CGFloat { Design.Chat.columnWidth + 2 * Design.Spacing.inset }

    /// A stale measured width must yield to the split pane's holding priority during resize.
    static let statedColumnPriority = NSLayoutConstraint.Priority(
        NSLayoutConstraint.Priority.defaultLow.rawValue + 1
    )

    /// The reply box's ceiling in a pane of `paneWidth`, on the same column the transcript takes.
    static func composerWidth(inPane paneWidth: CGFloat) -> CGFloat {
        Design.Chat.columnWidth(inPane: paneWidth) + 2 * Design.Spacing.inset
    }

    static func measuredComposerWidth(in paneWidth: CGFloat) -> CGFloat {
        min(composerWidth(inPane: paneWidth), paneWidth - 2 * Design.Spacing.inset)
    }

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
