import Foundation

/// Manages persistence of application and window state.
final class StateManager {

    // MARK: - Singleton

    static let shared = StateManager()
    private init() {}

    // MARK: - File Paths

    private var appSupportDirectory: URL {
        let fileManager = FileManager.default
        let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let appDirectory = appSupport.appendingPathComponent("Skalman")

        if !fileManager.fileExists(atPath: appDirectory.path) {
            try? fileManager.createDirectory(at: appDirectory, withIntermediateDirectories: true)
        }

        return appDirectory
    }

    private var sessionStateURL: URL {
        appSupportDirectory.appendingPathComponent("session-state.json")
    }

    private var projectsStateURL: URL {
        appSupportDirectory.appendingPathComponent("projects.json")
    }

    // MARK: - Projects State Persistence

    func saveProjectsState(_ state: ProjectsState) {
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(state)
            try data.write(to: projectsStateURL, options: .atomic)
        } catch {
            SkalmanLogger.agent.error("Failed to save projects state: \(error.localizedDescription, privacy: .public)")
        }
    }

    func loadProjectsState() -> ProjectsState? {
        guard FileManager.default.fileExists(atPath: projectsStateURL.path) else {
            return nil
        }

        do {
            let data = try Data(contentsOf: projectsStateURL)
            return try JSONDecoder().decode(ProjectsState.self, from: data)
        } catch {
            SkalmanLogger.agent.error("Failed to load projects state: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    // MARK: - Legacy Cleanup

    /// Removes the window-based state file left by the pre-project layout.
    func clearLegacySessionState() {
        try? FileManager.default.removeItem(at: sessionStateURL)
    }
}
