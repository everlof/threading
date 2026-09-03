import Foundation

/// The only bridge from mutable, main-actor project state into navigation search. The indexer
/// receives value copies, so its detached build and queries cannot race `ProjectStore`.
@MainActor
enum NavigationSearchProjection {
    static func records(projects: [Project]) -> [NavigationSearchRecord] {
        projects.flatMap { records(project: $0) }
    }

    static func records(project: Project) -> [NavigationSearchRecord] {
        var records = [record(project: project)]
        records.reserveCapacity(1 + project.sessions.count + project.terminals.count)
        records.append(contentsOf: project.sessions.map { record(session: $0, in: project) })
        records.append(contentsOf: project.terminals.map { record(terminal: $0, in: project) })
        return records
    }

    static func record(project: Project) -> NavigationSearchRecord {
        NavigationSearchRecord(
            destination: .project(project.id),
            title: project.name,
            projectName: project.name,
            searchableMetadata: [project.id.uuidString],
            updatedAt: project.createdAt
        )
    }

    static func record(session: AgentSession, in project: Project) -> NavigationSearchRecord {
        NavigationSearchRecord(
            destination: session.isArchived
                ? .archivedSession(projectID: project.id, sessionID: session.id)
                : .session(projectID: project.id, sessionID: session.id),
            title: session.displayTitle,
            projectName: project.name,
            providerName: session.kind.displayName,
            branch: session.branch,
            searchableMetadata: [
                session.title,
                session.customTitle,
                session.agentTitle,
                session.externalIdentifier,
                session.id.uuidString,
            ].compactMap { $0 },
            updatedAt: session.archivedAt ?? session.lastUsedAt
        )
    }

    static func record(terminal: ProjectTerminal, in project: Project) -> NavigationSearchRecord {
        NavigationSearchRecord(
            destination: .terminal(projectID: project.id, terminalID: terminal.id),
            title: terminal.displayTitle,
            projectName: project.name,
            providerName: "Terminal",
            branch: terminal.branch,
            searchableMetadata: [
                terminal.title,
                terminal.customTitle,
                terminal.id.uuidString,
                URL(fileURLWithPath: terminal.currentDirectory).lastPathComponent,
            ].compactMap { $0 },
            updatedAt: terminal.createdAt
        )
    }
}
