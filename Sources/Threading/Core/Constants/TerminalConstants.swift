import Foundation
import AppKit
import ThreadingRemoteKit

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

    /// What Return sends to a PTY. Named because it is being *typed on the user's behalf* — by
    /// `SessionContextHandoff`, when a comment is sent rather than parked — and a bare `"\r"`
    /// at a call site reads like a line ending rather than like pressing a key.
    static let submitSequence = "\r"

    /// How long a turn waits after a pasted file path before Return is typed for it.
    ///
    /// Claude Code and Codex resolve a pasted image path asynchronously — they read the file
    /// and mint their own attachment — so a Return sent in the same runloop turn risks
    /// submitting the prompt while the picture is still arriving, and the agent would answer a
    /// comment about an image it was never given. The value is a guess at the safe side of that
    /// race, not a measurement: it is long enough to clear a local file read and short enough
    /// that the send still reads as immediate. Raise it if a sent comment ever arrives bare.
    static let pastedTurnSubmitDelay: TimeInterval = 0.35
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

    /// Says "the stream you are writing to is not a colour terminal", whatever it is set to.
    /// Inside a session that stream is a PTY Threading draws, so an inherited value describes
    /// wherever the *app* was started from and is never true of a session. Cleared rather than
    /// overwritten: absence is the only way to say "colour is fine".
    static let noColor = "NO_COLOR"

    /// The same claim, but only when spelled `0` — any other value is the user *asking* for
    /// colour and is left alone.
    static let colorVetoes = ["CLICOLOR", "FORCE_COLOR"]

    /// The other half of "nothing is watching this": a caller that cannot page sets these to a
    /// program that does not page. A session *can* page, so the claim is dropped there — and
    /// only there. On the headless path it is true, and `AgentEnvironment.launchEnvironment`
    /// leaves it alone.
    static let pagers = ["PAGER", "GIT_PAGER", "GH_PAGER"]

    /// How that claim is spelled. Anything else is a pager the user chose, which is theirs.
    static let nonPager = "cat"

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
    static let grokExecutable = "grok"
    static let openCodeExecutable = "opencode"

    static let claudeModelFlag = "--model"
    static let codexModelFlag = "--model"
    static let grokModelFlag = "--model"
    static let openCodeModelFlag = "--model"

    /// Runs enabled hooks without the review Codex otherwise requires.
    ///
    /// Named here rather than written inline because of what it does: it un-gates every hook in
    /// the account's config directory for that invocation, not only the ones Threading installed.
    /// It is passed solely when `AppSettings.bypassesCodexHookTrust` is on.
    static let codexBypassHookTrustFlag = "--dangerously-bypass-hook-trust"

    /// How a launch states its permission posture. Claude and Grok name one mode; Codex splits
    /// the same idea across when-to-ask and what-may-happen-without-asking, so it takes two
    /// flags. `AgentPermissionMode` owns which values pair with which.
    static let claudePermissionModeFlag = "--permission-mode"
    static let codexApprovalFlag = "--ask-for-approval"
    static let codexSandboxFlag = "--sandbox"
    static let grokPermissionModeFlag = "--permission-mode"

    /// What Claude and Grok call Manual in their own vocabulary. It is Claude's *internal* name
    /// — `manual` is the external one its `--help` documents and the one `AgentPermissionMode`
    /// persists — but it is the spelling both CLIs hand back: Claude's control channel answers
    /// `{"mode":"default"}` to a `manual` request, and its transcript's `permission-mode`
    /// records carry it too. So it is written out, not accepted.
    static let agentInternalManualMode = "default"

    static let codexApprovalUntrusted = "untrusted"
    static let codexApprovalOnRequest = "on-request"
    static let codexApprovalNever = "never"

    static let codexSandboxReadOnly = "read-only"
    static let codexSandboxWorkspaceWrite = "workspace-write"
    static let codexSandboxFullAccess = "danger-full-access"

    /// Model choices offered for Claude: the aliases its `--help` documents, which track the
    /// latest of each family rather than pinning a dated name.
    ///
    /// All four the CLI accepts, matching the families its own picker lists at the top level
    /// (measured against 2.1.221). `haiku` was missing here for as long as this list existed,
    /// so the fastest model was the one model Threading could not select at all.
    ///
    /// The picker's second tier — dated versions such as Opus 4.6 under "More models" — is
    /// deliberately *not* mirrored. Those ids live only inside the CLI binary, with no local
    /// listing to read and no per-account access filter, so a copy here would be a hand-kept
    /// list that goes stale every release while claiming to be the catalog. An account granted
    /// anything beyond these four surfaces it through `claudeAdditionalModelsKey` instead.
    ///
    /// Written most capable first, which is the order `AgentModels.byCapability` puts them in
    /// anyway. Kept honest here so the constant is not read as a ranking that disagrees with the
    /// menu it feeds.
    static let claudeModels = ["fable", "opus", "sonnet", "haiku"]

    /// Fast mode is an Opus-family capability (measured against CLI 2.1.218). Matching the family
    /// name rather than pinning dated ids keeps the check correct as new Opus versions ship — the
    /// `opus` alias and every full Opus identifier share it.
    static let claudeFastModeFamily = "opus"

    /// Where Claude records the model an account runs on, so the composer can name it rather
    /// than calling it "Default".
    static let claudeSettingsFile = "settings.json"
    static let claudeModelKey = "model"
    static let claudeEffortKey = "effortLevel"
    static let claudeEffortFlag = "--effort"

    /// Claude's persisted speed switch. Threading writes it only into the per-session
    /// `--settings` layer, so choosing a startup speed never edits the account's own file.
    static let claudeFastModeKey = "fastMode"

    /// The session-level values the installed CLI documents for `--effort` (2.1.222).
    /// Unlike Codex, Claude does not publish per-model subsets, so these apply to every model
    /// the same CLI exposes. The string identifiers stay provider-native all the way to launch.
    static let claudeReasoningEfforts = ["low", "medium", "high", "xhigh", "max"]

    /// The CLI's own per-account state file, beside `settings.json` in the same config directory.
    ///
    /// `settings.json` is what the *user* wrote; this is what the CLI cached from the service, so
    /// it answers two questions the settings file cannot: which models beyond the documented
    /// aliases this login may select, and which model its organisation defaults to. Both keys are
    /// undocumented and frequently absent — they were null on two of four logins when this was
    /// measured — so every read of them is strictly additive and a miss changes nothing.
    static let claudeStateFile = ".claude.json"

    /// Models this login can use beyond `claudeModels`, each `{value, label, description}`.
    /// Observed carrying `claude-fable-5[1m]`, which no alias names.
    static let claudeAdditionalModelsKey = "additionalModelOptionsCache"

    /// The model a managed organisation defaults its logins to. Null on personal accounts, which
    /// is why it sits *below* the user's own `settings.json` rather than replacing it.
    static let claudeOrgDefaultModelKey = "orgModelDefaultCache"

    /// The keys an org default has been seen to hide behind when it is an object rather than a
    /// bare string. Tried in order; an unrecognised shape reads as absent.
    static let claudeOrgDefaultNestedKeys = ["model", "value"]

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

    /// The model a headless Claude research run asks for. `sonnet`, and measured rather than
    /// assumed (August 2026, five intent queries incl. one in Swedish, plus the full
    /// MCP round-trip): sonnet matched haiku's wall clock or beat it (5–10s against 7–16s),
    /// answered with every plausible page where haiku often named one, honoured the JSON-only
    /// reply contract that haiku wrapped in a code fence, and cost ~7¢ against ~4¢ per search
    /// — nothing, for a button clicked occasionally. Codex research states no model at all —
    /// its knob is reasoning effort above, because a model name would have to come from the
    /// account's own catalog.
    static let claudeResearchModel = "sonnet"

    /// The model a usage-window poke asks for: the cheapest one there is.
    ///
    /// The opposite trade to `claudeResearchModel`, and for the opposite reason. A research run
    /// is read for its answer, so quality is worth four cents; a poke's answer is discarded
    /// unread and the *only* thing it buys is the window's opening timestamp. Every token it
    /// spends comes out of the weekly limit the poke exists to spend more carefully, so the run
    /// asks the smallest model for the smallest reply it can.
    static let claudePokeModel = "haiku"

    /// What a poke says. One token in, one token out.
    ///
    /// Deliberately not a question: anything Claude might want to *do* about it costs tool calls
    /// and turns. The reply is never read.
    static let usageWindowPokePrompt = "Reply with the single character: ."

    /// Research runs work in a neutral scratch directory, which is not a repository. Codex
    /// refuses to run outside one unless told this is deliberate.
    static let codexSkipGitRepoCheckFlag = "--skip-git-repo-check"
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

