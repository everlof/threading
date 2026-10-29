/// The app-wide speed posture for sessions without a conversation override.
/// Omission preserves the provider's own configuration; Standard explicitly turns Fast off.
enum AgentStartupSpeed: String, CaseIterable {
    case agentSetting
    case standard
    case fast

    static let claudePersistenceKey = "claudeStartupSpeed"
    static let codexPersistenceKey = "codexStartupSpeed"

    var fastModeOverride: Bool? {
        switch self {
        case .agentSetting: nil
        case .standard: false
        case .fast: true
        }
    }

    static func persistenceKey(for kind: AgentKind) -> String? {
        switch kind {
        case .claude: claudePersistenceKey
        case .codex: codexPersistenceKey
        case .grok, .openCode, .cursor: nil
        }
    }

    /// The provider's configuration is read only if neither more specific choice is present.
    func resolve(selected: Bool?, configured: @autoclosure () -> Bool?) -> Bool? {
        selected ?? fastModeOverride ?? configured()
    }
}
