import Foundation

// Moving a mailbox. When a session's execution host changes, its address changes with it
// (`<host>/session/<id>`: the host part is where the agent runs). The owner writes a forwarding
// record, old address → new address, on both stores: on the old one it forwards mail that still
// arrives for the old address, once; on the new one it is the owner's consent to take that mail
// from the old address's host. Unacknowledged mail is moved in one owner operation with its
// message ids unchanged, so the receiver's idempotence makes a retried move harmless. A copy
// that was forwarded once is never forwarded again: no relaying. See agent-mail.md, "Mailbox
// location".

/// Owner-written and revisioned, keyed by the old address.
public struct MailForward: Codable, Equatable, Sendable {
    public let from: MailAddress
    public let to: MailAddress
    public let revision: Int
}

extension MailEnvelope {
    /// The one forwarded copy: the same message, addressed to the new mailbox.
    func forwarded(to address: MailAddress) -> MailEnvelope {
        var copy = MailEnvelope(id: id, sender: sender, senderName: senderName, recipient: address, text: text,
                                priority: priority, replyTo: replyTo, questionID: questionID, chainID: chainID,
                                depth: depth, sentAt: sentAt)
        copy.forwardedFrom = recipient
        copy.answeringFor = answeringFor
        return copy
    }
}

extension ControllerStore {

    // MARK: - Owner configuration

    /// Writes (or re-points) the forward for `from`. One end must be on this host: the old
    /// address (this store forwards) or the new one (this store accepts what is forwarded).
    public func setMailForward(from: MailAddress, to: MailAddress, expectedRevision: Int) throws -> MailForward {
        guard from != to, from.kind == to.kind else {
            throw ControllerError.invalidInput("mail_forward")
        }
        guard expectedRevision >= 0, expectedRevision < Int.max else { throw ControllerError.invalidInput("revision") }
        return try db.transaction {
            let local = try host().id
            guard from.host == local || to.host == local else { throw ControllerError.invalidInput("mail_forward") }
            if to.host == local { try requireMailbox(to) }
            if to.host != local, from.host == local, try mailPeer(to.host) == nil {
                throw ControllerError.invalidInput("unknown_host")
            }
            let prior: MailForward? = try optional("mailForward", from.description)
            guard (prior?.revision ?? 0) == expectedRevision else { throw ControllerError.conflict }
            let value = MailForward(from: from, to: to, revision: expectedRevision + 1)
            if prior == nil { try insert("mailForward", from.description, state: "active", value: value) }
            else { try update("mailForward", from.description, state: "active", value: value) }
            try event("mail.forward_changed", from.description)
            return value
        }
    }

    /// The live forward for `from`, or nil. A cleared one keeps its row for its revision.
    public func mailForward(_ from: MailAddress) throws -> MailForward? {
        guard let row = try db.rows("SELECT payload FROM record WHERE kind='mailForward' AND id=? AND state='active' LIMIT 1",
                                    [.text(from.description)]).first else { return nil }
        return try decode(row.text(0))
    }

    /// The forward's latest revision, live or cleared, for the next compare-and-swap.
    public func mailForwardRevision(_ from: MailAddress) throws -> Int {
        (try optional("mailForward", from.description) as MailForward?)?.revision ?? 0
    }

    /// Clears the forward for `from` — the mailbox came back to this address. Revisioned.
    public func clearMailForward(_ from: MailAddress, expectedRevision: Int) throws {
        try db.transaction {
            guard let prior: MailForward = try optional("mailForward", from.description) else { return }
            guard prior.revision == expectedRevision else { throw ControllerError.conflict }
            let value = MailForward(from: prior.from, to: prior.to, revision: prior.revision + 1)
            try update("mailForward", from.description, state: "removed", value: value)
            try event("mail.forward_changed", from.description)
        }
    }

    /// Moves `from`'s unacknowledged mail to `to` in one transaction: written forward, then each
    /// open message re-addressed in place (same host) or queued for `to`'s host and marked
    /// `moved` (another host). Returns how many moved. Idempotent: a second run finds nothing
    /// open, and a re-queued id is a duplicate at the receiver.
    public func moveMail(from: MailAddress, to: MailAddress) throws -> Int {
        try db.transaction {
            let local = try host().id
            guard from.host == local else { throw ControllerError.invalidInput("mail_forward") }
            if try mailForward(from)?.to != to {
                _ = try setMailForward(from: from, to: to, expectedRevision: try mailForwardRevision(from))
            }
            let rows = try db.rows("""
                SELECT payload FROM record WHERE kind='mail' AND parent=? AND state IN ('inbox','noticed')
                ORDER BY sequence LIMIT ?
                """, [.text(from.description), .integer(Int64(MailLimits.openInbox))])
            var moved = 0
            for row in rows {
                var message: MailMessage = try decode(row.text(0))
                let id = message.envelope.id.uuidString.lowercased()
                message.envelope = message.envelope.forwarded(to: to)
                if to.host == local {
                    message.state = .inbox
                    try db.run("UPDATE record SET parent=? WHERE kind='mail' AND id=?", [.text(to.description), .text(id)])
                    try update("mail", id, state: message.state.rawValue, value: message)
                } else {
                    message.state = .moved
                    try update("mail", id, state: message.state.rawValue, value: message)
                    try db.run("INSERT OR IGNORE INTO mail_outbound(host,message) VALUES(?,?)", [.text(to.host.description), .text(id)])
                }
                try event("mail.moved", id)
                moved += 1
            }
            return moved
        }
    }

