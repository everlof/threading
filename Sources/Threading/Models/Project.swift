import Foundation
import ThreadingExtensionKit

// MARK: - Projects State Version

enum ProjectsStateVersion {
  /// 2 dropped `AgentKind.shell`. A version-1 document may hold shell sessions, which no
  /// longer decode — `StateManager` strips them on the way through.
  static let current = 2
}

// MARK: - Agent Runtime

/// Features the host can rely on for one agent runtime.
///
/// Model providers are intentionally absent: OpenRouter, Anthropic, OpenAI, and xAI are model
/// backends selected by a runtime. Keeping this matrix about CLI behavior means a Grok model
/// selected through OpenCode is still an OpenCode session, while the standalone `grok` program
/// is its own runtime with its own sessions and launch contract.
/// Each member documents which runtimes have it and why, because this declaration is where
/// someone adding a fifth runtime reads the contract. The first seven also have a named
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

  /// Fast is a *live control-channel flag* that a running conversation starts with off until
  /// Threading sends it. Claude only, and deliberately distinct from `serviceTierFastMode`:
  /// the two differ in where the answer lives, in whether it survives a relaunch, and in
  /// whether "no explicit choice" means off or means the account's default.
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
  /// commands and `GrokACPStreamSession.send(_ invocation:)` forwards a literal `/compact …`
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
  /// Claude only, and the restriction belongs to the *reader* rather than to the runtime:
  /// `TranscriptUsageIndex.transcripts(inAccountAt:)` enumerates
  /// `AgentDefaults.claudeProjectsSubdirectory` and knows no other layout. Codex records its
  /// usage in a rollout of a different shape, and neither Grok nor OpenCode has a transcript
  /// this app parses at all. Stated here rather than as a filter over `AgentKind.allCases` at
  /// the call site, which put the restriction a file away from the thing that causes it and
  /// read like a policy rather than a limitation.
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

  /// The runtime publishes the current conversation name as provider metadata outside its
  /// transcript. Codex only: terminal sessions persist it in `session_index.jsonl`, while the
  /// app-server returns `Thread.name` and emits `thread/name/updated`.
  static let providerTitleMetadata = Self(rawValue: 1 << 20)
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

  /// Human-readable name shown in menus and the sidebar.
  var displayName: String {
    switch self {
    case .claude: return "Claude Code"
    case .codex: return "Codex"
    case .grok: return "Grok"
    case .openCode: return "OpenCode"
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
    }
  }

  /// The single capability declaration consumed by the composer, the launcher, the session
  /// actions and the conversation surface.
  ///
  /// This switch is the only place a runtime is named to decide what the host may do with it.
  /// Everywhere else asks `supports(_:)`, which is enforced by
  /// `scripts/check_architecture_boundaries.sh`: a feature that branches on the runtime's own
  /// identity is a feature nobody can extend to a fifth runtime without re-reading the whole
  /// app.
  var capabilities: AgentCapabilities {
    switch self {
    case .claude:
      return [
        .resume, .presetSessionID, .accounts, .nativeUI, .permissionModes, .forking,
        .threadingBridge, .remoteControl, .statusLine, .transcriptTitles,
        .transcriptModelRecord, .transcriptUsageIndex, .liveFastModeControl,
        .slashCommandPrefix, .terminalThreadingBridge, .headlessResearch
      ]
    case .codex:
      return [
        .resume, .accounts, .nativeUI, .permissionModes, .threadingBridge,
        .serviceTierFastMode, .sharedSubagentIdentity, .terminalThreadingBridge,
        .headlessResearch, .providerTitleMetadata
      ]
    case .grok:
      return [
        .resume, .presetSessionID, .nativeUI, .permissionModes, .threadingBridge,
        .deferredSessionIdentifier
      ]
    case .openCode:
      return [.resume, .deferredSessionIdentifier, .openingFileAttachments]
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

  /// Environment variable redirecting this CLI to an alternate config directory.
  var accountEnvironmentKey: String {
    switch self {
    case .claude: return "CLAUDE_CONFIG_DIR"
    case .codex: return "CODEX_HOME"
    case .grok: return "GROK_HOME"
    case .openCode: return "OPENCODE_CONFIG_DIR"
    }
  }
}

// MARK: - Resume State

/// Whether a session can identify a conversation to resume.
enum ResumeState: Equatable {
  /// This kind of session has no resumable conversation, as with a shell.
  case unavailable

  /// An agent conversation does not yet have a confirmed, resumable provider identifier.
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
/// operation with those semantics. Cross-provider continuation is provider-neutral lineage,
/// stored on `AgentSession` rather than smuggled into one runtime's launch configuration.
enum ClaudeSessionOrigin: Equatable {
  case original
  case forked(from: SessionID)
}

/// Provider-specific session state.
///
/// This replaces five independent optionals (`kind`, reasoning effort, Remote Control, fork
/// parent, and continuation kind) whose Cartesian product admitted states neither provider
/// could execute. Pattern matching now has to account only for states the product supports.
enum AgentSessionConfiguration: Equatable {
  case claude(
    remoteControl: Bool?,
    reasoningEffort: String?,
    origin: ClaudeSessionOrigin
  )
  case codex(reasoningEffort: String?)
  case grok
  case openCode

  var kind: AgentKind {
    switch self {
    case .claude: return .claude
    case .codex: return .codex
    case .grok: return .grok
    case .openCode: return .openCode
    }
  }

  /// The configuration a plain new session of this runtime starts from: no lineage, no
  /// reasoning override, nothing yet chosen. Total, because every runtime can host an ordinary
  /// new conversation — and the one switch the two initializers below share, so a fifth
  /// runtime is added here once rather than in each of them.
  static func original(for kind: AgentKind) -> AgentSessionConfiguration {
    switch kind {
    case .claude:
      return .claude(remoteControl: nil, reasoningEffort: nil, origin: .original)
    case .codex: return .codex(reasoningEffort: nil)
    case .grok: return .grok
    case .openCode: return .openCode
    }
  }

  /// The configuration for a newly requested session, or nil when the request describes a
  /// session the runtime cannot run.
  ///
  /// This lived in `ProjectStore.addSession` as a switch over the runtime, which put the rules
  /// about what a configuration may hold a file away from the cases that hold it. Two things
  /// follow from moving it here.
  ///
  /// A rejection now means one of exactly two things: the enum has no case that can represent
  /// the request, or the runtime lacks the capability the request needs. Nothing here is a
  /// rule about a runtime by name.
  ///
  /// And a setting the runtime merely *ignores* is clamped rather than refused — `AgentSession`
  /// already drops `usesNativeUI` for a runtime without that capability. Refusing the whole
  /// session for a setting the model would have corrected is how choosing Grok's conversation
  /// surface came to create nothing at all: the composer offered it, the capability allowed it,
  /// `ConversationViewController` had a transport for it, and the store returned nil.
  init?(
    kind: AgentKind,
    reasoningEffort: String?,
    accountHandle: AccountHandle,
    permissionMode: AgentPermissionMode?
  ) {
    guard accountHandle == .standard || kind.supportsAccounts,
          permissionMode == nil || kind.supportsPermissionModes
    else { return nil }

    switch kind {
    case .claude:
      self = .claude(
        remoteControl: nil,
        reasoningEffort: reasoningEffort,
        origin: .original
      )

    case .codex:
      self = .codex(reasoningEffort: reasoningEffort)

    case .grok, .openCode:
      guard reasoningEffort == nil else { return nil }
      self = .original(for: kind)
    }
  }

  fileprivate var derivedSessionID: SessionID? {
    switch self {
    case .claude(_, _, .forked(let source)):
      return source
    case .claude, .codex, .grok, .openCode:
      return nil
    }
  }
}

// MARK: - Conversation Handoff Provenance

/// One durable stop in a cross-runtime continuation path.
///
/// The model is captured at the moment of the handoff rather than resolved while drawing. A
/// session's explicit model, account default, and runtime-reported model can all change later;
/// provenance must continue to say what the handoff actually meant when it was made.
struct ConversationHandoffEndpoint: Codable, Equatable {
  let sessionID: SessionID
  let kind: AgentKind
  var model: String?
  var title: String?
  private var modelIsProvisional: Bool?

  init(
    sessionID: SessionID,
    kind: AgentKind,
    model: String?,
    title: String?,
    modelIsProvisional: Bool = false
  ) {
    self.sessionID = sessionID
    self.kind = kind
    self.model = model
    self.title = title
    self.modelIsProvisional = modelIsProvisional
  }

  var displayName: String {
    guard let model, !model.isEmpty else { return kind.displayName }
    return ModelName.display(for: model)
  }

  mutating func recordReportedModel(_ reportedModel: String) {
    guard !reportedModel.isEmpty,
          model == nil || modelIsProvisional == true else { return }
    model = reportedModel
    modelIsProvisional = false
  }
}

/// The full provider/model path that led to one destination conversation.
///
/// Every destination owns its copy. Deleting or renaming an ancestor therefore cannot rewrite
/// history, while the session ids still make surviving ancestors navigable. The path is bounded
/// because it rides every session row; the origin and newest hops are retained and the omitted
/// count says when the middle was compacted.
struct ConversationHandoff: Codable, Equatable {
  static let maximumEndpoints = 16

  private(set) var endpoints: [ConversationHandoffEndpoint]
  private(set) var omittedEndpointCount: Int
  let createdAt: Date

  var source: ConversationHandoffEndpoint? {
    endpoints.dropLast().last
  }

  var target: ConversationHandoffEndpoint? { endpoints.last }

  init?(
    endpoints: [ConversationHandoffEndpoint],
    omittedEndpointCount: Int = 0,
    createdAt: Date = Date()
  ) {
    guard endpoints.count >= 2,
          omittedEndpointCount >= 0,
          Self.hasValidRetainedPath(
            endpoints,
            omittedEndpointCount: omittedEndpointCount
          )
    else { return nil }

    self.endpoints = endpoints
    self.omittedEndpointCount = omittedEndpointCount
    self.createdAt = createdAt
    compactIfNeeded()
  }

  /// Carries an existing path into a new destination, refreshing the source's own endpoint with
  /// its current title/model snapshot first. This is what turns direct lineage into a real path
  /// across repeated handoffs.
  @MainActor
  static func continuing(
    source: AgentSession,
    targetID: SessionID,
    targetKind: AgentKind,
    targetModel: String?,
    targetTitle: String
  ) -> ConversationHandoff? {
    guard source.kind != targetKind, source.id != targetID else { return nil }

    var endpoints = source.handoff?.endpoints ?? []
    let sourceEndpoint = ConversationHandoffEndpoint(
      sessionID: source.id,
      kind: source.kind,
      model: source.handoffModelSnapshot,
      title: source.displayTitle
    )
    if endpoints.isEmpty {
      endpoints.append(sourceEndpoint)
    } else {
      endpoints[endpoints.count - 1] = sourceEndpoint
    }
    endpoints.append(ConversationHandoffEndpoint(
      sessionID: targetID,
      kind: targetKind,
      model: targetModel,
      title: targetTitle,
      modelIsProvisional: true
    ))

    return ConversationHandoff(
      endpoints: endpoints,
      omittedEndpointCount: source.handoff?.omittedEndpointCount ?? 0
    )
  }

  mutating func recordTargetModel(_ model: String) {
    guard !model.isEmpty, !endpoints.isEmpty else { return }
    endpoints[endpoints.count - 1].recordReportedModel(model)
  }

  func isValid(destinationID: SessionID, destinationKind: AgentKind) -> Bool {
    guard endpoints.count >= 2,
          endpoints.count <= Self.maximumEndpoints,
          omittedEndpointCount >= 0,
          Self.hasValidRetainedPath(
            endpoints,
            omittedEndpointCount: omittedEndpointCount
          ),
          let source,
          let target,
          source.sessionID != target.sessionID,
          source.kind != target.kind,
          target.sessionID == destinationID,
          target.kind == destinationKind
    else { return false }
    return true
  }

  private static func hasValidRetainedPath(
    _ endpoints: [ConversationHandoffEndpoint],
    omittedEndpointCount: Int
  ) -> Bool {
    guard Set(endpoints.map(\.sessionID)).count == endpoints.count else { return false }
    for (index, pair) in zip(endpoints, endpoints.dropFirst()).enumerated() {
      // Once a middle has been compacted, the origin and first retained suffix endpoint were
      // not necessarily adjacent in the real path. Every other pair still was.
      if omittedEndpointCount > 0, index == 0 { continue }
      guard pair.0.kind != pair.1.kind else { return false }
    }
    return true
  }

  private mutating func compactIfNeeded() {
    guard endpoints.count > Self.maximumEndpoints else { return }
    let removalCount = endpoints.count - Self.maximumEndpoints
    // Preserve the originating endpoint and the newest suffix. The path remains a path, while
    // `omittedEndpointCount` states the collapsed middle instead of silently pretending it never
    // existed.
    endpoints.removeSubrange(1 ... removalCount)
    omittedEndpointCount += removalCount
  }
}

// MARK: - Agent Title Source

/// How a session's `agentTitle` was obtained, which decides what may replace it — the same
/// shape as `ProjectIconSource`: a deliberate act is never displaced by an automatic one.
enum AgentTitleSource: String, Codable {
  /// Reported by a transport on its own — the terminal title while a PTY is attached, or
  /// the transcript's title records read when a turn ends. Follows whatever comes next.
  case reported
  /// Read from the provider's authoritative conversation metadata. It outranks a transient
  /// terminal caption but remains below a name deliberately chosen through Threading.
  case provider
  /// Asked for — `set_session_name`, which the user requested via Rename with Agent or the
  /// agent judged worth calling. Only another chosen name or the user's own rename outranks
  /// it; the transports re-reporting the CLI's old idea of a title do not.
  case chosen

  var authority: Int {
    switch self {
    case .reported: return 0
    case .provider: return 1
    case .chosen: return 2
    }
  }

  func canReplace(_ existing: AgentTitleSource?) -> Bool {
    authority >= (existing?.authority ?? -1)
  }
}

// MARK: - Agent Session

/// A single agent conversation belonging to a project.
///
/// The session outlives its terminal: when the agent exits, the PTY is torn down but
/// this record remains so the conversation can be resumed through `resumeState` later.
struct AgentSession: Codable, Identifiable {
  let id: SessionID
  private var configuration: AgentSessionConfiguration

  /// Durable, provider-neutral lineage for a cross-runtime continuation. Kept apart from the
  /// runtime configuration because all runtimes can receive a handoff even though their launch
  /// settings have different shapes.
  private(set) var handoff: ConversationHandoff?

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

  /// The agent's own name for the conversation, by whichever source last authoritatively
  /// reported it: terminal presentation, transcript records, or canonical provider metadata.
  /// This is what names a native session and what survives a surface switch. Retained after the
  /// agent exits so a dormant session still shows what it was.
  ///
  /// Stored under the `terminalTitle` key it had when the terminal was the only transport,
  /// so existing records decode unchanged.
  var agentTitle: String?

  /// How the current `agentTitle` arrived, which decides what may replace it: transient report,
  /// canonical provider metadata, or an explicitly chosen name, in increasing authority. Nil —
  /// every record from before the distinction — reads as reported.
  var agentTitleSource: AgentTitleSource?

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

  /// A per-conversation reasoning-effort override.
  ///
  /// Nil inherits the routed account when that value is supported by the selected model,
  /// otherwise the model catalog's own default. The value stays a string because the catalog
  /// is authoritative and may add levels without a Threading release.
  var reasoningEffort: String? {
    switch configuration {
    case .claude(_, let value, _), .codex(let value): return value
    case .grok, .openCode: return nil
    }
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
    guard case .claude(let value, _, _) = configuration else { return nil }
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
    guard case .claude(_, _, .forked(let parent)) = configuration else { return nil }
    return parent
  }

  /// Whether this session began as a fork of another.
  var isSideChat: Bool { forkedFrom != nil }

  /// The configuration a side chat of *this* conversation runs under, or nil where this
  /// runtime has no fork operation.
  ///
  /// The store used to build a `.claude` configuration itself after testing the parent's
  /// runtime, which meant granting `.forking` to a second runtime would have quietly minted
  /// Claude sessions from its parents. Deriving the child from the parent's own case makes
  /// that impossible to express: a runtime is forkable here only once someone writes down
  /// what its fork *is*. `AgentCapabilitiesTests` holds the two answers to each other.
  var forkedConfiguration: AgentSessionConfiguration? {
    switch configuration {
    case .claude(_, let reasoningEffort, _):
      return .claude(
        remoteControl: nil,
        reasoningEffort: reasoningEffort,
        origin: .forked(from: id)
      )
    case .codex, .grok, .openCode:
      return nil
    }
  }

  /// The session whose visible conversation seeded this one on another provider.
  ///
  /// Unlike `forkedFrom`, this is never handed to either CLI as a resume identifier. Threading
  /// snapshots the source transcript, normalises it through `TranscriptReplay`, and exposes
  /// only that snapshot to this session through the scoped `conversation_history` MCP tool.
  /// The destination then starts a genuinely new provider-native conversation.
  var continuedFrom: SessionID? {
    handoff?.source?.sessionID
  }

  /// The format of the frozen handoff transcript.
  ///
  /// Kept beside the lineage rather than recovered from the source record so the handoff
  /// remains readable if that original row is later deleted from Threading.
  var continuationSourceKind: AgentKind? {
    handoff?.source?.kind
  }

  /// Whether this session began as a cross-provider continuation.
  var isCrossProviderContinuation: Bool {
    handoff != nil
  }

  /// Best durable model label available before a handoff is made. A model the session pinned
  /// wins, then the account's configured default, then the runtime's last report for that
  /// account. Nil is preserved as an honest provider-name fallback for Grok/OpenCode and an
  /// account whose CLI states no default.
  @MainActor
  var handoffModelSnapshot: String? {
    if let model, !model.isEmpty { return model }
    let account = AgentAccountDiscovery.account(for: kind, handle: accountHandle)
    return AgentModels.defaultModel(for: kind, account: account)
      ?? account.flatMap { AccountPreferencesStore.shared.lastReportedModel(for: $0.id) }
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
    self.init(
      configuration: .original(for: kind),
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
    handoff: ConversationHandoff? = nil,
    id: SessionID = SessionID()
  ) {
    precondition(
      configuration.derivedSessionID != id,
      "A session cannot derive from itself"
    )
    self.id = id
    self.configuration = configuration
    precondition(
      handoff == nil || handoff?.target?.sessionID == id,
      "A handoff must end at its destination session"
    )
    precondition(
      handoff == nil || handoff?.target?.kind == configuration.kind,
      "A handoff must end at its destination runtime"
    )
    self.handoff = handoff
    self.title = title
    self.customTitle = nil
    self.agentTitle = nil
    self.agentTitleSource = nil
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
    self.usesNativeUI = usesNativeUI && configuration.kind.supportsNativeUI
    self.themeID = nil
    self.notificationsMuted = nil
  }

  private enum CodingKeys: String, CodingKey {
    case id, kind, title, customTitle, createdAt, lastActiveAt
    case agentTitle = "terminalTitle"
    case agentTitleSource
    case agentSessionID, hasLaunched, lastExitCode, accountHandle, model, reasoningEffort, branch
    case fastMode, remoteControl, permissionMode, archived, pinned, nativeUI, forkParent
    case continuationSource, continuationSourceKind
    case handoff
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
    agentTitleSource = try container.decodeIfPresent(
      AgentTitleSource.self,
      forKey: .agentTitleSource
    )
    createdAt = decodedCreatedAt ?? Date()
    lastActiveAt =
      try container.decodeIfPresent(Date.self, forKey: .lastActiveAt)
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
    let decodedHandoff = try container.decodeIfPresent(
      ConversationHandoff.self,
      forKey: .handoff
    )
    if decodedReasoningEffort != nil,
       decodedKind != .claude,
       decodedKind != .codex {
      throw DecodingError.dataCorruptedError(
        forKey: .reasoningEffort,
        in: container,
        debugDescription: "Reasoning effort is not valid for this runtime"
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

    let legacyHandoff: ConversationHandoff?
    if let decodedContinuationSource, let decodedContinuationKind {
      legacyHandoff = ConversationHandoff(
        endpoints: [
          ConversationHandoffEndpoint(
            sessionID: decodedContinuationSource,
            kind: decodedContinuationKind,
            model: nil,
            title: nil
          ),
          ConversationHandoffEndpoint(
            sessionID: id,
            kind: decodedKind,
            model: model,
            title: title
          )
        ],
        createdAt: decodedCreatedAt ?? Date()
      )
      guard legacyHandoff != nil else {
        throw DecodingError.dataCorruptedError(
          forKey: .continuationSourceKind,
          in: container,
          debugDescription: "A continuation must cross runtimes"
        )
      }
    } else {
      legacyHandoff = nil
    }

    if let decodedHandoff, let legacyHandoff,
       (decodedHandoff.source?.sessionID != legacyHandoff.source?.sessionID
        || decodedHandoff.source?.kind != legacyHandoff.source?.kind) {
      throw DecodingError.dataCorruptedError(
        forKey: .handoff,
        in: container,
        debugDescription: "Handoff path disagrees with its legacy direct source"
      )
    }
    handoff = decodedHandoff ?? legacyHandoff
    if let handoff {
      guard decodedForkParent == nil,
            handoff.isValid(destinationID: id, destinationKind: decodedKind) else {
        throw DecodingError.dataCorruptedError(
          forKey: .handoff,
          in: container,
          debugDescription: "Invalid handoff path for this destination session"
        )
      }
    }
    switch decodedKind {
    case .claude:
      let origin: ClaudeSessionOrigin
      if let decodedForkParent {
        origin = .forked(from: decodedForkParent)
      } else {
        origin = .original
      }
      configuration = .claude(
        remoteControl: decodedRemoteControl,
        reasoningEffort: decodedReasoningEffort,
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
      configuration = .codex(reasoningEffort: decodedReasoningEffort)
    case .grok:
      guard decodedForkParent == nil else {
        throw DecodingError.dataCorruptedError(
          forKey: .forkParent,
          in: container,
          debugDescription: "Grok sessions cannot yet be provider forks"
        )
      }
      guard accountHandle == .standard else {
        throw DecodingError.dataCorruptedError(
          forKey: .accountHandle,
          in: container,
          debugDescription: "Grok sessions do not yet use Threading account routing"
        )
      }
      guard decodedReasoningEffort == nil else {
        throw DecodingError.dataCorruptedError(
          forKey: .reasoningEffort,
          in: container,
          debugDescription: "Grok sessions have no reasoning-effort contract to launch with"
        )
      }
      guard fastMode == nil else {
        throw DecodingError.dataCorruptedError(
          forKey: .fastMode,
          in: container,
          debugDescription: "Grok sessions do not use Threading's Fast-mode control"
        )
      }
      configuration = .grok
    case .openCode:
      guard decodedForkParent == nil else {
        throw DecodingError.dataCorruptedError(
          forKey: .forkParent,
          in: container,
          debugDescription: "OpenCode sessions cannot yet be provider forks"
        )
      }
      guard !usesNativeUI else {
        throw DecodingError.dataCorruptedError(
          forKey: .nativeUI,
          in: container,
          debugDescription: "OpenCode sessions currently support the terminal interface only"
        )
      }
      guard accountHandle == .standard else {
        throw DecodingError.dataCorruptedError(
          forKey: .accountHandle,
          in: container,
          debugDescription: "OpenCode sessions do not use Threading account routing"
        )
      }
      guard decodedReasoningEffort == nil else {
        throw DecodingError.dataCorruptedError(
          forKey: .reasoningEffort,
          in: container,
          debugDescription: "OpenCode sessions select reasoning levels inside OpenCode"
        )
      }
      guard fastMode == nil else {
        throw DecodingError.dataCorruptedError(
          forKey: .fastMode,
          in: container,
          debugDescription: "OpenCode sessions select model variants inside OpenCode"
        )
      }
      guard permissionMode == nil else {
        throw DecodingError.dataCorruptedError(
          forKey: .permissionMode,
          in: container,
          debugDescription: "OpenCode sessions use OpenCode's own permission configuration"
        )
      }
      configuration = .openCode
    }
    themeID = try container.decodeIfPresent(TerminalThemeID.self, forKey: .themeID)
    if themeID == nil,
      let legacyName = try container.decodeIfPresent(String.self, forKey: .themeName)
    {
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
    try container.encodeIfPresent(agentTitleSource, forKey: .agentTitleSource)
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
    try container.encodeIfPresent(handoff, forKey: .handoff)
    try container.encodeIfPresent(themeID, forKey: .themeID)
    try container.encodeIfPresent(notificationsMuted, forKey: .notificationsMuted)
  }

  /// Changes a reasoning option only where the provider configuration can carry one.
  @discardableResult
  mutating func setReasoningEffort(_ effort: String?) -> Bool {
    switch configuration {
    case .claude(let remoteControl, _, let origin):
      configuration = .claude(
        remoteControl: remoteControl,
        reasoningEffort: effort,
        origin: origin
      )
      return true
    case .codex:
      configuration = .codex(reasoningEffort: effort)
      return true
    case .grok, .openCode:
      return false
    }
  }

  /// Changes a Claude-only option without admitting it into Codex's state space.
  @discardableResult
  mutating func setClaudeRemoteControl(_ remoteControl: Bool?) -> Bool {
    guard case .claude(_, let reasoningEffort, let origin) = configuration else { return false }
    configuration = .claude(
      remoteControl: remoteControl,
      reasoningEffort: reasoningEffort,
      origin: origin
    )
    return true
  }

  /// Replaces the destination endpoint's provisional/default model with the runtime's own
  /// report. The report is stamped into provenance once it is known, so later account-default
  /// changes do not rewrite the path.
  mutating func recordHandoffTargetModel(_ model: String) {
    handoff?.recordTargetModel(model)
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
      let agentTitle, !agentTitle.isEmpty
    {
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
    resumeState.transcriptID?.rawValue ?? threadingIdentifier
  }

  /// Threading's own identifier for this chat, in the lowercased spelling every app-side
  /// surface uses: the settings file, the MCP route, the history file, the extension command
  /// context and the diagnostics journal are all keyed by it.
  ///
  /// Exposed beside the agent's identifier rather than instead of it — the two name the same
  /// conversation to two different systems. For Claude and Grok they are the same string
  /// because Threading mints the UUID and hands it over; Codex and OpenCode name themselves,
  /// so there this is the only identifier that survives a `Continue with…` move intact.
  var threadingIdentifier: String { id.uuidString.lowercased() }

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

/// A durable standalone shell shown beside chats in the project sidebar.
///
/// The PTY itself is deliberately not persisted. While the app is running its controller keeps
/// the process and scrollback alive; after a relaunch this record starts a fresh shell in the
/// last reported directory.
struct ProjectTerminal: Codable, Identifiable {
  let id: TerminalID
  var title: String
  var customTitle: String?
  var currentDirectory: String
  var branch: String?
  var themeID: TerminalThemeID?
  let createdAt: Date

  init(
    currentDirectory: String,
    id: TerminalID = TerminalID(),
    title: String = "Terminal"
  ) {
    self.id = id
    self.title = title
    self.customTitle = nil
    self.currentDirectory = currentDirectory
    self.branch = GitInfo.currentBranch(for: currentDirectory)
    self.themeID = nil
    self.createdAt = Date()
  }

  /// The *stored* name — a rename, else the last title a program reported, else the
  /// `"Terminal"` placeholder a record is born with.
  ///
  /// Not what to put on screen: the top two rungs of the ladder live here, but the two that
  /// make an unnamed terminal legible — where it is and what it is running — need the project
  /// it is shown under and its live process. Use `ProjectTerminalTitle.displayTitle(for:)`.
  var displayTitle: String {
    let custom = customTitle?.trimmingCharacters(in: .whitespacesAndNewlines)
    if let custom, !custom.isEmpty { return custom }
    return title
  }
}

/// A folder the user has added, grouping chats and standalone terminals started inside it.
struct Project: Codable, Identifiable {
  let id: ProjectID
  var name: String
  /// Stored as a path string for reliable encoding, matching `SessionSnapshot`.
  var folderPath: String
  var sessions: [AgentSession]
  var terminals: [ProjectTerminal]
  var isExpanded: Bool
  let createdAt: Date

  /// The sidebar icon, discovered or chosen. Optional, so state written before icons
  /// existed still decodes.
  var icon: ProjectIcon?

  /// The terminal theme this project's chats and standalone terminals draw with, by stable ID.
  /// Nil inherits the app default; a child choosing its own theme overrides this.
  var themeID: TerminalThemeID?

  /// Whether this checkout's sessions are silenced. Nil inherits "not muted"; a session
  /// with an answer of its own overrides it either way. See `AttentionAlertScope`.
  var notificationsMuted: Bool?

  init(name: String, folderURL: URL, id: ProjectID = ProjectID()) {
    self.id = id
    self.name = name
    self.folderPath = folderURL.path
    self.sessions = []
    self.terminals = []
    self.isExpanded = true
    self.createdAt = Date()
    self.icon = nil
    self.themeID = nil
    self.notificationsMuted = nil
  }

  private enum CodingKeys: String, CodingKey {
    case id, name, folderPath, sessions, terminals, isExpanded, createdAt, icon, themeID, themeName
    case notificationsMuted
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    let decodedFolderPath = try container.decode(String.self, forKey: .folderPath)

    id = try container.decode(ProjectID.self, forKey: .id)
    name =
      try container.decodeIfPresent(String.self, forKey: .name)
      ?? URL(fileURLWithPath: decodedFolderPath).lastPathComponent
    folderPath = decodedFolderPath
    guard folderPath.hasPrefix("/"), !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    else {
      throw DecodingError.dataCorruptedError(
        forKey: folderPath.hasPrefix("/") ? .name : .folderPath,
        in: container,
        debugDescription: "A project requires an absolute folder path and a non-empty name"
      )
    }
    sessions = try container.decodeIfPresent([AgentSession].self, forKey: .sessions) ?? []
    terminals = try container.decodeIfPresent([ProjectTerminal].self, forKey: .terminals) ?? []
    isExpanded = try container.decodeIfPresent(Bool.self, forKey: .isExpanded) ?? true
    createdAt = try container.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
    icon = try container.decodeIfPresent(ProjectIcon.self, forKey: .icon)
    themeID = try container.decodeIfPresent(TerminalThemeID.self, forKey: .themeID)
    if themeID == nil,
      let legacyName = try container.decodeIfPresent(String.self, forKey: .themeName)
    {
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
    try container.encode(terminals, forKey: .terminals)
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

  func terminal(withID terminalID: TerminalID) -> ProjectTerminal? {
    terminals.first { $0.id == terminalID }
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
      !panelTabs.contains(where: { $0.id == activeTabID })
    {
      throw DecodingError.dataCorruptedError(
        forKey: .activeTabID,
        in: container,
        debugDescription: "Active panel tab does not exist in the panel host"
      )
    }
    if let drawerActiveTabID,
      !drawerTabs.contains(where: { $0.id == drawerActiveTabID })
    {
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
    case audit
    case html
    case image
    case semanticScene
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
  var semanticScene: ExtensionScene? = nil
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
  /// The directory `relativePath` resolves against. Still written under its original key: it held
  /// only checkouts before the store could take custody of a copy, and every payload already
  /// written says `projectRoot`.
  let root: String
  let relativePath: String

  /// Both absent in payloads written before provenance was recorded, which is why neither is
  /// required — a missing origin is read as `agent`, the only kind that could have been stored.
  let sourcePath: String?
  let kind: SessionAttachment.Kind
  let origin: SessionAttachment.Origin?

  /// Written only when true, and read as false when absent: every payload predating the
  /// configurable scope holds files that passed the narrow rule, so the absent case is a fact
  /// about those files rather than a gap. Keeping the key out of the common row also keeps a
  /// checkout's own document identical to what earlier builds wrote.
  let isOutsideProject: Bool?
  let referencedAt: Date

  private enum CodingKeys: String, CodingKey {
    case root = "projectRoot"
    case relativePath
    case sourcePath
    case kind
    case origin
    case isOutsideProject
    case referencedAt
  }
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
      .decode([PersistedSessionAttachment].self)
    {
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
    guard
      entries.allSatisfy({
        !$0.root.isEmpty
          && !$0.relativePath.isEmpty
          && !$0.relativePath.hasPrefix("/")
          && !$0.relativePath.split(separator: "/").contains("..")
      })
    else {
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
