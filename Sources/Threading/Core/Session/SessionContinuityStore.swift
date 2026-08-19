import Foundation

/// Device-local working state that belongs to an existing session rather than its transcript.
///
/// Drafts are written on every edit because they exist nowhere else. Viewport writes are
/// coalesced by the view controller; the store itself stays synchronous so teardown can flush
/// the final position before the controller is released.
@MainActor
final class SessionContinuityStore {

    static let shared = SessionContinuityStore()

    private var states: [SessionID: SessionContinuityState] = [:]
    private let persistence: RecoverableFileStore<SessionContinuityFile>

    init(directory: URL? = nil, fileManager: FileManager = .default) {
        let root = directory ?? fileManager
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(ProjectIconDefaults.applicationDirectoryName)
        persistence = RecoverableFileStore(
            url: root.appendingPathComponent(SessionContinuityDefaults.fileName),
            fileManager: fileManager,
            criticality: .userAuthored,
            sizePolicy: .userDocument
        )
        load()
    }

    func state(for sessionID: SessionID) -> SessionContinuityState {
        states[sessionID] ?? SessionContinuityState()
    }

    func setConversationDraft(
        _ draft: String,
        context: [ConversationContextAttachment] = [],
        for sessionID: SessionID
    ) {
        update(sessionID) { state in
            state.conversationDraft = draft.trimmingCharacters(in: .whitespacesAndNewlines)
                .isEmpty ? "" : draft
            state.conversationContext = ConversationContextPolicy.normalized(context)
        }
    }

    func setConversationViewport(
        progress: Double,
        followsBottom: Bool,
        for sessionID: SessionID
    ) {
        update(sessionID) { state in
            state.conversationViewportProgress = min(max(progress, 0), 1)
            state.conversationFollowsBottom = followsBottom
        }
    }

    // MARK: - Image annotations

    func imageAnnotationDocument(
        forAssetKey assetKey: String,
        in sessionID: SessionID
    ) -> ImageAnnotationDocument? {
        state(for: sessionID).imageAnnotationDocuments.values.first {
            $0.assetKeys.contains(assetKey)
        }
    }

    func imageAnnotationDocument(
        forContextAttachmentID contextAttachmentID: UUID,
        in sessionID: SessionID
    ) -> ImageAnnotationDocument? {
        state(for: sessionID).imageAnnotationDocuments.values.first {
            $0.contextAttachmentID == contextAttachmentID
        }
    }

    func imageAnnotationDocuments(in sessionID: SessionID) -> [ImageAnnotationDocument] {
        Array(state(for: sessionID).imageAnnotationDocuments.values)
    }

    func isImageAnnotationStaged(
        _ document: ImageAnnotationDocument,
        in sessionID: SessionID
    ) -> Bool {
        state(for: sessionID).conversationContext.contains {
            $0.id == document.contextAttachmentID
        }
    }

    /// Creates or updates the editable document for an image and returns only a committed value.
    /// Annotation edits advance the revision; discovering a stable attachment alias does not.
    @discardableResult
    func setImageAnnotations(
        _ annotations: [ImageAnnotation],
        assetKeys: [String],
        sourceAttachmentID: String?,
        sourcePath: String,
        title: String,
        in sessionID: SessionID
    ) -> ImageAnnotationDocument? {
        var state = states[sessionID] ?? SessionContinuityState()
        let keys = Array(Set(assetKeys)).sorted()
        let existing = state.imageAnnotationDocuments.values.first { document in
            !Set(document.assetKeys).isDisjoint(with: keys)
        }
        var document = existing ?? ImageAnnotationDocument(
            assetKeys: keys,
            sourceAttachmentID: sourceAttachmentID,
            sourcePath: sourcePath,
            title: title
        )

        let mergedKeys = Array(Set(document.assetKeys + keys)).sorted()
        let annotationsChanged = document.annotations != annotations
        document.assetKeys = mergedKeys
        document.sourceAttachmentID = sourceAttachmentID ?? document.sourceAttachmentID
        document.sourcePath = sourcePath
        document.title = title
        document.annotations = annotations
        if annotationsChanged { document.revision += 1 }

        guard existing != document else { return existing }
        document.updatedAt = Date()
        state.imageAnnotationDocuments[document.id.uuidString] = document
        state.updatedAt = document.updatedAt
        var candidate = states
        candidate[sessionID] = state
        guard commit(candidate) else { return existing }
        NotificationCenter.default.post(ImageAnnotationsDidChange(sessionID: sessionID))
        return document
    }

    @discardableResult
    func markImageAnnotationShared(
        documentID: UUID,
        revision: Int,
        attachmentID: String,
        in sessionID: SessionID
    ) -> ImageAnnotationDocument? {
        var state = states[sessionID] ?? SessionContinuityState()
        guard var document = state.imageAnnotationDocuments[documentID.uuidString] else {
            return nil
        }
        document.sharedRevision = revision
        document.sharedAttachmentID = attachmentID
        document.updatedAt = Date()
        state.imageAnnotationDocuments[documentID.uuidString] = document
        state.updatedAt = document.updatedAt
        var candidate = states
        candidate[sessionID] = state
        guard commit(candidate) else { return nil }
        NotificationCenter.default.post(ImageAnnotationsDidChange(sessionID: sessionID))
        return document
    }

    func clear(for sessionID: SessionID) {
        var candidate = states
        guard candidate.removeValue(forKey: sessionID) != nil else { return }
        _ = commit(candidate)
    }

