import Foundation

// MARK: - Claude Status Line Settings

/// The `statusLine` command an account would run, and the wrapper that silences it.
///
/// Claude renders a status line from its interactive TUI only: a native conversation runs
/// `--print --output-format stream-json`, where the CLI never mounts the component and never
/// invokes the command. So this question exists for **terminal** sessions alone.
///
/// **What the line prints is deliberately not asked.** Threading used to run the account's own
/// command with a truthful payload and search the output for values it already held, so the
/// session's status card could add only the facts the line left out. That is gone: the card now
/// shows every fact it can extract, always. Running another program on every session switch to
/// decide whether to *hide* one of our own rows cost a subprocess, a cache keyed on the command,
/// and a rule that could only fail by hiding something the user asked for — while the thing it
/// bought, a fact appearing twice in one pane, is the cheap outcome. See
/// [`git.md`](../../../../docs/architecture/git.md).
///
/// What remains is settings resolution, which reads files and runs nothing.
enum ClaudeStatusLineSettings {

    // MARK: - Public Methods

    /// The exact silencing wrapper the launcher writes when the user suppresses the line: the
    /// account's own command still runs — these commands are commonly bridges whose side
    /// effects matter, Claudex's usage cache being the live example — but nothing reaches the
    /// terminal. A brace group so a command that is itself a pipeline or list wraps whole,
    /// and stderr silenced too: a suppressed line must not degrade into a stray error line.
    ///
    /// Verified against the real bridge (2026-07-31): wrapped, it still rewrote its heartbeat
    /// while printing nothing. `type: "none"` was tried first and is a trap — the CLI schema-
    /// rejects the whole settings file, which would take the permission hooks down with it.
    static func silencedCommand(wrapping command: String) -> String {
        "{ \(command) ; } >/dev/null 2>&1"
    }

    /// The `statusLine` command that would run for this account in this project.
    ///
    /// The CLI's own order, which is *not* a merge for this key: a managed policy replaces the
    /// user's value outright (`policySettings.statusLine` is read *instead of* it), while the
    /// three writable layers override one another most-specific-first. Only `type: "command"`
    /// runs; any other shape draws nothing, so there is nothing to silence.
    ///
    /// That order is `ClaudeSettings`', not this type's: the permission mode and the speed
    /// resolve through exactly the same four files, and one of the three reading them privately
    /// would be a chain that could go stale in one place and not the others.
    static func resolvedCommand(account: AgentAccount, projectDirectory: String) -> String? {
        ClaudeSettings.statusLineCommand(account: account, projectDirectory: projectDirectory)
    }
}

// MARK: - Defaults

enum ClaudeSettingsDefaults {
    /// The enterprise layer, which *replaces* the user's `statusLine` rather than merging with it.
    static let managedSettingsPath = "/Library/Application Support/ClaudeCode/managed-settings.json"
    static let projectSettingsDirectory = ".claude"
    static let settingsFile = "settings.json"
    static let localSettingsFile = "settings.local.json"
    static let statusLineKey = "statusLine"
    static let typeKey = "type"
    static let commandKey = "command"

    /// How much a session may do before it has to ask, in the CLI's own spelling.
    /// `manual` is accepted as an alias for `default`; both read as `AgentPermissionMode.manual`.
    static let permissionsKey = "permissions"
    static let defaultModeKey = "defaultMode"
    /// The only shape that draws anything; a `statusLine` of any other type has nothing to hide.
    static let commandType = "command"
    static let maxSettingsBytes = 1 << 20
}
