import Foundation

/// Journals every removal that takes chats out of the store, naming the route that asked.
///
/// Every deletion passes through `ProjectStore.removeSession` or `removeProject`, and until this
/// existed none of them said so. Two chats that vanished together left only their processes'
/// exits in the PTY host's journal, so whether a confirmation, an adopted-row reclaim or a
/// rollback had removed them could not be answered after the fact — and this file is the one
/// that has to be believed after the fact. The caller is recorded as `#fileID:#line` captured at
/// the store's door, so a new route is attributed without anyone remembering to label it.
@MainActor
enum DeletionJournal {

    // MARK: - Constants

    /// Longest id list one record carries. The count beside it is always exact.
    static let maximumListedSessions = 20

    static let truncationMarker = "…"

    // MARK: - Recording

    static func sessionDeleted(
        _ session: AgentSession,
        from project: Project,
        caller: String
    ) {
        EventLog.shared.record(.session, "Session deleted", [
            "session": session.id.uuidString,
            "project": project.id.uuidString,
            "title": session.displayTitle,
            "agent": session.kind.rawValue,
            "archived": String(session.isArchived),
            "adoptedProject": String(project.wasAdoptedForCheckoutMove),
            "caller": caller,
        ])
    }

    static func projectRemoved(_ project: Project, caller: String) {
        let sessionIDs = project.sessions.map(\.id.uuidString)
        EventLog.shared.record(.session, "Project removed", [
            "project": project.id.uuidString,
            "name": project.name,
            "folder": project.folderPath,
            "adopted": String(project.wasAdoptedForCheckoutMove),
            "count": String(sessionIDs.count),
            "sessions": listed(sessionIDs),
            "caller": caller,
        ])
    }

    // MARK: - Formatting

    static func caller(_ file: StaticString, _ line: UInt) -> String {
        "\(file):\(line)"
    }

    /// The ids joined for one record, bounded so a large project cannot make a huge line.
    static func listed(_ ids: [String]) -> String {
        let shown = ids.prefix(maximumListedSessions).joined(separator: ",")
        return ids.count > maximumListedSessions ? shown + "," + truncationMarker : shown
    }
}
