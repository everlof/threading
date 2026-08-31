import Foundation

struct ConversationWindowRow: Identifiable, Hashable, Sendable {
    let id: SearchSourceRecordID
    let kind: SearchHitKind
    let author: SearchAuthor?
    let title: String
    let body: String
    let timestamp: Date?
    let hasError: Bool
}

struct ConversationWindow: Hashable, Sendable {
    let projectID: ProjectID
    let sessionID: SessionID
    let sourceID: SearchSourceID
    let sourceGeneration: UInt64
    let rows: [ConversationWindowRow]
    let anchorRowID: SearchSourceRecordID
    let anchorMatch: SearchTextRange?
    let hasEarlier: Bool
    let hasLater: Bool
    let isArchived: Bool
}

enum ConversationWindowLoadError: Error, Equatable, Sendable {
    case resultNoLongerAvailable
    case sourceUnavailable
}

/// The shared entry point used by local navigation and the remote projection. SQLite and source
/// validation remain actor-owned by the transcript index; callers receive only bounded values.
final class ConversationWindowLoader: @unchecked Sendable {
    private let index: TranscriptSearchIndex

    init(index: TranscriptSearchIndex) {
        self.index = index
    }

    func load(
        centeredOn locator: SearchConversationLocator,
        radius: Int = 40
    ) async throws -> ConversationWindow {
        try await index.conversationWindow(centeredOn: locator, radius: radius)
    }
}
