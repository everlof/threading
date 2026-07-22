import Foundation
import AppKit

// MARK: - Terminal Defaults

enum TerminalDefaults {
    static let columns = 80
    static let rows = 24
    static let scrollbackLines = 10_000
    static let defaultShell = "/bin/bash"
    static let defaultFont = "SF Mono"
    static let defaultFontSize: CGFloat = 13
    static let terminalType = "xterm-256color"

    /// Advertised to child processes so they emit colour. SwiftTerm renders 24-bit colour, and
    /// this is how a terminal declares it (iTerm2, Terminal.app and Alacritty all set it). It
    /// must be set explicitly rather than inherited: a GUI-launched app gets the launchd
    /// environment, which — unlike an interactive shell — carries no `COLORTERM`, so without
    /// this Claude Code and other tools fall back to monochrome.
    static let colorTerm = "truecolor"
}

// MARK: - Window Defaults

enum WindowDefaults {
    static let minWidth: CGFloat = 400
    static let minHeight: CGFloat = 300
    static let defaultWidth: CGFloat = 800
    static let defaultHeight: CGFloat = 600
    static let titleBarHeight: CGFloat = 22
}

// MARK: - Environment Keys

enum EnvironmentKeys {
    static let term = "TERM"
    static let colorTerm = "COLORTERM"
    static let lang = "LANG"
    static let path = "PATH"
    static let home = "HOME"
    static let shell = "SHELL"
    static let columns = "COLUMNS"
    static let lines = "LINES"
}

// MARK: - Menu Identifiers

enum MenuIdentifiers {
    static let mainMenu = "MainMenu"
    static let projectMenu = "Project"
    static let editMenu = "Edit"
    static let viewMenu = "View"
    static let windowMenu = "Window"
    static let helpMenu = "Help"
}

// MARK: - Process Tree Defaults

enum ProcessTreeDefaults {
    static let refreshInterval: TimeInterval = 2.0
    static let minPaneHeight: CGFloat = 100
    static let maxPaneHeight: CGFloat = 600
    static let defaultPaneHeight: CGFloat = 200
    static let detailPanelWidth: CGFloat = 200
}

// MARK: - AI Defaults

enum AIDefaults {
    static let maxOutputLength = 50_000
    static let requestTimeout: TimeInterval = 30
    static let ollamaDefaultURL = "http://localhost:11434"
    static let ollamaDefaultModel = "llama3"
    static let claudeDefaultModel = "claude-sonnet-4-20250514"
    static let openaiDefaultModel = "gpt-4"
}

// MARK: - Shell Defaults

enum ShellDefaults {
    /// Delay before sampling child processes to identify the newly spawned shell PID.
    static let pidCaptureDelay: TimeInterval = 0.3
}

// MARK: - Agent Defaults

enum AgentDefaults {
    static let defaultKind: AgentKind = .claude
    static let untitledSessionName = "New Session"

    /// Name a side chat carries until the agent reports a terminal title of its own.
    static let sideChatTitle = "Side Chat"

    static let claudeExecutable = "claude"
    static let codexExecutable = "codex"

    static let claudeModelFlag = "--model"
    static let codexModelFlag = "--model"

    /// Runs enabled hooks without the review Codex otherwise requires.
    ///
    /// Named here rather than written inline because of what it does: it un-gates every hook in
    /// the account's config directory for that invocation, not only the ones Skalman installed.
    /// It is passed solely when `AppSettings.bypassesCodexHookTrust` is on.
    static let codexBypassHookTrustFlag = "--dangerously-bypass-hook-trust"

    /// Model choices offered for Claude: the aliases its `--help` documents, which track the
    /// latest of each family rather than pinning a dated name.
    static let claudeModels = ["opus", "sonnet", "fable"]

    /// Where Claude records the model an account runs on, so the composer can name it rather
    /// than calling it "Default".
    static let claudeSettingsFile = "settings.json"
    static let claudeModelKey = "model"

    /// Codex publishes no alias list, so its options come from the user's own
    /// `~/.codex/config.toml` instead of names invented here.
    static let codexConfigFile = "config.toml"
    static let codexModelKey = "model"

    /// One-run override keys for background research launches.
    static let codexReasoningEffortKey = "model_reasoning_effort"
    static let codexResearchReasoningEffort = "low"

    /// Where Claude records transcripts, relative to an account's config directory.
    static let claudeProjectsSubdirectory = "projects"
    static let transcriptExtension = "jsonl"

    /// Claude names a project's directory after its absolute path with separators replaced.
    static let projectSlugSeparator = "-"
}

// MARK: - Agent Environment

