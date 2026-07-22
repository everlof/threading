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
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(state)

            // Move the last known-good state aside before replacing it. If any part of that
            // rotation fails, leave the current file untouched instead of falling through to
            // an overwrite without a backup.
            if fileManager.fileExists(atPath: projectsStateURL.path) {
                if fileManager.fileExists(atPath: projectsBackupURL.path) {
                    try fileManager.removeItem(at: projectsBackupURL)
                }
                try fileManager.moveItem(at: projectsStateURL, to: projectsBackupURL)
            }

            try data.write(to: projectsStateURL, options: .atomic)
            return true
        } catch {
            SkalmanLogger.agent.error("Failed to save projects state: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    func loadProjectsState() -> ProjectsStateLoadResult {
        guard fileManager.fileExists(atPath: projectsStateURL.path) else {
            return .missing
        }

        do {
            let data = try Data(contentsOf: projectsStateURL)
            return .loaded(try decodeAndMigrateProjectsState(from: data))
        } catch {
            SkalmanLogger.agent.error("Failed to load projects state: \(error.localizedDescription, privacy: .public)")
            return .failed(quarantinedAt: quarantineProjectsState())
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

    // MARK: - Legacy Cleanup

    /// Removes the window-based state file left by the pre-project layout.
    func clearLegacySessionState() {
        try? fileManager.removeItem(at: sessionStateURL)
    }
}
