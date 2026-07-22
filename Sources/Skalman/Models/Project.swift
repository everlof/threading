import Foundation

// MARK: - Projects State Version

enum ProjectsStateVersion {
    static let current = 1
}

// MARK: - Agent Kind

/// The kind of program a session hosts.
enum AgentKind: String, Codable, CaseIterable {
    case claude
    case codex
    case shell

    /// Human-readable name shown in menus and the sidebar.
    var displayName: String {
        switch self {
        case .claude: return "Claude Code"
        case .codex: return "Codex"
        case .shell: return "Shell"
        }
    }

    /// The executable invoked on the user's PATH.
    ///
    /// Nil for shells, whose executable comes from the active profile at launch rather than
    /// being fixed by the agent kind.
    var executableName: String? {
        switch self {
        case .claude: return AgentDefaults.claudeExecutable
        case .codex: return AgentDefaults.codexExecutable
        case .shell: return nil
        }
    }

    /// Whether sessions of this kind can be resumed by identifier after exiting.
    var supportsResume: Bool {
        switch self {
        case .claude, .codex: return true
        case .shell: return false
        }
    }

    /// Whether the session identifier can be chosen by us before launch.
    ///
    /// Claude accepts `--session-id <uuid>`, so we mint it. Codex assigns its own,
    /// which must be discovered afterwards via `CodexSessionDiscovery`.
    var supportsPresetSessionID: Bool {
        self == .claude
    }

    /// Whether this agent supports multiple logins.
    var supportsAccounts: Bool {
        self != .shell
    }

    /// Whether Skalman may render this agent's conversation itself, instead of a terminal.
    ///
    /// Both agents qualify: each exposes a supported headless transport — `codex exec --json`
    /// and `claude -p --output-format stream-json` — that Skalman drives by spawning the
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
    var supportsNativeUI: Bool {
        self != .shell
    }

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
    var accountEnvironmentKey: String? {
        switch self {
        case .claude: return "CLAUDE_CONFIG_DIR"
        case .codex: return "CODEX_HOME"
        case .shell: return nil
        }
    }
}

// MARK: - Resume State

/// Whether a session can identify a conversation to resume.
///
/// These are deliberately separate states rather than one optional transcript identifier:
/// a shell will never have a conversation, while a fresh agent session is waiting for an
/// identifier to be minted or discovered. Only `.resumable` names an existing conversation.
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

// MARK: - Agent Session

/// A single agent conversation or shell belonging to a project.
///
/// The session outlives its terminal: when the agent exits, the PTY is torn down but
/// this record remains so the conversation can be resumed through `resumeState` later.
struct AgentSession: Codable, Identifiable {
    let id: SessionID
    var kind: AgentKind

    /// The name assigned when the session was created, e.g. `Claude Code` or `claudedb`.
    /// Used as the fallback when nothing better is known.
    var title: String

    /// An explicit rename by the user. Takes precedence over the terminal's own title,
    /// so a deliberate name is never overwritten by agent activity.
    var customTitle: String?

    /// The most recent title reported by the terminal.
    ///
    /// Agents use this to report what they are working on. It is retained after the agent
    /// exits so a dormant session still shows what it was last doing.
    var terminalTitle: String?

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

    /// The branch the checkout was on when this session last ran.
    ///
    /// A branch belongs to a checkout, not a session — but a *conversation* happened on
    /// whatever branch was checked out at the time, and that is what this records: captured
    /// at creation and re-read each time the session stops working, then frozen while
    /// dormant. It drives the sidebar's optional branch grouping. Nil for non-git projects
    /// and when no branch was available while decoding an older record.
    var branch: String?

    /// The session this one was forked from, for a **side chat** — a conversation started
    /// with a copy of another's context so a question can be asked without joining the
    /// record it asks about.
    ///
    /// Skalman's own bookkeeping, because the CLI keeps none: a forked transcript carries no
    /// reference to its ancestor (measured — the only trace was a stale `session_id` left on
    /// one copied record, while every `sessionId` was rewritten to the fork's).
    ///
    /// It is read at *launch* rather than being a lasting mode: the fork happens once, when
    /// the child first runs, and afterwards this is lineage rather than behaviour. See
    /// `AgentLauncher.claudeForkCommand`.
    var forkedFrom: SessionID?

    /// Whether this session began as a fork of another.
    var isSideChat: Bool { forkedFrom != nil }

    /// Whether Skalman renders this conversation itself instead of showing the agent's
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

    /// The terminal theme this session draws with, by name. Nil inherits — from the project,
    /// and from the app default beyond that — so a session that never chose still follows a
    /// later change to either. See `ThemeResolution.resolve`.
    var themeName: String?

    init(
        kind: AgentKind,
        title: String,
        accountHandle: AccountHandle = .standard,
        model: String? = nil,
        usesNativeUI: Bool = false,
        forkedFrom: SessionID? = nil,
        id: SessionID = SessionID()
    ) {
        self.id = id
        self.kind = kind
        self.title = title
        self.customTitle = nil
        self.terminalTitle = nil
        self.createdAt = Date()
        self.lastActiveAt = Date()
        self.resumeState = ResumeState.initial(for: kind)
        self.hasLaunched = false
        self.lastExitCode = nil
        self.accountHandle = accountHandle
        self.model = model
        self.branch = nil
        self.isArchived = false
        self.usesNativeUI = usesNativeUI
        self.forkedFrom = forkedFrom
        self.themeName = nil
    }

