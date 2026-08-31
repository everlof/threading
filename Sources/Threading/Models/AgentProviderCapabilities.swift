import Foundation

// MARK: - Agent Runtime

/// Features the host can rely on for one agent runtime.
///
/// Model providers are intentionally absent: OpenRouter, Anthropic, OpenAI, and xAI are model
/// backends selected by a runtime. Keeping this matrix about CLI behavior means a Grok model
/// selected through OpenCode is still an OpenCode session, while the standalone `grok` program
/// is its own runtime with its own sessions and launch contract.
/// Each member documents which runtimes have it and why, because this declaration is where
/// someone adding a sixth runtime reads the contract. The first seven also have a named
/// `supportsX` property on `AgentKind`, which predates `supports(_:)`; new capabilities are
/// read through `supports(_:)` rather than growing that surface further.
///
/// A capability earns a member here only when the difference is a *static fact about the
/// runtime*. Two other mechanisms carry the rest and are not to be duplicated here:
/// catalog data (`AgentModelOption.reasoningLevels` decides whether an effort control
/// appears at all) and live-transport conformance (`FastModeConversation` and its kin decide
/// what a running conversation can be asked to change).
struct AgentCapabilities: OptionSet {
  let rawValue: Int

  static let resume = Self(rawValue: 1 << 0)
  static let presetSessionID = Self(rawValue: 1 << 1)
  static let accounts = Self(rawValue: 1 << 2)
  static let nativeUI = Self(rawValue: 1 << 3)
  static let permissionModes = Self(rawValue: 1 << 4)
  static let forking = Self(rawValue: 1 << 5)
  static let threadingBridge = Self(rawValue: 1 << 6)

  /// The runtime has its own remote-control bridge — the one that lets the vendor's web and
  /// mobile clients drive a local conversation — which Threading can set at launch and offer
  /// per session. Claude only; Codex, Grok and OpenCode expose no equivalent, and their
  /// launches never carry the key.
  static let remoteControl = Self(rawValue: 1 << 7)

  /// The runtime draws a status line inside its own TUI. That line is both something
  /// Threading can silence on the user's behalf and something whose coverage it must consult
  /// before drawing facts of its own, so a terminal does not state the model twice. Claude
  /// only. Native conversations run `--print`, where no status line is drawn at all, so this
  /// governs terminal surfaces regardless of the runtime.
  static let statusLine = Self(rawValue: 1 << 8)

  /// The runtime's transcript records a conversation title Threading can read back. This is
  /// what names a native session, which has no terminal to report a title over, and what
  /// carries a name across a surface switch. Claude only: Codex's rollout has no title
  /// record, so its sessions keep their prompt-derived name.
  static let transcriptTitles = Self(rawValue: 1 << 9)

  /// The runtime's transcript records which model actually answered. Threading reads it as
  /// the third source for the terminal's model reading, after the session's own choice and
  /// the account config — which is how a session visibly running Opus reported only its
  /// effort. Claude only; Codex records its model in a rollout of a different shape.
  static let transcriptModelRecord = Self(rawValue: 1 << 10)

  /// Fast is a *service tier* on the account's model catalog, inheritable from config and
  /// observable before launch. Codex only. This is what makes a fast reading reportable on a
  /// terminal surface, where no control channel exists to ask.
  static let serviceTierFastMode = Self(rawValue: 1 << 11)

  /// Fast is a *live control-channel flag* Threading can restate after the process starts.
  /// Claude only, and deliberately distinct from `serviceTierFastMode`: the two differ in where
  /// the live answer lives and how a turn changes it. Startup policy also travels through
  /// Claude's per-session settings layer; with no Threading choice, the native transport's
  /// fallback is off while a terminal may inherit Claude's own persisted setting.
  ///
  /// Whether a *given* transport can be asked mid-conversation stays with
  /// `FastModeConversation`; this states only what an unset choice means.
  static let liveFastModeControl = Self(rawValue: 1 << 12)

