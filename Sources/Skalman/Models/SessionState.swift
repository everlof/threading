import Foundation

// MARK: - Constants

enum SessionStateVersion {
    static let current = 1
}

// MARK: - Session Snapshot

/// Captures the state of a single terminal session for persistence.
struct SessionSnapshot: Codable {
    let identifier: UUID
    let profileName: String
    let workingDirectory: String?  // Store as path string for reliable encoding
    let title: String
}

// MARK: - Window State

/// Captures the state of a single window (which may contain multiple tabs).
struct WindowState: Codable {
    let identifier: UUID
    let frame: CGRect
    let tabGroupID: UUID
    let tabIndex: Int
    let sessions: [SessionSnapshot]
}

// MARK: - App State

/// Captures the complete application state for session restoration.
struct AppState: Codable {
    let version: Int
    let windows: [WindowState]
    let savedAt: Date

    init(version: Int = SessionStateVersion.current, windows: [WindowState], savedAt: Date) {
        self.version = version
        self.windows = windows
        self.savedAt = savedAt
    }
}

