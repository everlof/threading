import Foundation

/// Manages per-session shell history files.
///
/// Each terminal session gets its own history file, allowing history to persist
/// across app restarts while keeping each window's history separate.
enum HistoryManager {

    // MARK: - Constants

    private static let historyDirectoryName = "history"
    private static let historyFileExtension = "history"

    // MARK: - Paths

    /// Returns the directory where session history files are stored.
    static var historyDirectory: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let skalmanDir = appSupport.appendingPathComponent("Skalman", isDirectory: true)
        return skalmanDir.appendingPathComponent(historyDirectoryName, isDirectory: true)
    }

    /// Returns the history file path for a given session identifier.
    static func historyFilePath(for sessionID: SessionID) -> URL {
        return historyDirectory
            .appendingPathComponent(sessionID.uuidString)
            .appendingPathExtension(historyFileExtension)
    }

    // MARK: - Directory Management

    /// Ensures the history directory exists.
    static func ensureHistoryDirectoryExists() {
        let fileManager = FileManager.default
        let directory = historyDirectory

        if !fileManager.fileExists(atPath: directory.path) {
            do {
                try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            } catch {
                print("Failed to create history directory: \(error)")
            }
        }
    }

    // MARK: - Cleanup

    /// Removes history files for sessions that no longer exist.
    ///
    /// Call this on app launch with the set of active session identifiers.
    static func cleanupOrphanedHistoryFiles(activeSessionIDs: Set<SessionID>) {
        let fileManager = FileManager.default
        let directory = historyDirectory

        guard fileManager.fileExists(atPath: directory.path) else { return }

        do {
            let historyFiles = try fileManager.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: nil
            )

            for fileURL in historyFiles {
                // Extract UUID from filename (e.g., "ABC123.history" -> "ABC123")
                let filename = fileURL.deletingPathExtension().lastPathComponent

                if let fileSessionID = SessionID(uuidString: filename) {
                    if !activeSessionIDs.contains(fileSessionID) {
                        try fileManager.removeItem(at: fileURL)
                    }
                }
            }
        } catch {
            print("Failed to cleanup orphaned history files: \(error)")
        }
    }

    /// Removes the history file for a specific session.
    static func removeHistoryFile(for sessionID: SessionID) {
        let fileManager = FileManager.default
        let filePath = historyFilePath(for: sessionID)

        if fileManager.fileExists(atPath: filePath.path) {
            do {
                try fileManager.removeItem(at: filePath)
            } catch {
                print("Failed to remove history file: \(error)")
            }
        }
    }
}
