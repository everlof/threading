import AppKit

/// Publishes one immutable annotation revision while leaving its editable document in continuity.
@MainActor
enum ImageAnnotationChatHandoff {

    @discardableResult
    static func stage(
        _ document: ImageAnnotationDocument,
        image suppliedImage: NSImage? = nil,
        for sessionID: SessionID
    ) -> Bool {
        guard !document.annotations.isEmpty,
              SessionContextHandoff.canReceiveContext(for: sessionID) else { return false }

        let sourceURL = document.sourceAttachmentID
            .flatMap { SessionAttachmentStore.shared.attachment(for: sessionID, id: $0)?.url }
            ?? URL(fileURLWithPath: document.sourcePath)
        guard let image = suppliedImage ?? BoundedImageDecoder.image(
            at: sourceURL,
            policy: .userMedia
        ) else { return false }

        let workspace = FileManager.default.temporaryDirectory
            .appendingPathComponent("threading-annotation-\(UUID().uuidString)", isDirectory: true)
        do {
            try FileManager.default.createDirectory(
                at: workspace,
                withIntermediateDirectories: true
            )
        } catch {
            return false
        }
        defer { try? FileManager.default.removeItem(at: workspace) }

        guard let flattenedURL = ImageAnnotationFlattening.writeFlattenedPNG(
            image,
            annotations: document.annotations,
            basedOn: URL(fileURLWithPath: document.title),
            directory: workspace
        ), let attachment = SessionAttachmentStore.shared.recordSnapshot(
            of: flattenedURL,
            sessionID: sessionID,
            origin: .user,
            preferredName: revisionName(for: document)
        ) else { return false }

        let notes = ImageAnnotationSummary.lines(
            document.annotations,
            imageSize: image.size
        )
        let revision = max(1, document.revision)
        let context = ConversationContextAttachment(
            id: document.contextAttachmentID,
            kind: .comment,
            source: .attachment,
            title: L10n.format("Annotations on %@ · revision %lld", document.title, Int64(revision)),
            excerpt: attachment.relativePath,
            comment: notes.joined(separator: "\n"),
            locator: attachment.relativePath
        )
        SessionContextHandoff.stage(context, fileURL: attachment.url, for: sessionID)
        _ = SessionContinuityStore.shared.markImageAnnotationShared(
            documentID: document.id,
            revision: document.revision,
            attachmentID: attachment.id,
            in: sessionID
        )

        EventLog.shared.record(.session, "Staged an image annotation revision", [
            "session": sessionID.uuidString,
            "marks": String(document.annotations.count),
            "revision": String(revision)
        ])
        return true
    }

    @discardableResult
    static func removeFromChat(
        _ document: ImageAnnotationDocument,
        for sessionID: SessionID
    ) -> Bool {
        SessionContextHandoff.remove(document.contextAttachmentID, for: sessionID)
    }

    private static func revisionName(for document: ImageAnnotationDocument) -> String {
        let base = URL(fileURLWithPath: document.title).deletingPathExtension().lastPathComponent
        return "\(base)-annotated-r\(max(1, document.revision)).png"
    }
}
