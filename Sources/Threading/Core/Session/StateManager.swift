import Foundation

/// The result of attempting to restore the project store.
///
/// A failed load carries the quarantine location when the unreadable state was successfully
/// moved aside. Only that case is safe to follow with a new write.
enum ProjectsStateLoadResult {
    case missing
    case loaded(ProjectsState)
    case failed(quarantinedAt: URL?)
}

/// Whether this process may still treat the projects database as authoritative.
///
/// Once any operation says the database cannot be trusted, writes stay disabled for the rest
/// of the launch. A successful quarantine preserves the old bytes, but it does not turn the
/// empty in-memory state produced by a failed load into a valid replacement.
enum PersistenceHealth {
    case healthy
    case recoveryRequired(quarantinedAt: URL?)
}

/// Values that once appeared in a stored document and no longer exist in the model.
private enum LegacyKinds {
    static let shell = "shell"
}

private enum ProjectsStateLoadError: LocalizedError {
    case newerVersion(found: Int, current: Int)
    case missingMigration(from: Int)

    var errorDescription: String? {
        switch self {
        case .newerVersion(let found, let current):
            return "projects state version \(found) is newer than supported version \(current)"
        case .missingMigration(let version):
            return "no projects state migration exists from version \(version)"
        }
    }
}

/// Manages persistence of application and window state.
@MainActor
final class StateManager {

    // MARK: - Singleton

    static let shared = StateManager()

    private let fileManager: FileManager
    private let appSupportDirectoryOverride: URL?
    private let now: () -> Date

    private var openDatabase: ProjectDatabase?
    private var didAttemptPanelImport = false
    private(set) var persistenceHealth: PersistenceHealth = .healthy

    /// The auxiliary rows the last load could not decode, kept for the rest of the launch.
    ///
    /// This is the whole of the protection that used to be spelled "quarantine the database": a
    /// panel or attachment payload this build cannot read is reported to its feature as absent so
    /// the pane rebuilds, and refused to the writer so the stored bytes survive until a build that
    /// can read them opens the store.
    private var unreadableAuxiliaryRows = UnreadableAuxiliaryRows()

    /// Auxiliary rows successfully decoded since the last project-graph load.
    ///
    /// Validation moved from launch to first access so a chat that never opens a panel or an
    /// attachment list does not pay to decode them. Keeping the positive result avoids decoding
    /// the same panel again merely because its host saves several slices in one turn.
    private var readablePanelRows: Set<SessionID> = []
    private var readableAttachmentRows: Set<SessionID> = []

    /// Sessions already named in a refusal, so a pane that saves on every navigation says it once.
    private var reportedUnreadableWrites: Set<String> = []

    /// The injectable directory and clock keep persistence tests away from the user's real state.
    init(
        appSupportDirectory: URL? = nil,
        fileManager: FileManager = .default,
        now: @escaping () -> Date = Date.init
    ) {
        self.appSupportDirectoryOverride = appSupportDirectory
        self.fileManager = fileManager
        self.now = now
    }

    // MARK: - File Paths

    private var appSupportDirectory: URL {
        if let appSupportDirectoryOverride {
            ensureDirectoryExists(appSupportDirectoryOverride)
            return appSupportDirectoryOverride
        }

        let appSupport = fileManager.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support", isDirectory: true)
        let appDirectory = appSupport.appendingPathComponent("Threading")
        ensureDirectoryExists(appDirectory)
        return appDirectory
    }

    private func ensureDirectoryExists(_ directory: URL) {
        guard !fileManager.fileExists(atPath: directory.path) else { return }

        do {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            ThreadingLogger.agent.error(
                "Failed to create state directory: \(error.localizedDescription, privacy: .private(mask: .hash))"
            )
        }
    }

    private var sessionStateURL: URL {
        appSupportDirectory.appendingPathComponent("session-state.json")
    }

    private var projectsStateURL: URL {
        appSupportDirectory.appendingPathComponent("projects.json")
    }

    private var projectsBackupURL: URL {
        appSupportDirectory.appendingPathComponent("projects.json.bak")
    }

    // MARK: - Projects State Persistence

