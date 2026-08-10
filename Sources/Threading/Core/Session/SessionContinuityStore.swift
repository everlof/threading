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

    func setConversationDraft(_ draft: String, for sessionID: SessionID) {
        update(sessionID) { state in
            state.conversationDraft = draft.trimmingCharacters(in: .whitespacesAndNewlines)
                .isEmpty ? "" : draft
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

    func clear(for sessionID: SessionID) {
        var candidate = states
        guard candidate.removeValue(forKey: sessionID) != nil else { return }
        commit(candidate)
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
        commit(candidate)
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
        states = outcome.value.states.reduce(into: [:]) { result, entry in
            guard let id = SessionID(uuidString: entry.key) else { return }
            result[id] = entry.value
        }
    }

    /// This store carries unsent user text, so the verified file is the commit point. Keeping
    /// the prior in-memory value after failure also lets the standing composer continue to show
    /// what the next launch can actually recover.
    private func commit(_ candidate: [SessionID: SessionContinuityState]) {
        let file = SessionContinuityFile(states: candidate.reduce(into: [:]) {
            $0[$1.key.uuidString] = $1.value
        })
        guard persistence.save(file) else { return }
        states = candidate
    }
}

struct SessionContinuityState: Codable, Equatable {
    var conversationDraft = ""
    var conversationViewportProgress: Double?
    var conversationFollowsBottom = true
    var updatedAt = Date()

    var isEmpty: Bool {
        conversationDraft.isEmpty
            && conversationViewportProgress == nil
            && conversationFollowsBottom
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
}