/// Everything an agent runner exports about **its own run**, which must not be inherited by the
/// sessions Threading launches.
///
/// A session started from inside another agent's shell would otherwise be handed that
/// conversation's identifiers and treat itself as a nested child of it — and, worse than
/// identity, the *posture* that run was given. `open` forwards its caller's environment through
/// LaunchServices, so a Threading opened from a Codex tool call carried
/// `CODEX_SANDBOX_NETWORK_DISABLED=1` and `CODEX_PERMISSION_PROFILE=:workspace` into every
/// session under it: an agent told the network is off, by a sandbox that ended hours ago.
///
/// Named by family rather than variable by variable, because the failure is silent and the
/// families keep growing — `CODEX_THREAD` was listed and `CODEX_CI` was not, which is the kind of
/// gap nothing reports.
enum AgentEnvironment {
    /// The families. Each is a runner describing a run, never a machine describing itself.
    static let inheritedIdentityPrefixes = [
        "CLAUDE_",
        "CLAUDECODE",
        "CODEX_",
        "GROK_",
        "OPENCODE_",
        "AI_AGENT"
    ]

    /// The exception inside those families: where an account's config lives is a *place*, not a
    /// run, and it is how a launch reaches a login other than the default. `AgentKind` owns the
    /// four names, so a new runtime cannot be added and forgotten here.
    static var accountConfigKeys: Set<String> {
        Set(AgentKind.allCases.map(\.accountEnvironmentKey))
    }