  /// A leading `/` in submitted text is a command the runtime itself interprets. Threading
  /// therefore sends such a message bare, rather than wrapping it in the shared-chat
  /// participant envelope that would turn the command into prose.
  ///
  /// Claude only, and the reason is narrower than it first appears. Codex's app-server takes
  /// submitted text as text. **ACP does not**: `GrokACPComposerCatalog` enumerates Grok's slash
  /// commands and `ACPStreamSession.send(_ invocation:)` forwards a literal `/compact …`
  /// over `session/prompt`, so Grok plainly interprets the prefix. What has not been measured
  /// is the *uncatalogued* case — a participant's leading-slash message that matches no
  /// advertised command — which is the only text this capability governs. Granting it to Grok
  /// on the strength of the catalogue alone would be reasoning past the evidence, so the
  /// consequence is recorded instead: for Grok such a message keeps the participant envelope,
  /// and for Claude it does not.
  static let slashCommandPrefix = Self(rawValue: 1 << 13)

  /// A lifecycle hook and the native transport name a child agent the *same* way, so a hook
  /// may enrich a natively rendered subagent row instead of creating a twin of it. Codex
  /// only: its app-server and its hooks both use the child thread id, while Claude native
  /// keys on the Agent tool-use id and Claude's hook reports a different agent id — so for
  /// Claude the hook stays the terminal adapter alone.
  static let sharedSubagentIdentity = Self(rawValue: 1 << 14)

  /// The runtime writes no conversation record until the first prompt lands, so one poll at
  /// launch cannot settle the session's identifier. Discovery instead retries at a bounded
  /// cadence while the TUI produces output, and once more when it exits. Grok and OpenCode:
  /// both open a blank TUI that creates nothing until it is asked something.
  ///
  /// This is about the *record*, not about who chose the id, so it is orthogonal to
  /// `presetSessionID` and Grok has both: Threading mints Grok's id up front and still has to
  /// confirm the record exists before calling the conversation resumable. It is equally
  /// orthogonal to lacking `presetSessionID`, which Codex also lacks — Codex writes its
  /// rollout at launch, so one poll finds it.
  static let deferredSessionIdentifier = Self(rawValue: 1 << 15)

  /// Threading can walk this runtime's transcripts to price what a project or an account has
  /// spent, which is what the Usage report is built from.
  ///
  /// Claude, Codex and OpenCode. The restriction belongs to the *reader* rather than to a
  /// provider policy: Claude and Codex have measured local-file adapters, while OpenCode has a
  /// measured supported-export adapter. Grok's ACP reports context occupancy but its export
  /// currently carries no historical token bill, so it deliberately remains off until an
  /// authoritative source exists.
  static let transcriptUsageIndex = Self(rawValue: 1 << 16)

  /// A terminal launch can receive Threading's private, session-scoped MCP endpoint without
  /// changing persistent runtime configuration. Claude and Codex only. Grok has the bridge on
  /// its native ACP surface, but its TUI exposes persistent MCP configuration only; OpenCode's
  /// dynamic server is not owned by Threading yet.
  static let terminalThreadingBridge = Self(rawValue: 1 << 17)

  /// A first terminal turn can attach a file by launch flag. OpenCode's documented `--file`
  /// route is used for a durable handoff snapshot instead of squeezing a large export into one
  /// command-line prompt.
  static let openingFileAttachments = Self(rawValue: 1 << 18)

  /// The runtime has a one-shot, non-interactive surface Threading can drive for app-level
  /// research — prompt in, captured output out, no terminal and no session record of ours.
  /// Claude (`--print`) and Codex (`exec --json`) only: Grok and OpenCode expose no measured
  /// equivalent. This is what the AI settings search runs on; the older Codex-only research
  /// features (icon lookups, drafted messages) predate the flag and still gate on a Codex
  /// login directly.
  static let headlessResearch = Self(rawValue: 1 << 19)