    @discardableResult
    func saveProjectsState(_ state: ProjectsState) -> Bool {
        guard writesAreAllowed(for: "projects state") else { return false }
        do {
            try database().save(state)
            return true
        } catch {
            ThreadingLogger.agent.error("Failed to save projects state: \(error.localizedDescription, privacy: .private(mask: .hash))")
            requireRecovery()
            return false
        }
    }

    /// Writes one project's own fields without touching its session rows.
    @discardableResult
    func saveProject(_ project: Project, position: Int) -> Bool {
        guard writesAreAllowed(for: "project") else { return false }
        do {
            try database().saveProject(project, position: position)
            return true
        } catch {
            ThreadingLogger.agent.error(
                "Failed to save project: \(error.localizedDescription, privacy: .private(mask: .hash))"
            )
            requireRecovery()
            return false
        }
    }

    /// Writes the selected row without rewriting the projects and sessions beside it.
    @discardableResult
    func saveSelectedSessionID(_ id: SessionID?) -> Bool {
        guard writesAreAllowed(for: "selected session") else { return false }
        do {
            try database().saveSelectedSessionID(id)
            return true
        } catch {
            ThreadingLogger.agent.error(
                "Failed to save selected session: \(error.localizedDescription, privacy: .private(mask: .hash))"
            )
            requireRecovery()
            return false
        }
    }

    /// Whether this launch has read the record of what was running at the last quit.
    ///
    /// **A launch that never read it must not write over it.** Writing an empty list over a real
    /// record is how a whole set of sessions stops coming back, and it does not take a crash: an
    /// app opened and quit again within a second — a rebuild-and-open cycle, a scripted launch,
    /// the second copy somebody starts by accident — relaunches nothing, has nothing running, and
    /// stamps "nothing was running" over the list the previous real quit left. Measured on this
    /// store: seventeen sessions live one evening, then twenty such launches, then none of them
    /// ever came back. `AppDelegate` reads this to leave an unspent record alone.
    private(set) var hasConsumedRunningSessionIDs = false

    /// Records which sessions held a live agent at quit, for the next launch to relaunch.
    @discardableResult
    func saveRunningSessionIDs(_ ids: [SessionID]) -> Bool {
        guard writesAreAllowed(for: "running sessions") else { return false }
        do {
            try database().saveRunningSessionIDs(ids)
            return true
        } catch {
            ThreadingLogger.agent.error(
                "Failed to save running sessions: \(error.localizedDescription, privacy: .private(mask: .hash))"
            )
            requireRecovery()
            return false
        }
    }

    /// The sessions recorded at the last quit, cleared as they are read.
    ///
    /// Consumed rather than kept, the same way `EventLog`'s launch marker is: only a clean quit
    /// rewrites the record, so a list that outlived the launch that read it would relaunch
    /// sessions the user has since closed the first time this launch fails to quit cleanly.
    func consumeRunningSessionIDs() -> [SessionID] {
        guard case .healthy = persistenceHealth else { return [] }
        do {
            let ids = try database().runningSessionIDs()
            if !ids.isEmpty {
                try database().saveRunningSessionIDs([])
            }
            hasConsumedRunningSessionIDs = true
            return ids
        } catch {
            ThreadingLogger.agent.error(
                "Failed to read running sessions: \(error.localizedDescription, privacy: .private(mask: .hash))"
            )
            requireRecovery()
            return []
        }
    }

    /// Restores the store, importing a legacy `projects.json` the first time.
    ///
    /// Three outcomes, and the contract is the one the JSON document had: a missing store starts
    /// fresh, a readable one loads, and an unreadable one is moved aside and reported — which is
    /// what lets `ProjectStore` refuse to write over state it could not read.
    func loadProjectsState() -> ProjectsStateLoadResult {
        if case .recoveryRequired(let quarantinedAt) = persistenceHealth {
            return .failed(quarantinedAt: quarantinedAt)
        }

        do {
            let database = try self.database()

            if try database.isEmpty(), fileManager.fileExists(atPath: projectsStateURL.path) {
                let result = try importLegacyProjectsState(into: database)
                if case .failed(let quarantinedAt) = result {
                    requireRecovery(quarantinedAt: quarantinedAt)
                }
                return result
            }

            let load = try database.load()
            record(load.unreadable)

            let state = load.state
            return state.projects.isEmpty && state.selectedSessionID == nil ? .missing : .loaded(state)
        } catch SQLiteDatabase.Failure.newerSchema(let found, let supported) {
            ThreadingLogger.agent.error(
                "Refusing projects database schema \(found, privacy: .public); this build supports \(supported, privacy: .public)"
            )
            closeDatabase()
            requireRecovery()
            return .failed(quarantinedAt: nil)
        } catch {
            ThreadingLogger.agent.error(
                "Failed to load projects state: \(error.localizedDescription, privacy: .private(mask: .hash))"
            )
            let quarantinedAt = quarantineDatabase()
            requireRecovery(quarantinedAt: quarantinedAt)
            return .failed(quarantinedAt: quarantinedAt)
        }
    }

