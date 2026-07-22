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
final class StateManager {

    // MARK: - Singleton

    static let shared = StateManager()

    private let fileManager: FileManager
    private let appSupportDirectoryOverride: URL?
    private let now: () -> Date

    private var openDatabase: ProjectDatabase?
    private var didAttemptPanelImport = false

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

        let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let appDirectory = appSupport.appendingPathComponent("Skalman")
        ensureDirectoryExists(appDirectory)
        return appDirectory
    }

    private func ensureDirectoryExists(_ directory: URL) {
        guard !fileManager.fileExists(atPath: directory.path) else { return }

        do {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            SkalmanLogger.agent.error(
                "Failed to create state directory: \(error.localizedDescription, privacy: .public)"
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
        do {
            try database().save(state)
            return true
        } catch {
            SkalmanLogger.agent.error("Failed to save projects state: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    /// Restores the store, importing a legacy `projects.json` the first time.
    ///
    /// Three outcomes, and the contract is the one the JSON document had: a missing store starts
    /// fresh, a readable one loads, and an unreadable one is moved aside and reported — which is
    /// what lets `ProjectStore` refuse to write over state it could not read.
    func loadProjectsState() -> ProjectsStateLoadResult {
        do {
            let database = try self.database()

            if database.isEmpty, fileManager.fileExists(atPath: projectsStateURL.path) {
                return try importLegacyProjectsState(into: database)
            }

            let state = try database.load()
            return state.projects.isEmpty && state.selectedSessionID == nil ? .missing : .loaded(state)
        } catch {
            SkalmanLogger.agent.error(
                "Failed to load projects state: \(error.localizedDescription, privacy: .public)"
            )
            return .failed(quarantinedAt: quarantineDatabase())
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
            data = try Data(contentsOf: projectsStateURL)
            state = try decodeAndMigrateProjectsState(from: data)
        } catch {
            SkalmanLogger.agent.error(
                "Legacy projects.json could not be read: \(error.localizedDescription, privacy: .public)"
            )
            return .failed(quarantinedAt: quarantineProjectsState())
        }

        try database.save(state)
        retireLegacyProjectsState()

        SkalmanLogger.agent.info(
            "Imported \(state.projects.count, privacy: .public) projects from projects.json into the database"
        )
        return .loaded(state)
    }

    private func retireLegacyProjectsState() {
        let retiredURL = projectsStateURL.appendingPathExtension(SQLiteDefaults.migratedSuffix)
        try? fileManager.removeItem(at: retiredURL)
        try? fileManager.moveItem(at: projectsStateURL, to: retiredURL)
        // The rolling backup described the document, not the database; it would only ever be
        // restored *over* an import that has already happened.
        try? fileManager.moveItem(
            at: projectsBackupURL,
            to: projectsBackupURL.appendingPathExtension(SQLiteDefaults.migratedSuffix)
        )
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

    /// Migration seam for future schema versions. Each case upgrades exactly one version.
    private func migrateProjectsState(_ data: Data, from version: Int) throws -> Data {
        switch version {
        default:
            throw ProjectsStateLoadError.missingMigration(from: version)
        }
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
            SkalmanLogger.agent.error(
                "Quarantined unreadable projects state at \(destination.path, privacy: .public)"
            )
            return destination
        } catch {
            SkalmanLogger.agent.error(
                "Failed to quarantine projects state: \(error.localizedDescription, privacy: .public)"
            )
            return nil
        }
    }

    /// Moves an unopenable database aside, so the next launch starts on a fresh one rather than
    /// failing forever — and so the broken file is still there to look at.
    private func quarantineDatabase() -> URL? {
        openDatabase = nil

        let destination = uniqueQuarantineURL(named: "\(SQLiteDefaults.databaseName).corrupt")
        do {
            try fileManager.moveItem(at: databaseURL, to: destination)
            // WAL and shared-memory sidecars belong to the file they were written beside; left
            // behind, SQLite would try to recover a fresh database from them.
            for sidecar in ["-wal", "-shm"] {
                let url = URL(fileURLWithPath: databaseURL.path + sidecar)
                try? fileManager.removeItem(at: url)
            }
            SkalmanLogger.agent.error(
                "Quarantined unreadable database at \(destination.path, privacy: .public)"
            )
            return destination
        } catch {
            SkalmanLogger.agent.error(
                "Failed to quarantine the database: \(error.localizedDescription, privacy: .public)"
            )
            return nil
        }
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
        importLegacyPanelLayoutsIfNeeded()
        return try? database().panelPayload(for: sessionID)
    }

    func savePanelPayload(_ payload: String, for sessionID: SessionID) {
        do {
            try database().savePanelPayload(payload, for: sessionID)
        } catch {
            SkalmanLogger.mcp.error(
                "Could not persist display panel: \(error.localizedDescription, privacy: .public)"
            )
        }
    }

    func retainPanelLayouts(sessionIDs: Set<SessionID>) {
        try? database().retainPanels(sessionIDs: sessionIDs)
    }

    /// Reads the `panels/<uuid>.json` files into the database once, then renames the directory.
    ///
    /// Attempted at most once per launch whether or not it finds anything, since the common
    /// case is a user who has already migrated and the check is a directory listing.
    private func importLegacyPanelLayoutsIfNeeded() {
        guard !didAttemptPanelImport else { return }
        didAttemptPanelImport = true

        let legacyRoot = appSupportDirectory.appendingPathComponent(
            DisplayPaneStoreDefaults.rootDirectory,
            isDirectory: true
        )
        guard fileManager.fileExists(atPath: legacyRoot.path),
              let database = try? self.database(),
              !database.hasPanelLayouts else { return }

        let files = (try? fileManager.contentsOfDirectory(at: legacyRoot, includingPropertiesForKeys: nil)) ?? []
        var imported = 0

        for file in files where file.pathExtension == DisplayPaneStoreDefaults.layoutExtension {
            guard let sessionID = SessionID(uuidString: file.deletingPathExtension().lastPathComponent),
                  let payload = try? String(contentsOf: file, encoding: .utf8) else { continue }
            try? database.savePanelPayload(payload, for: sessionID)
            imported += 1
        }

        guard imported > 0 else { return }

        // The cached images stay where they are — they are PNGs, and the directory keeps them.
        // Only the layout files are retired, by extension, so the caches beside them survive.
        for file in files where file.pathExtension == DisplayPaneStoreDefaults.layoutExtension {
            try? fileManager.moveItem(
                at: file,
                to: file.appendingPathExtension(SQLiteDefaults.migratedSuffix)
            )
        }
        SkalmanLogger.mcp.info("Imported \(imported, privacy: .public) display panel layouts into the database")
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

    // MARK: - Legacy Cleanup

    /// Removes the window-based state file left by the pre-project layout.
    func clearLegacySessionState() {
        try? fileManager.removeItem(at: sessionStateURL)
    }
}