  /// The runtime's transcript records the permission mode the session is *in*, as opposed to
  /// the one Threading launched it with, so a terminal's posture can be read back after the
  /// user changed it inside the CLI.
  ///
  /// Claude only, and the record is a first-class one rather than something inferred from a
  /// TUI frame: `{"type":"permission-mode","permissionMode":"auto",…}` is written to the
  /// session's own transcript, which is what makes Shift+Tab observable at all. Claude's own
  /// external vocabulary comes back — its `default` for Manual included — so a reader has to
  /// go through `AgentPermissionMode(externalValue:for:)` rather than `init(rawValue:)`.
  ///
  /// Codex, Grok and OpenCode record nothing equivalent, which is deliberate as a capability
  /// rather than a Claude branch: the surfaces that show the mode ask this, so a runtime that
  /// starts writing one becomes readable by claiming the flag and adding its reader.
  static let transcriptPermissionModeRecord = Self(rawValue: 1 << 20)

  /// The runtime's short usage window is *anchored*: it opens on the account's first message
  /// and resets a fixed span later, rather than sliding continuously. That single fact is what
  /// makes the window's phase something a user owns, and it is the whole premise of
  /// `UsageWindowPoke` — on a sliding window there is no moment to move.
  ///
  /// Claude only, and on evidence rather than on documentation: `ClaudeUsageFetcher` reports a
  /// `resetsAt` that stands still through a session and jumps by exactly five hours when a new
  /// window opens, which is an anchor. Codex reports a five-hour window too and shares it
  /// between local messages and cloud chats, but whether its reset is anchored or sliding is
  /// not published, and the two behave identically until the account goes quiet across a
  /// boundary. So the flag stays off there until `UsageWindowAnchorEvidence` answers it from
  /// this account's own history, which is the honest order: the capability is granted by a
  /// measurement, and Threading is the instrument that takes it.
  ///
  /// Grok and OpenCode report no windows to Threading at all, and xAI's acceptable-use policy
  /// forbids scripted access outright, so neither is a candidate whatever it reports later.
  static let anchoredUsageWindow = Self(rawValue: 1 << 21)

  /// The runtime writes a refused request into the session's own transcript, so a conversation
  /// stopped on its account's usage limit can be told apart from one still working.
  ///
  /// Claude only, and the record is the only thing that reports it: a refusal raises no
  /// lifecycle hook — no turn began and none ended — and the CLI answers by printing a sentence
  /// into its TUI, which the host sees as bytes. Without this a spent session goes on drawing a
  /// spinner for as long as it is left alone. See `ObservedUsageLimit`.
  ///
  /// Separate from `anchoredUsageWindow`, which is about an *account's* window having a phase.
  /// This is about one conversation having been told no.
  static let transcriptUsageLimitRecord = Self(rawValue: 1 << 22)

  /// The runtime publishes the current conversation name as provider metadata outside its
  /// transcript. Codex only: terminal sessions persist it in `session_index.jsonl`, while the
  /// app-server returns `Thread.name` and emits `thread/name/updated`.
  static let providerTitleMetadata = Self(rawValue: 1 << 23)

  /// The runtime exposes a reversible archive operation for its retained conversations, and
  /// moves their records between active and archived stores in a way Threading can observe.
  /// Codex only. Claude Code and Grok expose no archive; OpenCode can set an archive timestamp,
  /// but its current public CLI/HTTP contract cannot clear it again. None therefore satisfies
  /// Threading's reversible Archive/Restore contract, so their filing stays local rather than
  /// losing Undo or being misrepresented as the destructive delete they also expose.
  static let providerArchive = Self(rawValue: 1 << 24)

  /// A terminal interruption is written as a structured transcript record that **names the turn
  /// it aborted**, while the lifecycle hook that ordinarily closes a reported turn is omitted.
  /// Codex only: 0.147.0 appends `event_msg / turn_aborted / reason: interrupted` and returns to
  /// its prompt without firing `Stop`. Claude records the same missing boundary without a turn
  /// identity, which is `transcriptInterruptedMessageRecord` and a different reader; Grok and
  /// OpenCode have no measured equivalent at all.
  static let transcriptInterruptedTurnRecord = Self(rawValue: 1 << 25)