    static func isInheritedAgentIdentity(_ key: String) -> Bool {
        guard !accountConfigKeys.contains(key) else { return false }
        return inheritedIdentityPrefixes.contains { key.hasPrefix($0) }
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

    /// Pre-rename aliases exported beside the current routing variables.
    ///
    /// Existing Codex hooks were approved by the hash of their exact command text. Rewriting
    /// `SKALMAN_*` to `THREADING_*` would invalidate that approval, so launches with the
    /// integration enabled keep the old vocabulary alive while the installer recognises the
    /// known-compatible old commands. These names carry the same per-process values and do not
    /// broaden the endpoint's reach.
    static let legacyPortEnvironmentKey = "SKALMAN_MCP_PORT"
    static let legacySessionTokenEnvironmentKey = "SKALMAN_SESSION_TOKEN"

    /// Set only for sessions Threading renders itself, and read by Codex's `PreToolUse` hook.
    ///
    /// Codex has one `hooks.json` per account, shared by every session, so a surface-specific
    /// behaviour cannot be expressed in the file. This variable is how a shared file is scoped
    /// to one surface: a terminal session raises Codex's own approval prompt and must not be
    /// intercepted, so it simply does not export this.
    static let brokerEnvironmentKey = "THREADING_BROKER_TOOLS"
    static let legacyBrokerEnvironmentKey = "SKALMAN_BROKER_TOOLS"

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

    /// How long an observational lifecycle hook waits before giving up.
    ///
    /// Deliberately tiny for observational boundaries. An unreachable app must cost a moment,
    /// not a turn. Turn start has its own timeout below because that reply is an admission
    /// barrier and therefore does carry correctness.
    static let lifecycleTimeout: TimeInterval = 2
    /// UserPromptSubmit is an admission barrier. A snapshot can run `rev-parse`, `read-tree`,
    /// `add`, and `write-tree`; each has GitReviewDefaults' 15-second process bound. Keep the
    /// hook alive for that full worst case plus transport overhead, or curl could release the
    /// agent while the baseline was still moving. Other observational hooks stay at 2s.
    static let turnStartLifecycleTimeout: TimeInterval = 62

    /// Stop is the other checkpoint barrier. Releasing it early would let the next queued turn
    /// alter the checkout before the authoritative final tree had been published.
    static let turnFinishLifecycleTimeout: TimeInterval = 62

    static func lifecycleTimeout(for event: HookLifecycleEvent) -> TimeInterval {
        switch event {
        case .turnStarted: return turnStartLifecycleTimeout
        case .turnFinished: return turnFinishLifecycleTimeout
        default: return lifecycleTimeout
        }
    }

    /// Also cleaned up when a session is deleted. Kept alongside the retained tokens so a
    /// revoked endpoint leaves no settings file pointing at it.
    static let cleanupDirectories = [configDirectoryName, settingsDirectoryName]

    /// Where per-session Claude `--mcp-config` files are written, under Application Support.
    static let configDirectoryName = "mcp"
    static let configFileExtension = "json"

    /// Claude tools are allowlisted wholesale, or every image would raise a permission prompt.
    static let allowedToolsPattern = "mcp__\(serverName)__*"

    /// The full Claude-side name of one tool, for launches that pre-approve a single tool
    /// rather than the wholesale pattern above — the scoped research runs.
    static func allowedToolName(_ tool: String) -> String {
        "mcp__\(serverName)__\(tool)"
    }

    /// Refused rather than read into memory, since the panel shows one image at a time.
    static let maximumImageBytes = 64 * 1024 * 1024
    /// Compressed bytes do not bound decoded memory. These still admit unusually long browser
    /// screenshots while refusing dimensions that would allocate hundreds of megabytes or
    /// overflow a decoder's row arithmetic.
    static let maximumImagePixelDimension = 32_768
    static let maximumImagePixelCount = 80_000_000

    /// Well under `maximumRequestBytes`, so an oversized document is refused with an
    /// explanation the agent can act on rather than a transport-level error it cannot.
    static let maximumHTMLBytes = 2 * 1024 * 1024

    /// Ceiling on a single HTTP request, so a malformed client cannot grow the buffer forever.
    static let maximumRequestBytes = 8 * 1024 * 1024
}

// MARK: - Display Pane Defaults

enum DisplayPaneDefaults {
    /// Narrower than this is not a width anyone chose: a value below it in the stored geometry
    /// is read as "never set". Not the split item's minimum — see `slimmestWidth`.
    static let minWidth: CGFloat = 200

