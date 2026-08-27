import Foundation

/// Everything one Agent Client Protocol CLI does differently from the protocol.
///
/// Each member is here because a shipping CLI needs it today, or because ACP itself sanctions the
/// extension point (`_meta`) and an agent has put something under it. A member added *for the next
/// provider* turns into a conditional inside `ACPStreamSession`, which is the shape this value
/// exists to remove — so nothing lands here before a real agent answers differently.
///
/// It is deliberately not an `AgentKind`. A transport that can ask which runtime it is starts
/// answering per runtime, which is the comparison `scripts/check_architecture_boundaries.sh`
/// refuses; a profile can only state facts, and the runtime can only read them.
///
/// Deliberately **not** members, each for its own reason:
///
/// - The permission option kinds (`allow_once`, `reject_once`, …) are ACP-standard vocabulary, so
///   they belong to the runtime's defaults rather than to a provider.
/// - `ACPProviderExecutionAdapter` derives its audit category from the neutral `ToolIdentity`, so
///   there is nothing provider-shaped for a profile to carry.
/// - `clientInfo`, `fs: false`, `terminal: false`, `session.configOptions`, the protocol version
///   and the MCP server list are Threading's own host policy: they describe what *this client*
///   implements, and stating them per provider would let one CLI claim a capability the host does
///   not have.
/// - `steerAvailability` is a fact about the specification — ACP names no way to add to a turn in
///   flight — not about an agent.
/// - `session/new` versus `session/load` follows from the session's `ResumeState`.
struct ACPProviderProfile {

    // MARK: - Identity

    /// Names the agent inside turn-failure prose the user reads.
    let displayName: String

    /// Names the transport in logs and in `StreamParseDiagnostics`.
    let diagnosticsLabel: String

    /// Namespaces a `session/update` this client does not understand, as `prefix + wire name`.
    let unknownEventPrefix: String

    // MARK: - Handshake

    /// Merged into `clientCapabilities._meta` on `initialize`; the key is omitted when empty.
    ///
    /// ACP reserves `_meta` for exactly this, so an agent that needs a private handshake flag gets
    /// one without the standard capability object growing a vendor member.
    let clientCapabilitiesMeta: [String: Any]

    /// Reads the model from wherever an agent reports it when the standard
    /// `models.currentModelId` is absent.
    let extendedModelID: ([String: Any]?) -> String?

    /// Reads the command catalog an agent returns from `initialize`.
    ///
    /// ACP standardizes the `available_commands_update` notification but not an initial catalog,
    /// so an agent that answers with one does so under `_meta`, and an agent with none says `nil`.
    let initializeCommands: ([String: Any]?) -> [[String: Any]]?

    /// Where the opening catalog becomes complete enough to resolve a first slash command.
    let initialCommandCatalog: ACPInitialCommandCatalog

    // MARK: - Host Policy

    let commandCatalog: ACPCommandCatalogPolicy
}

/// The two ACP-sanctioned places current agents publish their opening command catalog.
enum ACPInitialCommandCatalog: Equatable {
    /// Grok returns the complete list in its `initialize` response metadata.
    case initializeResponse

    /// Cursor pushes `available_commands_update` after `session/new` completes.
    case sessionUpdate
}

/// How one agent's advertised slash commands are presented in Threading's composer.
///
/// The gating is a host decision rather than a wire fact: a command that rewrites the session the
/// agent owns cannot be sent as an ordinary prompt until Threading can update its retained state
/// atomically, so it stays visible and says why it is refused.
struct ACPCommandCatalogPolicy {
    /// Namespaces the capability id, as `prefix + command name`.
    let identifierPrefix: String

    /// Commands only the agent's own terminal may run.
    let hostOnlyNames: Set<String>

    /// Shown on a refused command instead of letting it fail on the wire.
    let hostOnlyReason: String

    /// Commands that act on the session rather than starting a turn.
    let sessionCommandNames: Set<String>
}