  /// A turn the provider refused outright — an expired login, a dropped connection — is written
  /// as a structured API-error record in the session's own transcript, and the runtime returns to
  /// its prompt without firing the lifecycle hook that ends a reported turn. Claude only:
  /// measured on 2.1.226, where an expired login recorded `error: "authentication_failed"` and a
  /// `turn_duration` beside it, and fired no `Stop`. Distinct from
  /// `transcriptUsageLimitRecord`, which is the one refusal that has a park and a recovery of its
  /// own; this is every other way a request can fail, and all it needs is the turn ended. See
  /// `ClaudeTranscriptTurnRefusal`.
  static let transcriptRefusedTurnRecord = Self(rawValue: 1 << 26)

  /// Threading can normalize this runtime's durable conversation transcript into
  /// `[StreamEvent]` and rebuild the native conversation surface from it. Claude and Codex:
  /// both have measured local JSONL formats and concrete `TranscriptReplayFormat` adapters.
  ///
  /// This is deliberately not `transcriptUsageIndex`. OpenCode has a supported export from
  /// which Threading can total usage, but no local conversation format the UI can replay;
  /// Grok rebuilds native history through ACP `session/load`, not through a local transcript.
  /// Narrow facts such as transcript titles, model records and refused-turn records imply
  /// this base capability rather than each quietly inventing its own runtime allow-list.
  static let transcriptReplay = Self(rawValue: 1 << 27)

  /// The runtime's own interactive TUI can host a Threading session, and switching a session
  /// between that terminal and native Chat keeps the same conversation.
  ///
  /// Claude, Codex, Grok and OpenCode: for each, the id Threading stores names one conversation
  /// that both surfaces resume. Cursor does not, and it is the reason this capability exists.
  /// Measured 2026-08-12 (§11 of `docs/archive/research/CURSOR_ACP_FINDINGS.md`): `cursor-agent acp` writes its chats
  /// to `~/.cursor/acp-sessions/<uuid>/`, while the interactive `cursor-agent` writes
  /// `~/.cursor/projects/<slug>/agent-transcripts/<uuid>/`, and **neither store can read the
  /// other's id**. ACP answers `session/load` for a TUI chat with
  /// `-32602 Session "…" not found`; the TUI answers `--resume <acp id>` by opening a blank
  /// chat with no error at all. A Cursor session offered both surfaces would lose its
  /// conversation on the first switch, silently — so it is offered one.
  ///
  /// This governs the *surface*, not the launch: `AgentSession.init` clamps `usesNativeUI` on
  /// for a runtime without it, and `AgentLauncher.plan(for:in:)` refuses to build a terminal
  /// command line for one.
  static let terminalUI = Self(rawValue: 1 << 28)

  /// A terminal interruption is written into the conversation as an ordinary user record naming
  /// the assistant message it cut off, and the lifecycle hook that ends a reported turn is
  /// omitted. Claude only: measured on 2.1.238, where Escape appended
  /// `{"type":"user","interruptedMessageId":"msg_…","message":{"content":[{"type":"text",
  /// "text":"[Request interrupted by user]"}]}}` and fired no `Stop`, leaving the session
  /// `working` for hours.
  ///
  /// Deliberately distinct from `transcriptInterruptedTurnRecord`, which is the same fact carried
  /// by a record that names a *turn*. The difference is not cosmetic: a turn id lets a late read
  /// prove which turn it belongs to, and a record without one has to be matched against the
  /// tracker's own count of turns begun instead. One flag for both would hand each reader a
  /// transcript it cannot parse and an identity it cannot check.
  static let transcriptInterruptedMessageRecord = Self(rawValue: 1 << 29)

