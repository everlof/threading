import Foundation

// MARK: - Resolved Permission Mode

/// The posture a conversation runs in when it has pinned none of its own, and where that answer
/// was read from.
///
/// The permission-mode counterpart of `ResolvedDefaultModel`, and deliberately the same shape:
/// both answer "what will this session actually do if I change nothing", both have several
/// sources of differing authority, and both are rendered by naming the value and qualifying it
/// — never by naming the place the answer lives. A chip reading "Agent's Setting" tells the user
/// to go and look somewhere else for a fact this app can read.
///
/// `mode` is nil only when no source can name one: a runtime whose configuration Threading does
/// not read, on a login that has never run it. That is the one case a caller renders as
/// `PermissionModePresentation.agentSettingTitle`.
struct ResolvedPermissionMode: Equatable {

    // MARK: - Types

    /// Which source answered. They are ordered by authority in `resolve`, and rendered
    /// differently: two of them are settings the user can go and change, and two are reports
    /// about what happened, which may not describe the next launch.
    enum Source: Equatable {
        /// Threading's own Settings ▸ General default, which becomes `--permission-mode` on the
        /// launch line and therefore outranks anything the runtime would have chosen.
        case appDefault
        /// The runtime's own configuration: Claude's `permissions.defaultMode` across its
        /// settings layers, or Codex's `approval_policy` and `sandbox_mode` pair.
        case agentConfiguration
        /// What this conversation's own transcript records it being in. A report, not a setting.
        case observedInThisConversation
        /// What this login's newest conversation was in. A report about a *different* session,
        /// used only where nothing else can answer, and qualified hardest on screen.
        case rememberedFromEarlierRun
    }

    // MARK: - Properties

    var mode: AgentPermissionMode?
    var source: Source

    // MARK: - Public Methods

    /// The mode a session inheriting from every layer above it will run in.
    ///
    /// Passed in rather than looked up so this stays pure — the caller knows its session — and
    /// so the order is testable without an account directory on disk.
    ///
    /// **Configuration outranks observation** even though observation is the more recent fact.
    /// The chip states what this conversation will run with, which for a dormant one is the next
    /// launch; a mode read out of a transcript is where the session *got to*, including a
    /// Shift+Tab the next launch will not repeat. Observation is therefore a filler for the hole
    /// configuration leaves, not a correction of it.
    ///
    /// The lower sources are autoclosures because each costs something to fetch — a settings
    /// read, a directory walk — and a caller with an app-wide default set must not pay for three
    /// answers it will not use on every refresh.
    static func resolve(
        appDefault: AgentPermissionMode?,
        configured: @autoclosure () -> AgentPermissionMode?,
        observed: @autoclosure () -> AgentPermissionMode? = nil,
        remembered: @autoclosure () -> AgentPermissionMode? = nil
    ) -> ResolvedPermissionMode {
        if let appDefault {
            return ResolvedPermissionMode(mode: appDefault, source: .appDefault)
        }
        if let configured = configured() {
            return ResolvedPermissionMode(mode: configured, source: .agentConfiguration)
        }
        if let observed = observed() {
            return ResolvedPermissionMode(mode: observed, source: .observedInThisConversation)
        }
        if let remembered = remembered() {
            return ResolvedPermissionMode(mode: remembered, source: .rememberedFromEarlierRun)
        }
        return ResolvedPermissionMode(mode: nil, source: .agentConfiguration)
    }

    /// The same answer, gathering each source itself.
    ///
    /// `observed` stays a parameter because only the caller knows whether it has a conversation
    /// to ask about, and asking costs a transcript scan that a composer with no session must not
    /// pay. Everything else is a file read this type is willing to make.
    @MainActor
    static func inherited(
        for kind: AgentKind,
        account: AgentAccount?,
        projectDirectory: String?,
        observed: AgentPermissionMode? = nil
    ) -> ResolvedPermissionMode {
        resolve(
            appDefault: AppSettings.shared.defaultPermissionMode,
            configured: configured(
                for: kind,
                account: account,
                projectDirectory: projectDirectory
            ),
            observed: observed,
            remembered: account.flatMap(ClaudeAccountLastRunPermissionMode.lastRunMode)
        )
    }

    /// What the runtime's own configuration chooses for a session Threading launches without
    /// stating a mode, or nil where this app does not read that runtime's configuration.
    ///
    /// The exhaustive switch is the table, the same shape and for the same reason as
    /// `ObservedPermissionMode.record(for:)`: a fifth `AgentKind` is a build error here rather
    /// than a silent nil under whichever `else` was written first.
    ///
    /// Grok exposes the same six modes on its launch line but states none of them in
    /// `~/.grok/config.toml` — its `[ui] yolo` is a different switch, not one of the six — and
    /// OpenCode owns a richer per-tool policy that no single mode names. Both answer nil, which
    /// is the honest reading of a file that does not state the fact.
    static func configured(
        for kind: AgentKind,
        account: AgentAccount?,
        projectDirectory: String?
    ) -> AgentPermissionMode? {
        guard let account else { return nil }

        switch kind {
        case .claude:
            return ClaudeSettings.permissionMode(
                account: account,
                projectDirectory: projectDirectory
            )

        case .codex:
            return AgentPermissionMode(
                codexApprovalPolicy: AgentModels.configuredCodexValue(
                    AgentDefaults.codexApprovalPolicyKey,
                    account: account
                ),
                sandboxMode: AgentModels.configuredCodexValue(
                    AgentDefaults.codexSandboxModeKey,
                    account: account
                )
            )

        case .grok, .openCode:
            return nil
        }
    }
}