    /// The floor for a panel opening for the first time. What the panel is *for* — an image, a
    /// rendered report, a comparison — stops being legible below about this.
    static let defaultWidth: CGFloat = 440

    /// A first open takes this share of the window rather than one fixed number, clamped
    /// between `defaultWidth` and `widestOpening`. A panel that is a third of a 1600pt window is
    /// the same panel as a third of a 1200pt one; 440pt of either is two different panels, and
    /// on a large display it reads as a sliver stuck to the edge. Once the divider has been
    /// dragged, that width is the answer and this is not consulted again.
    static let openingFraction: CGFloat = 0.32

    /// The most a panel opens itself to. Past this it is taking the window rather than sharing
    /// it — and the user can still drag it wider.
    static let widestOpening: CGFloat = 620

    /// The footer's content dropdown floor, matching the Git Review overflow so the two panes'
    /// menus read as one control.
    static let contentMenuWidth: CGFloat = 190

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
    ///
    /// Stated as the parts rather than as the number they came to, because the parts are what
    /// moves it: the header's two trailing controls — `+` and the panel's own toggle — and the
    /// margin the row keeps from the pane's edge. The tab strip is not in the sum; it scrolls,
    /// and yields its whole width here (see `DisplayPaneController.setupConstraints`).
    ///
    /// Both are `.toolbar` icon buttons on the *session* header's margin, because the toggle is
    /// one control drawn in two headers and must not move between them (`DisplayPanelToggle`).
    /// That is 22pt more floor than the pane's own smaller buttons cost, and therefore 22pt of
    /// window minimum — the price of the corner control being the same button either way.
    @MainActor
    static var slimmestWidth: CGFloat {
        PaneHeaderDefaults.inset
            + Design.Size.toolbarButtonWidth
            + controlGap
            + Design.Size.toolbarButtonWidth
            + controlGap * 2
    }

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

