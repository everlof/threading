import Foundation
import ThreadingRemoteKit

/// The identity of the projected row array, separate from live metadata such as streaming text.
/// A new conversation gets a new generation; exact row edits advance only its value. Remote
/// broadcasting can therefore prove that thousands of settled rows are unchanged without
/// comparing every one on each streaming frame.
struct RemoteConversationRowsRevision: Equatable, Sendable {
    let generation: UUID
    let value: Int
}

/// The provider-neutral state a remote mirror consumes from a live native conversation.
struct RemoteConversationProjection: Sendable {
    let snapshot: RemoteConversationSnapshotDTO
    let rowsRevision: RemoteConversationRowsRevision
}

/// The complete live-conversation capability required by Core's remote transport.
///
/// The mirror may observe a bounded provider-neutral projection and submit an already-authorized
/// prompt through the conversation's ordinary validation path. It does not acquire an AppKit
/// controller, view hierarchy, provider transport, or mutable timeline.
@MainActor
protocol RemoteConversationSurface: AnyObject {
    var isRunning: Bool { get }
    var remoteProjection: RemoteConversationProjection { get }

    func answerRemoteQuestion(id: String, answers: [String: String]?) -> Bool

    @discardableResult
    func sendRemotePrompt(
        _ text: String,
        context: [ConversationContextAttachment],
        authorization: RemoteAuthorization
    ) -> Bool
}

extension RemoteConversationSurface {
    func answerRemoteQuestion(id: String, answers: [String: String]?) -> Bool { false }

    var remoteSnapshot: RemoteConversationSnapshotDTO {
        remoteProjection.snapshot
    }
}
