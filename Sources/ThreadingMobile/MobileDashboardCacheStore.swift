import Foundation
import ThreadingRemoteKit

/// A small, presentation-only copy of the last dashboard returned for one exact pairing.
///
/// Pairing identity is intentional: `/api/me` is capability-filtered, so two memberships on the
/// same Mac must never share cached rows. Transient activity, availability, sharing and theme
/// payloads are omitted because none of those facts can truthfully survive a disconnect.
struct MobileDashboardCacheSnapshot: Codable, Equatable, Sendable {
    struct Session: Codable, Equatable, Sendable {
        let id: String
        let title: String
        let agentKind: String
        let surface: String
        let projectName: String
        let projectID: String?
        let lastActiveAt: Double?
        let isPinned: Bool
        let isArchived: Bool
        let archivedAt: Double?
        let snoozedAt: Double?
        let snoozedUntil: Double?
        let account: RemoteSessionAccountDTO?

        init(_ session: RemoteSessionSummaryDTO) {
            id = session.id
            title = session.title
            agentKind = session.agentKind
            surface = session.surface.rawValue
            projectName = session.projectName
            projectID = session.projectID
            lastActiveAt = session.lastActiveAt
            isPinned = session.isPinned
            isArchived = session.isArchived
            archivedAt = session.archivedAt
            snoozedAt = session.snoozedAt
            snoozedUntil = session.snoozedUntil
            account = session.account
        }

        var presentation: RemoteSessionSummaryDTO {
            RemoteSessionSummaryDTO(
                id: id,
                title: title,
                agentKind: agentKind,
                surface: RemoteSessionSurface(rawValue: surface),
                state: .idle,
                projectName: projectName,
                projectID: projectID,
                isAvailable: true,
                lastActiveAt: lastActiveAt,
                isPinned: isPinned,
                isArchived: isArchived,
                archivedAt: archivedAt,
                snoozedAt: snoozedAt,
                snoozedUntil: snoozedUntil,
                account: account
            )
        }
    }

    struct Terminal: Codable, Equatable, Sendable {
        let id: String
        let title: String
        let projectName: String
        let projectID: String?
        let createdAt: Double?

        init(_ terminal: RemoteProjectTerminalSummaryDTO) {
            id = terminal.id
            title = terminal.title
            projectName = terminal.projectName
            projectID = terminal.projectID
            createdAt = terminal.createdAt
        }

        var presentation: RemoteProjectTerminalSummaryDTO {
            RemoteProjectTerminalSummaryDTO(
                id: id,
                title: title,
                projectName: projectName,
                projectID: projectID,
                state: .idle,
                isAvailable: true,
                createdAt: createdAt
            )
        }
    }

    let capturedAt: Double
    let shareExpiresAt: Double?
    let sessions: [Session]
    let terminals: [Terminal]
    let archivedSessions: [Session]

    static func make(
        from response: RemoteMeDTO,
        capturedAt: Date = Date()
    ) -> MobileDashboardCacheSnapshot? {
        let active = response.sessions
        let archived = response.archivedSessions ?? []
        let terminals = response.terminals ?? []
        guard active.count <= MobileDashboardCacheStore.maximumSessionsPerList,
              archived.count <= MobileDashboardCacheStore.maximumSessionsPerList,
              terminals.count <= MobileDashboardCacheStore.maximumTerminals,
              active.count + archived.count + terminals.count
                  <= MobileDashboardCacheStore.maximumRows else { return nil }
        return Self(
            capturedAt: capturedAt.timeIntervalSince1970,
            shareExpiresAt: response.share.expiresAt,
            sessions: active.map(Session.init),
            terminals: terminals.map(Terminal.init),
            archivedSessions: archived.map(Session.init)
        )
    }

    func isUsable(at date: Date) -> Bool {
        guard let shareExpiresAt else { return true }
        return shareExpiresAt > date.timeIntervalSince1970
    }
}

/// The catalogue visible right now. Live data always replaces the cache atomically by stable id.
struct MobileDashboardCatalogue: Equatable, Sendable {
    enum Source: Equatable, Sendable {
        case live
        case cached(capturedAt: Date)
    }

