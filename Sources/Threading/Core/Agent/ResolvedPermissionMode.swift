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
        /// settings layers, or Codex's approval, sandbox and reviewer configuration.
        case agentConfiguration
        /// What this conversation's own transcript records it being in. A report, not a setting.
        case observedInThisConversation
        /// What this login's newest conversation was in. A report about a *different* session,
        /// used only where nothing else can answer, and qualified hardest on screen.
        case rememberedFromEarlierRun

        // MARK: - Authority

        /// Whether this source will state the mode *again* on the next launch.
        ///
        /// The two settings will: Threading's own default becomes `--permission-mode` on the
        /// launch line, and the runtime reads its own configuration itself. The two reports will
        /// not — nothing replays a mode a transcript recorded, so a session that inherits one
        /// starts in the runtime's own fallback instead, which for Claude is `manual`.
        ///
        /// This is the difference between offering a posture and promising one, and it shipped
        /// wrong: the menu marked the *remembered* mode as the row to inherit, so choosing Auto
        /// recorded "follow the setting", the launch line carried no flag, and the session asked
        /// before every tool while its chip read Auto. Anything turning this answer into
        /// behaviour asks here first and pins the mode when it is false.
        var governsNextLaunch: Bool {
            switch self {
            case .appDefault, .agentConfiguration: return true
            case .observedInThisConversation, .rememberedFromEarlierRun: return false
            }
        }

        /// Whether this source describes the posture the agent is in **now**, rather than one it
        /// would start in. Only observation does, and only because the surfaces that pass it read
        /// their own *running* conversation — a dormant one passes nothing, since the same
        /// reading would then be a fact about a process that has exited.
        var describesTheRunningAgent: Bool {
            switch self {
            case .observedInThisConversation: return true
            case .appDefault, .agentConfiguration, .rememberedFromEarlierRun: return false
            }
        }
    }

    // MARK: - Properties

    var mode: AgentPermissionMode?
    var source: Source

    /// The mode the next launch will genuinely run in, and nil for every answer that only
    /// reports one. Nil is not "unknown": it means the runtime's own fallback decides, which is
    /// the closed end of the range, and it is what a surface offering *inherit* must be holding
    /// before it offers it.
    var governingMode: AgentPermissionMode? {
        source.governsNextLaunch ? mode : nil
    }

    /// The mode a chip may name as the one in force — what a setting states for the next launch,
    /// or what the agent is running in right now. A mode remembered from a *different* session is
    /// neither, and naming it is how this app came to promise a posture nothing would apply.
    var nameableMode: AgentPermissionMode? {
        source.governsNextLaunch || source.describesTheRunningAgent ? mode : nil
    }

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
                ),
                approvalsReviewer: AgentModels.configuredCodexValue(
                    AgentDefaults.codexApprovalsReviewerKey,
                    account: account
                )
            )

        case .grok, .openCode, .cursor:
            return nil
        }
    }
}
