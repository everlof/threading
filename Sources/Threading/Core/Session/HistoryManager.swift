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
        let fileManager = FileManager.default
        let appSupport = fileManager.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support", isDirectory: true)
        let threadingDir = appSupport.appendingPathComponent("Threading", isDirectory: true)
        return threadingDir.appendingPathComponent(historyDirectoryName, isDirectory: true)
    }

    /// Returns the history file path for a typed terminal owner.
    static func historyFilePath(for identity: TerminalInstanceIdentity) -> URL {
        return historyDirectory
            .appendingPathComponent(identity.historyFileStem)
            .appendingPathExtension(historyFileExtension)
    }

    /// Standalone terminals historically borrowed the bare UUID filename used by agent
    /// sessions. Move that file into the terminal namespace before either cleanup or launch.
    /// A matching active agent wins the ambiguous legacy filename; there is no honest way to
    /// tell which owner wrote old bytes when the two UUID domains happen to coincide.
    private static func migrateLegacyProjectHistory(
        for identity: TerminalInstanceIdentity,
        preservingAgentStems: Set<String>
    ) {
        guard case .projectTerminal(let terminalID) = identity,
              !preservingAgentStems.contains(terminalID.uuidString) else { return }

        let legacy = historyDirectory
            .appendingPathComponent(terminalID.uuidString)
            .appendingPathExtension(historyFileExtension)
        let destination = historyFilePath(for: identity)
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: legacy.path),
              !fileManager.fileExists(atPath: destination.path) else { return }

        do {
            try fileManager.moveItem(at: legacy, to: destination)
        } catch {
            ThreadingLogger.session.error(
                "Failed to migrate project terminal history: \(error.localizedDescription)"
            )
        }
    }

    static func prepareHistoryFile(for identity: TerminalInstanceIdentity) {
        ensureHistoryDirectoryExists()
        migrateLegacyProjectHistory(for: identity, preservingAgentStems: [])
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
                ThreadingLogger.session.error("Failed to create the history directory: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    // MARK: - Cleanup

    /// Removes history files for sessions that no longer exist.
    ///
    /// Call this on app launch with every terminal identity whose history should survive.
    static func cleanupOrphanedHistoryFiles(
        activeIdentities: Set<TerminalInstanceIdentity>
    ) {
        let fileManager = FileManager.default
        let directory = historyDirectory

        guard fileManager.fileExists(atPath: directory.path) else { return }

        do {
            let agentStems = Set(activeIdentities.compactMap { identity -> String? in
                guard case .agentSession = identity else { return nil }
                return identity.historyFileStem
            })
            for identity in activeIdentities {
                migrateLegacyProjectHistory(for: identity, preservingAgentStems: agentStems)
            }

            let activeStems = Set(activeIdentities.map(\.historyFileStem))
            let migratedHistoryFiles = try fileManager.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: nil
            )
            for fileURL in migratedHistoryFiles {
                let filename = fileURL.deletingPathExtension().lastPathComponent
                guard TerminalInstanceIdentity.recognizesHistoryFileStem(filename) else {
                    continue
                }
                if !activeStems.contains(filename) {
                    try fileManager.removeItem(at: fileURL)
                }
            }
        } catch {
            ThreadingLogger.session.error("Failed to clean up orphaned history files: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Removes the history file for a specific session.
    static func removeHistoryFile(for identity: TerminalInstanceIdentity) {
        let fileManager = FileManager.default
        var filePaths = [historyFilePath(for: identity)]
        if case .projectTerminal(let terminalID) = identity {
            filePaths.append(
                historyDirectory
                    .appendingPathComponent(terminalID.uuidString)
                    .appendingPathExtension(historyFileExtension)
            )
        }

        for filePath in filePaths where fileManager.fileExists(atPath: filePath.path) {
            do {
                try fileManager.removeItem(at: filePath)
            } catch {
                ThreadingLogger.session.error("Failed to remove a history file: \(error.localizedDescription, privacy: .public)")
            }
        }
    }
}
