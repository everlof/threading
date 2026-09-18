import Foundation

/// Durable unread state for one conversation.
///
/// The completion generation belongs to the conversation. Read generations belong to people:
/// every owner device uses the same owner participant id, while an accepted collaborator keeps
/// the stable member id carried by `RemoteAuthorization`. Socket ids never enter this record.
struct SessionReadReceiptState: Equatable {
    let sessionID: SessionID
    var completionGeneration: Int
    var seenGenerationByParticipant: [String: Int]

    init(
        sessionID: SessionID,
        completionGeneration: Int = 0,
        seenGenerationByParticipant: [String: Int] = [:]
    ) {
        self.sessionID = sessionID
        self.completionGeneration = max(0, completionGeneration)
        self.seenGenerationByParticipant = seenGenerationByParticipant
    }

    func hasUnread(for participantID: String) -> Bool {
        completionGeneration > (seenGenerationByParticipant[participantID] ?? 0)
    }
}
