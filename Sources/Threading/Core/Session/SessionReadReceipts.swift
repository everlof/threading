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

/// What the durable receipt ledger can prove for one participant.
///
/// `unknown` is deliberately not represented by `false`: a refused SQLite read or write must
/// never turn into an idle-looking row. Older presentation paths conservatively keep the
/// attention mark while newer wire clients can retain the distinction explicitly.
enum SessionAttentionProjection: Equatable {
    case read(completionGeneration: Int, seenGeneration: Int)
    case unread(completionGeneration: Int, seenGeneration: Int)
    case unknown
}

enum SessionReadReceiptPersistence: Equatable {
    case committed
    case unavailable
}

/// The complete outcome of one receipt mutation. Callers use `didChangeProjection` to publish
/// presentation and `persistence` to decide whether an acknowledgement may be claimed.
struct SessionReadReceiptMutationResult: Equatable {
    let didChangeProjection: Bool
    let persistence: SessionReadReceiptPersistence
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
    /// A failed load is not an empty ledger. Keep it distinct for this store's lifetime; the
    /// owning StateManager recovery replaces the process rather than blessing partial state.
    private var loadFailed = false
    /// A failed session-sized write leaves useful live state in memory, but none of its read/unread
    /// claims are durable until a later write succeeds.
    private var volatileSessionIDs = Set<SessionID>()

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
    func recordAttention(
        for sessionID: SessionID,
        seenBy viewingParticipantIDs: Set<String>
    ) -> SessionReadReceiptMutationResult {
        guard ensureLoaded() else {
            return SessionReadReceiptMutationResult(
                didChangeProjection: false,
                persistence: .unavailable
            )
        }
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
        if savePersisted(state) {
            volatileSessionIDs.remove(sessionID)
            return SessionReadReceiptMutationResult(
                didChangeProjection: true,
                persistence: .committed
            )
        }
        // Keep the new generation in memory so a later acknowledgement can retry the whole
        // session-sized record. Its projection remains unknown until that retry commits.
        volatileSessionIDs.insert(sessionID)
        return SessionReadReceiptMutationResult(
            didChangeProjection: true,
            persistence: .unavailable
        )
    }

    /// Advances one person's receipt through everything currently known for the conversation.
    /// The result separates a presentation change from proof that SQLite committed it.
    func acknowledge(
        sessionID: SessionID,
        participantID: String
    ) -> SessionReadReceiptMutationResult {
        guard !participantID.isEmpty, ensureLoaded() else {
            return SessionReadReceiptMutationResult(
                didChangeProjection: false,
                persistence: .unavailable
            )
        }
        let before = attention(sessionID: sessionID, participantID: participantID)
        guard var state = states?[sessionID] else {
            return SessionReadReceiptMutationResult(
                didChangeProjection: false,
                persistence: .committed
            )
        }
        let mustRetryVolatileWrite = volatileSessionIDs.contains(sessionID)
        guard state.hasUnread(for: participantID) || mustRetryVolatileWrite else {
            return SessionReadReceiptMutationResult(
                didChangeProjection: false,
                persistence: .committed
            )
        }

        state.seenGenerationByParticipant[participantID] = state.completionGeneration
        states?[sessionID] = state
        let persistence: SessionReadReceiptPersistence
        if savePersisted(state) {
            volatileSessionIDs.remove(sessionID)
            persistence = .committed
        } else {
            volatileSessionIDs.insert(sessionID)
            persistence = .unavailable
        }
        return SessionReadReceiptMutationResult(
            didChangeProjection: before != attention(
                sessionID: sessionID,
                participantID: participantID
            ),
            persistence: persistence
        )
    }

    func hasUnread(sessionID: SessionID, participantID: String) -> Bool {
        switch attention(sessionID: sessionID, participantID: participantID) {
        case .read: return false
        case .unread, .unknown: return true
        }
    }

    func attention(
        sessionID: SessionID,
        participantID: String
    ) -> SessionAttentionProjection {
        guard ensureLoaded(), !volatileSessionIDs.contains(sessionID) else { return .unknown }
        guard let state = states?[sessionID] else {
            return .read(completionGeneration: 0, seenGeneration: 0)
        }
        let seen = max(0, state.seenGenerationByParticipant[participantID] ?? 0)
        if state.hasUnread(for: participantID) {
            return .unread(
                completionGeneration: state.completionGeneration,
                seenGeneration: seen
            )
        }
        return .read(
            completionGeneration: state.completionGeneration,
            seenGeneration: seen
        )
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

    @discardableResult
    private func ensureLoaded() -> Bool {
        if states != nil { return true }
        if loadFailed { return false }
        guard let loaded = loadPersisted() else {
            loadFailed = true
            return false
        }
        states = loaded
        return true
    }
}
