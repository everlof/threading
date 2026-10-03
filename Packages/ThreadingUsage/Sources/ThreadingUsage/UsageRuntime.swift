import Foundation

/// The agent runtimes whose transcripts this package can account for.
///
/// The app's `AgentKind` decides what the host may do with a runtime; this names only what the
/// ledger needs from one — the stable identifier stored in every `UsageOrigin` and the name the
/// Usage page shows. The raw values and names are persisted in ledger rows, so they must stay
/// equal to `AgentKind`'s; the app's test suite pins that.
public enum UsageRuntime: String, Codable, CaseIterable, Sendable {
    case claude
    case codex
    case grok
    case openCode = "opencode"
    case cursor

    /// Human-readable runtime name, retained in `UsageOrigin.runtimeName`.
    public var displayName: String {
        switch self {
        case .claude: return "Claude Code"
        case .codex: return "Codex"
        case .grok: return "Grok"
        case .openCode: return "OpenCode"
        case .cursor: return "Cursor"
        }
    }
}