  /// Escape, typed into the runtime's own TUI, ends a turn it is running and returns it to the
  /// prompt with the conversation intact.
  ///
  /// This is what a curfew's last resort rests on. At T + grace a turn still in flight is stopped
  /// by typing `TerminalDefaults.interruptSequence` — the only key Threading presses on a
  /// sleeping user's behalf — and a runtime without this flag is given the hold alone: Threading
  /// stops spending the session itself and says so, rather than sending a keystroke whose effect
  /// on that CLI nobody has watched.
  ///
  /// Claude Code and Codex, on the strength of what each writes down when it happens.
  /// `transcriptInterruptedMessageRecord` cites Claude 2.1.238, where Escape appended
  /// `[Request interrupted by user]` and fired no `Stop`; `transcriptInterruptedTurnRecord` cites
  /// Codex 0.147.0 returning to its prompt with `turn_aborted / reason: interrupted`. Those are
  /// readings of the *record*, and this flag also claims the *keystroke* — so it owes the
  /// measurement `curfew.md`'s Verification section names, against the currently installed CLIs
  /// and including the confirmation that a second Escape never reaches an idle prompt. Recorded
  /// here as owed rather than assumed, which is the standard every other row on this matrix was
  /// granted by.
  static let escapeInterruptsTerminalTurn = Self(rawValue: 1 << 30)

  /// The runtime is launched in a supported inline terminal mode whose live
  /// viewport occupies only its populated rows while the terminal owns the
  /// retained transcript above it.
  ///
  /// Codex only: Threading supplies `--no-alt-screen`. Leaving SwiftTerm's
  /// ordinary full-screen scroll end in force makes every unused grid row
  /// beneath Codex's compact composer part of the scrollable tail, so a flick
  /// can settle on a mostly empty page. The terminal host may compact that end
  /// without changing shells or alternate/full-screen clients.
  static let inlineTerminalViewport = Self(rawValue: 1 << 31)

  /// The runtime stores one conversation beneath a checkout-derived project slug, so changing
  /// the checkout that owns a chat also requires copying that conversation record (and any
  /// unstarted fork dependency) to the destination slug before resume.
  ///
  /// Claude only. Codex keeps provider conversation ids in its global rollout store, while ACP
  /// runtimes resume through provider-owned ids rather than a checkout-shaped transcript path.
  static let checkoutScopedConversationStorage = Self(rawValue: 1 << 32)

  /// Lifecycle reports name the exact durable transcript file for the running terminal
  /// conversation, so observers can adopt that path without enumerating the provider's
  /// account-wide history tree. Codex only: its Threading lifecycle payload includes
  /// `rollout_path`; Claude's session-scoped transcript is already resolved from its preset id.
  static let lifecycleReportedTranscriptPath = Self(rawValue: 1 << 33)

  /// Lifecycle reports name the directory the agent is *currently* working in, so the host can
  /// tell where a conversation is executing from where it was launched.
  ///
  /// This is the only sound source for that fact, and the alternative was measured and found
  /// wrong. `TerminalSession.effectiveWorkingDirectory()` reads OSC 7 or the PTY root process's
  /// real cwd, and a runtime that runs `cd x && …` per tool call never moves either: a chat
  /// observed building in a sibling worktree for ten minutes had a root process still sitting
  /// in the checkout it launched from, while its own status line named the worktree. A process
  /// reading therefore cannot see the drift that matters, and a *reported* one can.
  ///
  /// Both hook-capable runtimes, each measured. Claude CLI 2.1.251 builds every hook payload
  /// with `cwd` beside `session_id` and `transcript_path`, and its status-line payload carries
  /// the same fact as `workspace.current_dir` next to an explicit `workspace.git_worktree`.
  /// Codex 0.151.0 was captured through Threading's own installed hook, pointed at a local
  /// listener: `sessionStarted`, `turnStarted` and `turnFinished` each arrived carrying `cwd`,
  /// naming the directory the run was started in.
  ///
  /// Grok, OpenCode and Cursor register no lifecycle hooks at all, so the question does not
  /// arise for them; they are absent here for the same reason they are absent from
  /// `HookLifecycleEvent`'s registrations.
  ///
  /// Reported, not guaranteed: the payload only arrives while the runtime's lifecycle hooks are
  /// installed, so a session running with reporting turned off contributes nothing and the
  /// observer must treat silence as "unknown", never as "has not moved".
  static let lifecycleReportedWorkingDirectory = Self(rawValue: 1 << 34)

