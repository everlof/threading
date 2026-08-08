import Foundation
import ThreadingRemoteKit

/// Short-lived, opaque references passed between Threading's own MCP tools.
///
/// A display or browser tool issues a reference only after it has created or resolved the object
/// it names. `notify_user` consumes that reference in the same session. The agent therefore never
/// has to assemble attachment ids, browser-tab ids, extension identities, or an application URL,
/// and a guessed reference cannot escape the session in which it was minted.
@MainActor
final class NotificationTargetRegistry {
    static let shared = NotificationTargetRegistry()

    private struct Entry {
        let sessionID: SessionID
        let destination: RemoteNotificationDestinationDTO
        let issuedAt: Date
    }

    private var entries: [String: Entry] = [:]
    private var referencesBySession: [SessionID: [String]] = [:]
    private let now: () -> Date

    init(now: @escaping () -> Date = Date.init) {
        self.now = now
    }

    func issue(
        _ destination: RemoteNotificationDestinationDTO,
        for sessionID: SessionID
    ) -> String? {
        guard destination.isValid else { return nil }
        pruneExpired()

        let reference = UUID().uuidString.lowercased()
        entries[reference] = Entry(
            sessionID: sessionID,
            destination: destination,
            issuedAt: now()
        )
        referencesBySession[sessionID, default: []].append(reference)
        trim(sessionID)
        return reference
    }

    func resolve(
        _ reference: String,
        for sessionID: SessionID
    ) -> RemoteNotificationDestinationDTO? {
        pruneExpired()
        guard let entry = entries[reference], entry.sessionID == sessionID else { return nil }
        return entry.destination
    }

    private func trim(_ sessionID: SessionID) {
        guard var references = referencesBySession[sessionID],
              references.count > NotificationTargetDefaults.maximumReferencesPerSession else {
            return
        }
        let excess = references.count - NotificationTargetDefaults.maximumReferencesPerSession
        for reference in references.prefix(excess) { entries[reference] = nil }
        references.removeFirst(excess)
        referencesBySession[sessionID] = references
    }

    private func pruneExpired() {
        let cutoff = now().addingTimeInterval(-NotificationTargetDefaults.lifetime)
        let expired = entries.compactMap { reference, entry in
            entry.issuedAt < cutoff ? reference : nil
        }
        guard !expired.isEmpty else { return }
        let expiredSet = Set(expired)
        for reference in expired { entries[reference] = nil }
        referencesBySession = referencesBySession.compactMapValues { references in
            let retained = references.filter { !expiredSet.contains($0) }
            return retained.isEmpty ? nil : retained
        }
    }
}

enum NotificationTargetDefaults {
    static let lifetime: TimeInterval = 60 * 60
    static let maximumReferencesPerSession = 64
}
