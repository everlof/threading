import Foundation

/// Owner policy for this host. Agents can observe the limit, but cannot change it.
public struct MailPolicy: Codable, Equatable, Sendable {
    public static let defaultChainMessageLimit = 50
    public let chainMessageLimit: Int

    public init(chainMessageLimit: Int = Self.defaultChainMessageLimit) {
        self.chainMessageLimit = chainMessageLimit
    }

    public static let agentGuidance = """
        Mail chains have an owner-configured message limit shared by all participants on each host. \
        Reading or acknowledging mail does not reset it. A new human prompt clears a chat session's \
        inherited chain, so its next send without reply_to can start a new chain. reply_to an old \
        message still uses that old chain; reading or acknowledging old mail can inherit it again. \
        When the limit refuses a send, tell the user in the chat that the message was not sent, \
        quote the reported limit, and explain how a new prompt can start a fresh chain. Do not \
        retry automatically or change the owner's limit to get around it.
        """

    public static func limitReachedMessage(_ limit: Int) -> String {
        """
        Message not sent: this mail chain has reached this host's configured limit of \(limit) messages. \
        Tell the user in the chat what was not delivered and why. A new human prompt clears this \
        chat session's inherited chain; after that, a send without reply_to can start a fresh chain. \
        The old chain stays capped: replying to, reading or acknowledging old mail can continue it. \
        Reading and acknowledging do not free message capacity. The owner can change the limit in \
        Settings > Tools > Mail chain message limit on this Mac, or with mail-policy-set on the \
        host that refused the message. Autonomous workers need new owner-started work or an owner \
        policy change. Do not retry automatically.
        """
    }
}

extension ControllerStore {
    public func mailPolicy() throws -> MailPolicy {
        try optional("mailPolicy", "host") ?? MailPolicy()
    }

    /// Owner-only entry point, deliberately absent from the agent broker and MCP tool set.
    @discardableResult
    public func setMailPolicy(chainMessageLimit: Int) throws -> MailPolicy {
        guard chainMessageLimit > 0 else { throw ControllerError.invalidInput("chain_message_limit") }
        return try db.transaction {
            let policy = MailPolicy(chainMessageLimit: chainMessageLimit)
            if let prior: MailPolicy = try optional("mailPolicy", "host") {
                guard prior != policy else { return prior }
                try update("mailPolicy", "host", value: policy)
            } else {
                try insert("mailPolicy", "host", value: policy)
            }
            try event("mail.policy_changed", "host")
            return policy
        }
    }
}