    /// The small square controls *inside* the pane — the footer's `⋯`, which sits with a caption
    /// rather than in the window's chrome. The header row's two are not this size: `+` and the
    /// panel's toggle are `.toolbar` icon buttons, because the session header across the split
    /// draws the same toggle and the two must land on one point (`DisplayPanelToggle`).
    static let buttonSize: CGFloat = 20

    /// The air between two of the header row's own controls — tighter than `padding`, which is
    /// what the row keeps from the pane's edge. One constant so `+`, the close and the strip
    /// beside them are spaced by the same hand.
    static let controlGap: CGFloat = 4
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
    static let sessionIndexFile = "session_index.jsonl"

    /// Bound for Codex's one-record-per-thread title index. The real index is a few hundred
    /// kilobytes for thousands of conversations; this leaves ample growth without letting a
    /// corrupt file turn one title refresh into an unbounded read.
    static let sessionIndexScanLimit = 64 * 1024 * 1024

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

// MARK: - OpenCode Discovery Defaults

enum OpenCodeDiscoveryDefaults {
    static let sessionIDPrefix = "ses_"
    static let sessionListLimit = 20
    static let pollInterval: TimeInterval = 0.5
    static let maxAttempts = 20
    static let commandTimeout: TimeInterval = 5
    static let maximumSessionListBytes = 512 * 1024

    /// OpenCode records creation timestamps at millisecond precision. Swift's launch timestamp
    /// has finer precision and may therefore compare fractionally later even when both reads
    /// occurred in the same millisecond; ten milliseconds covers only that quantization.
    static let clockSlack: TimeInterval = 0.01
}

// MARK: - Grok Discovery Defaults

enum GrokDiscoveryDefaults {
    static let sessionListLimit = 50
    static let pollInterval: TimeInterval = 0.5
    static let maxAttempts = 20
    static let commandTimeout: TimeInterval = 5
    static let maximumSessionListBytes = 512 * 1024
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

    /// The widest the app opens the column *itself* — restoring a stored width, or honouring an
    /// extension's preferred one. **Not a limit on the divider**: the split item sets no maximum,
    /// so a drag runs until the terminal reaches its own floor. A number here stopped the divider
    /// dead in open space, which reads as a broken drag rather than as a decision.
    static let maxWidth: CGFloat = 400
    static let defaultWidth: CGFloat = 240

    static let rowHeight: CGFloat = 28
    /// Every sidebar dropdown's floor, so the short menus read as the same control as the
    /// long ones.
    static let menuWidth: CGFloat = 190
    /// Project rows are a single line — the branch shows in a hover popover, not beneath the
    /// name — so one compact height covers them all.
    static let projectCompactRowHeight: CGFloat = 30
    /// Group headings (a repository above its checkouts, the archive) get extra height,
    /// which reads as space between groups.
    static let headingRowHeight: CGFloat = 32
    static let indentationPerLevel: CGFloat = 14

    /// The compact tree's one content edge, measured from the column's leading side.
    ///
    /// Wide enough that the disclosure chevron — kept, because collapsing a project is the
    /// affordance the indentation was paying for — fits in a fixed gutter before it, and equal
    /// to `SidebarRowDefaults.iconSlotWidth` so the gutter reads as the same column the row
    /// icons align down.
    static let compactCellLeading: CGFloat = SidebarRowDefaults.iconSlotWidth

