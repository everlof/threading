import Foundation

// MARK: - Projects State Version

enum ProjectsStateVersion {
    /// 2 dropped `AgentKind.shell`. A version-1 document may hold shell sessions, which no
    /// longer decode — `StateManager` strips them on the way through.
    static let current = 2
}

// MARK: - Agent Kind

/// The kind of program a session hosts.
/// A session is a *conversation*, so this names an agent and nothing else.
///
/// A shell used to be one of these — a sidebar row with a title, a launch record and an
/// account slot it could never use, for something with no conversation to resume, no
/// transcript, and nothing to import. It is now a surface belonging to a conversation
/// (`ShellDrawerViewController`), which is what it always was in practice. What that removes
/// is not one case: it is every branch in this file, in the launcher, the replayer, the
/// account discovery and the usage service that existed to say "not for shells".
enum AgentKind: String, Codable, CaseIterable {
    case claude
    case codex

    /// Human-readable name shown in menus and the sidebar.
    var displayName: String {
        switch self {
        case .claude: return "Claude Code"
        case .codex: return "Codex"
        }
    }

    /// The agent's own interactive TUI, hosted inside Threading's terminal surface.
    var originalUITitle: String { L10n.format("%@ UI", displayName) }

    /// The executable invoked on the user's PATH.
    var executableName: String {
        switch self {
        case .claude: return AgentDefaults.claudeExecutable
        case .codex: return AgentDefaults.codexExecutable
        }
    }

    /// Whether sessions of this kind can be resumed by identifier after exiting.
    ///
    /// Every kind can, now that shells are not a kind. Kept as a property rather than deleted
    /// with its call sites, because a future agent without a resume story would need it back
    /// and the branches reading it are the honest place to notice.
    var supportsResume: Bool { true }

    /// Whether the session identifier can be chosen by us before launch.
    ///
    /// Claude accepts `--session-id <uuid>`, so we mint it. Codex assigns its own,
    /// which must be discovered afterwards via `CodexSessionDiscovery`.
    var supportsPresetSessionID: Bool {
        self == .claude
    }

    /// Whether this agent supports multiple logins.
    var supportsAccounts: Bool { true }

    /// Whether Threading may render this agent's conversation itself, instead of a terminal.
    ///
    /// Both agents qualify: each exposes a supported headless transport — Codex app-server
    /// and `claude -p --output-format stream-json` — that Threading drives by spawning the
    /// user's own installed CLI, authenticated by whatever `claude auth login` / `codex login`
    /// already put on disk. No token is read, and no request is routed on the user's behalf,
    /// which is the line Anthropic's policy actually draws.
    ///
    /// Claude was excluded here for most of this project's life on the belief that `claude -p`
    /// on a subscription was off-limits to third-party apps. That was true of the February 2026
    /// terms as they read at the time, and is no longer: Anthropic's help centre now lists
    /// `claude -p` and "third-party apps that authenticate with your Claude subscription" as
    /// subscription-drawing usage, and the June 2026 attempt to move them onto separate metered
    /// credits was withdrawn on the day it was to take effect. That withdrawal was explicitly
    /// a pause, so this may become an economic choice — headless turns billed at API rates
    /// rather than against the plan — but it is a *permitted* one either way.
    var supportsNativeUI: Bool { true }

    /// Whether a conversation of this agent can be forked into a side chat.
    ///
    /// Claude only, and measured rather than assumed: `--fork-session` resumes a
    /// conversation into a *new* transcript, leaving the original untouched, and honours a
    /// `--session-id` given alongside it — so the child's identifier is minted up front like
    /// any other Claude session. Codex has no equivalent (`codex exec resume` takes an id and
    /// a prompt, nothing more), and forging one by copying its rollout is unproven.
    var supportsForking: Bool {
        self == .claude
    }

    /// Environment variable redirecting this CLI to an alternate config directory.
    var accountEnvironmentKey: String {
        switch self {
        case .claude: return "CLAUDE_CONFIG_DIR"
        case .codex: return "CODEX_HOME"
        }
    }
}

// MARK: - Resume State

/// Whether a session can identify a conversation to resume.
enum ResumeState: Equatable {
    /// This kind of session has no resumable conversation, as with a shell.
    case unavailable

    /// An agent conversation has not received its provider identifier yet.
    case awaitingIdentifier

    /// The provider identifier for an existing conversation.
    case resumable(TranscriptID)

    var transcriptID: TranscriptID? {
        guard case .resumable(let id) = self else { return nil }
        return id
    }

    var isResumable: Bool {
        if case .resumable = self { return true }
        return false
    }

    static func initial(for kind: AgentKind) -> ResumeState {
        kind.supportsResume ? .awaitingIdentifier : .unavailable
    }

