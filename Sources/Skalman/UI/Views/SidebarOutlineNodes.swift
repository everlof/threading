import Foundation

// MARK: - Outline Nodes

/// Reference-typed wrapper for a project row.
///
/// `NSOutlineView` identifies rows by object identity, which value types cannot provide,
/// so nodes are rebuilt from `ProjectStore` on every reload.
final class ProjectNode: NSObject {
    let projectID: UUID
    var sessionNodes: [SessionNode] = []

    init(projectID: UUID) {
        self.projectID = projectID
    }
}

/// Reference-typed wrapper for a session row.
final class SessionNode: NSObject {
    let sessionID: UUID

    init(sessionID: UUID) {
        self.sessionID = sessionID
    }
}

/// Groups the checkouts of one repository.
///
/// Only created when a repository has more than one checkout added, so a repository with a
/// single checkout keeps the flatter two-level layout.
final class RepoGroupNode: NSObject {
    let name: String
    var projectNodes: [ProjectNode] = []

    init(name: String) {
        self.name = name
    }
}
