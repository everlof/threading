import Foundation

/// Cursor's ACP profile, verified against `cursor-agent` 2026.08.11-e8db854 and ACP protocol
/// version 1.
///
/// Every value below cites the measurement behind it in
/// [`CURSOR_ACP_FINDINGS.md`](../../../../docs/CURSOR_ACP_FINDINGS.md). The second ACP provider
/// was supposed to cost one value and a launch line, and it does — but only because each of these
/// members was already the seam the runtime reads instead of asking who it is running.
extension ACPProviderProfile {
    static var cursor: ACPProviderProfile {
        ACPProviderProfile(
            displayName: CursorACPDefaults.displayName,
            diagnosticsLabel: CursorACPDefaults.diagnosticsLabel,
            unknownEventPrefix: CursorACPDefaults.unknownEventPrefix,
            // Empty **on purpose, and it is a decision rather than an omission.** Cursor reads
            // `clientCapabilities._meta.parameterizedModelPicker` at `initialize` and it selects
            // between two model-id spaces that are *disjoint* (§10.1): with the flag, ids are
            // bare (`claude-opus-5`) and names are marketing names; without it, ids carry their
            // variant parameters (`claude-opus-5[thinking=true,context=300k,…]`). §10.2 measured
            // `session/set_model` refusing an id from the other space with
            // `-32602 Invalid model value`. A host must pick one and stay in it, and Threading
            // stays in the raw one — the space this session's own `models` list is quoted in,
            // so any id Threading ever echoes back came from the same answer that gave it.
            clientCapabilitiesMeta: [:],
            // Nil, because the standard reader already has it. §10.1's verbatim `session/new`
            // result carries `models.currentModelId` (`"default[]"`, Cursor's Auto), and §10.4's
            // `session/load` result carries the same `models` object — so
            // `ACPWireAdapter.currentModel(in:)` answers for both, and a reader here would be
            // dead code pretending to cover something.
            extendedModelID: { _ in nil },
            // Nil for the same shape of reason: Cursor's `initialize` response carries no `_meta`
            // at all (§3), and its command list arrives unsolicited as an
            // `available_commands_update` notification about 0.7 s after the session opens
            // (§10.2) — the standard path the runtime already handles.
            initializeCommands: { _ in nil },
            commandCatalog: CursorACPComposerCatalog.policy
        )
    }
}

// MARK: - Composer Catalog

enum CursorACPComposerCatalog {
    /// Computed rather than stored: the refusal reason is localized, and a stored global would
    /// freeze the first language the process resolved.
    ///
    /// The catalog Cursor pushes is **account state, not a protocol constant** (§10.2): the 23
    /// entries measured on 2026-08-12 mixed Cursor's builtin skills with the user's own commands
    /// and their projects'. Only the builtins can be named here, and only those whose *effect*
    /// Threading cannot honour are refused — a user command this app has never heard of stays an
    /// ordinary turn, which is the behaviour a per-account list requires.
    static var policy: ACPCommandCatalogPolicy {
        ACPCommandCatalogPolicy(
            identifierPrefix: CursorACPDefaults.commandIdentifierPrefix,
            hostOnlyNames: [
                // Copies to the clipboard *from the CLI's own TUI*, which is not running here.
                "copy-request-id",
                // Configures the status line that TUI draws. Native Chat draws none.
                "statusline",
                // Edits `~/.cursor/cli-config.json` — the user's global CLI configuration,
                // shared with every other Cursor client. The same blast radius that makes
                // `allow_always` worth naming (§10.5), from a chat that cannot show the diff.
                "update-cli-config",
                // Installs recurring work inside the session. Threading has its own scheduled
                // messages with a visible record and a way to stop them; a second, invisible
                // schedule the host cannot see or cancel is the one thing worse than neither.
                "loop"
            ],
            hostOnlyReason: L10n.string(
                "Available in Cursor's own terminal; not available in native Chat yet"
            ),
            // Renames the retained conversation rather than answering anything. It is safe to
            // run — the new name comes back as the standard `session_info_update` (§10.3) that
            // Threading already routes through its protected agent-title slot — but it acts on
            // the session, so it is presented as an action rather than as a turn.
            sessionCommandNames: ["rename-chat"]
        )
    }
}

// MARK: - Constants

private enum CursorACPDefaults {
    static let displayName = "Cursor"
    static let diagnosticsLabel = "Cursor ACP"
    static let unknownEventPrefix = "cursor.acp."
    static let commandIdentifierPrefix = "cursor.command:"
}
