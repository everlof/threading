import Foundation

/// A distinct login for an agent CLI.
///
/// Both CLIs support multiple accounts by pointing an environment variable at an alternate
/// config directory (`CLAUDE_CONFIG_DIR`, `CODEX_HOME`). Each such directory is its own
/// account with its own conversation history.
struct AgentAccount: Equatable, Identifiable {

    // MARK: - Properties

    let provider: AgentKind

    /// Directory name minus its leading dot, or `default` for the CLI's standard location.
    let handle: String

    /// Absolute path of the config directory backing this account.
    let configPath: String

    /// Name shown in menus. A user override wins, then the user's own shell alias.
    let displayName: String

    /// Emoji shown in place of the agent's symbol, when the user has chosen one.
    let emoji: String?

    var id: String { "\(provider.rawValue):\(handle)" }

    /// Whether this is the CLI's standard config location rather than an alternate home.
    var isDefault: Bool { handle == AgentAccountDefaults.defaultHandle }

    // MARK: - Initialization

    init(
        provider: AgentKind,
        handle: String,
        configPath: String,
        displayName: String? = nil,
        emoji: String? = nil
    ) {
        self.provider = provider
        self.handle = handle
        self.configPath = configPath
        self.displayName = displayName ?? handle
        self.emoji = emoji
    }

    /// Identifier for an account before one has been constructed, used to read stored
    /// preferences during discovery.
    static func identifier(provider: AgentKind, handle: String) -> String {
        "\(provider.rawValue):\(handle)"
    }
}

// MARK: - Session Account Display

extension AgentSession {

    /// The account name for this session's tooltip, if one is worth showing.
    ///
    /// Only alternate accounts are labelled: the default account needs no badge, and a
    /// session already titled after its account would only repeat itself.
    var accountLineText: String? {
        guard let account = AgentAccountDiscovery.account(for: kind, handle: accountHandle),
              !account.isDefault,
              !displayTitle.localizedCaseInsensitiveContains(account.displayName)
        else { return nil }

        return account.displayName
    }
}

// MARK: - Agent Account Defaults

enum AgentAccountDefaults {
    /// Handle reserved for the CLI's standard config directory.
    static let defaultHandle = "default"

    /// Label shown for the standard account when no alias names it.
    static let defaultDisplayName = "Default"

    static let claudeDirectoryPrefix = ".claude-"
    static let codexDirectoryPrefix = ".codex-"

    static let claudeDefaultDirectory = ".claude"
    static let codexDefaultDirectory = ".codex"

    /// Files proving a directory is a real Claude config directory.
    static let claudeConfigMarkers = [".claude.json", "settings.json"]

    /// File proving a Codex home holds a completed login.
    static let codexAuthMarker = "auth.json"

    /// Claude Science's reserved data root. It carries Claude-shaped state but is not a
    /// login slot, so it must never appear as an account.
    static let claudeScienceDirectory = ".claude-science"

    /// Structural markers identifying a Claude Science data root under a custom name.
    /// All must be present, so an ordinary config directory is never excluded by accident.
    static let claudeScienceFileMarker = "install-id"
    static let claudeScienceDirectoryMarkers = ["runtime", "orgs"]

    /// Subdirectory holding recorded sessions, relative to an account's config directory.
    static let sessionsSubdirectory = "sessions"
}
