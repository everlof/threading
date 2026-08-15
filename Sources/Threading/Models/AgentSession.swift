import Foundation

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
  case cursor

  var kind: AgentKind {
    switch self {
    case .claude: return .claude
    case .codex: return .codex
    case .grok: return .grok
    case .openCode: return .openCode
    case .cursor: return .cursor
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
    case .cursor: return .cursor
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

    case .grok, .openCode, .cursor:
      guard reasoningEffort == nil else { return nil }
      self = .original(for: kind)
    }
  }

  fileprivate var derivedSessionID: SessionID? {
    switch self {
    case .claude(_, _, .forked(let source)):
      return source
    case .claude, .codex, .grok, .openCode, .cursor:
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

  private enum CodingKeys: String, CodingKey {
    case endpoints
    case omittedEndpointCount
    case createdAt
  }

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

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    let decodedEndpoints = try container.decode(
      [ConversationHandoffEndpoint].self,
      forKey: .endpoints
    )
    let decodedOmittedCount = try container.decodeIfPresent(
      Int.self,
      forKey: .omittedEndpointCount
    ) ?? 0
    let decodedCreatedAt = try container.decode(Date.self, forKey: .createdAt)
    guard let validated = Self(
      endpoints: decodedEndpoints,
      omittedEndpointCount: decodedOmittedCount,
      createdAt: decodedCreatedAt
    ) else {
      throw DecodingError.dataCorrupted(.init(
        codingPath: decoder.codingPath,
        debugDescription: "Conversation handoff does not form a valid cross-runtime path."
      ))
    }
    self = validated
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

// MARK: - Session Snooze

/// Why a snoozed session returned to attention before (or at) its deadline.
///
/// Raw values are a wire and persistence contract. Unknown remote values remain optional on
/// clients, while an older app simply ignores the newer session keys around this value.
enum SessionWakeReason: String, Codable, Sendable, Equatable {
  case timeReached
  case approvalRequested
  case inputRequested
  case failed
  case turnCompleted
  case requestedUpdate
}

/// The durable receipt shown until the session is visited.
struct SessionWake: Codable, Sendable, Equatable {
  let reason: SessionWakeReason
  let wokeAt: Date
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

  /// When a turn last began in this conversation, whoever started it.
  ///
  /// Deliberately apart from `lastActiveAt`, which the runtime stamps on launch and on exit: a
  /// background relaunch touches every session it brings back, so "last active" answers "last
  /// *touched*" and cannot say when a chat was last used. Measured against this store, that
  /// difference is days — sessions relaunched one morning read as active that morning while
  /// their transcripts had not been written to since the week before.
  ///
  /// Nil for every record written before this field existed; `lastUsedAt` resolves that.
  var lastTurnAt: Date?

  /// When this conversation was last used, as well as the record can say.
  ///
  /// The real turn where there is one, and the runtime's own timestamp for records that predate
  /// it. The launch restore window reads this, and this fallback is exactly why that window is
  /// also capped: on the first launch after the field arrives, every older session reads as
  /// recently touched, and the cap is what keeps that from booting the whole store.
  var lastUsedAt: Date { lastTurnAt ?? lastActiveAt }

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
    case .grok, .openCode, .cursor: return nil
    }
  }

  /// A per-conversation Fast-mode override.
  ///
  /// Nil inherits the routed account's setting, true requests Fast, and false explicitly
  /// requests Standard. The third state matters: decoding an older session must not silently
  /// turn off an account whose config already selected Fast.
  ///
  /// Claude applies this through the per-session settings layer on both surfaces and restates
  /// it through the persistent print transport's control protocol. Codex maps it onto launch
  /// configuration on both surfaces and the next app-server `turn/start` request while
  /// preserving the same process and conversation id.
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
    case .codex, .grok, .openCode, .cursor:
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
  /// The identifier and conversation are untouched, so an archived session resumes exactly as
  /// it would have. Where the runtime exposes its own reversible archive, `ProviderArchiveSync`
  /// keeps this flag and that provider state together; elsewhere it remains a Threading-only
  /// filing choice.
  var isArchived: Bool

  /// The archive value on which Threading and a capable provider last agreed.
  ///
  /// Nil means the session predates synchronization, has no provider conversation yet, or uses
  /// a runtime with no reversible provider archive. It is a three-way-sync base rather than a
  /// duplicate of `isArchived`: if only one side later differs from this value, that side is the
  /// one the user changed. On the first observation the safe merge is archive-if-either, so an
  /// existing filing choice is never silently resurfaced in the other application.
  private(set) var lastSynchronizedArchiveState: Bool?

  /// Pinned conversations sort ahead of the ordinary project order on every surface.
  /// This is shared session state rather than a phone-only preference: pinning from either
  /// side should mean the same thing everywhere the conversation is listed.
  var isPinned: Bool

  /// A visibility overlay only. Neither value changes the process, provider conversation,
  /// archive state, or managed-workspace lifecycle. Both dates are stored explicitly so an app
  /// relaunch (or a missed timer) derives the same answer from the record.
  var snoozedAt: Date?
  var snoozedUntil: Date?

  /// Captured at the action boundary so only the completion of the turn that was already in
  /// flight can wake this snooze. A later turn is new work and has its own activity edges.
  var hadTurnInFlightWhenSnoozed: Bool

  /// Present after an important edge wakes the session, and cleared only by an explicit visit
  /// or acknowledgement. This is durable so every window and remote client reads one receipt.
  var wake: SessionWake?

  /// The terminal theme this session draws with, by stable ID. Nil inherits — from the project,
  /// and from the app default beyond that — so a session that never chose still follows a
  /// later change to either. See `ThemeResolution.resolve`.
  var themeID: TerminalThemeID?

  /// Whether this conversation's macOS notifications are silenced. Nil inherits the
  /// project's answer, which inherits "not muted" — the same three scopes as the theme, and
  /// optional for the same reason: a session inside a muted project can still say no.
  /// See `AttentionAlertScope`.
  var notificationsMuted: Bool?

  /// Sounds this conversation overrides. Absent — the common case — inherits everything.
  /// Keys are `SoundEvent` raw values plus the reserved `all`, `bell` and `alert`; values are
  /// `SoundChoice` stored strings. See `SoundResolution`.
  ///
  /// `[String: String]` rather than a typed dictionary **at the storage boundary on purpose**:
  /// a record written by a later build, naming an event this one has never heard of, has to
  /// survive being read and written here. Decoding to the typed form for use and writing back
  /// through it would delete exactly those entries.
  var soundOverrides: [String: String]?

  /// What happens when this conversation is refused over its account's usage limit. Nil inherits
  /// the project's answer, which inherits the Settings choice — the same three scopes as the
  /// theme, and optional for the same reason: a chat inside an armed checkout can still say no.
  ///
  /// Per-conversation rather than only global because the setting arms an unattended keystroke:
  /// "this long-running chat carries on at reset, my other five do not" is the narrow opt-in, and
  /// the global switch could only ever be the broad one. See `LimitRecoveryResolution`.
  var limitRecoveryPolicy: LimitRecoveryPolicy?

  /// An execution directory owned for this session alone. Nil is the ordinary path: launch in
  /// the Project folder exactly as Threading always has.
  var managedWorkspace: ManagedWorkspace?

  /// The surface a session of this runtime is actually shown on, given what was asked for.
  ///
  /// Two clamps, one rule, and both are corrections rather than refusals: the surface is
  /// Threading's own choice about how to *draw* a conversation, not a setting a CLI was asked to
  /// honour, so an impossible one is fixed instead of costing the record. A runtime with no
  /// native transport falls back to its terminal, which is how a session flagged native for an
  /// agent since changed keeps working. A runtime with no terminal surface is always native —
  /// Cursor, whose two interfaces do not share a conversation store, so a terminal for a chat
  /// created over ACP would be a different, empty chat.
  static func resolvedNativeSurface(_ requested: Bool, for kind: AgentKind) -> Bool {
    guard kind.supports(.terminalUI) else { return kind.supportsNativeUI }
    return requested && kind.supportsNativeUI
  }

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
    self.lastTurnAt = nil
    self.resumeState = ResumeState.initial(for: configuration.kind)
    self.hasLaunched = false
    self.lastExitCode = nil
    self.accountHandle = accountHandle
    self.model = model
    self.fastMode = nil
    self.permissionMode = nil
    self.branch = nil
    self.isArchived = false
    self.lastSynchronizedArchiveState = nil
    self.isPinned = false
    self.snoozedAt = nil
    self.snoozedUntil = nil
    self.hadTurnInFlightWhenSnoozed = false
    self.wake = nil
    self.usesNativeUI = AgentSession.resolvedNativeSurface(
      usesNativeUI,
      for: configuration.kind
    )
    self.themeID = nil
    self.notificationsMuted = nil
    self.soundOverrides = nil
    self.limitRecoveryPolicy = nil
    self.managedWorkspace = nil
  }

  private enum CodingKeys: String, CodingKey {
    case id, kind, title, customTitle, createdAt, lastActiveAt, lastTurnAt
    case agentTitle = "terminalTitle"
    case agentTitleSource
    case agentSessionID, hasLaunched, lastExitCode, accountHandle, model, reasoningEffort, branch
    case fastMode, remoteControl, permissionMode, archived, providerArchiveState, pinned, nativeUI
    case snoozedAt, snoozedUntil, hadTurnInFlightWhenSnoozed, wake
    case forkParent
    case continuationSource, continuationSourceKind
    case handoff
    case themeID, themeName, notificationsMuted, soundOverrides
    case limitRecoveryPolicy
    case managedWorkspace
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
    lastTurnAt = try container.decodeIfPresent(Date.self, forKey: .lastTurnAt)
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
    // Through the raw string, for the reason `limitRecoveryPolicy` states below — and with more
    // at stake: a mode name a later build invented would otherwise throw away the whole session
    // record over one setting. It reads as "chose none" instead, which is the conservative
    // direction here too. Nothing then reaches the launch line, and the runtime's own fallback
    // asks before it acts rather than a half-understood posture deciding it may not.
    permissionMode = try container.decodeIfPresent(
      String.self,
      forKey: .permissionMode
    ).flatMap(AgentPermissionMode.init(rawValue:))
    branch = try container.decodeIfPresent(String.self, forKey: .branch)
    isArchived = try container.decodeIfPresent(Bool.self, forKey: .archived) ?? false
    lastSynchronizedArchiveState = try container.decodeIfPresent(
      Bool.self,
      forKey: .providerArchiveState
    )
    isPinned = try container.decodeIfPresent(Bool.self, forKey: .pinned) ?? false
    snoozedAt = try container.decodeIfPresent(Date.self, forKey: .snoozedAt)
    snoozedUntil = try container.decodeIfPresent(Date.self, forKey: .snoozedUntil)
    hadTurnInFlightWhenSnoozed = try container.decodeIfPresent(
      Bool.self,
      forKey: .hadTurnInFlightWhenSnoozed
    ) ?? false
    wake = try container.decodeIfPresent(SessionWake.self, forKey: .wake)
    usesNativeUI = AgentSession.resolvedNativeSurface(
      try container.decodeIfPresent(Bool.self, forKey: .nativeUI) ?? false,
      for: decodedKind
    )
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
    case .cursor:
      guard decodedForkParent == nil else {
        throw DecodingError.dataCorruptedError(
          forKey: .forkParent,
          in: container,
          debugDescription: "Cursor implements no session fork"
        )
      }
      guard accountHandle == .standard else {
        throw DecodingError.dataCorruptedError(
          forKey: .accountHandle,
          in: container,
          debugDescription: "Cursor holds its login outside any config directory Threading can route"
        )
      }
      guard decodedReasoningEffort == nil else {
        throw DecodingError.dataCorruptedError(
          forKey: .reasoningEffort,
          in: container,
          debugDescription: "Cursor states reasoning effort per model, not per launch"
        )
      }
      guard fastMode == nil else {
        throw DecodingError.dataCorruptedError(
          forKey: .fastMode,
          in: container,
          debugDescription: "Cursor sessions do not use Threading's Fast-mode control"
        )
      }
      guard permissionMode == nil else {
        throw DecodingError.dataCorruptedError(
          forKey: .permissionMode,
          in: container,
          debugDescription: "Cursor's execution modes are a different axis from Threading's"
        )
      }
      configuration = .cursor
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
    soundOverrides = try container.decodeIfPresent(
      [String: String].self,
      forKey: .soundOverrides
    )
    // Through the raw string rather than the enum: `decodeIfPresent` on a `RawRepresentable`
    // *throws* on a value it does not recognise, which would cost the whole session record —
    // its title, its resume state, its account — over one unreadable setting. A policy name a
    // later build invented reads as "never chose" instead, and the answer falls through to the
    // project and the app, the conservative direction.
    limitRecoveryPolicy = try container.decodeIfPresent(
      String.self,
      forKey: .limitRecoveryPolicy
    ).flatMap(LimitRecoveryPolicy.init(rawValue:))
    managedWorkspace = try container.decodeIfPresent(
      ManagedWorkspace.self,
      forKey: .managedWorkspace
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
    try container.encodeIfPresent(lastTurnAt, forKey: .lastTurnAt)
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
    try container.encodeIfPresent(
      lastSynchronizedArchiveState,
      forKey: .providerArchiveState
    )
    try container.encode(isPinned, forKey: .pinned)
    try container.encodeIfPresent(snoozedAt, forKey: .snoozedAt)
    try container.encodeIfPresent(snoozedUntil, forKey: .snoozedUntil)
    if hadTurnInFlightWhenSnoozed {
      try container.encode(true, forKey: .hadTurnInFlightWhenSnoozed)
    }
    try container.encodeIfPresent(wake, forKey: .wake)
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
    try container.encodeIfPresent(soundOverrides, forKey: .soundOverrides)
    try container.encodeIfPresent(limitRecoveryPolicy, forKey: .limitRecoveryPolicy)
    try container.encodeIfPresent(managedWorkspace, forKey: .managedWorkspace)
  }

  /// Where this conversation's process and project-relative tools run.
  ///
  /// Managed sessions retain their logical Project relationship for navigation, theming and
  /// persistence; substituting the directory only at execution seams prevents a temporary
  /// worktree from becoming a second sidebar project.
  func workingDirectory(in project: Project) -> String {
    managedWorkspace?.executionPath ?? project.folderPath
  }

  /// Records one archive state as the value both Threading and the provider now hold.
  /// Returns whether either persisted field changed, so a batch reconciliation writes once.
  @discardableResult
  mutating func synchronizeArchiveState(_ archived: Bool) -> Bool {
    let clearsAttentionOverlay = archived
      && (snoozedAt != nil || snoozedUntil != nil || wake != nil)
    guard isArchived != archived || lastSynchronizedArchiveState != archived
      || clearsAttentionOverlay else {
      return false
    }
    isArchived = archived
    lastSynchronizedArchiveState = archived
    if archived { clearAttentionOverlay() }
    return true
  }

  /// Whether the persisted overlay suppresses attention at `date`.
  ///
  /// Deliberately does not require `date >= snoozedAt`: if the wall clock moves backwards, the
  /// session remains snoozed until the stored deadline instead of briefly resurfacing.
  func isSnoozed(at date: Date) -> Bool {
    guard !isArchived, let snoozedAt, let snoozedUntil,
          snoozedAt < snoozedUntil else { return false }
    return date < snoozedUntil
  }

  mutating func clearAttentionOverlay() {
    snoozedAt = nil
    snoozedUntil = nil
    hadTurnInFlightWhenSnoozed = false
    wake = nil
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
    case .grok, .openCode, .cursor:
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
