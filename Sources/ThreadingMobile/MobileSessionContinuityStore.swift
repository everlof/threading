import Foundation

/// Private working state for remote sessions on this phone or tablet.
///
/// The Mac owns the transcript and session lifecycle. This store owns only what is meaningful
/// on one client: drafts, viewport positions, terminal input preference, and the last route. Host
/// identity is part of every key because two Macs may use the same provider session identifier.
@MainActor
final class MobileSessionContinuityStore: ObservableObject {
    @Published private(set) var recoveryMessage: String?
    enum Surface: String, Codable {
        case conversation
        case terminal
    }

    struct Route: Codable, Equatable {
        let hostID: String
        let sessionID: String
    }

    struct SessionState: Codable, Equatable {
        var conversationDraft = ""
        var terminalDraft = ""
        var conversationViewportProgress: Double?
        var conversationFollowsBottom = true
        var terminalViewportProgress: Double?
        var terminalInputPreference: MobileTerminalInputPreference?
        /// Whether the terminal's keyboard was wanted up when the chat was last left, so it
        /// comes back the same way. Position-like: disposable, and never a user choice in
        /// itself.
        var terminalKeyboardWasUp: Bool?
        var updatedAt = Date()

        var hasDraft: Bool { !conversationDraft.isEmpty || !terminalDraft.isEmpty }
        var hasUserChoice: Bool { hasDraft || terminalInputPreference != nil }
        var isEmpty: Bool {
            !hasDraft
                && conversationViewportProgress == nil
                && conversationFollowsBottom
                && terminalViewportProgress == nil
                && terminalInputPreference == nil
                && terminalKeyboardWasUp == nil
        }
    }

    private struct Archive: Codable {
        var version: Int?
        var activeHostID: String?
        var lastRoute: Route?
        var states: [String: SessionState]
    }

    private enum Defaults {
        static let archiveKey = "threading.mobile.session-continuity.v1"
        static let archiveVersion = 1
        static let unreadableKeyPrefix = "threading.mobile.session-continuity.unreadable."
        static let maximumArchiveBytes = 1 * 1_024 * 1_024
        static let maximumStateCount = 512
        static let retainedPositionCount = 250
        static let maximumIdentifierBytes = 1_024
        static let maximumStorageKeyBytes = 2 * maximumIdentifierBytes + 32
        static let maximumDraftBytes = 256 * 1_024
        static let maximumAggregateStringBytes = 768 * 1_024
    }