    let source: Source
    let sessions: [RemoteSessionSummaryDTO]
    let terminals: [RemoteProjectTerminalSummaryDTO]
    let archivedSessions: [RemoteSessionSummaryDTO]
    private let shareExpiresAt: Date?

    var isLive: Bool { source == .live }
    var cachedAt: Date? {
        guard case let .cached(capturedAt) = source else { return nil }
        return capturedAt
    }

    func isUsable(at date: Date = Date()) -> Bool {
        guard let shareExpiresAt else { return true }
        return shareExpiresAt > date
    }

    static func current(
        live: RemoteMeDTO?,
        cached: MobileDashboardCacheSnapshot?,
        now: Date = Date()
    ) -> Self? {
        if let live {
            return Self(
                source: .live,
                sessions: live.sessions,
                terminals: live.terminals ?? [],
                archivedSessions: live.archivedSessions ?? [],
                shareExpiresAt: nil
            )
        }
        guard let cached, cached.isUsable(at: now) else { return nil }
        return Self(
            source: .cached(capturedAt: Date(timeIntervalSince1970: cached.capturedAt)),
            sessions: cached.sessions.map(\.presentation),
            terminals: cached.terminals.map(\.presentation),
            archivedSessions: cached.archivedSessions.map(\.presentation),
            shareExpiresAt: cached.shareExpiresAt.map(Date.init(timeIntervalSince1970:))
        )
    }

    func session(id: String) -> RemoteSessionSummaryDTO? {
        sessions.first { $0.id == id } ?? archivedSessions.first { $0.id == id }
    }

    func terminal(id: String) -> RemoteProjectTerminalSummaryDTO? {
        terminals.first { $0.id == id }
    }
}

