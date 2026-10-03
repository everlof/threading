import Foundation
import ThreadingController

// MARK: - Session Mail Presentation

/// A session's mail as the Info panel shows it: what is waiting for it and what it sent lately,
/// each row naming the other party, their host and the message's state. Never the text — the
/// panel says *that* mail moved, and the agent's own `mail_inbox` is where it is read.
///
/// A value built from `MacMailbox.Snapshot`, which is already bounded (`snapshotRows` per list),
/// so the panel constructs at most that many rows whatever the mailbox holds.
struct SessionMailPresentation: Equatable, Sendable {

    enum Direction: Equatable, Sendable {
        case received
        case sent
    }

    struct Row: Equatable, Sendable {
        let id: UUID
        let direction: Direction
        /// The other party's display name.
        let party: String
        /// Where the other party runs.
        let host: String
        let state: String
        let isUrgent: Bool
        let isProblem: Bool
    }

    let received: [Row]
    let sent: [Row]
    /// Where the mail is kept, and whether this reading is stale — shown under the rows.
    private(set) var note: String?

    /// One live grant on the mailbox: who may write, and how.
    struct Grant: Equatable, Sendable {
        let sender: String
        let mode: MailMode
    }

    /// The owner's grants, live ones only. Bounded by the store's page.
    private(set) var grants: [Grant] = []

    func granting(_ grants: [MailGrant]) -> SessionMailPresentation {
        var copy = self
        copy.grants = grants.compactMap { grant in grant.mode.map { Grant(sender: grant.sender, mode: $0) } }
        return copy
    }

    /// The same rows with a note on where they were read from.
    func located(_ note: String?) -> SessionMailPresentation {
        var copy = self
        copy.note = note
        return copy
    }

    var isEmpty: Bool { received.isEmpty && sent.isEmpty }

    static func words(for mode: MailMode) -> String {
        switch mode {
        case .notify: return L10n.string("Can write")
        case .wake: return L10n.string("Can write and wake")
        case .ask: return L10n.string("Can ask")
        }
    }

    /// Row identity only, so a poll with the same rows updates nothing.
    var shape: String {
        (received + sent).map { "\($0.id.uuidString):\($0.state)" }.joined(separator: ",") + "|\(note ?? "")|" + grants.map { "\($0.sender)=\($0.mode.rawValue)" }.joined(separator: ",")
    }

    init(received: [Row], sent: [Row]) {
        self.received = received
        self.sent = sent
    }

    /// `sessionTitle` names a session on this Mac by its id; nil when the record is gone.
    @MainActor
    init(_ snapshot: MacMailbox.Snapshot, sessionTitle: @MainActor (SessionID) -> String?) {
        func hostName(_ host: HostID) -> String {
            if host == snapshot.localHost { return L10n.string("this Mac") }
            return snapshot.peerNames[host] ?? L10n.format("host %@", String(host.description.prefix(8)))
        }
        received = snapshot.open.map { message in
            let envelope = message.envelope
            return Row(
                id: envelope.id, direction: .received,
                party: WorkspaceControlPlane.safeHeaderTitle(envelope.senderName),
                host: hostName(envelope.sender.host),
                state: Self.words(for: message.state),
                isUrgent: envelope.priority == .interrupt,
                isProblem: false
            )
        }
        sent = snapshot.sent.map { message in
            let envelope = message.envelope
            let recipient = envelope.recipient
            let party: String
            if recipient.kind == .session {
                party = sessionTitle(SessionID(recipient.id)).map(WorkspaceControlPlane.safeHeaderTitle)
                    ?? L10n.string("A removed session")
            } else {
                party = recipient.kind == .worker ? L10n.string("Worker") : L10n.string("Session")
            }
            return Row(
                id: envelope.id, direction: .sent, party: party, host: hostName(recipient.host),
                state: Self.words(for: message.state),
                isUrgent: envelope.priority == .interrupt,
                isProblem: message.state == .bounced
            )
        }
    }

    static func words(for state: MailState) -> String {
        switch state {
        case .inbox: return L10n.string("Unread")
        case .noticed: return L10n.string("Told, unread")
        case .acked: return L10n.string("Acknowledged")
        case .outbound: return L10n.string("Waiting for host")
        case .forwarded: return L10n.string("Handed to host")
        case .bounced: return L10n.string("Refused by host")
        }
    }
}
