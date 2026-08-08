import AppKit

// MARK: - Context Comment Alert

/// The one sheet that asks "what should change?" about a thing already on screen.
///
/// Every site that can stage context reaches it: a message, a diff line, a changed file, a
/// composer thumbnail, and the Attachments pane. Keeping the wording, the two affirmatives and
/// their chords in one place is the point — the alternative is five sheets that agree today and
/// answer Return differently in a year.
///
/// **Return holds it, ⌘Return sends it.** The two are the same decision at different urgencies,
/// which is exactly the pair `TextPromptRequest.immediateTitle` exists for: a comment usually
/// wants company — two more files, a sentence of framing — and sometimes is the whole turn.
/// Making the second one a chord rather than a second trip through the menu is what keeps this
/// cheaper than copying the path by hand, which is the only reason the feature is here.
///
/// It routes through `SessionContextHandoff` rather than through a conversation, so it answers
/// for a terminal session too. See that type for what a terminal is handed instead.
@MainActor
enum ContextCommentAlert {

    /// Asks, then hands the answer to whichever surface holds this session's input.
    ///
    /// `fileURL` is the attachment's file on disk, which only the terminal path needs — it is
    /// what a CLI reads as an attached image rather than as a line of path.
    static func request(
        on attachment: ConversationContextAttachment,
        preview: CodeContextPreview? = nil,
        fileURL: URL? = nil,
        for sessionID: SessionID
    ) {
        // Asked before the sheet, not after: a modal that collects a sentence and then discards
        // it because nothing was listening is worse than never opening.
        guard SessionContextHandoff.canReceiveContext(for: sessionID) else { return }

        let supportingView = preview.map(CodeContextPreviewView.init)
        switch TextPromptAlert.ask(
            makeRequest(for: attachment, preview: preview),
            supportingView: supportingView
        ) {
        case .text(let body):
            SessionContextHandoff.stage(
                attachment.commenting(body),
                fileURL: fileURL,
                for: sessionID
            )
        case .immediate(let body):
            SessionContextHandoff.send(
                attachment.commenting(body),
                fileURL: fileURL,
                for: sessionID
            )
        case .cleared, nil:
            break
        }
    }

    /// Built without being asked, so a test can read the wording and both affirmatives.
    static func makeRequest(
        for attachment: ConversationContextAttachment,
        preview: CodeContextPreview? = nil
    ) -> TextPromptRequest {
        TextPromptRequest(
            title: L10n.format("Comment on %@", attachment.title),
            message: preview == nil ? attachment.excerpt : nil,
            confirmTitle: L10n.string("Add to Chat"),
            immediateTitle: L10n.string("Send"),
            placeholder: L10n.string("What should change?"),
            fieldSize: NSSize(
                width: TextPromptDefaults.commentFieldWidth,
                height: TextPromptDefaults.fieldHeight
            )
        )
    }
}
