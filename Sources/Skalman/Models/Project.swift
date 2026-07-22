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

// MARK: - Agent Session

/// A single agent conversation or shell belonging to a project.
///
/// The session outlives its terminal: when the agent exits, the PTY is torn down but
/// this record remains so the conversation can be resumed by `agentSessionID` later.
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

    /// Identifier used to resume this conversation.
    ///
    /// For Claude this is minted by us and set at first launch. For Codex it is assigned
    /// by the CLI and remains nil until discovery completes. Always nil for shells.
    var agentSessionID: TranscriptID?

    /// Whether this session has been launched at least once, distinguishing a first
    /// launch from a resume.
    var hasLaunched: Bool

    /// Exit code from the most recent run, if it has ended.
    var lastExitCode: Int32?

    /// Which agent login this session belongs to. `.standard` means the provider's default.
    ///
    /// Conversations are stored per account, so this must be stable across resumes: the same
    /// identifier resumed under a different account would not be found.
    @PersistedAccountHandle var accountHandle: AccountHandle

    /// Model the session was started with, passed again on resume so it does not drift.
    /// Nil uses whatever the CLI defaults to.
    var model: String?

    /// The branch the checkout was on when this session last ran.
    ///
    /// A branch belongs to a checkout, not a session — but a *conversation* happened on
    /// whatever branch was checked out at the time, and that is what this records: captured
    /// at creation and re-read each time the session stops working, then frozen while
    /// dormant. It drives the sidebar's optional branch grouping. Nil for non-git projects
    /// and for sessions recorded before this existed.
    var branch: String?

    /// Stored optional so state written before archiving existed still decodes: synthesized
    /// `Codable` throws on a missing key rather than falling back to a property's default.
    private var archived: Bool?

    /// Stored optional for the same reason as `archived`.
    private var nativeUI: Bool?

    /// Stored optional for the same reason as `archived`.
    private var forkParent: SessionID?

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
    var forkedFrom: SessionID? {
        get { forkParent }
        set { forkParent = newValue }
    }

    /// Whether this session began as a fork of another.
    var isSideChat: Bool { forkParent != nil }

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
    var usesNativeUI: Bool {
        get { nativeUI ?? false }
        set { nativeUI = newValue }
    }

    /// Whether the session has been filed away.
    ///
    /// Archiving only affects where the session appears: its identifier and conversation are
    /// untouched, so an archived session resumes exactly as it would have.
    var isArchived: Bool {
        get { archived ?? false }
        set { archived = newValue }
    }

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
        self.agentSessionID = nil
        self.hasLaunched = false
        self.lastExitCode = nil
        self.accountHandle = accountHandle
        self.model = model
        self.branch = nil
        self.archived = nil
        self.nativeUI = usesNativeUI
        self.forkParent = forkedFrom
    }

    /// Whether a previous conversation exists that can be resumed.
    var isResumable: Bool {
        kind.supportsResume && agentSessionID != nil
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

    init(name: String, folderURL: URL, id: ProjectID = ProjectID()) {
        self.id = id
        self.name = name
        self.folderPath = folderURL.path
        self.sessions = []
        self.isExpanded = true
        self.createdAt = Date()
        self.icon = nil
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