    static func restoring(_ transcriptID: TranscriptID?, for kind: AgentKind) -> ResumeState {
        guard kind.supportsResume else { return .unavailable }
        return transcriptID.map(ResumeState.resumable) ?? .awaitingIdentifier
    }
}

// MARK: - Provider Configuration

/// How a Claude session was created.
///
/// Forking is deliberately absent from the Codex configuration below: Codex has no provider
/// operation with those semantics. Cross-provider continuation also names its source provider
/// in the case itself, so a destination cannot claim it continued from its own provider.
enum ClaudeSessionOrigin: Equatable {
    case original
    case forked(from: SessionID)
    case continuedFromCodex(SessionID)
}

/// Provider-specific session state.
///
/// This replaces five independent optionals (`kind`, reasoning effort, Remote Control, fork
/// parent, and continuation kind) whose Cartesian product admitted states neither provider
/// could execute. Pattern matching now has to account only for states the product supports.
enum AgentSessionConfiguration: Equatable {
    case claude(remoteControl: Bool?, origin: ClaudeSessionOrigin)
    case codex(reasoningEffort: String?, continuedFromClaude: SessionID?)

    var kind: AgentKind {
        switch self {
        case .claude: return .claude
        case .codex: return .codex
        }
    }

    fileprivate var derivedSessionID: SessionID? {
        switch self {
        case .claude(_, .forked(let source)),
             .claude(_, .continuedFromCodex(let source)),
             .codex(_, .some(let source)):
            return source
        case .claude, .codex:
            return nil
        }
    }
}

// MARK: - Agent Session

/// A single agent conversation or shell belonging to a project.
///
/// The session outlives its terminal: when the agent exits, the PTY is torn down but
/// this record remains so the conversation can be resumed through `resumeState` later.
struct AgentSession: Codable, Identifiable {
    let id: SessionID
    private var configuration: AgentSessionConfiguration

    var kind: AgentKind { configuration.kind }

    /// The name derived from the session's first prompt — set at creation when the composer
    /// has the prompt, or by the first `UserPromptSubmit` report for a prompt typed straight
    /// into the terminal. Empty until a prompt exists; the display falls back to a generic
    /// label then, never to the agent's or account's name, which the row's icon and chip
    /// already carry.
    var title: String

    /// An explicit rename by the user. Takes precedence over the agent's own title,
    /// so a deliberate name is never overwritten by agent activity.
    var customTitle: String?

    /// The agent's own name for the conversation, by whichever transport last reported it:
    /// the terminal title while a PTY is attached, or the transcript's title records read
    /// when a turn ends — which is what names a native session, and what survives a surface
    /// switch. Retained after the agent exits so a dormant session still shows what it was.
    ///
    /// Stored under the `terminalTitle` key it had when the terminal was the only transport,
    /// so existing records decode unchanged.
    var agentTitle: String?

    let createdAt: Date
    var lastActiveAt: Date

    /// Whether this record has no conversation, is waiting for an identifier, or can resume.
    ///
    /// Claude's identifier is minted at first launch. Codex reports its identifier after
    /// launch. Shells stay `.unavailable` for their lifetime.
    var resumeState: ResumeState

    /// Whether this session has been launched at least once, distinguishing a first
    /// launch from a resume.
    var hasLaunched: Bool

    /// Exit code from the most recent run, if it has ended.
    var lastExitCode: Int32?

    /// Which agent login this session belongs to. `.standard` means the provider's default.
    ///
    /// Conversations are stored per account, so this must be stable across resumes: the same
    /// identifier resumed under a different account would not be found.
    var accountHandle: AccountHandle

    /// Model the session was started with, passed again on resume so it does not drift.
    /// Nil uses whatever the CLI defaults to.
    var model: String?

    /// A per-conversation Codex reasoning-effort override.
    ///
    /// Nil inherits the routed account when that value is supported by the selected model,
    /// otherwise the model catalog's own default. The value stays a string because the catalog
    /// is authoritative and may add levels without a Threading release.
    var reasoningEffort: String? {
        guard case .codex(let value, _) = configuration else { return nil }
        return value
    }

    /// A per-conversation Fast-mode override.
    ///
    /// Nil inherits the routed account's setting, true requests Fast, and false explicitly
    /// requests Standard. The third state matters: decoding an older session must not silently
    /// turn off an account whose config already selected Fast.
    ///
    /// Claude applies this through its persistent print transport's control protocol. Codex
    /// maps it onto the next app-server `turn/start` request's `serviceTier` while preserving
    /// the same process and conversation id.
    var fastMode: Bool?