    /// Where the compact tree's disclosure chevrons sit, all depths alike.
    static let compactMarkerLeading: CGFloat = Design.Spacing.hairline

    /// The extra height a group-opening row takes in the compact tree, standing in for the
    /// indentation that no longer says where one project ends and the next begins. Centred
    /// content splits it above and below, the same way `headingRowHeight` already reads as
    /// space between groups.
    static let compactGroupSpacing: CGFloat = Design.Spacing.inset

    /// How far below a compact group row's top edge its rule is drawn — inside the added
    /// spacing, nearer the group it closes than the title it introduces.
    static let compactGroupRuleOffset: CGFloat = Design.Spacing.tight

    /// 1pt rather than the theme's rule weight, the same choice `Design.Chat.turnDividerHeight`
    /// makes for the same reason: this separates rows inside one pane, and a border's weight
    /// would read as a box around the group rather than a fold between two.
    static let compactGroupRuleHeight: CGFloat = 1

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

    /// Marks a session held ahead of the ordinary sidebar order.
    static let pinnedSymbol = "pin.fill"
    static var pinnedAccessibilityLabel: String { L10n.string("Pinned") }

    /// Revealed on hover, opening the row's actions.
    static let actionSymbol = "ellipsis"
    /// Revealed on hover beside the `⋯`, filing the session away in one press.
    ///
    /// Archiving is the one row action reached often enough to be worth a button of its own;
    /// it stays in the menu too, so the two surfaces cannot drift.
    static let archiveSymbol = "archivebox"
    static var archiveAccessibilityLabel: String { L10n.string("Archive session") }
    /// The `+` on a project row's hover, opening its new-session choices.
    static let createSymbol = "plus"
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

    /// Expanded width of a *session* row's trailing slot, which carries two buttons on hover.
    ///
    /// Stated as the pair's full width rather than one button's, so both buttons lie inside
    /// the slot. A button pinned to the slot's edge and allowed to overhang it draws
    /// perfectly and cannot be clicked at all: `NSView.hitTest` stops at the container's
    /// bounds, which is the same class of bug as the `⋯` the status dot used to swallow.
    ///
    /// At rest the row reserves only `trailingSlotSize` for its status. It pays this full width
    /// while the buttons are visible, when yielding that title space describes what is actually
    /// on screen rather than taxing every truncated title for controls nobody can see.
    static let sessionTrailingSlotWidth: CGFloat = trailingSlotSize * 2 + hoverButtonSpacing
    /// A working/attention state is durable information, not chrome to trade for actions. On a
    /// hovered active row the two action targets move inboard and the status keeps the stable
    /// outer target it occupies at rest.
    static let sessionTrailingSlotWithStatusWidth: CGFloat =
        trailingSlotSize * 3 + hoverButtonSpacing * 2
    static let projectTrailingSlotWidth: CGFloat = sessionTrailingSlotWidth

    /// Matches the inset of the source list's own selection shape.
    static let hoverHighlightInsetX: CGFloat = 10
    static let hoverHighlightInsetY: CGFloat = 1
    /// The hover corner under the **System** theme alone, measured against the stock source
    /// list's selection. Every other theme draws its own selection, so hover takes that
    /// theme's `Design.Radius.control` instead — see `SidebarHoverRowView.highlightRadius`.
    static let systemHoverHighlightRadius: CGFloat = 5
    static let hoverHighlightAlpha: CGFloat = 0.06
}

enum ProjectTerminalDefaults {
    /// Process cwd is the fallback for shells that do not emit OSC 7 directory reports.
    static let directoryRefreshInterval: TimeInterval = 1
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
        object: Any? = nil,
        using handler: @escaping @MainActor @Sendable () -> Void
    ) {
        let token = storage.center.addObserver(forName: name, object: object, queue: .main) { _ in
            MainActor.assumeIsolated { handler() }
        }
        storage.tokens.append(token)
    }

