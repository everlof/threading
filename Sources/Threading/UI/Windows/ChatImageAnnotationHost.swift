import AppKit

// MARK: - Chat Image Annotation Host

/// Where marks go when nobody else asked for them: into the chat.
///
/// The report sheet takes its own marks because it has a rail to put them in and a report to
/// write them into. Every *other* image in the app — an attachment, a chart the agent drew, a
/// browser baseline, a screenshot dropped in a moment ago — has no such owner, and the only
/// useful thing to do with "this bit, here, is wrong" is to tell the agent working on it.
///
/// **Handed over on close, not on every pin.** Marking is a sentence being composed: the third
/// pin often renames the first, and a handoff per click would put three versions of the same
/// picture in the composer. `MediaInspectorView` calls `inspectorDidClose` once, and only when
/// something was actually marked.
///
/// What arrives is what the user chose it to be: the picture **with the pins drawn into it**, so
/// the agent sees the marks where they were made, and the numbered notes **carrying each mark's
/// point in the image's own pixels**, so a reader measuring the file lands on the same spot. One
/// file rather than two — the original is still on disk and named in the same message.
@MainActor
final class ChatImageAnnotationHost: MediaInspectorAnnotationHost {

    /// Which session the marks are for, asked at the moment they are handed over rather than
    /// captured when the inspector opened: the user may have changed rows while looking at a
    /// picture, and the chat they are looking at now is the one they mean.
    private let sessionID: () -> SessionID?

    /// The marks for the picture currently open, keyed by file so arrowing along a collection
    /// and back does not lose them. Bounded by the inspector's own lifetime — the whole map goes
    /// when this host does, which is when the overlay closes.
    private var annotationsByURL: [URL: [ImageAnnotation]] = [:]

    init(sessionID: @escaping () -> SessionID?) {
        self.sessionID = sessionID
    }

    /// Whether there is a chat to hand anything to. The inspector offers no annotation button
    /// when this answers false, because a mode whose result goes nowhere is worse than no mode.
    var canHandOff: Bool {
        guard let id = sessionID() else { return false }
        return SessionContextHandoff.canReceiveContext(for: id)
    }

    // MARK: - MediaInspectorAnnotationHost

    func annotations(for item: MediaInspectorItem) -> [ImageAnnotation] {
        annotationsByURL[item.url.standardizedFileURL] ?? []
    }

    func inspector(
        didChange annotations: [ImageAnnotation],
        for item: MediaInspectorItem,
        image: NSImage?
    ) {
        annotationsByURL[item.url.standardizedFileURL] = annotations
    }

    func inspectorDidClose(
        with annotations: [ImageAnnotation],
        for item: MediaInspectorItem,
        image: NSImage?
    ) {
        guard !annotations.isEmpty,
              let sessionID = sessionID(),
              SessionContextHandoff.canReceiveContext(for: sessionID),
              let image,
              let annotatedURL = ImageAnnotationFlattening.writeFlattenedPNG(
                  image,
                  annotations: annotations,
                  basedOn: item.url
              ) else { return }

        let notes = ImageAnnotationSummary.lines(annotations, imageSize: image.size)

        // The same shape the Attachments pane's **Add attachment to chat** uses, deliberately:
        // one provider-neutral reference, staged through the seam that answers for a native
        // conversation *and* a terminal. A second, image-only route would work on one surface
        // and silently do nothing on the other, which is the gap `SessionContextHandoff` exists
        // to have closed.
        SessionContextHandoff.stage(
            ConversationContextAttachment(
                kind: .comment,
                source: .attachment,
                title: annotatedURL.lastPathComponent,
                excerpt: annotatedURL.path,
                comment: notes.joined(separator: "\n"),
                locator: annotatedURL.path
            ),
            fileURL: annotatedURL,
            for: sessionID
        )

        EventLog.shared.record(.session, "Annotated an image into the chat", [
            "session": sessionID.uuidString,
            "marks": String(annotations.count)
        ])

        annotationsByURL.removeValue(forKey: item.url.standardizedFileURL)
    }
}