    // MARK: - Accepting

    /// Whether `envelope` is a forwarded copy this store's owner agreed to take from `peer`.
    func expectsForward(_ envelope: MailEnvelope, from peer: HostID?) throws -> Bool {
        guard let old = envelope.forwardedFrom, let peer, old.host == peer,
              let forward = try mailForward(old) else { return false }
        return forward.to == envelope.recipient
    }

    /// Mail accepted for a forwarded address goes on once: re-addressed here, or queued for the
    /// new address's host. A copy that was already forwarded is refused rather than relayed.
    func forwardOnce(_ envelope: MailEnvelope, along forward: MailForward, peer: HostID?,
                     ownerAdmitted: Bool) throws -> MailMessage {
        guard envelope.forwardedFrom == nil else { throw ControllerError.forbidden }
        let copy = envelope.forwarded(to: forward.to)
        let local = try host().id
        if forward.to.host == local {
            // Already admitted under the old address's rules; re-addressed here as the same message.
            return try accept(copy, peer: nil, ownerAdmitted: ownerAdmitted || peer == nil)
        }
        guard try mailPeer(forward.to.host) != nil else { throw ControllerError.invalidInput("unknown_host") }
        try copy.validate()
        let message = MailMessage(envelope: copy, state: .moved, acceptedAt: Self.now())
        let id = copy.id.uuidString.lowercased()
        try insert("mail", id, parent: envelope.recipient.description, state: message.state.rawValue,
                   scope: copy.sender.description, value: message)
        try db.run("INSERT INTO mail_outbound(host,message) VALUES(?,?)", [.text(forward.to.host.description), .text(id)])
        try event("mail.forwarded_on", id)
        return message
    }

    /// A mailbox moved away and back: the copy it left here as `moved` gives way to the one
    /// coming home, under the same id. Only for the address this store's owner forwards from.
    func retireReturningMove(_ prior: MailMessage, _ envelope: MailEnvelope, from peer: HostID?) throws -> Bool {
        guard prior.state == .moved, envelope.forwardedFrom == prior.envelope.recipient,
              try expectsForward(envelope, from: peer) else { return false }
        let id = envelope.id.uuidString.lowercased()
        try db.run("DELETE FROM mail_outbound WHERE message=?", [.text(id)])
        try db.run("DELETE FROM record WHERE kind='mail' AND id=?", [.text(id)])
        try event("mail.returned", id)
        return true
    }

    /// A mailbox moved onto the sender's own host: the forwarded copy arriving here carries the
    /// id of the copy this host already holds as sent. One store keeps one record per message,
    /// so the sent copy gives way and the message is accepted as the recipient's inbox copy.
    func adoptSentCopy(_ prior: MailMessage, _ envelope: MailEnvelope, expectedForward: Bool) throws -> Bool {
        guard expectedForward, [.outbound, .forwarded, .bounced].contains(prior.state),
              prior.envelope.sender.host == (try host().id), envelope.forwardedFrom == prior.envelope.recipient,
              prior.envelope.sameRequest(as: MailEnvelope(id: envelope.id, sender: envelope.sender, senderName: envelope.senderName,
                                                          recipient: prior.envelope.recipient, text: envelope.text,
                                                          priority: envelope.priority, replyTo: envelope.replyTo,
                                                          questionID: envelope.questionID, chainID: envelope.chainID,
                                                          depth: envelope.depth, sentAt: envelope.sentAt)) else { return false }
        let id = envelope.id.uuidString.lowercased()
        try db.run("DELETE FROM mail_outbound WHERE message=?", [.text(id)])
        try db.run("DELETE FROM record WHERE kind='mail' AND id=?", [.text(id)])
        try event("mail.came_home", id)
        return true
    }

    private func requireMailbox(_ address: MailAddress) throws {
        switch address.kind {
        case .session: let _: MailMailbox = try required("mailbox", address.description)
        case .worker: try requireActiveWorker(WorkerID(address.id))
        }
    }
}
