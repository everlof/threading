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

    /// `<foreground>;<background>`, as ANSI colour indices — rxvt's convention for telling a
    /// program whether it is drawing on paper or on ink. See `TerminalTheme.colorFGBG`.
    static let colorFGBG = "COLORFGBG"
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
    static var projectMenu: String { L10n.string("Project") }
    static var editMenu: String { L10n.string("Edit") }
    static var viewMenu: String { L10n.string("View") }
    static var windowMenu: String { L10n.string("Window") }
    static var helpMenu: String { L10n.string("Help") }
}

// MARK: - Process Tree Defaults

enum SessionInfoDefaults {
    /// How often the info panel re-reads while it is on screen.
    ///
    /// Processes and ports raise no filesystem event, so the panel has to ask again rather than
    /// be told. Two seconds is short enough that a server started in the terminal appears about
    /// as fast as the eye moves to the pane, and long enough that the walk costs nothing
    /// noticeable — and it is also the window each CPU percentage is measured over.
    static let refreshInterval: TimeInterval = 2.0
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

// MARK: - Agent Defaults

enum AgentDefaults {
    static let defaultKind: AgentKind = .claude
    static let untitledSessionName = "New Session"

    /// Name a side chat carries until a prompt or the agent names it.
    static let sideChatTitle = "Side Chat"

    static let claudeExecutable = "claude"
    static let codexExecutable = "codex"

    static let claudeModelFlag = "--model"
    static let codexModelFlag = "--model"

    /// Runs enabled hooks without the review Codex otherwise requires.
    ///
    /// Named here rather than written inline because of what it does: it un-gates every hook in
    /// the account's config directory for that invocation, not only the ones Threading installed.
    /// It is passed solely when `AppSettings.bypassesCodexHookTrust` is on.
    static let codexBypassHookTrustFlag = "--dangerously-bypass-hook-trust"

    /// How a launch states its permission posture. Claude names one mode; Codex splits the same
    /// idea across when-to-ask and what-may-happen-without-asking, so it takes two flags.
    /// `AgentPermissionMode` owns which values pair with which.
    static let claudePermissionModeFlag = "--permission-mode"
    static let codexApprovalFlag = "--ask-for-approval"
    static let codexSandboxFlag = "--sandbox"

    static let codexApprovalUntrusted = "untrusted"
    static let codexApprovalOnRequest = "on-request"
    static let codexApprovalNever = "never"

    static let codexSandboxReadOnly = "read-only"
    static let codexSandboxWorkspaceWrite = "workspace-write"
    static let codexSandboxFullAccess = "danger-full-access"

    /// Model choices offered for Claude: the aliases its `--help` documents, which track the
    /// latest of each family rather than pinning a dated name.
    static let claudeModels = ["opus", "sonnet", "fable"]

    /// Fast mode is an Opus-family capability (measured against CLI 2.1.218). Matching the family
    /// name rather than pinning dated ids keeps the check correct as new Opus versions ship — the
    /// `opus` alias and every full Opus identifier share it.
    static let claudeFastModeFamily = "opus"

    /// Where Claude records the model an account runs on, so the composer can name it rather
    /// than calling it "Default".
    static let claudeSettingsFile = "settings.json"
    static let claudeModelKey = "model"
    static let claudeEffortKey = "effortLevel"

    /// Claude's own switch for its Remote Control bridge, written into the per-session
    /// `--settings` file rather than the account's config: a settings file is read ahead of the
    /// CLI's global config (measured against 2.1.220 — `claude doctor` validates the key from a
    /// `--settings` path), so Threading can override `/config` for one conversation without
    /// touching a file the user owns. There is no launch flag for the off direction:
    /// `--remote-control` only opts in.
    static let claudeRemoteControlKey = "remoteControlAtStartup"

    /// Codex writes the model catalog it receives for each account beside config.toml.
    static let codexConfigFile = "config.toml"
    static let codexModelsCacheFile = "models_cache.json"
    static let codexModelKey = "model"
    static let codexVisibleModel = "list"

    /// One-run override keys and values.
    static let codexReasoningEffortKey = "model_reasoning_effort"
    static let codexResearchReasoningEffort = "low"
    static let codexServiceTierKey = "service_tier"
    static let codexStandardServiceTier = "default"
    static let codexFastServiceTier = "priority"
    static let codexFastServiceTierAlias = "fast"
    static let codexFastModeFeatureKey = "features.fast_mode"
    static let codexFastModeName = "Fast"

    /// Where Claude records transcripts, relative to an account's config directory.
    static let claudeProjectsSubdirectory = "projects"
    static let claudeSubagentsSubdirectory = "subagents"
    static let transcriptExtension = "jsonl"