    private let defaults: UserDefaults
    private var archive: Archive
    private var writesAllowed = true

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        recoveryMessage = nil
        let empty = Archive(
            version: Defaults.archiveVersion,
            activeHostID: nil,
            lastRoute: nil,
            states: [:]
        )
        guard let data = defaults.data(forKey: Defaults.archiveKey) else {
            archive = empty
            return
        }
        do {
            guard data.count <= Defaults.maximumArchiveBytes else {
                throw ValidationError.invalidArchive
            }
            var decoded = try JSONDecoder().decode(Archive.self, from: data)
            guard (decoded.version ?? 1) <= Defaults.archiveVersion else {
                archive = empty
                writesAllowed = false
                recoveryMessage = "Saved session state was created by a newer version."
                MobileDiagnostics.logDegraded(.continuityStorage, code: .newerFormat)
                return
            }
            decoded.version = Defaults.archiveVersion
            try Self.validate(decoded)
            archive = decoded
        } catch {
            MobileDiagnostics.logFailure(.continuityStorage, error: error)
            let recoveryKey = Defaults.unreadableKeyPrefix + UUID().uuidString.lowercased()
            defaults.set(data, forKey: recoveryKey)
            if defaults.data(forKey: recoveryKey) == data {
                defaults.removeObject(forKey: Defaults.archiveKey)
                archive = empty
                recoveryMessage = "An unreadable saved draft was preserved for recovery."
            } else {
                archive = empty
                writesAllowed = false
                recoveryMessage = "Saved drafts could not be read or preserved. New writes are paused."
            }
        }
    }

    var activeHostID: String? { archive.activeHostID }
    var lastRoute: Route? { archive.lastRoute }

    func state(hostID: String, sessionID: String) -> SessionState {
        archive.states[key(hostID: hostID, sessionID: sessionID)] ?? SessionState()
    }

    func draft(surface: Surface, hostID: String, sessionID: String) -> String {
        let state = state(hostID: hostID, sessionID: sessionID)
        return surface == .conversation ? state.conversationDraft : state.terminalDraft
    }

    func setDraft(_ draft: String, surface: Surface, hostID: String, sessionID: String) {
        update(hostID: hostID, sessionID: sessionID) { state in
            let value = draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? "" : draft
            if surface == .conversation {
                state.conversationDraft = value
            } else {
                state.terminalDraft = value
            }
        }
    }

    func setConversationViewport(
        progress: Double,
        followsBottom: Bool,
        hostID: String,
        sessionID: String
    ) {
        update(hostID: hostID, sessionID: sessionID) { state in
            state.conversationViewportProgress = clamp(progress)
            state.conversationFollowsBottom = followsBottom
        }
    }

    func setTerminalViewport(progress: Double, hostID: String, sessionID: String) {
        update(hostID: hostID, sessionID: sessionID) { state in
            state.terminalViewportProgress = clamp(progress)
        }
    }

    func setTerminalInputPreference(
        _ preference: MobileTerminalInputPreference,
        hostID: String,
        sessionID: String
    ) {
        update(hostID: hostID, sessionID: sessionID) { state in
            state.terminalInputPreference = preference
        }
    }

    func setTerminalKeyboardUp(_ isUp: Bool, hostID: String, sessionID: String) {
        update(hostID: hostID, sessionID: sessionID) { state in
            state.terminalKeyboardWasUp = isUp
        }
    }

    func setActiveHostID(_ hostID: String?) {
        guard archive.activeHostID != hostID else { return }
        var candidate = archive
        candidate.activeHostID = hostID
        save(candidate)
    }

    func setLastRoute(hostID: String, sessionID: String) {
        let route = Route(hostID: hostID, sessionID: sessionID)
        guard archive.lastRoute != route else { return }
        var candidate = archive
        candidate.lastRoute = route
        save(candidate)
    }

    func clearLastRoute() {
        guard archive.lastRoute != nil else { return }
        var candidate = archive
        candidate.lastRoute = nil
        save(candidate)
    }

    private func update(
        hostID: String,
        sessionID: String,
        mutation: (inout SessionState) -> Void
    ) {
        let storageKey = key(hostID: hostID, sessionID: sessionID)
        var state = archive.states[storageKey] ?? SessionState()
        let previous = state
        mutation(&state)
        guard state != previous else { return }
        state.updatedAt = Date()
        var candidate = archive
        if state.isEmpty {
            candidate.states.removeValue(forKey: storageKey)
        } else {
            candidate.states[storageKey] = state
        }
        prunePositions(in: &candidate)
        save(candidate)
    }

    /// Position-only records are disposable history; records containing unsent words or an
    /// explicit input choice are not.
    private func prunePositions(in candidate: inout Archive) {
        let positionOnly = candidate.states.filter { !$0.value.hasUserChoice }
            .sorted { $0.value.updatedAt > $1.value.updatedAt }
        guard positionOnly.count > Defaults.retainedPositionCount else { return }
        for entry in positionOnly.dropFirst(Defaults.retainedPositionCount) {
            candidate.states.removeValue(forKey: entry.key)
        }
    }

    private func save(_ candidate: Archive) {
        guard writesAllowed else { return }
        var candidate = candidate
        candidate.version = Defaults.archiveVersion
        do {
            try Self.validate(candidate)
        } catch {
            MobileDiagnostics.logFailure(.continuityStorage, code: .validation)
            recoveryMessage = "Session state exceeded its safe storage limits and was not changed."
            return
        }
        guard let data = try? JSONEncoder().encode(candidate),
              data.count <= Defaults.maximumArchiveBytes else {
            MobileDiagnostics.logFailure(.continuityStorage, code: .encode)
            recoveryMessage = "Session state exceeded its safe storage limit and was not changed."
            return
        }
        defaults.set(data, forKey: Defaults.archiveKey)
        guard defaults.data(forKey: Defaults.archiveKey) == data else {
            MobileDiagnostics.logFailure(.continuityStorage, code: .writeVerification)
            writesAllowed = false
            recoveryMessage = "Session state could not be saved. New writes are paused."
            return
        }
        archive = candidate
        recoveryMessage = nil
    }

    private func key(hostID: String, sessionID: String) -> String {
        "\(hostID.utf8.count):\(hostID)\(sessionID)"
    }

    private func clamp(_ value: Double) -> Double { min(max(value, 0), 1) }

    private enum ValidationError: Error {
        case invalidArchive
    }

    private static func validate(_ archive: Archive) throws {
        guard archive.states.count <= Defaults.maximumStateCount else {
            throw ValidationError.invalidArchive
        }

        var aggregateBytes = 0
        func count(_ value: String, maximum: Int) throws {
            let bytes = value.utf8.count
            guard !value.isEmpty, bytes <= maximum else {
                throw ValidationError.invalidArchive
            }
            let (total, overflow) = aggregateBytes.addingReportingOverflow(bytes)
            guard !overflow, total <= Defaults.maximumAggregateStringBytes else {
                throw ValidationError.invalidArchive
            }
            aggregateBytes = total
        }

        if let hostID = archive.activeHostID {
            try count(hostID, maximum: Defaults.maximumIdentifierBytes)
        }
        if let route = archive.lastRoute {
            try count(route.hostID, maximum: Defaults.maximumIdentifierBytes)
            try count(route.sessionID, maximum: Defaults.maximumIdentifierBytes)
        }
        for (storageKey, state) in archive.states {
            try count(storageKey, maximum: Defaults.maximumStorageKeyBytes)
            if !state.conversationDraft.isEmpty {
                try count(state.conversationDraft, maximum: Defaults.maximumDraftBytes)
            }
            if !state.terminalDraft.isEmpty {
                try count(state.terminalDraft, maximum: Defaults.maximumDraftBytes)
            }
            for progress in [state.conversationViewportProgress, state.terminalViewportProgress]
                .compactMap({ $0 }) {
                guard progress.isFinite, (0 ... 1).contains(progress) else {
                    throw ValidationError.invalidArchive
                }
            }
        }
    }
}