    /// A per-conversation override for Claude's Remote Control bridge — the built-in feature
    /// that lets claude.ai and the mobile app drive this session.
    ///
    /// Nil defers to `AppSettings.claudeRemoteControl`, which in turn may defer to Claude's own
    /// `/config`. True and false are decisions this conversation made for itself and keep
    /// making on every resume. The third state is what lets one chat stay off the network while
    /// the rest follow whatever default is set later.
    ///
    /// Applied by writing `remoteControlAtStartup` into the per-session settings file Threading
    /// already passes as `--settings`; see `MCPSessionRegistry.writeHookSettings`. Claude reads
    /// merged settings ahead of its global config, so a value here wins. Claude only — Codex has
    /// no equivalent bridge.
    var remoteControl: Bool? {
        guard case .claude(let value, _) = configuration else { return nil }
        return value
    }

    /// How much this conversation may do before it has to ask.
    ///
    /// Nil defers to `AppSettings.defaultPermissionMode`, which may itself defer to the CLI's
    /// own configuration — Claude's `permissions.defaultMode`, Codex's `config.toml`. The third
    /// state is what keeps an installed update from changing anyone's agent: a mode written to
    /// mean "no opinion" would override a config the user set deliberately, exactly the trap
    /// `remoteControl` above is shaped around.
    ///
    /// This records the mode the session is **launched** in, not a live mirror of the mode it is
    /// in now. A terminal session's own Shift+Tab is invisible to Threading, so changing this
    /// while a session runs takes effect on its next launch.
    var permissionMode: AgentPermissionMode?

    /// The branch of the checkout this session runs in, as last observed.
    ///
    /// A branch belongs to a checkout, not a session. This records the checkout's branch as
    /// this session knows it: captured at creation, re-read each time the session stops
    /// working, and — while `AppSettings.followsCheckoutBranch` is on, the default — kept
    /// following the checkout even while dormant (`CheckoutBranchFollower`), because a
    /// dormant session resumes onto whatever the checkout is on *now*. With that setting
    /// off the record freezes while dormant instead, keeping the branch the conversation
    /// actually happened on. It drives the sidebar's optional branch grouping. Nil for
    /// non-git projects and when no branch was available while decoding an older record.
    var branch: String?

    /// The session this one was forked from, for a **side chat** — a conversation started
    /// with a copy of another's context so a question can be asked without joining the
    /// record it asks about.
    ///
    /// Threading's own bookkeeping, because the CLI keeps none: a forked transcript carries no
    /// reference to its ancestor (measured — the only trace was a stale `session_id` left on
    /// one copied record, while every `sessionId` was rewritten to the fork's).
    ///
    /// It is read at *launch* rather than being a lasting mode: the fork happens once, when
    /// the child first runs, and afterwards this is lineage rather than behaviour. See
    /// `AgentLauncher.claudeForkCommand`.
    var forkedFrom: SessionID? {
        guard case .claude(_, .forked(let parent)) = configuration else { return nil }
        return parent
    }

    /// Whether this session began as a fork of another.
    var isSideChat: Bool { forkedFrom != nil }

    /// The session whose visible conversation seeded this one on another provider.
    ///
    /// Unlike `forkedFrom`, this is never handed to either CLI as a resume identifier. Threading
    /// snapshots the source transcript, normalises it through `TranscriptReplay`, and exposes
    /// only that snapshot to this session through the scoped `conversation_history` MCP tool.
    /// The destination then starts a genuinely new provider-native conversation.
    var continuedFrom: SessionID? {
        switch configuration {
        case .claude(_, .continuedFromCodex(let source)):
            return source
        case .codex(_, .some(let source)):
            return source
        case .claude, .codex:
            return nil
        }
    }

    /// The format of the frozen handoff transcript.
    ///
    /// Kept beside the lineage rather than recovered from the source record so the handoff
    /// remains readable if that original row is later deleted from Threading.
    var continuationSourceKind: AgentKind? {
        switch configuration {
        case .claude(_, .continuedFromCodex):
            return .codex
        case .codex(_, .some):
            return .claude
        case .claude, .codex:
            return nil
        }
    }

    /// Whether this session began as a cross-provider continuation.
    var isCrossProviderContinuation: Bool {
        continuedFrom != nil && continuationSourceKind != nil
    }

    /// Whether Threading renders this conversation itself instead of showing the agent's
    /// terminal. Experimental, and available only where the agent exposes a supported
    /// structured-output transport.
    ///
    /// Switchable mid-conversation, because the two surfaces turn out to drive *one*
    /// conversation rather than incompatible ones: both resume the CLI by this session's own
    /// id, and both append to the same transcript. Measured on Claude 2.1.217 — a session
    /// created by `-p --session-id` resumed in the interactive TUI with its context intact,
    /// resumed back into `--print` (and into `--input-format stream-json`, the transport the
    /// native surface actually uses) quoting the terminal turn verbatim, one file and one id
    /// throughout. `--fork-session` exists to opt *into* a new id, which is what makes plain
    /// `--resume` keeping it a documented guarantee rather than an accident.
    ///
    /// The switch still costs a relaunch: the old process must be gone before the new one
    /// resumes the same id, since two live processes would interleave writes into that one
    /// transcript.
    var usesNativeUI: Bool