    /// Claude names a project's directory after its absolute path with separators replaced.
    static let projectSlugSeparator = "-"
}

// MARK: - Agent Environment

/// Environment variables identifying an agent session, which must not be inherited by the
/// sessions Threading launches.
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

/// Settings for the MCP server Threading exposes to the agents it launches.
///
/// The server gives an agent a way to reach the GUI it is running inside — showing an image
/// in the side panel rather than naming a file path the terminal cannot render.
enum MCPDefaults {
    /// The server name agents see. Tool names derive from it: `mcp__threading__display_image`.
    static let serverName = "threading"
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
    static let portEnvironmentKey = "THREADING_MCP_PORT"
    static let sessionTokenEnvironmentKey = "THREADING_SESSION_TOKEN"

    /// Set only for sessions Threading renders itself, and read by Codex's `PreToolUse` hook.
    ///
    /// Codex has one `hooks.json` per account, shared by every session, so a surface-specific
    /// behaviour cannot be expressed in the file. This variable is how a shared file is scoped
    /// to one surface: a terminal session raises Codex's own approval prompt and must not be
    /// intercepted, so it simply does not export this.
    static let brokerEnvironmentKey = "THREADING_BROKER_TOOLS"

    /// Marks the entries in a shared `hooks.json` that belong to Threading.
    ///
    /// A shell comment, so it is inert where it sits, and the only way to tell our entries from
    /// another tool's when updating a file we do not own.
    static let hookMarker = "# threading-lifecycle"

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
    /// The width the panel is *opened* at when nothing narrower was chosen, and the floor a
    /// stored width is clamped to. Not the split item's minimum — see `slimmestWidth`.
    static let minWidth: CGFloat = 200
    static let defaultWidth: CGFloat = 380

    /// The panel's hard floor: its own chrome and nothing more.
    ///
    /// `NSSplitViewItem.minimumThickness` is a **required** constraint, and a window laid out
    /// with Auto Layout cannot be resized below what its required constraints ask for — so a
    /// pane minimum is also a *window* minimum. Measured: the window's minimum content width was
    /// 572pt with the panel shut and 773pt with it open at a 200pt minimum. `display_image`
    /// opens the panel, so showing a picture quietly cost 200pt of how small the window was
    /// allowed to be, which is not a price a panel gets to charge.
    ///
    /// At the pane's own chrome width the panel costs the window nothing it was not already
    /// paying, and a divider dragged past it still snaps the panel shut (`canCollapse`). The
    /// 200pt is still where it opens; it is simply no longer where the *window* stops.
    static let slimmestWidth: CGFloat = 48

    /// How hard the panel holds the width the divider was dragged to.
    ///
    /// `NSSplitViewController` positions its items with a constraint at the item's holding
    /// priority, and an ordinary view's content hugging is `defaultLow` — the *same* 250. A tie
    /// is what the panel had: drag it wider and on mouse-up the solver was free to prefer the
    /// labels' natural width, so the pane sprang back to whatever its content happened to want.
    /// One step above that settles it, and leaves the panel below the priority at which its own
    /// content resists being squeezed — the pane still stops at `minWidth`, it just no longer
    /// undoes the drag. The terminal keeps the default and so absorbs a window resize.
    static let holdingPriority = NSLayoutConstraint.Priority(
        NSLayoutConstraint.Priority.defaultLow.rawValue + 10
    )
    static let padding: CGFloat = 8
    static let buttonSize: CGFloat = 20
    static let titleFontSize: CGFloat = 11
    static let captionFontSize: CGFloat = 10

    /// The pane's one header row is its tabs and the `+` beside them: there was a titled header
    /// above the strip once, and it spent two rows of a narrow pane saying the name of the tab
    /// twice. The row's *height* is no longer stated here — `ThemedTabStripView.bandHeight`
    /// owns the strip band, one silhouette for every pane that draws tabs.
    static let tabChipMaxWidth: CGFloat = 180

    /// The "+" menu's floor, shared by every host that offers one.
    static let newTabMenuMinimumWidth: CGFloat = 160

    /// Agent-created content and browser tabs are capped independently so neither repeated
    /// rendering nor tab-opening can grow an unbounded strip or retain unbounded web processes.
    static let maximumContentTabs = 8
    static let maximumBrowserTabs = 8
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
    /// What the *list* needs: an icon, an indented name, and the row's two trailing buttons.
    ///
    /// Not where the column actually stops. The window controls float over the sidebar at a
    /// fixed x, so the real floor is where they end — claimed at runtime by
    /// `MainWindowController.updateSidebarMinimumThickness`, which can only ever raise this.
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

    /// Breathing room between the header band's hairline and the first row.
    static let contentTopInset: CGFloat = 4

    /// The header's arrangement control — the platform's "use groups" glyph, which is the
    /// closest thing the menu behind it (grouping, then sorting) has to one name.
    static let arrangementSymbol = "square.grid.3x1.below.line.grid.1x2"