/// Environment variables identifying an agent session, which must not be inherited by the
/// sessions Skalman launches.
///
/// A session started from inside another agent's shell would otherwise be handed that
/// conversation's identifiers and treat itself as a nested child of it.
enum AgentEnvironment {
    /// Prefixes covering the identity variables the agent CLIs export.
    static let inheritedIdentityPrefixes = [
        "CLAUDE_CODE_",
        "CLAUDECODE",
        "CLAUDE_PID",
        "CLAUDE_EFFORT",
        "CODEX_SESSION",
        "CODEX_THREAD"
    ]

    static func isInheritedAgentIdentity(_ key: String) -> Bool {
        inheritedIdentityPrefixes.contains { key.hasPrefix($0) }
    }

    /// The app's environment with inherited agent identity removed, for launches that do not
    /// go through a PTY. `TerminalSession` builds on the same rule and adds terminal-specific
    /// variables a headless run has no use for.
    static func launchEnvironment() -> [String: String] {
        var environment = ProcessInfo.processInfo.environment

        for key in environment.keys where isInheritedAgentIdentity(key) {
            environment.removeValue(forKey: key)
        }

        return environment
    }
}

// MARK: - MCP Defaults

/// Settings for the MCP server Skalman exposes to the agents it launches.
///
/// The server gives an agent a way to reach the GUI it is running inside — showing an image
/// in the side panel rather than naming a file path the terminal cannot render.
enum MCPDefaults {
    /// The server name agents see. Tool names derive from it: `mcp__skalman__display_image`.
    static let serverName = "skalman"
    static let serverVersion = "0.1.0"

    /// Spoken when a client offers no version of its own.
    static let protocolVersion = "2025-06-18"

    /// Loopback only. The endpoint is unauthenticated apart from its per-session token, so it
    /// must never be reachable off this machine.
    static let host = "127.0.0.1"

    /// Path prefix for session endpoints, completed by the session's token.
    static let pathPrefix = "/mcp/"

    /// Path prefix for `PreToolUse` permission requests, completed by the same token.
    static let permissionPathPrefix = "/permission/"

    /// Path prefix for lifecycle hook reports, completed by the same token.
    ///
    /// Separate from the permission prefix because the two have opposite blocking rules: a
    /// permission request holds the agent until a person answers, while a lifecycle report is
    /// told and forgotten.
    static let lifecyclePathPrefix = "/lifecycle/"

    /// The query parameter naming which lifecycle event a report describes.
    ///
    /// The event is carried in the URL rather than read from the payload so that one endpoint
    /// per session still distinguishes the events, and so nothing depends on the payload's own
    /// event field — Claude and Codex spell it differently.
    static let lifecycleEventParameter = "event"

    /// Environment variables carrying the listener's port and the session's token into a hook.
    ///
    /// Codex reads one `hooks.json` per account, shared by every session, and refuses to run a
    /// hook whose text has not been reviewed. Passing the port and token through the
    /// environment answers both at once: one static file routes every session correctly, and
    /// its text never changes — so a trust decision survives the next launch, which a file
    /// carrying today's port would not.
    static let portEnvironmentKey = "SKALMAN_MCP_PORT"
    static let sessionTokenEnvironmentKey = "SKALMAN_SESSION_TOKEN"

    /// Set only for sessions Skalman renders itself, and read by Codex's `PreToolUse` hook.
    ///
    /// Codex has one `hooks.json` per account, shared by every session, so a surface-specific
    /// behaviour cannot be expressed in the file. This variable is how a shared file is scoped
    /// to one surface: a terminal session raises Codex's own approval prompt and must not be
    /// intercepted, so it simply does not export this.
    static let brokerEnvironmentKey = "SKALMAN_BROKER_TOOLS"

    /// Marks the entries in a shared `hooks.json` that belong to Skalman.
    ///
    /// A shell comment, so it is inert where it sits, and the only way to tell our entries from
    /// another tool's when updating a file we do not own.
    static let hookMarker = "# skalman-lifecycle"

    /// Where per-session hook settings files are written, under Application Support.
    static let settingsDirectoryName = "settings"

    /// How long the permission hook waits for a decision. Long, because what it is waiting
    /// for is a person reading a dialog, not a machine.
    static let permissionTimeout: TimeInterval = 600

    /// How long a lifecycle hook waits before giving up.
    ///
    /// Deliberately tiny. These hooks run on the agent's own turn boundaries, so every one of
    /// them is latency the user feels before their prompt is answered — and nothing depends on
    /// the reply. An unreachable app must cost a moment, not a turn.
    static let lifecycleTimeout: TimeInterval = 2

