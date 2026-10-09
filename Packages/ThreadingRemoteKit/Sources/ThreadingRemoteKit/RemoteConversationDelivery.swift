import Foundation

public enum RemoteConversationDeliveryMode: String, Codable, Sendable {
    case queue
    case steer
}

/// Optional metadata supplies live capabilities. The hello's conversationFollowups feature
/// also gates retries, before the new connection's first snapshot has arrived.
public struct RemoteConversationDeliveryDTO: Codable, Equatable, Sendable {
    public struct Message: Codable, Equatable, Identifiable, Sendable {
        public enum State: String, Codable, Sendable { case queued, sending, delivered, working }
        public let id: String
        public let summary: String
        public let state: State

        public init(id: String, summary: String, state: State) {
            self.id = id
            self.summary = String(summary.prefix(512))
            self.state = state
        }
    }

    public let canQueue: Bool
    public let canSteer: Bool
    public let messages: [Message]

    public init(canQueue: Bool, canSteer: Bool, messages: [Message] = []) {
        self.canQueue = canQueue
        self.canSteer = canSteer
        self.messages = Array(messages.prefix(20))
    }

    public func allowingInput(_ allowed: Bool) -> Self {
        Self(canQueue: allowed && canQueue, canSteer: allowed && canSteer, messages: messages)
    }
}
