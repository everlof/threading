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
        request(on: [attachment], preview: preview, fileURL: fileURL, for: sessionID)
    }

    /// The same sheet over several receipts — one per contiguous run of a line selection with
    /// gaps. One question, one answer, staged on every run, so each receipt keeps an exact
    /// line range; the alternative was one receipt whose range had to lie about the gaps.
    static func request(
        on attachments: [ConversationContextAttachment],
        preview: CodeContextPreview? = nil,
        fileURL: URL? = nil,
        for sessionID: SessionID
    ) {
        // Asked before the sheet, not after: a modal that collects a sentence and then discards
        // it because nothing was listening is worse than never opening.
        guard !attachments.isEmpty,
              SessionContextHandoff.canReceiveContext(for: sessionID) else { return }

        let supportingView = preview.map(CodeContextPreviewView.init)
        let answer = TextPromptAlert.ask(
            makeRequest(for: attachments, preview: preview),
            supportingView: supportingView
        )
        apply(
            answer,
            to: attachments,
            fileURL: fileURL,
            for: sessionID,
            querying: SessionContextHandoff.liveDestinations
        )
    }

    /// Hands the sheet's answer over. Held, every receipt is staged. Sent, all but the last
    /// are staged and the last submits — the native composer sends whatever is staged with it,
    /// so the runs still travel as one turn rather than one turn each.
    static func apply(
        _ answer: TextPromptAlert.Answer?,
        to attachments: [ConversationContextAttachment],
        fileURL: URL? = nil,
        for sessionID: SessionID,
        querying destinations: any SessionContextDestinationQuerying
    ) {
        switch answer {
        case .text(let body):
            for attachment in attachments {
                SessionContextHandoff.stage(
                    attachment.commenting(body),
                    fileURL: fileURL,
                    for: sessionID,
                    querying: destinations
                )
            }
        case .immediate(let body):
            for attachment in attachments.dropLast() {
                SessionContextHandoff.stage(
                    attachment.commenting(body),
                    fileURL: fileURL,
                    for: sessionID,
                    querying: destinations
                )
            }
            if let last = attachments.last {
                SessionContextHandoff.send(
                    last.commenting(body),
                    fileURL: fileURL,
                    for: sessionID,
                    querying: destinations
                )
            }
        case .cleared, nil:
            break
        }
    }

    /// Built without being asked, so a test can read the wording and both affirmatives.
    static func makeRequest(
        for attachment: ConversationContextAttachment,
        preview: CodeContextPreview? = nil
    ) -> TextPromptRequest {
        makeRequest(for: [attachment], preview: preview)
    }

    static func makeRequest(
        for attachments: [ConversationContextAttachment],
        preview: CodeContextPreview? = nil
    ) -> TextPromptRequest {
        TextPromptRequest(
            title: L10n.format("Comment on %@", headline(for: attachments)),
            message: preview == nil ? attachments.first?.excerpt : nil,
            confirmTitle: L10n.string("Add to Chat"),
            immediateTitle: L10n.string("Send"),
            placeholder: L10n.string("What should change?"),
            fieldSize: NSSize(
                width: TextPromptDefaults.commentFieldWidth,
                height: TextPromptDefaults.fieldHeight
            )
        )
    }

    /// One receipt's title, or several receipts' shared path with every run's lines after it:
    /// `Foo.swift:3-5, 9, 12-14`. A batch without line numbers keeps the first title.
    static func headline(for attachments: [ConversationContextAttachment]) -> String {
        guard attachments.count > 1,
              let first = attachments.first,
              let path = first.locator else { return attachments.first?.title ?? "" }
        var parts: [String] = []
        for attachment in attachments {
            guard let start = attachment.lineStart else { return first.title }
            let end = attachment.lineEnd ?? start
            parts.append(end > start ? "\(start)-\(end)" : "\(start)")
        }
        return "\(path):" + parts.joined(separator: ", ")
    }
}
