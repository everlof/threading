import Foundation

/// Persisted defaults for conversations that have not chosen these values themselves.
enum NewChatDefaults {
    static let agentPersistenceKey = "defaultAgentKind"
    static let permissionPersistenceKey = "defaultPermissionMode"
    static let openingPrefixPersistenceKey = "newChatOpeningPrefix"
    /// Historical key: the suffix existed before the prefix was added.
    static let openingSuffixPersistenceKey = "newChatOpeningMessage"
    static let openingTextMaximumBytes = 1_048_576
    static let textSettingCoalescingInterval: TimeInterval = 0.4

    static func permissionMode(selected: AgentPermissionMode?,
                               appDefault: AgentPermissionMode?) -> AgentPermissionMode? {
        selected ?? appDefault
    }
}