    private enum CodingKeys: String, CodingKey {
        case id, kind, title, customTitle, terminalTitle, createdAt, lastActiveAt
        case agentSessionID, hasLaunched, lastExitCode, accountHandle, model, branch
        case archived, nativeUI, forkParent, themeName
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let decodedCreatedAt = try container.decodeIfPresent(Date.self, forKey: .createdAt)

        id = try container.decodeIfPresent(SessionID.self, forKey: .id) ?? SessionID()
        kind = try container.decodeIfPresent(AgentKind.self, forKey: .kind)
            ?? AgentDefaults.defaultKind
        title = try container.decodeIfPresent(String.self, forKey: .title)
            ?? AgentDefaults.untitledSessionName
        customTitle = try container.decodeIfPresent(String.self, forKey: .customTitle)
        terminalTitle = try container.decodeIfPresent(String.self, forKey: .terminalTitle)
        createdAt = decodedCreatedAt ?? Date()
        lastActiveAt = try container.decodeIfPresent(Date.self, forKey: .lastActiveAt)
            ?? createdAt
        resumeState = ResumeState.restoring(
            try container.decodeIfPresent(TranscriptID.self, forKey: .agentSessionID),
            for: kind
        )
        hasLaunched = try container.decodeIfPresent(Bool.self, forKey: .hasLaunched) ?? false
        lastExitCode = try container.decodeIfPresent(Int32.self, forKey: .lastExitCode)
        accountHandle = AccountHandle(
            storedName: try container.decodeIfPresent(String.self, forKey: .accountHandle)
        )
        model = try container.decodeIfPresent(String.self, forKey: .model)
        branch = try container.decodeIfPresent(String.self, forKey: .branch)
        isArchived = try container.decodeIfPresent(Bool.self, forKey: .archived) ?? false
        usesNativeUI = try container.decodeIfPresent(Bool.self, forKey: .nativeUI) ?? false
        forkedFrom = try container.decodeIfPresent(SessionID.self, forKey: .forkParent)
        themeName = try container.decodeIfPresent(String.self, forKey: .themeName)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(kind, forKey: .kind)
        try container.encode(title, forKey: .title)
        try container.encodeIfPresent(customTitle, forKey: .customTitle)
        try container.encodeIfPresent(terminalTitle, forKey: .terminalTitle)
        try container.encode(createdAt, forKey: .createdAt)
        try container.encode(lastActiveAt, forKey: .lastActiveAt)
        try container.encodeIfPresent(resumeState.transcriptID, forKey: .agentSessionID)
        try container.encode(hasLaunched, forKey: .hasLaunched)
        try container.encodeIfPresent(lastExitCode, forKey: .lastExitCode)
        try container.encodeIfPresent(accountHandle.persistedSessionName, forKey: .accountHandle)
        try container.encodeIfPresent(model, forKey: .model)
        try container.encodeIfPresent(branch, forKey: .branch)
        try container.encode(isArchived, forKey: .archived)
        try container.encode(usesNativeUI, forKey: .nativeUI)
        try container.encodeIfPresent(forkedFrom, forKey: .forkParent)
        try container.encodeIfPresent(themeName, forKey: .themeName)
    }

    /// Whether a previous conversation exists that can be resumed.
    var isResumable: Bool {
        resumeState.isResumable
    }

    /// The name shown in the sidebar.
    ///
    /// An explicit rename wins, then the terminal's own title when that behaviour is
    /// enabled, then the name the session was created with.
    @MainActor
    var displayTitle: String {
        if let customTitle, !customTitle.isEmpty {
            return customTitle
        }

        if AppSettings.usesTerminalTitleInSidebar,
           let terminalTitle, !terminalTitle.isEmpty {
            return terminalTitle
        }

        return title
    }

    /// The name handed to the agent at launch.
    ///
    /// Deliberately excludes the terminal title, which the agent itself produces and which
    /// would otherwise be fed back into the next launch.
    var launchName: String {
        if let customTitle, !customTitle.isEmpty {
            return customTitle
        }

        return title
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

    /// The terminal theme this project's sessions draw with, by name. Nil inherits the app
    /// default; a session naming its own theme overrides this.
    var themeName: String?

    init(name: String, folderURL: URL, id: ProjectID = ProjectID()) {
        self.id = id
        self.name = name
        self.folderPath = folderURL.path
        self.sessions = []
        self.isExpanded = true
        self.createdAt = Date()
        self.icon = nil
        self.themeName = nil
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, folderPath, sessions, isExpanded, createdAt, icon, themeName
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let decodedFolderPath = try container.decodeIfPresent(String.self, forKey: .folderPath)
            ?? ""

        id = try container.decodeIfPresent(ProjectID.self, forKey: .id) ?? ProjectID()
        name = try container.decodeIfPresent(String.self, forKey: .name)
            ?? URL(fileURLWithPath: decodedFolderPath).lastPathComponent
        folderPath = decodedFolderPath
        sessions = try container.decodeIfPresent([AgentSession].self, forKey: .sessions) ?? []
        isExpanded = try container.decodeIfPresent(Bool.self, forKey: .isExpanded) ?? true
        createdAt = try container.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
        icon = try container.decodeIfPresent(ProjectIcon.self, forKey: .icon)
        themeName = try container.decodeIfPresent(String.self, forKey: .themeName)
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
        try container.encodeIfPresent(themeName, forKey: .themeName)
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
