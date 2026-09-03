import Foundation

struct ProjectsDidChange: AppEvent {
    static let name = Notification.Name("projectsDidChange")

    /// How much of the sidebar can have changed. Other observers still treat this as the same
    /// project-store event; the outline uses the narrower case to avoid rebuilding thousands of
    /// nodes for a title that can only repaint one row.
    enum SidebarImpact: Sendable {
        case structure
        /// One project and the exact identities it owned left the graph.
        case projectRemoved(
            projectID: ProjectID,
            sessionIDs: Set<SessionID>,
            terminalIDs: Set<TerminalID>
        )
        /// Rows were added, removed, or regrouped inside one project; repository roots stand.
        case projectStructure(ProjectID)
        /// One project's own row changed without changing any descendants.
        case projectRow(ProjectID)
        /// One session joined an otherwise standing project hierarchy.
        case sessionAdded(projectID: ProjectID, sessionID: SessionID)
        /// One durable session row left an otherwise standing project hierarchy.
        case sessionRemoved(projectID: ProjectID, sessionID: SessionID)
        /// One session changed where it appears without changing any neighbouring record.
        case sessionStructure(projectID: ProjectID, sessionID: SessionID)
        /// One session's display name changed; `reorders` says whether Name ordering can move it.
        case sessionTitle(SessionID, reorders: Bool)
        case sessionRow(SessionID)
        case terminalRow(TerminalID)
    }

    let sidebarImpact: SidebarImpact

    init(sidebarImpact: SidebarImpact = .structure) {
        self.sidebarImpact = sidebarImpact
    }
}
