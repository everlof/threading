import Foundation

// Store-and-forward between hosts. One bounded JSON request reaches the other host's
// `mail-rpc`, run by a forced-command SSH key that pins which peer is calling. A host behind NAT
// (the Mac) initiates both directions: it pushes what it holds for a peer, and pulls what the
// peer holds for it. Acceptance is idempotent by message id, so every retry is safe.

public struct MailRefusal: Codable, Equatable, Sendable {
    public let id: UUID
    public let reason: String
    public init(id: UUID, reason: String) { self.id = id; self.reason = reason }
}
public struct MailPush: Codable, Sendable {
    public let from: HostID
    public let messages: [MailEnvelope]
    public init(from: HostID, messages: [MailEnvelope]) { self.from = from; self.messages = messages }
}
/// `after` acknowledges everything the caller received up to it; `refused` names which of those
/// its host refused, so the sender can bounce them instead of marking them forwarded.
public struct MailPull: Codable, Sendable {
    public let after: Int64
    public let refused: [MailRefusal]?
    public init(after: Int64, refused: [MailRefusal]?) { self.after = after; self.refused = refused }
}
public struct MailRPCRequest: Codable, Sendable {
    public let push: MailPush?
    public let pull: MailPull?
    public init(push: MailPush? = nil, pull: MailPull? = nil) { self.push = push; self.pull = pull }
}
public enum MailPushOutcome: String, Codable, Sendable { case accepted, duplicate, refused }
public struct MailPushResult: Codable, Equatable, Sendable {
    public let id: UUID
    public let outcome: MailPushOutcome
    public let reason: String?
}
/// Every response names the answering host, so a caller that reached the wrong machine (a
/// changed SSH alias, a restored backup) refuses the exchange instead of trusting it.
public struct MailRPCResponse: Codable, Sendable {
    public let host: HostID
    public let hostName: String
    public let results: [MailPushResult]?
    public let messages: [MailEnvelope]?
    public let next: Int64?
}

public enum MailTransportLimits {
    public static let batch = 100
    public static let batchBytes = 1_048_576
    public static let requestBytes = 2_097_152
    public static let responseBytes = 2_097_152
}

extension ControllerStore {
    /// The receiving end. `peer` is the identity the forced command pinned, not a claim in the
    /// request; a peer this host has not configured is refused.
    public func handleMailRPC(_ request: MailRPCRequest, peer: HostID) throws -> MailRPCResponse {
        let local = try host()
        guard try mailPeer(peer) != nil else { throw ControllerError.forbidden }
        if let push = request.push {
            guard request.pull == nil, push.from == peer, push.messages.count <= MailTransportLimits.batch else {
                throw ControllerError.invalidInput("mail_rpc")
            }
            var results: [MailPushResult] = []
            for envelope in push.messages {
                results.append(acceptPushed(envelope, peer: peer))
            }
            return MailRPCResponse(host: local.id, hostName: local.name, results: results, messages: nil, next: nil)
        }
        guard let pull = request.pull, pull.after >= 0, (pull.refused?.count ?? 0) <= MailTransportLimits.batch else {
            throw ControllerError.invalidInput("mail_rpc")
        }
        try settleOutbound(for: peer, through: pull.after, refused: pull.refused ?? [])
        let batch = try outboundBatch(for: peer, after: pull.after)
        return MailRPCResponse(host: local.id, hostName: local.name, results: nil,
                               messages: batch.envelopes, next: batch.next)
    }

    private func acceptPushed(_ envelope: MailEnvelope, peer: HostID) -> MailPushResult {
        do {
            return try db.transaction {
                if let prior: MailMessage = try optional("mail", envelope.id.uuidString.lowercased()) {
                    guard prior.envelope.sameRequest(as: envelope) else { throw ControllerError.conflict }
                    return MailPushResult(id: envelope.id, outcome: .duplicate, reason: nil)
                }
                _ = try accept(envelope, peer: peer)
                return MailPushResult(id: envelope.id, outcome: .accepted, reason: nil)
            }
        } catch let error as ControllerError {
            if case .storage = error { return MailPushResult(id: envelope.id, outcome: .refused, reason: "unavailable") }
            return MailPushResult(id: envelope.id, outcome: .refused, reason: error.description)
        } catch {
            return MailPushResult(id: envelope.id, outcome: .refused, reason: "invalid")
        }
    }

