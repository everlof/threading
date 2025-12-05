import Foundation

// MARK: - Workspace Version

enum WorkspaceVersion {
    static let current = 1
}

// MARK: - Workspace

/// Represents a saved collection of windows that can be restored together.
struct Workspace: Codable, Identifiable {
    let id: UUID
    var name: String
    let createdAt: Date
    var lastUsedAt: Date
    var windows: [WindowState]

    init(id: UUID = UUID(), name: String, windows: [WindowState]) {
        self.id = id
        self.name = name
        self.createdAt = Date()
        self.lastUsedAt = Date()
        self.windows = windows
    }
}

// MARK: - Workspace State

/// Tracks all workspaces and the currently active one.
struct WorkspaceAppState: Codable {
    let version: Int
    var workspaces: [WorkspaceMetadata]
    var lastActiveWorkspaceID: UUID?

    init(version: Int = WorkspaceVersion.current, workspaces: [WorkspaceMetadata] = [], lastActiveWorkspaceID: UUID? = nil) {
        self.version = version
        self.workspaces = workspaces
        self.lastActiveWorkspaceID = lastActiveWorkspaceID
    }
}

// MARK: - Workspace Metadata

/// Lightweight metadata for listing workspaces without loading full window state.
struct WorkspaceMetadata: Codable, Identifiable {
    let id: UUID
    var name: String
    let createdAt: Date
    var lastUsedAt: Date
    var windowCount: Int

    init(from workspace: Workspace) {
        self.id = workspace.id
        self.name = workspace.name
        self.createdAt = workspace.createdAt
        self.lastUsedAt = workspace.lastUsedAt
        self.windowCount = workspace.windows.count
    }
}