    /// Reads the JSON document through the decoder and migration chain it always used, writes it
    /// into the database in one transaction, and renames it out of the way.
    ///
    /// It is *renamed, never deleted*. opencode's own move off per-file JSON is the cautionary
    /// tale — an update that recreated the directory without migrating took sessions with it —
    /// and a file still sitting there is a rollback that costs nothing to keep.
    private func importLegacyProjectsState(into database: ProjectDatabase) throws -> ProjectsStateLoadResult {
        let data: Data
        let state: ProjectsState
        do {
            data = try BoundedFileReader.read(
                projectsStateURL,
                maximumBytes: StateManagerDefaults.maximumLegacyProjectsBytes
            )
            state = try decodeAndMigrateProjectsState(from: data)
        } catch {
            ThreadingLogger.agent.error(
                "Legacy projects.json could not be read: \(error.localizedDescription, privacy: .private(mask: .hash))"
            )
            return .failed(quarantinedAt: quarantineProjectsState())
        }

        try database.save(state)
        retireLegacyProjectsState()

        ThreadingLogger.agent.info(
            "Imported \(state.projects.count, privacy: .public) projects from projects.json into the database"
        )
        return .loaded(state)
    }

    private func retireLegacyProjectsState() {
        let retiredURL = projectsStateURL.appendingPathExtension(SQLiteDefaults.migratedSuffix)
        if fileManager.fileExists(atPath: retiredURL.path) {
            do {
                try fileManager.removeItem(at: retiredURL)
            } catch {
                ThreadingLogger.agent.warning(
                    "Could not replace retired legacy projects state destination=\(retiredURL.path, privacy: .private(mask: .hash)): \(error.localizedDescription, privacy: .private(mask: .hash))"
                )
            }
        }
        do {
            try fileManager.moveItem(at: projectsStateURL, to: retiredURL)
        } catch {
            ThreadingLogger.agent.warning(
                "Could not retire imported legacy projects state source=\(self.projectsStateURL.path, privacy: .private(mask: .hash)): \(error.localizedDescription, privacy: .private(mask: .hash))"
            )
        }
        // The rolling backup described the document, not the database; it would only ever be
        // restored *over* an import that has already happened.
        if fileManager.fileExists(atPath: projectsBackupURL.path) {
            do {
                try fileManager.moveItem(
                    at: projectsBackupURL,
                    to: projectsBackupURL.appendingPathExtension(SQLiteDefaults.migratedSuffix)
                )
            } catch {
                ThreadingLogger.agent.warning(
                    "Could not retire legacy projects backup source=\(self.projectsBackupURL.path, privacy: .private(mask: .hash)): \(error.localizedDescription, privacy: .private(mask: .hash))"
                )
            }
        }
    }

    /// Reads the version before the full schema, refusing state from a newer app and routing
    /// older state through an explicit migration chain.
    private func decodeAndMigrateProjectsState(from data: Data) throws -> ProjectsState {
        struct VersionEnvelope: Decodable {
            let version: Int
        }

        let decoder = JSONDecoder()
        let storedVersion = try decoder.decode(VersionEnvelope.self, from: data).version
        guard storedVersion <= ProjectsStateVersion.current else {
            throw ProjectsStateLoadError.newerVersion(
                found: storedVersion,
                current: ProjectsStateVersion.current
            )
        }

        var migratedData = data
        var version = storedVersion
        while version < ProjectsStateVersion.current {
            migratedData = try migrateProjectsState(migratedData, from: version)
            version += 1
        }

        return try decoder.decode(ProjectsState.self, from: migratedData)
    }

