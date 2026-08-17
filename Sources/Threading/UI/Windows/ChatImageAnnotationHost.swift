import AppKit

// MARK: - Chat Image Annotation Host

/// Makes ordinary inspector annotations durable and publishes them to chat only on request.
///
/// The editable document belongs to the session continuity store, not the inspector window.
/// Closing, reopening, or moving through a collection therefore changes no state. Sharing mints
/// an immutable flattened attachment revision and upserts one linked composer receipt.
@MainActor
final class ChatImageAnnotationHost: MediaInspectorAnnotationHost {

    let sessionID: SessionID
    private let continuity: SessionContinuityStore
    private let attachments: SessionAttachmentStore

    init(
        sessionID: SessionID,
        continuity: SessionContinuityStore = .shared,
        attachments: SessionAttachmentStore = .shared
    ) {
        self.sessionID = sessionID
        self.continuity = continuity
        self.attachments = attachments
    }

    var canHandOff: Bool { SessionContextHandoff.canReceiveContext(for: sessionID) }

    func annotations(for item: MediaInspectorItem) -> [ImageAnnotation] {
        document(for: item)?.annotations ?? []
    }

    func inspector(
        didChange annotations: [ImageAnnotation],
        for item: MediaInspectorItem,
        image: NSImage?
    ) {
        let existing = document(for: item)
        // Entering and leaving an untouched annotation mode must not promote arbitrary image
        // bytes into the session attachment store.
        guard existing != nil || !annotations.isEmpty else { return }

        let stableAttachment = stableAttachment(for: item, existing: existing)
        var keys = [ImageAnnotationAssetKey.file(item.url)]
        if let id = item.annotationAssetID ?? stableAttachment?.id ?? existing?.sourceAttachmentID {
            keys.append(ImageAnnotationAssetKey.attachment(id))
        }
        let sourceURL = stableAttachment?.url
            ?? existing?.sourceAttachmentID.flatMap {
                attachments.attachment(for: sessionID, id: $0)?.url
            }
            ?? item.url
        _ = continuity.setImageAnnotations(
            annotations,
            assetKeys: keys,
            sourceAttachmentID: item.annotationAssetID
                ?? stableAttachment?.id
                ?? existing?.sourceAttachmentID,
            sourcePath: sourceURL.path,
            title: item.title,
            in: sessionID
        )
    }

    func sharingState(for item: MediaInspectorItem) -> ImageAnnotationSharingState {
        guard let document = document(for: item) else { return .local }
        let staged = continuity.isImageAnnotationStaged(document, in: sessionID)
        if staged {
            return document.sharedRevision == document.revision ? .currentInChat : .changedInChat
        }
        guard let sharedRevision = document.sharedRevision else { return .local }
        return sharedRevision == document.revision ? .shared : .changedSinceShared
    }

    func showsChatActions(for item: MediaInspectorItem) -> Bool { true }

    func canShareAnnotations(for item: MediaInspectorItem) -> Bool { canHandOff }

    func inspectorDidRequestShare(for item: MediaInspectorItem, image: NSImage?) {
        guard let document = document(for: item) else { return }
        _ = ImageAnnotationChatHandoff.stage(document, image: image, for: sessionID)
    }

    func inspectorDidRequestRemoveFromChat(for item: MediaInspectorItem) {
        guard let document = document(for: item) else { return }
        _ = ImageAnnotationChatHandoff.removeFromChat(document, for: sessionID)
    }

    private func document(for item: MediaInspectorItem) -> ImageAnnotationDocument? {
        if let id = item.annotationAssetID,
           let document = continuity.imageAnnotationDocument(
               forAssetKey: ImageAnnotationAssetKey.attachment(id),
               in: sessionID
           ) {
            return document
        }
        return continuity.imageAnnotationDocument(
            forAssetKey: ImageAnnotationAssetKey.file(item.url),
            in: sessionID
        )
    }

    /// An image not already in the session's attachment collection is captured exactly once on
    /// its first mark. That makes reopening independent of a temporary source URL and exposes
    /// the editable work from the Attachments pane as soon as it exists.
    private func stableAttachment(
        for item: MediaInspectorItem,
        existing: ImageAnnotationDocument?
    ) -> SessionAttachment? {
        if let id = item.annotationAssetID ?? existing?.sourceAttachmentID {
            return attachments.attachment(for: sessionID, id: id)
        }
        return attachments.recordSnapshot(
            of: item.url,
            sessionID: sessionID,
            origin: .user,
            preferredName: item.title
        )
    }
}