  /// A running terminal invocation exposes an exact `resume <conversation-id>` argument pair,
  /// and the runtime refuses a second process that tries to own that identifier concurrently.
  /// Threading can therefore recognise the refusal before launching, without reading another
  /// process's output or guessing from a transcript lock.
  ///
  /// Codex only, measured on 0.151.0. Claude's resume syntax is visible too, but concurrent
  /// ownership has not been measured as an explicit refusal there; Grok and OpenCode have
  /// likewise not earned both halves of the claim. A visible argv without measured exclusivity
  /// is not enough to block a launch.
  static let detectableExternalResume = Self(rawValue: 1 << 35)
}

/// The kind of program a session hosts: an installed agent client/runtime, not the model
/// provider it talks to. A session is a *conversation*, so this names an agent and nothing else.
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
  case grok
  case openCode = "opencode"
  case cursor

  /// Human-readable name shown in menus and the sidebar.
  var displayName: String {
    switch self {
    case .claude: return "Claude Code"
    case .codex: return "Codex"
    case .grok: return "Grok"
    case .openCode: return "OpenCode"
    case .cursor: return "Cursor"
    }
  }

  /// The truthful sign-in boundary shown by the fixed supported-agent roster.
  ///
  /// Keeping the exhaustive switch beside the capability catalogue means a sixth runtime cannot
  /// silently disappear from onboarding or inherit another runtime's account promise. The setup
  /// action remains a separate, narrower adapter (`AgentAccountSetupProvider`).
  var accountAccessDetail: String {
    switch self {
    case .claude:
      return L10n.string("Use another Claude subscription or organization.")
    case .codex:
      return L10n.string("Use another ChatGPT account with Codex.")
    case .grok:
      return L10n.string("Sign in inside Grok's terminal UI. Threading uses one Grok login.")
    case .openCode:
      return L10n.string("Connect model providers inside OpenCode with /connect.")
    case .cursor:
      return L10n.string("Run agent login once on this Mac. Threading uses that Cursor login.")
    }
  }

  /// Short trailing answer to who owns this runtime's sign-in flow.
  var accountAccessOwner: String {
    switch self {
    case .claude, .codex: return L10n.string("Threading")
    case .grok: return L10n.string("In Grok")
    case .openCode: return L10n.string("In OpenCode")
    case .cursor: return L10n.string("Mac login")
    }
  }

  /// The agent's own interactive TUI, hosted inside Threading's terminal surface.
  var originalUITitle: String { L10n.format("%@ UI", displayName) }

  /// The executable invoked on the user's PATH.
  var executableName: String {
    switch self {
    case .claude: return AgentDefaults.claudeExecutable
    case .codex: return AgentDefaults.codexExecutable
    case .grok: return AgentDefaults.grokExecutable
    case .openCode: return AgentDefaults.openCodeExecutable
    case .cursor: return AgentDefaults.cursorExecutable
    }
  }

  /// The single capability declaration consumed by the composer, the launcher, the session
  /// actions and the conversation surface.
  ///
  /// This switch is the only place a runtime is named to decide what the host may do with it.
  /// Everywhere else asks `supports(_:)`, which is enforced by
  /// `scripts/check_architecture_boundaries.sh`: a feature that branches on the runtime's own
  /// identity is a feature nobody can extend to a sixth runtime without re-reading the whole
  /// app.
  var capabilities: AgentCapabilities {
    switch self {
    case .claude:
      return [
        .resume, .presetSessionID, .accounts, .nativeUI, .terminalUI, .permissionModes, .forking,
        .threadingBridge, .remoteControl, .statusLine, .transcriptTitles,
        .transcriptModelRecord, .transcriptPermissionModeRecord, .transcriptUsageIndex,
        .liveFastModeControl, .slashCommandPrefix, .terminalThreadingBridge, .headlessResearch,
        .anchoredUsageWindow, .transcriptUsageLimitRecord, .transcriptRefusedTurnRecord,
        .transcriptInterruptedMessageRecord, .transcriptReplay, .escapeInterruptsTerminalTurn,
        .checkoutScopedConversationStorage, .lifecycleReportedWorkingDirectory
      ]
    case .codex:
      return [
        .resume, .accounts, .nativeUI, .terminalUI, .permissionModes, .threadingBridge,
        .serviceTierFastMode, .sharedSubagentIdentity, .terminalThreadingBridge,
        .headlessResearch, .providerTitleMetadata, .providerArchive, .transcriptUsageIndex,
        .transcriptInterruptedTurnRecord, .transcriptReplay, .escapeInterruptsTerminalTurn,
        .inlineTerminalViewport, .lifecycleReportedTranscriptPath,
        .lifecycleReportedWorkingDirectory, .detectableExternalResume
      ]
    case .grok:
      return [
        .resume, .presetSessionID, .nativeUI, .terminalUI, .permissionModes, .threadingBridge,
        .deferredSessionIdentifier
      ]
    case .openCode:
      return [
        .resume, .terminalUI, .deferredSessionIdentifier, .openingFileAttachments,
        .transcriptUsageIndex
      ]

    // Every row below cites the measurement that grants it in the archived Cursor ACP findings. The
    // absences are as deliberate as the claims and are listed after them.
    case .cursor:
      return [
        // §10.4: a session created in one process was loaded in another after the first died,
        // and `session/load` replayed the whole conversation as ordinary `session/update`
        // notifications before answering. The id survives on disk in
        // `~/.cursor/acp-sessions/<uuid>/`.
        .resume,
        // §10.1/§10.3: `session/new` answers with a session, `session/prompt` streams a turn
        // and settles on `stopReason`, and §10.7 a mid-turn `session/cancel` settles it as
        // `cancelled` in 4 ms. That is the whole contract `ACPStreamSession` needs.
        .nativeUI,
        // §10.9: a `mcpServers` entry passed to `session/new` was connected during session
        // creation — MCP `2025-11-25`, `tools/list` then `tools/call` — without touching the
        // user's own `~/.cursor/mcp.json`.
        .threadingBridge
      ]
      // Not `.terminalUI` (§11): the TUI and ACP keep disjoint conversation stores and neither
      //   can read the other's id, so the surface switch would silently lose the chat.
      // Not `.presetSessionID` (§6.1, §10.1): Cursor mints the id itself inside `session/new`;
      //   Threading persists what the `initialised` event reports, as it does for Codex.
      // Not `.deferredSessionIdentifier`: that is the *terminal* discovery poll, and Cursor has
      //   no terminal surface here. The id arrives on the wire, at once.
      // Not `.permissionModes` (§10.2): Cursor's `agent`/`plan`/`ask` are execution modes, a
      //   different axis from Threading's six Claude-derived permission modes, and the `acp`
      //   subcommand takes no mode flag. Claiming them would draw a chip that changes nothing.
      // Not `.forking` (§4): `session/fork` answers `-32601 Method not found`.
      // Not `.accounts`: measured 2026-08-12 — neither `CURSOR_DATA_DIR` nor `XDG_CONFIG_HOME`
      //   moves the login (`status` still reports authenticated with either pointed at an empty
      //   directory), because the token is in the system keychain rather than in a config
      //   directory. There is nothing for `env` routing to point at.
      // Not any transcript capability (§10.10, §10.4): there is no local conversation format to
      //   replay — history comes back over `session/load` — and no usage, token or
      //   context-window notification exists on this protocol at all.
    }
  }

  /// Whether this runtime has one capability. The accessor for everything the seven named
  /// `supportsX` properties below do not already cover.
  func supports(_ capability: AgentCapabilities) -> Bool {
    capabilities.contains(capability)
  }

  /// Whether sessions of this kind can be resumed by identifier after exiting.
  ///
  /// Every kind can, now that shells are not a kind. Kept as a property rather than deleted
  /// with its call sites, because a future agent without a resume story would need it back
  /// and the branches reading it are the honest place to notice.
  var supportsResume: Bool { capabilities.contains(.resume) }

  /// Whether the session identifier can be chosen by us before launch.
  ///
  /// Claude and Grok accept `--session-id <uuid>`, so we mint it. Codex and OpenCode
  /// assign their own, which must be discovered afterwards.
  var supportsPresetSessionID: Bool { capabilities.contains(.presetSessionID) }

  /// Whether this agent supports Threading's config-directory account routing.
  ///
  /// OpenCode stores provider credentials in one shared data directory and selects providers
  /// inside the TUI. Grok supports `GROK_HOME`, but Threading has not yet defined or measured
  /// multiple-login discovery for it. Neither runtime is presented as account-routable yet.
  var supportsAccounts: Bool { capabilities.contains(.accounts) }

  /// Whether Threading may render this agent's conversation itself, instead of a terminal.
  ///
  /// Claude, Codex, and Grok qualify: each exposes a supported headless transport — Codex
  /// app-server, `claude -p --output-format stream-json`, and `grok agent stdio` over ACP —
  /// that Threading drives by spawning the user's own installed CLI, authenticated by that
  /// CLI's existing login state. No token is read, and no request is routed on the user's
  /// behalf, which is the line Anthropic's policy actually draws.
  ///
  /// Claude was excluded here for most of this project's life on the belief that `claude -p`
  /// on a subscription was off-limits to third-party apps. That was true of the February 2026
  /// terms as they read at the time, and is no longer: Anthropic's help centre now lists
  /// `claude -p` and "third-party apps that authenticate with your Claude subscription" as
  /// subscription-drawing usage, and the June 2026 attempt to move them onto separate metered
  /// credits was withdrawn on the day it was to take effect. That withdrawal was explicitly
  /// a pause, so this may become an economic choice — headless turns billed at API rates
  /// rather than against the plan — but it is a *permitted* one either way.
  var supportsNativeUI: Bool { capabilities.contains(.nativeUI) }

  /// Whether Threading can translate its shared permission-mode vocabulary into launch flags.
  ///
  /// OpenCode owns a richer per-tool policy in `opencode.json`. Its `--auto` switch is not
  /// equivalent to any one of Threading's six Claude-derived modes, so terminal sessions leave
  /// that policy to OpenCode instead of presenting a false mapping. Grok's documented
  /// `--permission-mode` values match all six modes exactly.
  var supportsPermissionModes: Bool { capabilities.contains(.permissionModes) }

  /// Whether Threading can inject its per-session lifecycle/MCP bridge without replacing the
  /// runtime's own configuration.
  var supportsThreadingBridge: Bool { capabilities.contains(.threadingBridge) }

  /// Whether a conversation of this agent can be forked into a side chat.
  ///
  /// Claude only, and measured rather than assumed: `--fork-session` resumes a
  /// conversation into a *new* transcript, leaving the original untouched, and honours a
  /// `--session-id` given alongside it — so the child's identifier is minted up front like
  /// any other Claude session. Codex has no equivalent (`codex exec resume` takes an id and
  /// a prompt, nothing more), and forging one by copying its rollout is unproven. Grok and
  /// OpenCode both expose fork flags, but Threading has not yet measured their complete
  /// side-chat lifecycle, so neither is advertised here yet.
  var supportsForking: Bool { capabilities.contains(.forking) }

  /// Environment variable redirecting this CLI to an alternate config directory, where it has
  /// one.
  ///
  /// Optional because a login does not have to live in a directory. Cursor's does not: measured
  /// 2026-08-12, pointing either `CURSOR_DATA_DIR` or `XDG_CONFIG_HOME` at an empty directory
  /// still reports `status: authenticated`, because the token is held in the system keychain and
  /// only `cli-config.json` follows the directory. There is therefore no name here that a launch
  /// could set to reach a different Cursor login, and inventing one would put an inert lie in the
  /// one place `AgentEnvironment` reads to decide what *not* to strip.
  var accountEnvironmentKey: String? {
    switch self {
    case .claude: return "CLAUDE_CONFIG_DIR"
    case .codex: return "CODEX_HOME"
    case .grok: return "GROK_HOME"
    case .openCode: return "OPENCODE_CONFIG_DIR"
    case .cursor: return nil
    }
  }
}