    /// Migration seam for schema versions. Each case upgrades exactly one version.
    private func migrateProjectsState(_ data: Data, from version: Int) throws -> Data {
        switch version {
        case 1:
            return try dropShellSessions(from: data)
        default:
            throw ProjectsStateLoadError.missingMigration(from: version)
        }
    }

    /// Version 2 removed `AgentKind.shell`, so a version-1 document may name a kind that no
    /// longer decodes — and one undecodable session would otherwise fail the whole document.
    ///
    /// They are dropped rather than converted, because a shell session held nothing to convert:
    /// no transcript, no resume identifier, and scrollback that was never persisted. What is
    /// lost is a row in the sidebar, and every session gains a shell of its own in exchange.
    private func dropShellSessions(from data: Data) throws -> Data {
        guard var document = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let projects = document["projects"] as? [[String: Any]] else {
            throw ProjectsStateLoadError.missingMigration(from: 1)
        }

        var dropped = 0
        document["projects"] = projects.map { project -> [String: Any] in
            guard let sessions = project["sessions"] as? [[String: Any]] else { return project }

            var updated = project
            updated["sessions"] = sessions.filter { session in
                let isShell = (session["kind"] as? String) == LegacyKinds.shell
                if isShell { dropped += 1 }
                return !isShell
            }
            return updated
        }
        document["version"] = 2

        if dropped > 0 {
            ThreadingLogger.agent.info(
                "Dropped \(dropped, privacy: .public) shell sessions: shells are a surface now, not a kind"
            )
        }
        return try JSONSerialization.data(withJSONObject: document)
    }

    /// Moves unreadable or unsupported state out of the live path so it cannot be overwritten.
    private func quarantineProjectsState() -> URL? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let timestamp = formatter.string(from: now())

        let baseName = "projects.json.corrupt-\(timestamp)"
        var destination = appSupportDirectory.appendingPathComponent(baseName)
        var suffix = 2
        while fileManager.fileExists(atPath: destination.path) {
            destination = appSupportDirectory.appendingPathComponent("\(baseName)-\(suffix)")
            suffix += 1
        }

