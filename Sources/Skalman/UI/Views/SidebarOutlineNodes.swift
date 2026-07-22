import Foundation

// MARK: - Outline Nodes

/// Reference-typed wrapper for a project row.
///
/// `NSOutlineView` identifies rows by object identity, which value types cannot provide,
/// so nodes are rebuilt from `ProjectStore` on every reload.
final class ProjectNode: NSObject {
    let projectID: UUID

    /// Every session in the project, flat, regardless of how it is displayed. Lookup paths
    /// (selection, row refresh) go through this so they need not care about grouping.
    var sessionNodes: [SessionNode] = []

    /// What the outline actually shows under the project: a `BranchGroupNode` where a
    /// branch gathered several sessions, a bare `SessionNode` everywhere else.
    var childNodes: [NSObject] = []

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

/// Gathers a project's sessions that ran on the same branch.
///
/// Only created when grouping is enabled and the branch has more than one session — the
/// same rule that keeps single-checkout repositories flat, applied one level down. Sessions
/// with no recorded branch stay directly under the project.
final class BranchGroupNode: NSObject {
    let branch: String
    let projectID: UUID
    var sessionNodes: [SessionNode] = []

    init(branch: String, projectID: UUID) {
        self.branch = branch
        self.projectID = projectID
    }
}

// MARK: - Tree Builder

/// Builds the sidebar's node tree from the store's projects.
///
/// Pure construction — it reads the store and git metadata but holds no view state, which
/// is what lets it live beside the node types rather than in the view controller.
enum SidebarTreeBuilder {

    /// Arranges projects into the tree, grouping only where a repository has more than one
    /// checkout added. A single-checkout repository stays a plain project row, so the extra
    /// level never appears without cause.
    static func rootNodes(from projects: [Project]) -> [NSObject] {
        let identities = projects.map { GitInfo.repositoryIdentity(for: $0.folderPath) }

        var checkoutCounts: [String: Int] = [:]
        for identity in identities.compactMap({ $0 }) {
            checkoutCounts[identity, default: 0] += 1
        }

        var roots: [NSObject] = []
        var groupsByIdentity: [String: RepoGroupNode] = [:]

        for (project, identity) in zip(projects, identities) {
            let node = ProjectNode(projectID: project.id)
            // Archived sessions are gathered separately, below the projects.
            let activeSessions = project.sessions.filter { !$0.isArchived }
            node.sessionNodes = activeSessions.map { SessionNode(sessionID: $0.id) }
            node.childNodes = childNodes(
                projectID: project.id,
                sessions: activeSessions,
                sessionNodes: node.sessionNodes
            )

            guard let identity, checkoutCounts[identity, default: 0] > 1 else {
                roots.append(node)
                continue
            }

            if let group = groupsByIdentity[identity] {
                group.projectNodes.append(node)
                continue
            }

            let group = RepoGroupNode(name: GitInfo.repositoryName(forIdentity: identity))
            group.projectNodes.append(node)
            groupsByIdentity[identity] = group
            roots.append(group)
        }

        // Archived sessions are not shown here at all — they live in Settings, so the sidebar
        // stays a list of what is active.
        return roots
    }

    /// Arranges a project's sessions for display, gathering a branch's sessions under a
    /// `BranchGroupNode` when the branch has more than one — the "group only where it earns
    /// its level" rule, applied inside a project. Sessions on lone branches, or with no
    /// recorded branch, stay directly under the project; a group takes the position of its
    /// first session, so the list keeps its familiar order.
    private static func childNodes(
        projectID: UUID,
        sessions: [AgentSession],
        sessionNodes: [SessionNode]
    ) -> [NSObject] {
        guard AppSettings.shared.groupsSessionsByBranch else { return sessionNodes }

        var sessionCounts: [String: Int] = [:]
        for session in sessions {
            if let branch = session.branch {
                sessionCounts[branch, default: 0] += 1
            }
        }

        var children: [NSObject] = []
        var groupsByBranch: [String: BranchGroupNode] = [:]

        for (session, sessionNode) in zip(sessions, sessionNodes) {
            guard let branch = session.branch, sessionCounts[branch, default: 0] > 1 else {
                children.append(sessionNode)
                continue
            }

            if let group = groupsByBranch[branch] {
                group.sessionNodes.append(sessionNode)
                continue
            }

            let group = BranchGroupNode(branch: branch, projectID: projectID)
            group.sessionNodes.append(sessionNode)
            groupsByBranch[branch] = group
            children.append(group)
        }

        return children
    }
}
