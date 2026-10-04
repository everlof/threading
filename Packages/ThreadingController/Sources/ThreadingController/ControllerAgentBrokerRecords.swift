import Foundation

/// Where the resident supervisor serves agent tools (`ControllerAgentBroker` in the runtime).
/// Written when its socket is listening and withdrawn when it stops; a crash can leave it behind,
/// so a reader also proves the socket answers before relying on it.
public struct ControllerAgentBrokerAdvertisement: Codable, Equatable, Sendable {
    public let socket: String
    public let since: String
}

/// What the broker records about who connected. Informational only: the credential is the
/// authority, and the peer's uid is evidence for an owner reading the history afterwards.
public enum ControllerAgentPeerEvent: Sendable {
    /// The first request a peer uid made for an execution or mailbox in this broker's lifetime.
    case served(subject: AgentSubject, uid: UInt32)
    /// A request refused before any operation ran (a wrong credential, an unknown caller, an
    /// unreadable request). Rate-limited by the broker.
    case refused(uid: UInt32, reason: String)

    public enum AgentSubject: Sendable {
        case execution(ExecutionID)
        case mailbox(MailAddress)
    }
}

extension ControllerStore {
    static let brokerKind = "agentBroker"
    static let brokerID = "current"
    static let refusalReasonLimit = 64

    public func advertiseAgentBroker(socket: String) throws -> ControllerAgentBrokerAdvertisement {
        try Limits.text(socket, field: "agent_socket", maximum: 4096)
        let value = ControllerAgentBrokerAdvertisement(socket: socket, since: Self.now())
        try db.transaction {
            try db.run("""
                INSERT INTO record(kind,id,payload) VALUES(?,?,?)
                ON CONFLICT(kind,id) DO UPDATE SET payload=excluded.payload
                """, [.text(Self.brokerKind), .text(Self.brokerID), .text(try encode(value))])
            try event("agent.broker_listening", socket)
        }
        return value
    }

    /// Removes the advertisement only when it still names this socket, so a supervisor that
    /// stops late does not withdraw a successor's.
    public func withdrawAgentBroker(socket: String) throws {
        try db.transaction {
            guard let current: ControllerAgentBrokerAdvertisement = try optional(Self.brokerKind, Self.brokerID),
                  current.socket == socket else { return }
            try db.run("DELETE FROM record WHERE kind=? AND id=?", [.text(Self.brokerKind), .text(Self.brokerID)])
            try event("agent.broker_stopped", socket)
        }
    }

    public func agentBrokerAdvertisement() throws -> ControllerAgentBrokerAdvertisement? {
        try optional(Self.brokerKind, Self.brokerID)
    }

    public func recordAgentPeer(_ value: ControllerAgentPeerEvent) throws {
        try db.transaction {
            switch value {
            case .served(.execution(let id), let uid):
                // A launch-family event, so it also lands in the work's history beside the launch.
                try event("launch.agent_peer", id.description, text: "peer uid \(uid)")
            case .served(.mailbox(let address), let uid):
                try event("mail.agent_peer", "\(address.description) uid=\(uid)")
            case .refused(let uid, let reason):
                try event("agent.broker_refused", "uid=\(uid) \(reason.prefix(Self.refusalReasonLimit))")
            }
        }
    }
}

extension ControllerStore {
    /// A dispatch in the same-account compatibility mode: the child was given the store path.
    public func recordLegacyAgentDatabase(_ id: ExecutionID) throws {
        try db.transaction { try event("launch.legacy_agent_database", id.description, text: "agent tools open the store directly") }
    }
}