        do {
            try fileManager.moveItem(at: projectsStateURL, to: destination)
            ThreadingLogger.agent.error(
                "Quarantined unreadable projects state at \(destination.path, privacy: .private(mask: .hash))"
            )
            return destination
        } catch {
            ThreadingLogger.agent.error(
                "Failed to quarantine projects state: \(error.localizedDescription, privacy: .private(mask: .hash))"
            )
            return nil
        }
    }

    /// Moves an unopenable database aside, so the next launch starts on a fresh one rather than
    /// failing forever — and so the broken file is still there to look at.
    ///
    /// The database moves only after SQLite itself has folded WAL into the main file and switched
    /// out of WAL mode. A second build or hosted test can pin committed frames in the log; moving
    /// the three filenames underneath that live connection is an SQLite API violation and can
    /// split one logical database across two names. In that state quarantine refuses, leaves every
    /// byte in place, and recovery remains required. Once the other owner closes, the next launch
    /// can checkpoint and quarantine the now-single-file artifact safely.
    private func quarantineDatabase() -> URL? {
        let log = URL(fileURLWithPath: databaseURL.path + SQLiteDefaults.walSuffix)
        let sharedMemory = URL(
            fileURLWithPath: databaseURL.path + SQLiteDefaults.sharedMemorySuffix
        )

        if let database = openDatabase {
            let isSafeToMove = database.prepareForFileMove()
            database.close()
            openDatabase = nil
            guard isSafeToMove else {
                ThreadingLogger.agent.error(
                    "Left the unreadable database in place because another SQLite connection is active"
                )
                return nil
            }
        } else {
            // Initialization failed before this manager owned a connection. Sidecars are evidence
            // that the main file may still depend on WAL bytes we cannot checkpoint safely.
            guard !fileManager.fileExists(atPath: log.path),
                  !fileManager.fileExists(atPath: sharedMemory.path) else {
                ThreadingLogger.agent.error(
                    "Left the unreadable database bundle in place because it could not be checkpointed"
                )
                return nil
            }
        }

        // DELETE mode means every committed frame is now in the main file. SQLite may leave empty
        // sidecar names behind after the connection closes; remove those known-non-authoritative
        // indexes before moving the single authoritative artifact.
        do {
            for sidecar in [log, sharedMemory] where fileManager.fileExists(atPath: sidecar.path) {
                try fileManager.removeItem(at: sidecar)
            }
        } catch {
            ThreadingLogger.agent.error(
                "Left the unreadable database bundle in place because a retired sidecar could not be removed: \(error.localizedDescription, privacy: .private(mask: .hash))"
            )
            return nil
        }

        guard !fileManager.fileExists(atPath: log.path),
              !fileManager.fileExists(atPath: sharedMemory.path) else {
            ThreadingLogger.agent.error(
                "Left the unreadable database bundle in place because SQLite retained a sidecar"
            )
            return nil
        }

        let destination = uniqueQuarantineURL(named: "\(SQLiteDefaults.databaseName).corrupt")
        do {
            try fileManager.moveItem(at: databaseURL, to: destination)
        } catch {
            ThreadingLogger.agent.error(
                "Failed to quarantine the database: \(error.localizedDescription, privacy: .private(mask: .hash))"
            )
            return nil
        }

        ThreadingLogger.agent.error(
            "Quarantined unreadable database at \(destination.path, privacy: .private(mask: .hash))"
        )
        return destination
    }

    private func uniqueQuarantineURL(named baseName: String) -> URL {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        let stamped = "\(baseName)-\(formatter.string(from: now()))"
        var destination = appSupportDirectory.appendingPathComponent(stamped)
        var suffix = 2
        while fileManager.fileExists(atPath: destination.path) {
            destination = appSupportDirectory.appendingPathComponent("\(stamped)-\(suffix)")
            suffix += 1
        }
        return destination
    }

    // MARK: - Panel Layouts

    /// The display panel's stored record for a session, or nil when it has none.
    ///
    /// Routed through here rather than opened separately by `DisplayPaneStore`, so the process
    /// keeps one connection: two would each hold their own WAL reader and checkpoint against
    /// each other for no benefit.
    func loadPanelPayload(for sessionID: SessionID) -> String? {
        guard case .healthy = persistenceHealth else { return nil }
        guard !isUnreadable(unreadableAuxiliaryRows.panelLayouts, for: sessionID) else { return nil }
        importLegacyPanelLayoutsIfNeeded()
        do {
            let payload = try database().panelPayload(for: sessionID)
            guard panelPayloadIsReadable(payload, for: sessionID) else { return nil }
            return payload
        } catch {
            ThreadingLogger.mcp.error(
                "Could not load display panel: \(error.localizedDescription, privacy: .private(mask: .hash))"
            )
            requireRecovery()
            return nil
        }
    }

    func savePanelPayload(_ payload: String, for sessionID: SessionID) {
        guard writesAreAllowed(for: "display panel") else { return }
        guard !isUnreadable(
            unreadableAuxiliaryRows.panelLayouts,
            for: sessionID,
            refusing: "display panel"
        ) else { return }
        do {
            let database = try database()
            if !readablePanelRows.contains(sessionID) {
                let existing = try database.panelPayload(for: sessionID)
                guard panelPayloadIsReadable(existing, for: sessionID) else {
                    _ = isUnreadable(
                        unreadableAuxiliaryRows.panelLayouts,
                        for: sessionID,
                        refusing: "display panel"
                    )
                    return
                }
            }
            try database.savePanelPayload(payload, for: sessionID)
            readablePanelRows.insert(sessionID)
        } catch {
            ThreadingLogger.mcp.error(
                "Could not persist display panel: \(error.localizedDescription, privacy: .private(mask: .hash))"
            )
            requireRecovery()
        }
    }

    func retainPanelLayouts(sessionIDs: Set<SessionID>) {
        guard writesAreAllowed(for: "display panel cleanup") else { return }
        guard prunePermitted(
            unreadableAuxiliaryRows.panelLayouts,
            for: "display panel cleanup"
        ) else { return }
        do {
            try database().retainPanels(sessionIDs: sessionIDs)
        } catch {
            ThreadingLogger.mcp.error(
                "Could not prune display panels: \(error.localizedDescription, privacy: .private(mask: .hash))"
            )
            requireRecovery()
        }
    }

    // MARK: - Session Attachments

    /// The attachment references a session has surfaced, stored beside its panel layout for the
    /// same reason: both are what the display pane rebuilds after a relaunch.
    func loadAttachmentsPayload(for sessionID: SessionID) -> String? {
        guard case .healthy = persistenceHealth else { return nil }
        guard !isUnreadable(
            unreadableAuxiliaryRows.sessionAttachments,
            for: sessionID
        ) else { return nil }
        do {
            let payload = try database().attachmentsPayload(for: sessionID)
            guard attachmentsPayloadIsReadable(payload, for: sessionID) else { return nil }
            return payload
        } catch {
            ThreadingLogger.mcp.error(
                "Could not load session attachments: \(error.localizedDescription, privacy: .private(mask: .hash))"
            )
            requireRecovery()
            return nil
        }
    }

    func saveAttachmentsPayload(_ payload: String, for sessionID: SessionID) {
        guard writesAreAllowed(for: "session attachments") else { return }
        guard !isUnreadable(
            unreadableAuxiliaryRows.sessionAttachments,
            for: sessionID,
            refusing: "session attachments"
        ) else { return }
        do {
            let database = try database()
            if !readableAttachmentRows.contains(sessionID) {
                let existing = try database.attachmentsPayload(for: sessionID)
                guard attachmentsPayloadIsReadable(existing, for: sessionID) else {
                    _ = isUnreadable(
                        unreadableAuxiliaryRows.sessionAttachments,
                        for: sessionID,
                        refusing: "session attachments"
                    )
                    return
                }
            }
            try database.saveAttachmentsPayload(payload, for: sessionID)
            readableAttachmentRows.insert(sessionID)
        } catch {
            ThreadingLogger.mcp.error(
                "Could not persist session attachments: \(error.localizedDescription, privacy: .private(mask: .hash))"
            )
            requireRecovery()
        }
    }

    func retainAttachments(sessionIDs: Set<SessionID>) {
        guard writesAreAllowed(for: "session attachment cleanup") else { return }
        guard prunePermitted(
            unreadableAuxiliaryRows.sessionAttachments,
            for: "session attachment cleanup"
        ) else { return }
        do {
            try database().retainAttachments(sessionIDs: sessionIDs)
        } catch {
            ThreadingLogger.mcp.error(
                "Could not prune session attachments: \(error.localizedDescription, privacy: .private(mask: .hash))"
            )
            requireRecovery()
        }
    }

    /// Where `SessionAttachmentStore` keeps the files it had to take custody of.
    ///
    /// Bytes rather than rows, so this lives beside the database instead of in it: an attachment
    /// declared from `$TMPDIR` has no other owner, and a blob column would put a session's
    /// screenshots into the file the whole app's state is read from. Reset already removes the
    /// whole Application Support directory, so nothing here needs its own erasure path.
    var attachmentCopiesDirectory: URL {
        let directory = appSupportDirectory.appendingPathComponent(
            "Attachments",
            isDirectory: true
        )
        ensureDirectoryExists(directory)
        return directory
    }

    /// Reads the `panels/<uuid>.json` files into the database once, then renames the directory.
    ///
    /// Attempted at most once per launch whether or not it finds anything, since the common
    /// case is a user who has already migrated and the check is a directory listing.
    private func importLegacyPanelLayoutsIfNeeded() {
        guard case .healthy = persistenceHealth else { return }
        guard !didAttemptPanelImport else { return }
        didAttemptPanelImport = true

        let legacyRoot = appSupportDirectory.appendingPathComponent(
            DisplayPaneStoreDefaults.rootDirectory,
            isDirectory: true
        )
        guard fileManager.fileExists(atPath: legacyRoot.path) else { return }

        let database: ProjectDatabase
        do {
            database = try self.database()
        } catch {
            ThreadingLogger.mcp.error(
                "Could not inspect display panel storage: \(error.localizedDescription, privacy: .private(mask: .hash))"
            )
            requireRecovery()
            return
        }

        let files: [URL]
        do {
            files = try fileManager.contentsOfDirectory(
                at: legacyRoot,
                includingPropertiesForKeys: nil
            )
        } catch {
            ThreadingLogger.mcp.error(
                "Could not inspect legacy display panels: \(error.localizedDescription, privacy: .private(mask: .hash))"
            )
            requireRecovery()
            return
        }
        var imported = 0
        var retired: [URL] = []

        for file in files where file.pathExtension == DisplayPaneStoreDefaults.layoutExtension {
            guard let sessionID = SessionID(
                uuidString: file.deletingPathExtension().lastPathComponent
            ) else {
                continue
            }
            do {
                let data = try BoundedFileReader.read(
                    file,
                    maximumBytes: DisplayPaneStoreDefaults.maximumLayoutBytes
                )
                guard let payload = String(data: data, encoding: .utf8) else {
                    throw CocoaError(.fileReadInapplicableStringEncoding)
                }
                if try database.panelPayload(for: sessionID) == nil {
                    try database.savePanelPayload(payload, for: sessionID)
                    imported += 1
                }
                retired.append(file)
            } catch {
                ThreadingLogger.mcp.error(
                    "Could not import legacy display panel \(file.lastPathComponent, privacy: .private(mask: .hash)): \(error.localizedDescription, privacy: .private(mask: .hash))"
                )
                requireRecovery()
                return
            }
        }

        guard !retired.isEmpty else { return }

        // The cached images stay where they are — they are PNGs, and the directory keeps them.
        // Only the layout files are retired, by extension, so the caches beside them survive.
        for file in retired {
            do {
                try fileManager.moveItem(
                    at: file,
                    to: file.appendingPathExtension(SQLiteDefaults.migratedSuffix)
                )
            } catch {
                ThreadingLogger.mcp.error(
                    "Could not retire legacy display panel \(file.lastPathComponent, privacy: .private(mask: .hash)): \(error.localizedDescription, privacy: .private(mask: .hash))"
                )
            }
        }
        ThreadingLogger.mcp.info("Imported \(imported, privacy: .public) display panel layouts into the database")
    }

    // MARK: - Database

    private var databaseURL: URL {
        appSupportDirectory.appendingPathComponent(SQLiteDefaults.databaseName)
    }

    /// Opened once and held for the process. A connection is cheap but not free, and WAL wants
    /// a long-lived one — reopening per write would checkpoint far more often than necessary.
    private func database() throws -> ProjectDatabase {
        if let openDatabase { return openDatabase }

        let database = try ProjectDatabase(url: databaseURL)
        openDatabase = database
        return database
    }

    /// Closes the cached WAL connection before its containing directory is moved or removed.
    /// A later operation may reopen it, which keeps a failed reset recoverable without leaving
    /// an invalid file descriptor behind. Ordinary app lifetime still uses one long-lived open.
    func closeDatabase() {
        openDatabase?.close()
        openDatabase = nil
        readablePanelRows.removeAll()
        readableAttachmentRows.removeAll()
    }

    // MARK: - Persistence Health

    private func writesAreAllowed(for operation: String) -> Bool {
        guard case .healthy = persistenceHealth else {
            ThreadingLogger.agent.error(
                "Refusing to write \(operation, privacy: .public) while persistence recovery is required"
            )
            return false
        }
        return true
    }

    private func requireRecovery(quarantinedAt: URL? = nil) {
        guard case .healthy = persistenceHealth else { return }
        persistenceHealth = .recoveryRequired(quarantinedAt: quarantinedAt)
    }

    // MARK: - Unreadable Auxiliary Rows

    /// Records structural auxiliary hazards startup cannot defer, and says so once.
    ///
    /// Payload failures join these sets lazily at first feature access. Startup only needs to find
    /// rows whose session id is malformed, because no feature can ever request one and discover it.
    private func record(_ unreadable: UnreadableAuxiliaryRows) {
        unreadableAuxiliaryRows = unreadable
        readablePanelRows.removeAll()
        readableAttachmentRows.removeAll()
        reportedUnreadableWrites.removeAll()
        guard !unreadable.isEmpty else { return }

        let unkeyed = unreadable.panelLayouts.containsUnkeyedRows
            || unreadable.sessionAttachments.containsUnkeyedRows
        ThreadingLogger.agent.error(
            """
            Loaded the store with \(unreadable.panelLayouts.sessions.count, privacy: .public) \
            unreadable display panels, \
            \(unreadable.sessionAttachments.sessions.count, privacy: .public) unreadable \
            attachment lists\(unkeyed ? ", and a row naming no session" : "", privacy: .public); \
            those rows are kept and will not be written over this launch
            """
        )
    }

    /// Validates one panel at the feature boundary instead of every panel during launch.
    private func panelPayloadIsReadable(_ payload: String?, for sessionID: SessionID) -> Bool {
        guard let payload else {
            readablePanelRows.insert(sessionID)
            return true
        }
        guard !readablePanelRows.contains(sessionID) else { return true }
        do {
            _ = try JSONDecoder().decode(PersistedPanel.self, from: Data(payload.utf8))
            readablePanelRows.insert(sessionID)
            return true
        } catch {
            unreadableAuxiliaryRows.panelLayouts.sessions.insert(sessionID)
            ThreadingLogger.storage.error(
                """
                Unreadable \(ProjectDatabaseSchema.panelTable, privacy: .public) row for session \
                \(sessionID.uuidString, privacy: .public): \
                \(error.localizedDescription, privacy: .private(mask: .hash))
                """
            )
            return false
        }
    }

    /// Validates one attachment document at first use, with the same overwrite refusal as panels.
    private func attachmentsPayloadIsReadable(
        _ payload: String?,
        for sessionID: SessionID
    ) -> Bool {
        guard let payload else {
            readableAttachmentRows.insert(sessionID)
            return true
        }
        guard !readableAttachmentRows.contains(sessionID) else { return true }
        do {
            _ = try JSONDecoder().decode(
                PersistedSessionAttachments.self,
                from: Data(payload.utf8)
            )
            readableAttachmentRows.insert(sessionID)
            return true
        } catch {
            unreadableAuxiliaryRows.sessionAttachments.sessions.insert(sessionID)
            ThreadingLogger.storage.error(
                """
                Unreadable \(ProjectDatabaseSchema.attachmentsTable, privacy: .public) row for \
                session \(sessionID.uuidString, privacy: .public): \
                \(error.localizedDescription, privacy: .private(mask: .hash))
                """
            )
            return false
        }
    }

    /// Whether this session's row in an auxiliary table is one the load could not read.
    ///
    /// A read answers nil so the feature rebuilds from nothing, and a write is refused so the
    /// bytes it could not read are still there for the build that can.
    private func isUnreadable(
        _ rows: UnreadableRows,
        for sessionID: SessionID,
        refusing operation: String? = nil
    ) -> Bool {
        guard rows.sessions.contains(sessionID) else { return false }
        if let operation, reportedUnreadableWrites.insert("\(operation):\(sessionID.uuidString)").inserted {
            ThreadingLogger.mcp.error(
                """
                Refusing to write \(operation, privacy: .public) for \
                \(sessionID.uuidString, privacy: .public): its stored row could not be read by \
                this build, and overwriting it would destroy the only copy
                """
            )
        }
        return true
    }

    /// Whether pruning a table would delete a row the load could not read *and* could not key.
    ///
    /// Every prune keeps the rows belonging to live sessions, so an unreadable row with a valid
    /// session id looks after itself. One whose `session_id` is not an identifier at all belongs
    /// to no session, so a prune would take it — and this is the only thing that stops that.
    private func prunePermitted(_ rows: UnreadableRows, for operation: String) -> Bool {
        guard rows.containsUnkeyedRows else { return true }
        ThreadingLogger.mcp.error(
            """
            Skipping \(operation, privacy: .public): the store holds a row this build could not \
            read and cannot match to a session, which a prune would delete
            """
        )
        return false
    }

    // MARK: - Legacy Cleanup

    /// Removes the window-based state file left by the pre-project layout.
    func clearLegacySessionState() {
        guard fileManager.fileExists(atPath: sessionStateURL.path) else { return }
        do {
            try fileManager.removeItem(at: sessionStateURL)
        } catch {
            ThreadingLogger.session.warning(
                "Could not remove legacy session state source=\(self.sessionStateURL.path, privacy: .private(mask: .hash)): \(error.localizedDescription, privacy: .private(mask: .hash))"
            )
        }
    }
}

enum StateManagerDefaults {
    /// Legacy `projects.json` was a whole-store document. Sixteen MiB leaves room for tens of
    /// thousands of ordinary rows while preventing a corrupt or externally replaced migration
    /// source from becoming an unbounded allocation before SQLite takes ownership.
    static let maximumLegacyProjectsBytes = 16 * 1_024 * 1_024
}
