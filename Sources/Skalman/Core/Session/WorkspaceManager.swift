import Foundation

/// Manages workspace persistence and retrieval.
enum WorkspaceManager {

    // MARK: - Paths

    private static var appSupportDirectory: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return appSupport.appendingPathComponent("Skalman", isDirectory: true)
    }

    static var workspacesDirectory: URL {
        appSupportDirectory.appendingPathComponent("workspaces", isDirectory: true)
    }

    private static var workspaceStateURL: URL {
        appSupportDirectory.appendingPathComponent("workspace-state.json")
    }

    private static func workspaceFileURL(for id: UUID) -> URL {
        workspacesDirectory.appendingPathComponent("\(id.uuidString).workspace.json")
    }

    // MARK: - Directory Management

    private static func ensureDirectoriesExist() {
        let fileManager = FileManager.default

        if !fileManager.fileExists(atPath: appSupportDirectory.path) {
            try? fileManager.createDirectory(at: appSupportDirectory, withIntermediateDirectories: true)
        }

        if !fileManager.fileExists(atPath: workspacesDirectory.path) {
            try? fileManager.createDirectory(at: workspacesDirectory, withIntermediateDirectories: true)
        }
    }

    // MARK: - Workspace State (Index)

    static func loadWorkspaceState() -> WorkspaceAppState {
        do {
            let data = try Data(contentsOf: workspaceStateURL)
            let decoder = JSONDecoder()
            return try decoder.decode(WorkspaceAppState.self, from: data)
        } catch {
            return WorkspaceAppState()
        }
    }

    static func saveWorkspaceState(_ state: WorkspaceAppState) {
        ensureDirectoriesExist()

        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(state)
            try data.write(to: workspaceStateURL, options: .atomic)
        } catch {
            print("Failed to save workspace state: \(error)")
        }
    }

    // MARK: - Individual Workspaces

    static func loadWorkspace(id: UUID) -> Workspace? {
        let url = workspaceFileURL(for: id)

        do {
            let data = try Data(contentsOf: url)
            let decoder = JSONDecoder()
            return try decoder.decode(Workspace.self, from: data)
        } catch {
            print("Failed to load workspace \(id): \(error)")
            return nil
        }
    }

    static func saveWorkspace(_ workspace: Workspace) {
        ensureDirectoriesExist()

        let url = workspaceFileURL(for: workspace.id)

        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(workspace)
            try data.write(to: url, options: .atomic)

            // Update metadata in workspace state
            var state = loadWorkspaceState()
            let metadata = WorkspaceMetadata(from: workspace)

            if let index = state.workspaces.firstIndex(where: { $0.id == workspace.id }) {
                state.workspaces[index] = metadata
            } else {
                state.workspaces.append(metadata)
            }

            saveWorkspaceState(state)
        } catch {
            print("Failed to save workspace \(workspace.id): \(error)")
        }
    }

    static func deleteWorkspace(id: UUID) {
        let url = workspaceFileURL(for: id)

        // Remove the workspace file
        try? FileManager.default.removeItem(at: url)

        // Update workspace state
        var state = loadWorkspaceState()
        state.workspaces.removeAll { $0.id == id }

        // Clear last active if it was this workspace
        if state.lastActiveWorkspaceID == id {
            state.lastActiveWorkspaceID = nil
        }

        saveWorkspaceState(state)
    }

    static func renameWorkspace(id: UUID, newName: String) {
        guard var workspace = loadWorkspace(id: id) else { return }

        workspace.name = newName
        saveWorkspace(workspace)
    }

    // MARK: - Convenience

    static func listWorkspaces() -> [WorkspaceMetadata] {
        let state = loadWorkspaceState()
        return state.workspaces.sorted { $0.lastUsedAt > $1.lastUsedAt }
    }

    static func setLastActiveWorkspace(id: UUID?) {
        var state = loadWorkspaceState()
        state.lastActiveWorkspaceID = id
        saveWorkspaceState(state)
    }

    static func getLastActiveWorkspaceID() -> UUID? {
        loadWorkspaceState().lastActiveWorkspaceID
    }

    /// Updates the lastUsedAt timestamp for a workspace.
    static func touchWorkspace(id: UUID) {
        guard var workspace = loadWorkspace(id: id) else { return }
        workspace.lastUsedAt = Date()
        saveWorkspace(workspace)
    }

    /// Checks if a workspace file exists.
    static func workspaceExists(id: UUID) -> Bool {
        FileManager.default.fileExists(atPath: workspaceFileURL(for: id).path)
    }
}