    /// Whether the session has been filed away.
    ///
    /// Archiving only affects where the session appears: its identifier and conversation are
    /// untouched, so an archived session resumes exactly as it would have.
    var isArchived: Bool

    /// Pinned conversations sort ahead of the ordinary project order on every surface.
    /// This is shared session state rather than a phone-only preference: pinning from either
    /// side should mean the same thing everywhere the conversation is listed.
    var isPinned: Bool

    /// The terminal theme this session draws with, by stable ID. Nil inherits — from the project,
    /// and from the app default beyond that — so a session that never chose still follows a
    /// later change to either. See `ThemeResolution.resolve`.
    var themeID: TerminalThemeID?

    /// Whether this conversation's macOS notifications are silenced. Nil inherits the
    /// project's answer, which inherits "not muted" — the same three scopes as the theme, and
    /// optional for the same reason: a session inside a muted project can still say no.
    /// See `AttentionAlertScope`.
    var notificationsMuted: Bool?

    init(
        kind: AgentKind,
        title: String,
        accountHandle: AccountHandle = .standard,
        model: String? = nil,
        usesNativeUI: Bool = false,
        id: SessionID = SessionID()
    ) {
        let configuration: AgentSessionConfiguration = switch kind {
        case .claude:
            .claude(remoteControl: nil, origin: .original)
        case .codex:
            .codex(reasoningEffort: nil, continuedFromClaude: nil)
        }
        self.init(
            configuration: configuration,
            title: title,
            accountHandle: accountHandle,
            model: model,
            usesNativeUI: usesNativeUI,
            id: id
        )
    }

    init(
        configuration: AgentSessionConfiguration,
        title: String,
        accountHandle: AccountHandle = .standard,
        model: String? = nil,
        usesNativeUI: Bool = false,
        id: SessionID = SessionID()
    ) {
        precondition(
            configuration.derivedSessionID != id,
            "A session cannot derive from itself"
        )
        self.id = id
        self.configuration = configuration
        self.title = title
        self.customTitle = nil
        self.agentTitle = nil
        self.createdAt = Date()
        self.lastActiveAt = Date()
        self.resumeState = ResumeState.initial(for: configuration.kind)
        self.hasLaunched = false
        self.lastExitCode = nil
        self.accountHandle = accountHandle
        self.model = model
        self.fastMode = nil
        self.permissionMode = nil
        self.branch = nil
        self.isArchived = false
        self.isPinned = false
        self.usesNativeUI = usesNativeUI
        self.themeID = nil
        self.notificationsMuted = nil
    }

    private enum CodingKeys: String, CodingKey {
        case id, kind, title, customTitle, createdAt, lastActiveAt
        case agentTitle = "terminalTitle"
        case agentSessionID, hasLaunched, lastExitCode, accountHandle, model, reasoningEffort, branch
        case fastMode, remoteControl, permissionMode, archived, pinned, nativeUI, forkParent
        case continuationSource, continuationSourceKind
        case themeID, themeName, notificationsMuted
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let decodedCreatedAt = try container.decodeIfPresent(Date.self, forKey: .createdAt)

