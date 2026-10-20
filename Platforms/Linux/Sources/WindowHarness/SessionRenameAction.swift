#if os(Linux)
import Foundation
import Glibc
@testable import CoreSlice

/// Applies the row menu's explicit name under the store lock. Blank clears the custom title,
/// letting the shared row presentation follow the provider again.
enum SessionRenameAction {
    struct Result: Sendable {
        let changed: Bool
        let title: String
        let customTitle: String?
    }

    static func run(store: String, sessionID: SessionID, projectID: ProjectID,
                    title: String, displayedCurrentTitle: String?,
                    at date: Date = Date()) throws -> Result {
        guard title.utf8.count <= 4_096 else { throw WindowFailure("session name is too long") }
        let root = URL(fileURLWithPath: store, isDirectory: true)
        let databaseURL = root.appendingPathComponent("threading.db")
        guard FileManager.default.fileExists(atPath: databaseURL.path) else {
            throw WindowFailure("session store does not exist")
        }
        let lock = Glibc.open(root.appendingPathComponent("host.lock").path,
                              O_CREAT | O_RDWR | O_CLOEXEC, 0o600)
        guard lock >= 0 else { throw WindowFailure("cannot open session store lock") }
        defer { Glibc.close(lock) }
        guard flock(lock, LOCK_EX | LOCK_NB) == 0 else {
            throw WindowFailure("session store is already owned")
        }

        let database = try ProjectDatabase(url: databaseURL)
        defer { database.close() }
        guard let record = try database.sessionRecord(id: sessionID),
              record.project.id == projectID, !record.session.isArchived else {
            throw WindowFailure("session is no longer in this project")
        }
        var session = record.session
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let customTitle = trimmed.isEmpty ? nil : trimmed
        // The bounded navigator snapshot may display only a prefix of an older, very long
        // name. Accepting that unchanged field must not replace the full durable value.
        if title == displayedCurrentTitle, session.customTitle != displayedCurrentTitle {
            return presentation(for: session, changed: false)
        }
        if session.customTitle != customTitle {
            let previous = SessionHistoryTitle.name(for: session, usesAgentTitle: true)
            session.customTitle = customTitle
            let current = SessionHistoryTitle.name(for: session, usesAgentTitle: true)
            session.nameHistory.recordChange(from: previous, to: current, at: date)
            try database.saveSession(session, in: projectID, position: record.position)
            return presentation(for: session, changed: true)
        }
        return presentation(for: session, changed: false)
    }

    private static func presentation(for session: AgentSession, changed: Bool) -> Result {
        Result(changed: changed,
               title: AgentSessionRowPresentation(session: session, usesAgentTitle: true,
                   untitledTitle: AgentDefaults.untitledSessionName).title,
               customTitle: session.customTitle)
    }
}
#endif