    /// How hard the sidebar holds its width against a window resize.
    ///
    /// The sidebar behaviour arranged this for itself; a plain split item does not, and without
    /// it both panes grew when the window did — a sidebar that widens with the window is a
    /// sidebar the user has to keep putting back. One step above the default settles it in
    /// favour of the terminal, which is the pane that should absorb the change. The same
    /// reasoning and the same step as `DisplayPaneDefaults.holdingPriority`, at the other end
    /// of the window.
    static let holdingPriority = NSLayoutConstraint.Priority(
        NSLayoutConstraint.Priority.defaultLow.rawValue + 10
    )

    static let renameFieldWidth: CGFloat = 260
    /// The same height every other single-line field draws — see `Design.Size.fieldHeight`.
    static let renameFieldHeight: CGFloat = Design.Size.fieldHeight

    /// Hint shown in the list area while no project has been added.
    static let emptyTitleFontSize: CGFloat = 13
    static let emptySubtitleFontSize: CGFloat = 11
    static let emptyStateSpacing: CGFloat = 4
    static let emptyStateInset: CGFloat = 20
}

// MARK: - Sidebar Strings

enum SidebarStrings {
    static var emptyTitle: String { L10n.string("No Projects") }
    static var emptySubtitle: String {
        L10n.string("Drop a folder here, or click + above.")
    }
    static var arrangementOptions: String { L10n.string("Grouping and Sorting") }
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
    static var sideChatAccessibilityLabel: String { L10n.string("Side chat") }

    /// Revealed on hover, opening the row's actions.
    static let actionSymbol = "ellipsis"
    /// Revealed on hover beside the `⋯`, filing the session away in one press.
    ///
    /// Archiving is the one row action reached often enough to be worth a button of its own;
    /// it stays in the menu too, so the two surfaces cannot drift.
    static let archiveSymbol = "archivebox"
    static var archiveAccessibilityLabel: String { L10n.string("Archive session") }
    /// The `+` on a project row's hover, opening its new-session choices.
    /// Revealed on hover over a branch heading, opening the grouping options.
    static let settingsSymbol = "gearshape"
    /// Applied to secondary text when inverted on an emphasized selection.
    static let secondaryTextAlpha: CGFloat = 0.7

    // The three below were 7, 5 and 8 — none of them on `Design.Spacing`'s scale, which is
    // deliberately small (4/6/10/12) precisely so a row cannot drift a point away from every
    // other row in the app. They were each measured against this one list rather than chosen,
    // which is how the `⋯` came to sit at a different inset from the `×` beside it in the
    // toolbar. On the scale now, at the nearest step in each case.
    static let horizontalSpacing: CGFloat = Design.Spacing.small
    /// The outline view places the cell almost flush against the disclosure chevron, so the
    /// gap between them is owned here.
    static let leadingInset: CGFloat = Design.Spacing.tight
    static let trailingInset: CGFloat = Design.Spacing.small
    static let iconSize: CGFloat = 13
    /// Wider than `iconSize` so a 12pt emoji, whose glyph outgrows its font size, is not
    /// clipped at the slot's edges.
    static let iconSlotWidth: CGFloat = 16

    /// The row's trailing control — its status dot, and the `⋯` that replaces it on hover.
    ///
    /// The same target as every other nested icon button, rather than the 16 it used to be: a
    /// row's `⋯` and a tab's `×` are one control, and sizing this one where it was used is what
    /// made them differ. See `ThemedIconButton.Target.inline`.
    static let trailingSlotSize: CGFloat = Design.Size.inlineButtonTarget
    /// Gap between the `+` and `⋯` when a project row shows both on hover.
    static let hoverButtonSpacing: CGFloat = 2

    /// Width of a *session* row's trailing slot, which carries two buttons on hover.
    ///
    /// Stated as the pair's full width rather than one button's, so both buttons lie inside
    /// the slot. A button pinned to the slot's edge and allowed to overhang it draws
    /// perfectly and cannot be clicked at all: `NSView.hitTest` stops at the container's
    /// bounds, which is the same class of bug as the `⋯` the status dot used to swallow.
    ///
    /// The cost is real and deliberate — the title gives up this much width on every row,
    /// hovered or not, because a slot that resized under the pointer would re-lay out the
    /// row as the pointer crossed it.
    static let sessionTrailingSlotWidth: CGFloat = trailingSlotSize * 2 + hoverButtonSpacing