        // Identity and provider are not migration defaults. Inventing either while decoding
        // changes which conversation a row means and can make a later save overwrite or launch
        // the wrong provider.
        id = try container.decode(SessionID.self, forKey: .id)
        let decodedKind = try container.decode(AgentKind.self, forKey: .kind)
        title = try container.decodeIfPresent(String.self, forKey: .title) ?? ""
        customTitle = try container.decodeIfPresent(String.self, forKey: .customTitle)
        agentTitle = try container.decodeIfPresent(String.self, forKey: .agentTitle)
        createdAt = decodedCreatedAt ?? Date()
        lastActiveAt = try container.decodeIfPresent(Date.self, forKey: .lastActiveAt)
            ?? createdAt
        resumeState = ResumeState.restoring(
            try container.decodeIfPresent(TranscriptID.self, forKey: .agentSessionID),
            for: decodedKind
        )
        hasLaunched = try container.decodeIfPresent(Bool.self, forKey: .hasLaunched) ?? false
        lastExitCode = try container.decodeIfPresent(Int32.self, forKey: .lastExitCode)
        accountHandle = AccountHandle(
            storedName: try container.decodeIfPresent(String.self, forKey: .accountHandle)
        )
        model = try container.decodeIfPresent(String.self, forKey: .model)
        let decodedReasoningEffort = try container.decodeIfPresent(
            String.self,
            forKey: .reasoningEffort
        )
        fastMode = try container.decodeIfPresent(Bool.self, forKey: .fastMode)
        let decodedRemoteControl = try container.decodeIfPresent(
            Bool.self,
            forKey: .remoteControl
        )
        permissionMode = try container.decodeIfPresent(
            AgentPermissionMode.self,
            forKey: .permissionMode
        )
        branch = try container.decodeIfPresent(String.self, forKey: .branch)
        isArchived = try container.decodeIfPresent(Bool.self, forKey: .archived) ?? false
        isPinned = try container.decodeIfPresent(Bool.self, forKey: .pinned) ?? false
        usesNativeUI = try container.decodeIfPresent(Bool.self, forKey: .nativeUI) ?? false
        let decodedForkParent = try container.decodeIfPresent(
            SessionID.self,
            forKey: .forkParent
        )
        let decodedContinuationSource = try container.decodeIfPresent(
            SessionID.self,
            forKey: .continuationSource
        )
        let decodedContinuationKind = try container.decodeIfPresent(
            AgentKind.self,
            forKey: .continuationSourceKind
        )
        if decodedReasoningEffort != nil, decodedKind != .codex {
            throw DecodingError.dataCorruptedError(
                forKey: .reasoningEffort,
                in: container,
                debugDescription: "Reasoning effort is only valid for Codex sessions"
            )
        }
        if decodedRemoteControl != nil, decodedKind != .claude {
            throw DecodingError.dataCorruptedError(
                forKey: .remoteControl,
                in: container,
                debugDescription: "Remote Control is only valid for Claude sessions"
            )
        }
        if (decodedContinuationSource == nil) != (decodedContinuationKind == nil) {
            throw DecodingError.dataCorruptedError(
                forKey: decodedContinuationSource == nil
                    ? .continuationSourceKind
                    : .continuationSource,
                in: container,
                debugDescription: "Continuation source and provider must be present together"
            )
        }
        if decodedForkParent != nil, decodedContinuationSource != nil {
            throw DecodingError.dataCorruptedError(
                forKey: .forkParent,
                in: container,
                debugDescription: "A session cannot be both forked and continued"
            )
        }
        if decodedForkParent == id || decodedContinuationSource == id {
            throw DecodingError.dataCorruptedError(
                forKey: decodedForkParent == id ? .forkParent : .continuationSource,
                in: container,
                debugDescription: "A session cannot derive from itself"
            )
        }
        switch decodedKind {
        case .claude:
            let origin: ClaudeSessionOrigin
            if let decodedForkParent {
                origin = .forked(from: decodedForkParent)
            } else if let decodedContinuationSource {
                guard decodedContinuationKind == .codex else {
                    throw DecodingError.dataCorruptedError(
                        forKey: .continuationSourceKind,
                        in: container,
                        debugDescription: "Claude can only continue a Codex conversation"
                    )
                }
                origin = .continuedFromCodex(decodedContinuationSource)
            } else {
                origin = .original
            }
            configuration = .claude(
                remoteControl: decodedRemoteControl,
                origin: origin
            )
        case .codex:
            guard decodedForkParent == nil else {
                throw DecodingError.dataCorruptedError(
                    forKey: .forkParent,
                    in: container,
                    debugDescription: "Codex sessions cannot be provider forks"
                )
            }
            if decodedContinuationSource != nil,
               decodedContinuationKind != .claude {
                throw DecodingError.dataCorruptedError(
                    forKey: .continuationSourceKind,
                    in: container,
                    debugDescription: "Codex can only continue a Claude conversation"
                )
            }
            configuration = .codex(
                reasoningEffort: decodedReasoningEffort,
                continuedFromClaude: decodedContinuationSource
            )
        }
        themeID = try container.decodeIfPresent(TerminalThemeID.self, forKey: .themeID)
        if themeID == nil,
           let legacyName = try container.decodeIfPresent(String.self, forKey: .themeName) {
            themeID = .migratedFromName(legacyName)
        }
        notificationsMuted = try container.decodeIfPresent(
            Bool.self,
            forKey: .notificationsMuted
        )
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(kind, forKey: .kind)
        try container.encode(title, forKey: .title)
        try container.encodeIfPresent(customTitle, forKey: .customTitle)
        try container.encodeIfPresent(agentTitle, forKey: .agentTitle)
        try container.encode(createdAt, forKey: .createdAt)
        try container.encode(lastActiveAt, forKey: .lastActiveAt)
        try container.encodeIfPresent(resumeState.transcriptID, forKey: .agentSessionID)
        try container.encode(hasLaunched, forKey: .hasLaunched)
        try container.encodeIfPresent(lastExitCode, forKey: .lastExitCode)
        try container.encodeIfPresent(accountHandle.persistedSessionName, forKey: .accountHandle)
        try container.encodeIfPresent(model, forKey: .model)
        try container.encodeIfPresent(reasoningEffort, forKey: .reasoningEffort)
        try container.encodeIfPresent(fastMode, forKey: .fastMode)
        try container.encodeIfPresent(remoteControl, forKey: .remoteControl)
        try container.encodeIfPresent(permissionMode, forKey: .permissionMode)
        try container.encodeIfPresent(branch, forKey: .branch)
        try container.encode(isArchived, forKey: .archived)
        try container.encode(isPinned, forKey: .pinned)
        try container.encode(usesNativeUI, forKey: .nativeUI)
        try container.encodeIfPresent(forkedFrom, forKey: .forkParent)
        try container.encodeIfPresent(continuedFrom, forKey: .continuationSource)
        try container.encodeIfPresent(
            continuationSourceKind,
            forKey: .continuationSourceKind
        )
        try container.encodeIfPresent(themeID, forKey: .themeID)
        try container.encodeIfPresent(notificationsMuted, forKey: .notificationsMuted)
    }