/// Versioned, bounded optional launch memory. Encoding and validation stay actor-isolated so a
/// large host catalogue never turns the main actor into the reconnect bottleneck it is fixing.
actor MobileDashboardCacheStore {
    private struct Record: Codable, Equatable, Sendable {
        let identity: String
        let snapshot: MobileDashboardCacheSnapshot
    }

    private struct Archive: Codable, Equatable, Sendable {
        var version: Int?
        var records: [Record]
    }

    static let archiveKey = "threading.mobile.dashboard-cache.v1"
    static let unreadableKeyPrefix = "threading.mobile.dashboard-cache.unreadable."
    static let archiveVersion = 1
    static let maximumArchiveBytes = 4 * 1_024 * 1_024
    static let maximumRecordCount = 8
    static let maximumSessionsPerList = 2_000
    static let maximumTerminals = 1_000
    static let maximumRows = 5_000
    static let maximumIdentifierBytes = 1_024
    static let maximumStringBytes = 4 * 1_024
    static let maximumAggregateStringBytes = 2 * 1_024 * 1_024

    private let defaults: UserDefaults
    private var archive: Archive?
    private var writesAllowed = true
    private(set) var recoveryMessage: String?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    init(suiteName: String) {
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            preconditionFailure("Could not create dashboard cache test defaults")
        }
        self.defaults = defaults
    }

    /// Loads and validates on the store's executor. Cold-launch work scales with catalogue size,
    /// so neither JSON decoding nor row projection belongs in `RemoteAppModel.init`.
    func load(at now: Date = Date()) -> [String: MobileDashboardCacheSnapshot] {
        ensureLoaded()
        guard let archive else { return [:] }
        return Dictionary(uniqueKeysWithValues: archive.records.compactMap {
            $0.snapshot.isUsable(at: now) ? ($0.identity, $0.snapshot) : nil
        })
    }

    func loadCatalogues(at now: Date = Date()) -> [String: MobileDashboardCatalogue] {
        load(at: now).compactMapValues {
            MobileDashboardCatalogue.current(live: nil, cached: $0, now: now)
        }
    }

    private func ensureLoaded() {
        guard archive == nil else { return }
        let empty = Archive(version: Self.archiveVersion, records: [])
        guard let data = defaults.data(forKey: Self.archiveKey) else {
            archive = empty
            return
        }

        do {
            guard data.count <= Self.maximumArchiveBytes else {
                throw ValidationError.invalidArchive
            }
            var decoded = try JSONDecoder().decode(Archive.self, from: data)
            guard (decoded.version ?? 1) <= Self.archiveVersion else {
                archive = empty
                writesAllowed = false
                recoveryMessage = "Saved session lists were created by a newer version."
                return
            }
            decoded.version = Self.archiveVersion
            try Self.validate(decoded)
            archive = decoded
        } catch {
            let recoveryKey = Self.unreadableKeyPrefix + UUID().uuidString.lowercased()
            defaults.set(data, forKey: recoveryKey)
            guard defaults.data(forKey: recoveryKey) == data else {
                archive = empty
                writesAllowed = false
                recoveryMessage = "Saved session lists could not be preserved. Changes are paused."
                return
            }
            defaults.removeObject(forKey: Self.archiveKey)
            guard defaults.data(forKey: Self.archiveKey) == nil else {
                archive = empty
                writesAllowed = false
                recoveryMessage = "Saved session lists could not be cleared safely. Changes are paused."
                return
            }
            archive = empty
            recoveryMessage = "Unreadable saved session lists were preserved for recovery."
        }
    }

    @discardableResult
    func remember(_ snapshot: MobileDashboardCacheSnapshot, for identity: String) -> Bool {
        ensureLoaded()
        guard writesAllowed, let archive else { return false }
        if archive.records.first(where: { $0.identity == identity })?.snapshot == snapshot {
            return true
        }
        var records = archive.records.filter { $0.identity != identity }
        records.insert(Record(identity: identity, snapshot: snapshot), at: 0)
        if records.count > Self.maximumRecordCount {
            records.removeLast(records.count - Self.maximumRecordCount)
        }
        return commit(Archive(version: Self.archiveVersion, records: records))
    }

    @discardableResult
    func remove(identity: String) -> Bool {
        ensureLoaded()
        // Forget and authorization refusal are security boundaries. If this build cannot safely
        // rewrite a newer or otherwise write-disabled archive, discard the whole optional cache
        // rather than leave revoked rows for a future build to redisplay.
        guard writesAllowed else {
            defaults.removeObject(forKey: Self.archiveKey)
            guard defaults.data(forKey: Self.archiveKey) == nil,
                  removeQuarantinedArchives() else {
                recoveryMessage = "Saved session lists could not be cleared safely. Changes are paused."
                return false
            }
            archive = Archive(version: Self.archiveVersion, records: [])
            writesAllowed = true
            recoveryMessage = nil
            return true
        }
        guard let archive else { return false }
        let records = archive.records.filter { $0.identity != identity }
        if records.count != archive.records.count,
           !commit(Archive(version: Self.archiveVersion, records: records)) {
            return false
        }
        // A quarantined archive cannot be inspected well enough to remove one pairing. Security
        // deletion therefore clears every recovery copy owned by this optional cache.
        guard removeQuarantinedArchives() else {
            recoveryMessage = "Saved session lists could not be cleared safely. Changes are paused."
            return false
        }
        return true
    }

    func removeExpired(at date: Date = Date()) {
        ensureLoaded()
        guard writesAllowed, let archive else { return }
        let records = archive.records.filter { $0.snapshot.isUsable(at: date) }
        guard records.count != archive.records.count else { return }
        _ = commit(Archive(version: Self.archiveVersion, records: records))
    }

    private func commit(_ proposed: Archive) -> Bool {
        var candidate = proposed
        var data: Data?
        while data == nil {
            do {
                try Self.validate(candidate)
                if let encoded = try? JSONEncoder().encode(candidate),
                   encoded.count <= Self.maximumArchiveBytes {
                    data = encoded
                    break
                }
            } catch {
                // An invalid newest record will remain after all older records are evicted, then
                // fail without replacing the last-good archive. Aggregate/encoded size pressure,
                // by contrast, sheds least-recent records until the bounded archive fits.
            }
            guard candidate.records.count > 1 else {
                recoveryMessage = "Saved session lists exceeded their safe storage limit and were not changed."
                return false
            }
            candidate.records.removeLast()
        }
        guard let data else { return false }
        defaults.set(data, forKey: Self.archiveKey)
        guard defaults.data(forKey: Self.archiveKey) == data else {
            writesAllowed = false
            recoveryMessage = "Saved session lists could not be saved. Changes are paused."
            return false
        }
        archive = candidate
        recoveryMessage = nil
        return true
    }

    private func removeQuarantinedArchives() -> Bool {
        let keys = defaults.dictionaryRepresentation().keys.filter {
            $0.hasPrefix(Self.unreadableKeyPrefix)
        }
        for key in keys {
            defaults.removeObject(forKey: key)
        }
        return !defaults.dictionaryRepresentation().keys.contains {
            $0.hasPrefix(Self.unreadableKeyPrefix)
        }
    }

    private enum ValidationError: Error {
        case invalidArchive
    }

    private static func validate(_ archive: Archive) throws {
        guard archive.records.count <= maximumRecordCount,
              Set(archive.records.map(\.identity)).count == archive.records.count else {
            throw ValidationError.invalidArchive
        }
        var aggregateBytes = 0
        func count(_ value: String?, required: Bool = false, limit: Int = maximumStringBytes) throws {
            guard let value else {
                if required { throw ValidationError.invalidArchive }
                return
            }
            let bytes = value.utf8.count
            guard (!required || !value.isEmpty), bytes <= limit else {
                throw ValidationError.invalidArchive
            }
            let (total, overflow) = aggregateBytes.addingReportingOverflow(bytes)
            guard !overflow, total <= maximumAggregateStringBytes else {
                throw ValidationError.invalidArchive
            }
            aggregateBytes = total
        }
        func timestamp(_ value: Double?) throws {
            guard value == nil || value?.isFinite == true else {
                throw ValidationError.invalidArchive
            }
        }

        for record in archive.records {
            try count(record.identity, required: true, limit: maximumIdentifierBytes)
            let snapshot = record.snapshot
            guard snapshot.sessions.count <= maximumSessionsPerList,
                  snapshot.archivedSessions.count <= maximumSessionsPerList,
                  snapshot.terminals.count <= maximumTerminals,
                  snapshot.sessions.count + snapshot.archivedSessions.count
                      + snapshot.terminals.count <= maximumRows else {
                throw ValidationError.invalidArchive
            }
            try timestamp(snapshot.capturedAt)
            try timestamp(snapshot.shareExpiresAt)
            let sessionIDs = snapshot.sessions.map(\.id) + snapshot.archivedSessions.map(\.id)
            guard Set(sessionIDs).count == sessionIDs.count,
                  Set(snapshot.terminals.map(\.id)).count == snapshot.terminals.count else {
                throw ValidationError.invalidArchive
            }
            for session in snapshot.sessions + snapshot.archivedSessions {
                try count(session.id, required: true, limit: maximumIdentifierBytes)
                try count(session.title, required: true)
                try count(session.agentKind, required: true, limit: maximumIdentifierBytes)
                try count(session.surface, required: true, limit: maximumIdentifierBytes)
                try count(session.projectName)
                try count(session.projectID, limit: maximumIdentifierBytes)
                try timestamp(session.lastActiveAt)
                try timestamp(session.archivedAt)
                try timestamp(session.snoozedAt)
                try timestamp(session.snoozedUntil)
                try count(session.account?.name)
                try count(session.account?.glyph)
                if let hue = session.account?.hue,
                   !hue.isFinite || !(0 ... 1).contains(hue) {
                    throw ValidationError.invalidArchive
                }
            }
            for terminal in snapshot.terminals {
                try count(terminal.id, required: true, limit: maximumIdentifierBytes)
                try count(terminal.title, required: true)
                try count(terminal.projectName)
                try count(terminal.projectID, limit: maximumIdentifierBytes)
                try timestamp(terminal.createdAt)
            }
        }
    }
}

enum MobileDashboardCachePolicy {
    static func discardsSnapshot(after error: Error) -> Bool {
        switch RemoteConnectionAttempt.underlying(error) as? RemoteClientError {
        case .unauthorized:
            return true
        case let .server(status, _, _):
            return status == 401 || status == 403
        default:
            return false
        }
    }
}

enum MobileDashboardItemError: LocalizedError {
    case sessionUnavailable
    case terminalUnavailable

    var errorDescription: String? {
        switch self {
        case .sessionUnavailable:
            return MobileL10n.string("This session is no longer available on the Mac.")
        case .terminalUnavailable:
            return MobileL10n.string("This terminal is no longer available on the Mac.")
        }
    }
}