    /// Matches the inset of the source list's own selection shape.
    static let hoverHighlightInsetX: CGFloat = 10
    static let hoverHighlightInsetY: CGFloat = 1
    /// The hover corner under the **System** theme alone, measured against the stock source
    /// list's selection. Every other theme draws its own selection, so hover takes that
    /// theme's `Design.Radius.control` instead — see `SidebarHoverRowView.highlightRadius`.
    static let systemHoverHighlightRadius: CGFloat = 5
    static let hoverHighlightAlpha: CGFloat = 0.06
}

// MARK: - Typed App Events

/// A notification whose concrete value is also its payload. Callers can no longer pair a name
/// with the wrong `object` type, and observers receive the value they asked for without casts.
protocol AppEvent: Sendable {
    static var name: Notification.Name { get }
}

extension NotificationCenter {
    func post<Event: AppEvent>(_ event: Event) {
        post(name: Event.name, object: event)
    }

    @discardableResult
    @MainActor
    func observe<Event: AppEvent>(
        _ type: Event.Type,
        using handler: @escaping @MainActor @Sendable (Event) -> Void
    ) -> NSObjectProtocol {
        addObserver(forName: Event.name, object: nil, queue: .main) { notification in
            guard let event = notification.object as? Event else { return }
            MainActor.assumeIsolated {
                handler(event)
            }
        }
    }
}

/// Owns block-observer tokens and unregisters them with its own lifetime.
@MainActor
final class AppEventObservations {
    private let storage: AppEventObservationStorage

    init(center: NotificationCenter = .default) {
        storage = AppEventObservationStorage(center: center)
    }

    func observe<Event: AppEvent>(
        _ type: Event.Type,
        using handler: @escaping @MainActor @Sendable (Event) -> Void
    ) {
        storage.tokens.append(storage.center.observe(type, using: handler))
    }

    /// A notification AppKit posts, which carries no `AppEvent` value of ours. Same main-queue
    /// delivery and the same lifetime, so an observer of a platform preference is torn down with
    /// the view that cared about it rather than through a hand-held token.
    func observe(
        _ name: Notification.Name,
        using handler: @escaping @MainActor @Sendable () -> Void
    ) {
        let token = storage.center.addObserver(forName: name, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { handler() }
        }
        storage.tokens.append(token)
    }
}

/// NotificationCenter's token protocol predates Sendable. Mutation is main-actor confined by
/// `AppEventObservations`; teardown may run from a nonisolated deinitializer, where the object
/// is uniquely owned and only removes its immutable snapshot of tokens.
private final class AppEventObservationStorage: @unchecked Sendable {
    let center: NotificationCenter
    var tokens: [NSObjectProtocol] = []

    init(center: NotificationCenter) {
        self.center = center
    }

    deinit {
        tokens.forEach(center.removeObserver)
    }
}

struct TerminalSessionDidEnd: AppEvent {
    static let name = Notification.Name("terminalSessionDidEnd")
    let sessionID: SessionID
}

struct ProjectsDidChange: AppEvent {
    static let name = Notification.Name("projectsDidChange")

    /// How much of the sidebar can have changed. Other observers still treat this as the same
    /// project-store event; the outline uses the narrower case to avoid rebuilding thousands of
    /// nodes for a title that can only repaint one row.
    enum SidebarImpact {
        case structure
        case sessionRow(SessionID)
    }

    let sidebarImpact: SidebarImpact

    init(sidebarImpact: SidebarImpact = .structure) {
        self.sidebarImpact = sidebarImpact
    }
}

struct SessionActivityDidChange: AppEvent {
    static let name = Notification.Name("sessionActivityDidChange")
    let sessionID: SessionID
}

/// A macOS notification about this session was clicked; the window should show it.
struct SessionNotificationOpened: AppEvent {
    static let name = Notification.Name("sessionNotificationOpened")
    let sessionID: SessionID
}

struct AppSettingsDidChange: AppEvent {
    static let name = Notification.Name("appSettingsDidChange")
}

/// A storage scan finished, or its cached findings changed.
struct ArtifactScanDidChange: AppEvent {
    static let name = Notification.Name("artifactScanDidChange")
}

/// A project's code count finished, or its cached reading changed.
struct CodeStatsDidChange: AppEvent {
    static let name = Notification.Name("codeStatsDidChange")
    let projectID: ProjectID
}

/// The transcript usage report was rebuilt.
struct TranscriptUsageDidChange: AppEvent {
    static let name = Notification.Name("transcriptUsageDidChange")
}

struct AccountPreferencesDidChange: AppEvent {
    static let name = Notification.Name("accountPreferencesDidChange")
}

struct ProfileDidChange: AppEvent {
    static let name = Notification.Name("profileDidChange")
    let profile: TerminalProfile
}

struct AccountUsageDidChange: AppEvent {
    static let name = Notification.Name("ThreadingAccountUsageDidChange")
    let accountID: AccountID
}

struct ThemesDidChange: AppEvent {
    static let name = Notification.Name("themesDidChange")
}

struct ThemeAssignmentsDidChange: AppEvent {
    static let name = Notification.Name("themeAssignmentsDidChange")
}