    /// What this host holds for `host`, oldest first, bounded by count and bytes.
    public func outboundBatch(for peerHost: HostID, after: Int64 = 0) throws -> (envelopes: [MailEnvelope], next: Int64) {
        let rows = try db.rows("""
            SELECT o.sequence, r.payload FROM mail_outbound AS o JOIN record AS r ON r.kind='mail' AND r.id=o.message
            WHERE o.host=? AND o.sequence>? ORDER BY o.sequence LIMIT ?
            """, [.text(peerHost.description), .integer(after), .integer(Int64(MailTransportLimits.batch))],
            pageByteLimit: MailTransportLimits.batchBytes)
        let envelopes = try rows.map { row -> MailEnvelope in (try decode(row.text(1)) as MailMessage).envelope }
        return (envelopes, rows.last?.integers[0] ?? after)
    }

    /// The pushing end records the other host's answer for each message it handed over.
    public func applyPushResults(_ results: [MailPushResult], peer: HostID) throws {
        try db.transaction {
            for result in results {
                let held = try db.rows("SELECT sequence FROM mail_outbound WHERE host=? AND message=? LIMIT 1",
                                       [.text(peer.description), .text(result.id.uuidString.lowercased())])
                guard let sequence = held.first?.integers[0] else { continue }
                if result.outcome == .refused, result.reason == "unavailable" { continue } // Retry later.
                try settle(sequence: sequence, id: result.id, refusal: result.outcome == .refused ? (result.reason ?? "refused") : nil)
            }
        }
    }

    /// Accepts a page pulled from `peer` and moves the pull cursor in the same transaction, so a
    /// crash cannot acknowledge mail this host never stored. Refusals travel on the next pull.
    public func acceptPulled(_ envelopes: [MailEnvelope], from peer: HostID, next: Int64) throws {
        try db.transaction {
            guard var record = try mailPeer(peer) else { throw ControllerError.forbidden }
            var refused: [MailRefusal] = []
            for envelope in envelopes.prefix(MailTransportLimits.batch) {
                let result = acceptPushed(envelope, peer: peer)
                if result.outcome == .refused { refused.append(MailRefusal(id: envelope.id, reason: result.reason ?? "refused")) }
            }
            record.pullCursor = max(record.pullCursor, next)
            record.pendingRefusals = refused.isEmpty ? nil : refused
            try update("mailPeer", peer.description, value: record)
        }
    }

    private func settleOutbound(for peerHost: HostID, through after: Int64, refused: [MailRefusal]) throws {
        guard after > 0 else { return }
        try db.transaction {
            let reasons = Dictionary(refused.map { ($0.id, $0.reason) }, uniquingKeysWith: { first, _ in first })
            let rows = try db.rows("SELECT sequence,message FROM mail_outbound WHERE host=? AND sequence<=? ORDER BY sequence LIMIT ?",
                                   [.text(peerHost.description), .integer(after), .integer(Int64(MailTransportLimits.batch))])
            for row in rows {
                guard let id = UUID(uuidString: try row.text(1)) else { continue }
                try settle(sequence: row.integers[0], id: id, refusal: reasons[id].map { String($0.prefix(256)) })
            }
        }
    }

    private func settle(sequence: Int64, id: UUID, refusal: String?) throws {
        try db.run("DELETE FROM mail_outbound WHERE sequence=?", [.integer(sequence)])
        var message: MailMessage = try required("mail", id.uuidString.lowercased())
        guard message.state == .outbound else { return }
        message.state = refusal == nil ? .forwarded : .bounced
        message.bounce = refusal
        try update("mail", id.uuidString.lowercased(), state: message.state.rawValue, value: message)
        try event(refusal == nil ? "mail.forwarded" : "mail.bounced", id.uuidString.lowercased())
        // A refused question would otherwise wait forever: answer it with the refusal so the
        // asking work continues and can decide what to do.
        if let refusal, let question = message.envelope.questionID {
            do {
                _ = try resolveQuestion(question, answeredBy: "host:\(try host().id)",
                                        text: "Undeliverable: the recipient's host refused this question (\(refusal)).", authorized: false)
            } catch ControllerError.conflict {}
        }
    }

    /// Peers this host initiates exchanges with, a bounded page at a time.
    public func mailPeersToSync(after: Int64, limit: Int = 8) throws -> ControllerPage<MailPeer> {
        try Limits.page(after, limit)
        let rows = try db.rows("SELECT sequence,payload FROM record WHERE kind='mailPeer' AND sequence>? ORDER BY sequence LIMIT ?",
                               [.integer(after), .integer(Int64(limit))])
        let peers = try rows.map { try decode($0.text(1)) as MailPeer }.filter { $0.transport != nil && ($0.push || $0.pull) }
        return ControllerPage(items: peers, next: rows.last?.integers[0] ?? 0)
    }
}