    /// Changes a Codex-only option without admitting it into Claude's state space.
    @discardableResult
    mutating func setCodexReasoningEffort(_ effort: String?) -> Bool {
        guard case .codex(_, let source) = configuration else { return false }
        configuration = .codex(
            reasoningEffort: effort,
            continuedFromClaude: source
        )
        return true
    }

    /// Changes a Claude-only option without admitting it into Codex's state space.
    @discardableResult
    mutating func setClaudeRemoteControl(_ remoteControl: Bool?) -> Bool {
        guard case .claude(_, let origin) = configuration else { return false }
        configuration = .claude(remoteControl: remoteControl, origin: origin)
        return true
    }

    /// Whether a previous conversation exists that can be resumed.
    var isResumable: Bool {
        resumeState.isResumable
    }

    /// The name shown in the sidebar.
    ///
    /// An explicit rename wins, then the agent's own title when that behaviour is enabled,
    /// then the first-prompt name — and a generic label when nothing has named the session
    /// yet. Never the agent or account, which the row's icon slot already identifies.
    @MainActor
    var displayTitle: String {
        if let customTitle, !customTitle.isEmpty {
            return customTitle
        }

        if AppSettings.usesAgentTitleInSidebar,
           let agentTitle, !agentTitle.isEmpty {
            return agentTitle
        }

        return title.isEmpty ? AgentDefaults.untitledSessionName : title
    }

    /// The identifier that names this conversation outside Threading.
    ///
    /// The agent's own identifier where it has one, because that is what a `--resume` takes,
    /// what the transcript file is named after, and what an agent reports about itself. For
    /// Claude the two are the same string — Threading mints the UUID and passes it as
    /// `--session-id` — so this only diverges for Codex, which names itself and is discovered
    /// afterwards.
    ///
    /// The fallback is Threading's own id rather than nothing: before the agent has named a
    /// conversation, that id is still what the settings file, the MCP route, the history file
    /// and the diagnostics journal are all keyed by, which is exactly what someone reading a
    /// log needs. It is a `TranscriptID` the caller must not assume resumable — `resumeState`
    /// remains the authority on that.
    var externalIdentifier: String {
        resumeState.transcriptID?.rawValue ?? id.uuidString.lowercased()
    }

    /// The name handed to the agent at launch, or nil when the user has not chosen one.
    ///
    /// Only an explicit rename is forwarded. `--name` marks the conversation custom-titled
    /// in the CLI, which sets its terminal title *and stops it generating its own `ai-title`*
    /// (measured: 9 of 10 transcripts launched under a default name held no `ai-title` at
    /// all) — so passing anything less deliberate than the user's own choice would feed the
    /// launcher's fallback into the CLI's picker and switch off the agent-naming signal the
    /// sidebar prefers.
    var launchName: String? {
        guard let customTitle, !customTitle.isEmpty else { return nil }
        return customTitle
    }
}

// MARK: - Project Icon

/// How a project's sidebar icon was obtained, which decides what may replace it: automatic
/// discovery only ever fills an empty slot, while a user's explicit choice is never
/// overwritten by anything automatic.
enum ProjectIconSource: String, Codable {
    /// Chosen by the user.
    case custom
    /// Found in the checkout itself — a favicon, touch icon, or app icon set.
    case repoFile
    /// The avatar of the repository's GitHub owner.
    case remoteAvatar
    /// The favicon of the homepage the project declares.
    case homepage
    /// Set by an agent, through the MCP tool or icon research.
    case agent
}

/// A project's sidebar icon: where its image lives and how it was obtained.
struct ProjectIcon: Codable, Equatable {
    let source: ProjectIconSource

    /// File name inside `ProjectIconStore`'s cache directory — not a path, so the record
    /// survives the cache directory moving with the user's home.
    let fileName: String
}

// MARK: - Project

/// A folder the user has added, grouping the agent sessions started inside it.
struct Project: Codable, Identifiable {
    let id: ProjectID
    var name: String
    /// Stored as a path string for reliable encoding, matching `SessionSnapshot`.
    var folderPath: String
    var sessions: [AgentSession]
    var isExpanded: Bool
    let createdAt: Date