    /// Ends one presentation generation while leaving the owner reusable for the next. Popovers
    /// and completion panels observe a particular window only while they are open.
    func removeAll() {
        storage.removeAll()
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

    func removeAll() {
        let removed = tokens
        tokens.removeAll()
        removed.forEach(center.removeObserver)
    }

    deinit {
        tokens.forEach(center.removeObserver)
    }
}

/// Owns one application-local event monitor and removes it exactly once.
///
/// AppKit exposes monitor tokens as `Any`, which is not Sendable. Storing that value directly on
/// a main-actor view made every deinitializer reach for `nonisolated(unsafe)`. The owner below is
/// main-actor confined during use; its private Sendable storage is uniquely owned at teardown and
/// hands an opaque token back to the main queue if destruction ever arrives elsewhere.
@MainActor
final class LocalEventMonitor {
    private let storage = LocalEventMonitorStorage()

    var isInstalled: Bool { storage.token != nil }

    func install(
        matching mask: NSEvent.EventTypeMask,
        handler: @escaping (NSEvent) -> NSEvent?
    ) {
        remove()
        guard let token = NSEvent.addLocalMonitorForEvents(matching: mask, handler: handler) else {
            return
        }
        storage.token = LocalEventMonitorToken(token)
    }

    func remove() {
        guard let token = storage.token else { return }
        storage.token = nil
        NSEvent.removeMonitor(token.value)
    }
}

private final class LocalEventMonitorStorage: @unchecked Sendable {
    var token: LocalEventMonitorToken?

    deinit {
        guard let token else { return }
        if Thread.isMainThread {
            MainActor.assumeIsolated {
                NSEvent.removeMonitor(token.value)
            }
        } else {
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    NSEvent.removeMonitor(token.value)
                }
            }
        }
    }
}

/// The opaque AppKit token crosses only the exceptional deinit-to-main handoff above.
private final class LocalEventMonitorToken: @unchecked Sendable {
    let value: Any
    init(_ value: Any) { self.value = value }
}

/// Owns one main-run-loop timer without making every AppKit owner expose actor-isolated state
/// to `deinit` through `nonisolated(unsafe)`.
///
/// Callers still choose the timer's cadence and run-loop mode. This type owns only the lifecycle:
/// installing a replacement invalidates the old generation, explicit shutdown is idempotent, and
/// an owner dropped without shutdown hands its last timer back to the main queue for invalidation.
@MainActor
final class MainRunLoopTimer {
    private let storage = MainRunLoopTimerStorage()

    var isInstalled: Bool { storage.timer != nil }

    func install(_ timer: Timer) {
        invalidate()
        storage.timer = MainRunLoopTimerToken(timer)
    }

    func invalidate() {
        guard let timer = storage.timer else { return }
        storage.timer = nil
        timer.value.invalidate()
    }
}

private final class MainRunLoopTimerStorage: @unchecked Sendable {
    var timer: MainRunLoopTimerToken?

    deinit {
        guard let timer else { return }
        if Thread.isMainThread {
            MainActor.assumeIsolated {
                timer.value.invalidate()
            }
        } else {
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    timer.value.invalidate()
                }
            }
        }
    }
}

