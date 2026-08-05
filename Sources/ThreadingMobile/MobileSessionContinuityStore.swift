import Foundation

/// Private working state for remote sessions on this phone or tablet.
///
/// The Mac owns the transcript and session lifecycle. This store owns only what is meaningful
/// on one client: drafts, viewport positions, and the last route. Host identity is part of every
/// key because two Macs may use the same provider session identifier.
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
        var updatedAt = Date()

        var hasDraft: Bool { !conversationDraft.isEmpty || !terminalDraft.isEmpty }
        var isEmpty: Bool {
            !hasDraft
                && conversationViewportProgress == nil
                && conversationFollowsBottom
                && terminalViewportProgress == nil
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
        static let retainedPositionCount = 250
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
            var decoded = try JSONDecoder().decode(Archive.self, from: data)
            guard (decoded.version ?? 1) <= Defaults.archiveVersion else {
                archive = empty
                writesAllowed = false
                recoveryMessage = "Saved session state was created by a newer version."
                return
            }
            decoded.version = Defaults.archiveVersion
            archive = decoded
        } catch {
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

    func setActiveHostID(_ hostID: String?) {
        guard archive.activeHostID != hostID else { return }
        archive.activeHostID = hostID
        save()
    }

    func setLastRoute(hostID: String, sessionID: String) {
        let route = Route(hostID: hostID, sessionID: sessionID)
        guard archive.lastRoute != route else { return }
        archive.lastRoute = route
        save()
    }

    func clearLastRoute() {
        guard archive.lastRoute != nil else { return }
        archive.lastRoute = nil
        save()
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
        if state.isEmpty {
            archive.states.removeValue(forKey: storageKey)
        } else {
            archive.states[storageKey] = state
        }
        prunePositions()
        save()
    }

    /// Position-only records are disposable history; records containing unsent words are not.
    private func prunePositions() {
        let positionOnly = archive.states.filter { !$0.value.hasDraft }
            .sorted { $0.value.updatedAt > $1.value.updatedAt }
        guard positionOnly.count > Defaults.retainedPositionCount else { return }
        for entry in positionOnly.dropFirst(Defaults.retainedPositionCount) {
            archive.states.removeValue(forKey: entry.key)
        }
    }

    private func save() {
        guard writesAllowed else { return }
        archive.version = Defaults.archiveVersion
        guard let data = try? JSONEncoder().encode(archive) else {
            writesAllowed = false
            recoveryMessage = "Session state could not be encoded. New writes are paused."
            return
        }
        defaults.set(data, forKey: Defaults.archiveKey)
        guard defaults.data(forKey: Defaults.archiveKey) == data else {
            writesAllowed = false
            recoveryMessage = "Session state could not be saved. New writes are paused."
            return
        }
    }

    private func key(hostID: String, sessionID: String) -> String {
        "\(hostID.utf8.count):\(hostID)\(sessionID)"
    }

    private func clamp(_ value: Double) -> Double { min(max(value, 0), 1) }
}
