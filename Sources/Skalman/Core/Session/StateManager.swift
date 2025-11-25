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

    // MARK: - App State Persistence

    func saveAppState(_ state: AppState) {
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(state)
            try data.write(to: sessionStateURL, options: .atomic)
        } catch {
            print("Failed to save app state: \(error)")
        }
    }

    func loadAppState() -> AppState? {
        guard FileManager.default.fileExists(atPath: sessionStateURL.path) else {
            return nil
        }

        do {
            let data = try Data(contentsOf: sessionStateURL)
            let decoder = JSONDecoder()
            return try decoder.decode(AppState.self, from: data)
        } catch {
            print("Failed to load app state: \(error)")
            return nil
        }
    }

    func clearAppState() {
        try? FileManager.default.removeItem(at: sessionStateURL)
    }

    // MARK: - Window State Persistence (for .anotherterm files)

    func saveWindowState(_ state: WindowState, to url: URL) {
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(state)
            try data.write(to: url, options: .atomic)
        } catch {
            print("Failed to save window state: \(error)")
        }
    }

    func loadWindowState(from url: URL) -> WindowState? {
        do {
            let data = try Data(contentsOf: url)
            let decoder = JSONDecoder()
            return try decoder.decode(WindowState.self, from: data)
        } catch {
            print("Failed to load window state: \(error)")
            return nil
        }
    }
}
