import Foundation

/// The only bridge from mutable, main-actor project state into navigation search. The indexer
/// receives value copies, so its detached build and queries cannot race `ProjectStore`.
@MainActor
enum NavigationSearchProjection {
    static func records(projects: [Project]) -> [NavigationSearchRecord] {
        var records: [NavigationSearchRecord] = []
        records.reserveCapacity(projects.reduce(into: projects.count) {
            $0 += $1.sessions.count + $1.terminals.count
        })

        for project in projects {
            records.append(NavigationSearchRecord(
                destination: .project(project.id),
                title: project.name,
                projectName: project.name,
                searchableMetadata: [project.id.uuidString],
                updatedAt: project.createdAt
            ))

            for session in project.sessions {
                let title = session.displayTitle
                let destination: NavigationSearchRecord.Destination = session.isArchived
                    ? .archivedSession(projectID: project.id, sessionID: session.id)
                    : .session(projectID: project.id, sessionID: session.id)
                records.append(NavigationSearchRecord(
                    destination: destination,
                    title: title,
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
                ))
            }

            for terminal in project.terminals {
                records.append(NavigationSearchRecord(
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
                ))
            }
        }
        return records
    }
}