/// `Timer` is run-loop-bound rather than Sendable; this token crosses only the exceptional
/// deinit-to-main handoff above.
private final class MainRunLoopTimerToken: @unchecked Sendable {
    let value: Timer
    init(_ value: Timer) { self.value = value }
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
        /// One session's display name can move it among otherwise unchanged siblings.
        case sessionOrder(SessionID)
        case sessionRow(SessionID)
        case terminalRow(TerminalID)
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

/// One chat's live audience moved: somebody joined, left, resized, or started composing.
///
/// Separate from `SessionSharingDidChange` on purpose — who is *watching* changes many times a
/// minute while who *may* watch changes when the owner acts, and the corner card only wants to
/// redraw for the first.
struct SessionFollowersDidChange: AppEvent {
    static let name = Notification.Name("sessionFollowersDidChange")
    let sessionID: SessionID
}

/// A link was created or withdrawn, or somebody's access was revoked.
struct SessionSharingDidChange: AppEvent {
    static let name = Notification.Name("sessionSharingDidChange")
}

/// The live writer mode or controller changed for one shared session.
struct SessionInputControlDidChange: AppEvent {
    static let name = Notification.Name("sessionInputControlDidChange")
    let sessionID: SessionID
}

/// A collaborator asked the current controller to hand them the input stream.
struct SessionInputControlRequested: AppEvent {
    static let name = Notification.Name("sessionInputControlRequested")
    let sessionID: SessionID
    let requesterName: String
}

/// The focused controller is remote and the owner attempted a local terminal gesture.
struct SessionLocalInputBlocked: AppEvent {
    static let name = Notification.Name("sessionLocalInputBlocked")
    let sessionID: SessionID
}

/// An archive an agent asked for has come due: its turn has ended and it can be filed away.
///
/// Announced rather than performed, because the archive is a sidebar action with a receipt on
/// it and `SessionArchiveScheduler` is in Core. See `SessionCoordinator.archiveAtAgentRequest`.
struct SessionArchiveRequestDidBecomeDue: AppEvent {
    static let name = Notification.Name("sessionArchiveRequestDidBecomeDue")
    let sessionID: SessionID
    let reason: String?
}

/// A local archive flag changed through provider synchronization.
///
/// `ProjectsDidChange` rebuilds lists, but it deliberately says nothing about the pane currently
/// showing a row that just disappeared. The window observes this narrower lifecycle event to put
/// an externally archived conversation away as completely as one archived from its own menu.
struct SessionArchivedStateDidChange: AppEvent {
    static let name = Notification.Name("sessionArchivedStateDidChange")
    let sessionID: SessionID
    let isArchived: Bool
}

/// A macOS notification about this session was clicked; the window should show it.
struct SessionNotificationOpened: AppEvent {
    static let name = Notification.Name("sessionNotificationOpened")
    let sessionID: SessionID
    let destination: RemoteNotificationDestinationDTO

    init(
        sessionID: SessionID,
        destination: RemoteNotificationDestinationDTO = .session
    ) {
        self.sessionID = sessionID
        self.destination = destination
    }
}

/// Something was scheduled, unscheduled, rescheduled, delivered or given up on.
///
/// Carries no identity: every surface that draws scheduled sends draws a *list* of them, and a
/// per-item event would have each one rebuilding the same list anyway.
struct ScheduledMessagesDidChange: AppEvent {
    static let name = Notification.Name("scheduledMessagesDidChange")
}

/// A scheduled send's moment has arrived.
///
/// Announced rather than performed, for `SessionArchiveRequestDidBecomeDue`'s reason:
/// `ScheduledMessageScheduler` lives in Core and knows nothing about sidebars, surfaces or
/// launching. `SessionCoordinator` performs it — and **claims the record first**, because a send
/// is not idempotent the way an archive is.
struct ScheduledMessageDidBecomeDue: AppEvent {
    static let name = Notification.Name("scheduledMessageDidBecomeDue")
    let id: ScheduledMessageID
}

/// Sends whose moment passed while the app was not running, gathered for one review.
struct ScheduledMessagesWereMissed: AppEvent {
    static let name = Notification.Name("scheduledMessagesWereMissed")
    let ids: [ScheduledMessageID]
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

struct UsageLimitHistoryDidChange: AppEvent {
    static let name = Notification.Name.usageLimitHistoryDidChange
}

/// The usage-window poke's schedule was edited.
struct UsageWindowScheduleDidChange: AppEvent {
    static let name = Notification.Name("ThreadingUsageWindowScheduleDidChange")
}

/// A poke fired, failed, or the standing reason it is holding changed — the signal the settings
/// page redraws its ledger on.
struct UsageWindowPokeDidChange: AppEvent {
    static let name = Notification.Name("ThreadingUsageWindowPokeDidChange")
}

struct ThemesDidChange: AppEvent {
    static let name = Notification.Name("themesDidChange")
}

struct ThemeAssignmentsDidChange: AppEvent {
    static let name = Notification.Name("themeAssignmentsDidChange")
}