    private func update(
        _ sessionID: SessionID,
        mutation: (inout SessionContinuityState) -> Void
    ) {
        var state = states[sessionID] ?? SessionContinuityState()
        let previous = state
        mutation(&state)
        guard state != previous else { return }
        state.updatedAt = Date()
        var candidate = states
        if state.isEmpty {
            candidate.removeValue(forKey: sessionID)
        } else {
            candidate[sessionID] = state
        }
        _ = commit(candidate)
    }

    private func load() {
        let outcome = persistence.load(
            defaultValue: SessionContinuityFile(states: [:])
        ) { stored in
            if let invalidID = stored.states.keys.first(where: {
                SessionID(uuidString: $0) == nil
            }) {
                throw SessionContinuityStoreError.invalidSessionIdentifier(invalidID)
            }
        }
        // Pruned on the way in, not written back: a file that grew before the bound existed
        // becomes small at the next mutation rather than costing a write at every launch.
        states = pruningPositions(
            outcome.value.states.reduce(into: [:]) { result, entry in
                guard let id = SessionID(uuidString: entry.key) else { return }
                result[id] = entry.value
            }
        )
    }

    /// Position-only records are disposable history; records holding unsent words or marks are
    /// not — the same rule `MobileSessionContinuityStore` applies to the same data.
    ///
    /// It belongs here rather than at the callers because the growth is not any one caller's:
    /// a reading position is written for every session that is ever scrolled, and nothing else
    /// in the app ever deletes one. Left unbounded on this machine it reached 7,163 records and
    /// 2.2 MB, and since every mutation rewrites, re-reads and re-verifies the whole file, one
    /// keystroke in a composer or an annotation note cost 47 ms. Bounded, the same keystroke
    /// costs about 2 ms. See [`performance.md`](../../../docs/architecture/performance.md).
    private func pruningPositions(
        _ candidate: [SessionID: SessionContinuityState]
    ) -> [SessionID: SessionContinuityState] {
        let positionOnly = candidate
            .filter { !$0.value.hasUserContent }
            .sorted { $0.value.updatedAt > $1.value.updatedAt }
        guard positionOnly.count > SessionContinuityDefaults.retainedPositionCount else {
            return candidate
        }
        var pruned = candidate
        for entry in positionOnly.dropFirst(SessionContinuityDefaults.retainedPositionCount) {
            pruned.removeValue(forKey: entry.key)
        }
        return pruned
    }

    /// This store carries unsent user text, so the verified file is the commit point. Keeping
    /// the prior in-memory value after failure also lets the standing composer continue to show
    /// what the next launch can actually recover.
    @discardableResult
    private func commit(_ unbounded: [SessionID: SessionContinuityState]) -> Bool {
        let candidate = pruningPositions(unbounded)
        let file = SessionContinuityFile(states: candidate.reduce(into: [:]) {
            $0[$1.key.uuidString] = $1.value
        })
        guard persistence.save(file) else { return false }
        states = candidate
        return true
    }
}

struct SessionContinuityState: Codable, Equatable {
    var conversationDraft = ""
    var conversationContext: [ConversationContextAttachment] = []
    var conversationViewportProgress: Double?
    var conversationFollowsBottom = true
    var imageAnnotationDocuments: [String: ImageAnnotationDocument] = [:]
    var updatedAt = Date()

    var isEmpty: Bool {
        !hasUserContent
            && conversationViewportProgress == nil
            && conversationFollowsBottom
    }

    /// Words or marks the user authored and has not sent, which no prune may take.
    var hasUserContent: Bool {
        !conversationDraft.isEmpty
            || !conversationContext.isEmpty
            || !imageAnnotationDocuments.isEmpty
    }

    private enum CodingKeys: String, CodingKey {
        case conversationDraft
        case conversationContext
        case conversationViewportProgress
        case conversationFollowsBottom
        case imageAnnotationDocuments
        case updatedAt
    }

    init() {}

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        conversationDraft = try values.decodeIfPresent(String.self, forKey: .conversationDraft) ?? ""
        conversationContext = try values.decodeIfPresent(
            [ConversationContextAttachment].self,
            forKey: .conversationContext
        ) ?? []
        conversationViewportProgress = try values.decodeIfPresent(
            Double.self,
            forKey: .conversationViewportProgress
        )
        conversationFollowsBottom = try values.decodeIfPresent(
            Bool.self,
            forKey: .conversationFollowsBottom
        ) ?? true
        imageAnnotationDocuments = try values.decodeIfPresent(
            [String: ImageAnnotationDocument].self,
            forKey: .imageAnnotationDocuments
        ) ?? [:]
        updatedAt = try values.decodeIfPresent(Date.self, forKey: .updatedAt) ?? Date()
    }
}

private struct SessionContinuityFile: Codable {
    var states: [String: SessionContinuityState]
}

private enum SessionContinuityStoreError: LocalizedError {
    case invalidSessionIdentifier(String)

    var errorDescription: String? {
        switch self {
        case .invalidSessionIdentifier(let value):
            return "session-continuity key '\(value)' is not a session identifier"
        }
    }
}

enum SessionContinuityDefaults {
    static let fileName = "session-continuity.json"
    static let viewportSaveDelay: TimeInterval = 0.25
    /// How many position-only records survive, newest first. The companion clients keep the
    /// same number of the same thing; see `MobileSessionContinuityStore`.
    static let retainedPositionCount = 250
}