    /// The sidebar icon, discovered or chosen. Optional, so state written before icons
    /// existed still decodes.
    var icon: ProjectIcon?

    /// The terminal theme this project's sessions draw with, by stable ID. Nil inherits the app
    /// default; a session choosing its own theme overrides this.
    var themeID: TerminalThemeID?

    /// Whether this checkout's sessions are silenced. Nil inherits "not muted"; a session
    /// with an answer of its own overrides it either way. See `AttentionAlertScope`.
    var notificationsMuted: Bool?

    init(name: String, folderURL: URL, id: ProjectID = ProjectID()) {
        self.id = id
        self.name = name
        self.folderPath = folderURL.path
        self.sessions = []
        self.isExpanded = true
        self.createdAt = Date()
        self.icon = nil
        self.themeID = nil
        self.notificationsMuted = nil
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, folderPath, sessions, isExpanded, createdAt, icon, themeID, themeName
        case notificationsMuted
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let decodedFolderPath = try container.decode(String.self, forKey: .folderPath)

        id = try container.decode(ProjectID.self, forKey: .id)
        name = try container.decodeIfPresent(String.self, forKey: .name)
            ?? URL(fileURLWithPath: decodedFolderPath).lastPathComponent
        folderPath = decodedFolderPath
        guard folderPath.hasPrefix("/"), !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw DecodingError.dataCorruptedError(
                forKey: folderPath.hasPrefix("/") ? .name : .folderPath,
                in: container,
                debugDescription: "A project requires an absolute folder path and a non-empty name"
            )
        }
        sessions = try container.decodeIfPresent([AgentSession].self, forKey: .sessions) ?? []
        isExpanded = try container.decodeIfPresent(Bool.self, forKey: .isExpanded) ?? true
        createdAt = try container.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
        icon = try container.decodeIfPresent(ProjectIcon.self, forKey: .icon)
        themeID = try container.decodeIfPresent(TerminalThemeID.self, forKey: .themeID)
        if themeID == nil,
           let legacyName = try container.decodeIfPresent(String.self, forKey: .themeName) {
            themeID = .migratedFromName(legacyName)
        }
        notificationsMuted = try container.decodeIfPresent(
            Bool.self,
            forKey: .notificationsMuted
        )
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encode(folderPath, forKey: .folderPath)
        try container.encode(sessions, forKey: .sessions)
        try container.encode(isExpanded, forKey: .isExpanded)
        try container.encode(createdAt, forKey: .createdAt)
        try container.encodeIfPresent(icon, forKey: .icon)
        try container.encodeIfPresent(themeID, forKey: .themeID)
        try container.encodeIfPresent(notificationsMuted, forKey: .notificationsMuted)
    }

    var folderURL: URL {
        URL(fileURLWithPath: folderPath)
    }

    /// Looks up a session by identifier.
    func session(withID sessionID: SessionID) -> AgentSession? {
        sessions.first { $0.id == sessionID }
    }
}

// MARK: - Projects State

/// The complete persisted state of the project sidebar.
struct ProjectsState: Codable {
    let version: Int
    var projects: [Project]
    var selectedSessionID: SessionID?
    var savedAt: Date

    init(
        version: Int = ProjectsStateVersion.current,
        projects: [Project] = [],
        selectedSessionID: SessionID? = nil,
        savedAt: Date = Date()
    ) {
        self.version = version
        self.projects = projects
        self.selectedSessionID = selectedSessionID
        self.savedAt = savedAt
    }
}

// MARK: - Session Auxiliary Documents

/// The persisted form of a session's display panel.
///
/// `formatVersion` is decoded explicitly rather than defaulted by synthesis: absence means the
/// legacy version-zero document, while a value newer than this app is refused. That keeps a
/// future layout from being partially interpreted and then replaced by today's narrower model.
struct PersistedPanel: Codable {
    static let currentFormatVersion = 1

    var tabs: [PersistedTab]
    var activeTabID: String?
    var observedSignature: String?
    var drawerActiveTabID: String? = nil
    var drawerOpen: Bool? = nil

    var panelTabs: [PersistedTab] { tabs.filter { $0.host == nil } }
    var drawerTabs: [PersistedTab] { tabs.filter { $0.host == PersistedTab.drawerHost } }

    private enum CodingKeys: String, CodingKey {
        case formatVersion
        case tabs
        case activeTabID
        case observedSignature
        case drawerActiveTabID
        case drawerOpen
    }
}

extension PersistedPanel {
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let version = try container.decodeIfPresent(Int.self, forKey: .formatVersion) ?? 0
        guard version <= Self.currentFormatVersion else {
            throw DecodingError.dataCorruptedError(
                forKey: .formatVersion,
                in: container,
                debugDescription: "Unsupported panel format version \(version)"
            )
        }