    /// Also cleaned up when a session is deleted. Kept alongside the retained tokens so a
    /// revoked endpoint leaves no settings file pointing at it.
    static let cleanupDirectories = [configDirectoryName, settingsDirectoryName]

    /// Where per-session Claude `--mcp-config` files are written, under Application Support.
    static let configDirectoryName = "mcp"
    static let configFileExtension = "json"

    /// Claude tools are allowlisted wholesale, or every image would raise a permission prompt.
    static let allowedToolsPattern = "mcp__\(serverName)__*"

    /// Refused rather than read into memory, since the panel shows one image at a time.
    static let maximumImageBytes = 64 * 1024 * 1024

    /// Well under `maximumRequestBytes`, so an oversized document is refused with an
    /// explanation the agent can act on rather than a transport-level error it cannot.
    static let maximumHTMLBytes = 2 * 1024 * 1024

    /// Ceiling on a single HTTP request, so a malformed client cannot grow the buffer forever.
    static let maximumRequestBytes = 8 * 1024 * 1024
}

// MARK: - Display Pane Defaults

enum DisplayPaneDefaults {
    static let minWidth: CGFloat = 260
    static let defaultWidth: CGFloat = 380
    static let headerHeight: CGFloat = 28
    static let padding: CGFloat = 8
    static let buttonSize: CGFloat = 20
    static let titleFontSize: CGFloat = 11
    static let captionFontSize: CGFloat = 10

    /// The tab strip appears only once surfaces coexist — a lone image keeps the cleaner
    /// header-titled look, and the strip earns its row only when there is a choice to make.
    static let tabBarMinimumTabs = 2
    static let tabBarHeight: CGFloat = 30
    static let tabChipMaxWidth: CGFloat = 140
    static let tabChipFontSize: CGFloat = 11

    /// Content tabs an agent stacks up are capped so a session that keeps displaying charts
    /// does not grow an unbounded strip; the oldest content tab is dropped, never the browser.
    static let maximumContentTabs = 8
}

// MARK: - Codex Discovery Defaults

enum CodexDiscoveryDefaults {
    static let rolloutPrefix = "rollout-"
    static let rolloutExtension = "jsonl"
    static let sessionMetaType = "session_meta"

    /// Event recording a turn the user typed, as opposed to the copy replayed into the
    /// conversation behind the CLI's instruction blocks.
    static let userMessageType = "user_message"

    /// Codex writes the rollout file shortly after launch, so discovery retries briefly.
    static let pollInterval: TimeInterval = 0.25
    static let maxAttempts = 40

    /// Tolerance for the gap between our launch timestamp and the file's creation date.
    static let clockSlack: TimeInterval = 5.0

    /// The `session_meta` record is the first line, so only a prefix needs reading.
    static let headerReadLimit = 64 * 1024
}

// MARK: - Terminal Padding

/// Inset between the terminal and the edges of its pane.
///
/// Slightly larger on the leading edge, which sits against the sidebar divider.
enum TerminalPadding {
    static let top: CGFloat = 6
    static let bottom: CGFloat = 4
    static let leading: CGFloat = 10
    static let trailing: CGFloat = 6
}

// MARK: - Project Store Defaults

enum ProjectStoreDefaults {
    /// Window over which rapid updates are merged into one write.
    static let saveCoalescingInterval: TimeInterval = 2.0
}

// MARK: - Sidebar Defaults

enum SidebarDefaults {
    static let minWidth: CGFloat = 180
    static let maxWidth: CGFloat = 400
    static let defaultWidth: CGFloat = 240
    static let rowHeight: CGFloat = 28
    /// Project rows are a single line — the branch shows in a hover popover, not beneath the
    /// name — so one compact height covers them all.
    static let projectCompactRowHeight: CGFloat = 30
    /// Group headings (a repository above its checkouts, the archive) get extra height,
    /// which reads as space between groups.
    static let headingRowHeight: CGFloat = 32
    static let indentationPerLevel: CGFloat = 14

    /// Breathing room between the toolbar's safe area and the first row.
    static let contentTopInset: CGFloat = 4

    /// Reserved strip at the bottom of the sidebar for the add-project control.
    static let footerHeight: CGFloat = 32
    static let footerInset: CGFloat = 10

    static let renameFieldWidth: CGFloat = 260
    static let renameFieldHeight: CGFloat = 24

    /// Hint shown in the list area while no project has been added.
    static let emptyTitleFontSize: CGFloat = 13
    static let emptySubtitleFontSize: CGFloat = 11
    static let emptyStateSpacing: CGFloat = 4
    static let emptyStateInset: CGFloat = 20

    static let toggleAnimationDuration: TimeInterval = 0.2
}

// MARK: - Sidebar Strings

