import Foundation
import ThreadingRemoteKit

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

/// Owns participant-scoped read receipts and their in-memory projection.
///
/// Reads are O(1) after one lazy load of the auxiliary SQLite tables. Each completion or visit
/// persists one session-sized record, rather than rewriting the project graph or a global JSON
/// blob whose cost would grow with every historical conversation.
@MainActor
final class SessionReadReceiptStore {

    static let shared = SessionReadReceiptStore()
    static let ownerParticipantID = RemoteCollaborationParticipantDTO.ownerID

    typealias Load = @MainActor () -> [SessionID: SessionReadReceiptState]?
    typealias Save = @MainActor (SessionReadReceiptState) -> Bool

    private let loadPersisted: Load
    private let savePersisted: Save
    private var states: [SessionID: SessionReadReceiptState]?

    init(stateManager: StateManager = .shared) {
        loadPersisted = { stateManager.sessionReadReceiptStates() }
        savePersisted = { stateManager.saveSessionReadReceiptState($0) }
    }

    /// Injectable persistence keeps identity and generation policy independently testable.
    init(load: @escaping Load, save: @escaping Save) {
        loadPersisted = load
        savePersisted = save
    }

    /// Records one new result and atomically marks it read for everybody currently viewing it.
    ///
    /// Participant ids are deduplicated before persistence. Two sockets for one person are one
    /// receipt, and all owner devices deliberately collapse to `ownerParticipantID`.
    @discardableResult
    func recordAttention(
        for sessionID: SessionID,
        seenBy viewingParticipantIDs: Set<String>
    ) -> Bool {
        ensureLoaded()
        var state = states?[sessionID] ?? SessionReadReceiptState(sessionID: sessionID)

        // This cannot be reached in a human lifetime, but preserving the comparison invariant
        // is cheaper than allowing an overflowing counter to make every old receipt look newer.
        if state.completionGeneration == Int.max {
            state.completionGeneration = 1
            state.seenGenerationByParticipant.removeAll(keepingCapacity: true)
        } else {
            state.completionGeneration += 1
        }
        for participantID in viewingParticipantIDs where !participantID.isEmpty {
            state.seenGenerationByParticipant[participantID] = state.completionGeneration
        }

        states?[sessionID] = state
        // Keep the live projection useful if storage is temporarily refused. StateManager logs
        // and gates the failed durable write; a disk-full condition must not also lie in the UI.
        return savePersisted(state)
    }

    /// Advances one person's receipt through everything currently known for the conversation.
    /// Returns true only when the projected unread state changed.
    @discardableResult
    func acknowledge(sessionID: SessionID, participantID: String) -> Bool {
        guard !participantID.isEmpty else { return false }
        ensureLoaded()
        guard var state = states?[sessionID],
              state.hasUnread(for: participantID) else { return false }

        state.seenGenerationByParticipant[participantID] = state.completionGeneration
        states?[sessionID] = state
        _ = savePersisted(state)
        return true
    }

    func hasUnread(sessionID: SessionID, participantID: String) -> Bool {
        ensureLoaded()
        return states?[sessionID]?.hasUnread(for: participantID) == true
    }

    /// Applies a reader's receipt only to the one reader-specific state. Work, blocking asks,
    /// limits and dormancy are shared runtime facts and therefore always pass through unchanged.
    func project(
        _ activity: SessionActivity,
        sessionID: SessionID,
        participantID: String
    ) -> SessionActivity {
        switch activity {
        case .idle, .needsAttention:
            return hasUnread(sessionID: sessionID, participantID: participantID)
                ? .needsAttention
                : .idle
        case .dormant, .working, .readyWithBackgroundWork, .awaitingUser, .limitReached:
            return activity
        }
    }

    private func ensureLoaded() {
        guard states == nil else { return }
        states = loadPersisted() ?? [:]
    }
}