        tabs = try container.decode([PersistedTab].self, forKey: .tabs)
        activeTabID = try container.decodeIfPresent(String.self, forKey: .activeTabID)
        observedSignature = try container.decodeIfPresent(String.self, forKey: .observedSignature)
        drawerActiveTabID = try container.decodeIfPresent(String.self, forKey: .drawerActiveTabID)
        drawerOpen = try container.decodeIfPresent(Bool.self, forKey: .drawerOpen)

        let ids = tabs.map(\.id)
        guard ids.allSatisfy({ !$0.isEmpty }), Set(ids).count == ids.count else {
            throw DecodingError.dataCorruptedError(
                forKey: .tabs,
                in: container,
                debugDescription: "Panel tab identifiers must be non-empty and unique"
            )
        }
        guard tabs.allSatisfy({ $0.host == nil || $0.host == PersistedTab.drawerHost }) else {
            throw DecodingError.dataCorruptedError(
                forKey: .tabs,
                in: container,
                debugDescription: "Panel tab has an unknown host"
            )
        }
        if let activeTabID,
           !panelTabs.contains(where: { $0.id == activeTabID }) {
            throw DecodingError.dataCorruptedError(
                forKey: .activeTabID,
                in: container,
                debugDescription: "Active panel tab does not exist in the panel host"
            )
        }
        if let drawerActiveTabID,
           !drawerTabs.contains(where: { $0.id == drawerActiveTabID }) {
            throw DecodingError.dataCorruptedError(
                forKey: .drawerActiveTabID,
                in: container,
                debugDescription: "Active drawer tab does not exist in the drawer host"
            )
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(Self.currentFormatVersion, forKey: .formatVersion)
        try container.encode(tabs, forKey: .tabs)
        try container.encodeIfPresent(activeTabID, forKey: .activeTabID)
        try container.encodeIfPresent(observedSignature, forKey: .observedSignature)
        try container.encodeIfPresent(drawerActiveTabID, forKey: .drawerActiveTabID)
        try container.encodeIfPresent(drawerOpen, forKey: .drawerOpen)
    }
}

/// One display tab reduced to the state needed to restore it.
struct PersistedTab: Codable {
    enum Kind: String, Codable {
        case browser
        case html
        case image
        case review
        case info
        case terminal
        case files
        case attachments
        case extensionPanel
        case compare
    }

    var id: String
    var kind: Kind
    var title: String?
    var subtitle: String
    var url: String?
    var html: String?
    var cacheFile: String?
    var mode: String? = nil
    var extensionIdentifier: String? = nil
    var extensionPanelID: String? = nil
    var compareOldPath: String? = nil
    var compareNewPath: String? = nil
    var compareOldTitle: String? = nil
    var compareNewTitle: String? = nil
    var host: String? = nil

    static let drawerHost = "drawer"
}

/// One attachment reference in the persisted session document.
struct PersistedSessionAttachment: Codable {
    let projectRoot: String
    let relativePath: String
    let kind: SessionAttachment.Kind
    let referencedAt: Date
}

/// A versioned attachment document with an explicit legacy-array migration.
struct PersistedSessionAttachments: Codable {
    static let currentFormatVersion = 1

    var entries: [PersistedSessionAttachment]

    private enum CodingKeys: String, CodingKey {
        case formatVersion
        case entries
    }

    init(entries: [PersistedSessionAttachment]) {
        self.entries = entries
    }

    init(from decoder: Decoder) throws {
        if let legacy = try? decoder.singleValueContainer()
            .decode([PersistedSessionAttachment].self) {
            entries = legacy
            try Self.validate(entries, codingPath: decoder.codingPath)
            return
        }

        let container = try decoder.container(keyedBy: CodingKeys.self)
        let version = try container.decode(Int.self, forKey: .formatVersion)
        guard version == Self.currentFormatVersion else {
            throw DecodingError.dataCorruptedError(
                forKey: .formatVersion,
                in: container,
                debugDescription: "Unsupported attachments format version \(version)"
            )
        }
        entries = try container.decode([PersistedSessionAttachment].self, forKey: .entries)
        try Self.validate(entries, codingPath: container.codingPath + [CodingKeys.entries])
    }

    private static func validate(
        _ entries: [PersistedSessionAttachment],
        codingPath: [CodingKey]
    ) throws {
        guard entries.allSatisfy({
            !$0.projectRoot.isEmpty
                && !$0.relativePath.isEmpty
                && !$0.relativePath.hasPrefix("/")
                && !$0.relativePath.split(separator: "/").contains("..")
        }) else {
            throw DecodingError.dataCorrupted(
                .init(
                    codingPath: codingPath,
                    debugDescription: "Attachment paths must be non-empty and relative"
                )
            )
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(Self.currentFormatVersion, forKey: .formatVersion)
        try container.encode(entries, forKey: .entries)
    }
}