enum SidebarStrings {
    static let emptyTitle = "No Projects"
    static let emptySubtitle = "Drop a folder here, or click Add Project below."
}

// MARK: - Sidebar Row Defaults

enum SidebarRowDefaults {
    static let projectFontSize: CGFloat = 13
    static let headingFontSize: CGFloat = 11
    static let sessionFontSize: CGFloat = 12
    static let countFontSize: CGFloat = 11

    /// Hugging low enough that a stack unambiguously stretches this view over its siblings.
    static let stretchableHugging = NSLayoutConstraint.Priority(rawValue: 1)

    /// Marks a session forked from the one it is nested under.
    static let sideChatSymbol = "arrow.triangle.branch"
    static let sideChatAccessibilityLabel = "Side chat"

    /// Revealed on hover, opening the row's actions.
    static let actionSymbol = "ellipsis"
    /// The `+` on a project row's hover, opening its new-session choices.
    /// Revealed on hover over a branch heading, opening the grouping options.
    static let settingsSymbol = "gearshape"
    /// Applied to secondary text when inverted on an emphasized selection.
    static let secondaryTextAlpha: CGFloat = 0.7
    static let horizontalSpacing: CGFloat = 7
    /// The outline view places the cell almost flush against the disclosure chevron, so the
    /// gap between them is owned here.
    static let leadingInset: CGFloat = 5
    static let trailingInset: CGFloat = 8
    static let iconSize: CGFloat = 13
    /// Wider than `iconSize` so a 12pt emoji, whose glyph outgrows its font size, is not
    /// clipped at the slot's edges.
    static let iconSlotWidth: CGFloat = 16
    static let trailingSlotSize: CGFloat = 16
    /// Gap between the `+` and `⋯` when a project row shows both on hover.
    static let hoverButtonSpacing: CGFloat = 2

    static let hoverFadeDuration: TimeInterval = 0.15
    /// Matches the inset and radius of the source list's own selection shape.
    static let hoverHighlightInsetX: CGFloat = 10
    static let hoverHighlightInsetY: CGFloat = 1
    static let hoverHighlightRadius: CGFloat = 5
    static let hoverHighlightAlpha: CGFloat = 0.06
}

// MARK: - Typed App Events

/// A notification whose concrete value is also its payload. Callers can no longer pair a name
/// with the wrong `object` type, and observers receive the value they asked for without casts.
protocol AppEvent {
    static var name: Notification.Name { get }
}

extension NotificationCenter {
    func post<Event: AppEvent>(_ event: Event) {
        post(name: Event.name, object: event)
    }

    @discardableResult
    func observe<Event: AppEvent>(
        _ type: Event.Type,
        queue: OperationQueue? = nil,
        using handler: @escaping (Event) -> Void
    ) -> NSObjectProtocol {
        addObserver(forName: Event.name, object: nil, queue: queue) { notification in
            guard let event = notification.object as? Event else { return }
            handler(event)
        }
    }
}

/// Owns block-observer tokens and unregisters them with its own lifetime.
final class AppEventObservations {
    private let center: NotificationCenter
    private var tokens: [NSObjectProtocol] = []

    init(center: NotificationCenter = .default) {
        self.center = center
    }

    deinit {
        tokens.forEach(center.removeObserver)
    }

    func observe<Event: AppEvent>(
        _ type: Event.Type,
        using handler: @escaping (Event) -> Void
    ) {
        tokens.append(center.observe(type, using: handler))
    }
}

struct TerminalSessionDidEnd: AppEvent {
    static let name = Notification.Name("terminalSessionDidEnd")
    let sessionID: SessionID
}

struct ProjectsDidChange: AppEvent {
    static let name = Notification.Name("projectsDidChange")
}

struct AppSettingsDidChange: AppEvent {
    static let name = Notification.Name("appSettingsDidChange")
}

/// A storage scan finished, or its cached findings changed.
struct ArtifactScanDidChange: AppEvent {
    static let name = Notification.Name("artifactScanDidChange")
}

struct AccountPreferencesDidChange: AppEvent {
    static let name = Notification.Name("accountPreferencesDidChange")
}

struct ProfileDidChange: AppEvent {
    static let name = Notification.Name("profileDidChange")
    let profile: TerminalProfile
}

struct AccountUsageDidChange: AppEvent {
    static let name = Notification.Name("SkalmanAccountUsageDidChange")
    let accountID: AccountID
}

struct ThemesDidChange: AppEvent {
    static let name = Notification.Name("themesDidChange")
}

struct ThemeAssignmentsDidChange: AppEvent {
    static let name = Notification.Name("themeAssignmentsDidChange")
}
