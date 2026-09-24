import Foundation

// MARK: - Projects State Version

enum ProjectsStateVersion {
  /// 2 dropped `AgentKind.shell`. A version-1 document may hold shell sessions, which no
  /// longer decode — `StateManager` strips them on the way through.
  static let current = 2
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
  /// Legacy automatic homepage discovery. Retained so existing project records still decode;
  /// repository-declared homepages are no longer contacted automatically.
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

  /// Sounds this terminal overrides, in the same stored shape `AgentSession` carries. The
  /// submenu writes only its `all` entry: a standalone terminal keeps no activity tracker, so
  /// nothing here can say *why* a bell rang and there is no finer level to scope. The
  /// synthesized `Codable` handles a new optional without a custom initializer.
  var soundOverrides: [String: String]?
  let createdAt: Date

  /// The *stored* name — a rename, else the last title a program reported, else the
  /// `"Terminal"` placeholder a record is born with.
  ///
  /// Not what to put on screen: the top two rungs of the ladder live here, but the two that
  /// make an unnamed terminal legible — where it is and what it is running — need its owning
  /// project and live process. Use `ProjectTerminalTitle.displayTitle(for:)`.
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
  /// The repository last verified for this checkout. Its folder can disappear while its chats
  /// remain; this keeps the sidebar relationship without treating the path as runnable.
  var lastKnownRepositoryIdentity: String?
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

  /// Hidden from native project navigation on Mac and iPhone until Show Hidden Projects is enabled.
  var isHidden: Bool = false

  /// Sounds this checkout overrides, in the same stored shape `AgentSession` carries — and for
  /// the same reason it is a raw map rather than a typed one. Its chats and terminals follow
  /// unless they answered for themselves. See `SoundResolution`.
  var soundOverrides: [String: String]?

  /// What happens when a chat in this checkout is refused over its account's usage limit. Nil
  /// inherits the Settings choice; a chat with an answer of its own overrides it either way.
  /// See `LimitRecoveryResolution`.
  var limitRecoveryPolicy: LimitRecoveryPolicy?

  /// Whether this checkout's chats are exempt from the standing quiet hours. Nil inherits the
  /// Settings answer; a chat with an answer of its own overrides it either way. See
  /// `CurfewResolution`.
  ///
  /// **Only `.exempt` or nothing is ever written here.** Fixed and reset-conditioned rules are
  /// one-shot session choices; one stored on a checkout would keep ending chats created weeks
  /// later for a condition nobody chose. `ProjectStore.setCurfewRule(_:forProjectID:)` refuses
  /// both. A record carrying one anyway decodes rather than costing the checkout, and the chain
  /// falls through it to the standing window.
  var curfewRule: CurfewRule?

  /// Whether this is the scratchpad — the one folder Threading owns itself, for chats that are
  /// about no project. There is at most one, and it is the store's business to keep it that
  /// way; see `ProjectStore.scratchpadProject`.
  ///
  /// A stored flag rather than "the project whose path matches the setting", because the user
  /// can move the folder: identity has to survive the path changing under it.
  ///
  /// Optional and absent-when-false, so state written before the scratchpad existed decodes
  /// unchanged and every ordinary checkout keeps encoding exactly what it did before.
  var isScratchpad: Bool?

  /// Whether Threading made this row itself, to receive a chat whose agent had walked into a
  /// checkout that was not a project yet — rather than the user adding the folder.
  ///
  /// The distinction has to be stored, because the two are otherwise identical and the question
  /// only gets asked later: when the last chat leaves, an adopted row has nothing left to justify
  /// it and is reclaimed, while a folder the user added stays whether or not it holds chats. It
  /// shipped without this and left empty rows behind — and, worse than the row,
  /// `CheckoutBranchFollower` keeps a live `HEAD` watcher on every project, so each dead row cost
  /// a whole-sidebar reload every time anything wrote to that checkout.
  ///
  /// Cleared the moment the row earns its place another way (see
  /// `ProjectStore.noteProjectEarnedItsPlace`), so a folder you go on to use deliberately stops
  /// being disposable. Optional and absent-when-false, exactly like `isScratchpad`.
  var isAdoptedForCheckoutMove: Bool?

  /// The Linux machine this checkout's agent sessions run on, or nil for this Mac. Honoured only
  /// by builds that can run remote sessions; any other build refuses the launch rather than
  /// running it here. See `ProjectExecutionHost` and `RemoteExecutionHostRoute`.
  var executionHost: ProjectExecutionHost?

  init(name: String, folderURL: URL, id: ProjectID = ProjectID()) {
    self.id = id
    self.name = name
    self.folderPath = folderURL.path
    self.lastKnownRepositoryIdentity = nil
    self.sessions = []
    self.terminals = []
    self.isExpanded = true
    self.createdAt = Date()
    self.icon = nil
    self.themeID = nil
    self.notificationsMuted = nil
    self.soundOverrides = nil
    self.limitRecoveryPolicy = nil
    self.curfewRule = nil
    self.isScratchpad = nil
    self.isAdoptedForCheckoutMove = nil
    self.executionHost = nil
  }

  private enum CodingKeys: String, CodingKey {
    case id, name, folderPath, sessions, terminals, isExpanded, createdAt, icon, themeID, themeName
    case isHidden
    case notificationsMuted, soundOverrides, limitRecoveryPolicy, isScratchpad
    case curfewRule, isAdoptedForCheckoutMove
    case executionHost, lastKnownRepositoryIdentity
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    let decodedFolderPath = try container.decode(String.self, forKey: .folderPath)

    id = try container.decode(ProjectID.self, forKey: .id)
    name =
      try container.decodeIfPresent(String.self, forKey: .name)
      ?? URL(fileURLWithPath: decodedFolderPath).lastPathComponent
    folderPath = decodedFolderPath
    lastKnownRepositoryIdentity = try container.decodeIfPresent(
      String.self, forKey: .lastKnownRepositoryIdentity
    )
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
    isHidden = try container.decodeIfPresent(Bool.self, forKey: .isHidden) ?? false
    notificationsMuted = try container.decodeIfPresent(
      Bool.self,
      forKey: .notificationsMuted
    )
    soundOverrides = try container.decodeIfPresent(
      [String: String].self,
      forKey: .soundOverrides
    )
    // Leniently, for the reason `AgentSession` states: an unrecognised name must not cost the
    // checkout and every session inside it.
    limitRecoveryPolicy = try container.decodeIfPresent(
      String.self,
      forKey: .limitRecoveryPolicy
    ).flatMap(LimitRecoveryPolicy.init(rawValue:))
    // Through the stored form, leniently, for the reason `AgentSession` states: a rule kind
    // this build has never heard of reads as "never chose" instead of costing the checkout and
    // every session inside it.
    curfewRule = try container.decodeIfPresent(
      CurfewRule.Stored.self,
      forKey: .curfewRule
    ).flatMap(CurfewRule.init(stored:))
    // Normalised on the way in: a stored `false` and an absent key mean the same thing, and
    // letting both exist would give the sidebar two encodings of "ordinary checkout" to match.
    isScratchpad = try container.decodeIfPresent(Bool.self, forKey: .isScratchpad) == true
      ? true
      : nil
    // Same normalisation, same reason: one encoding of "an ordinary row the user added".
    isAdoptedForCheckoutMove = try container.decodeIfPresent(
      Bool.self,
      forKey: .isAdoptedForCheckoutMove
    ) == true ? true : nil
    // Leniently, like the rules above: a host this build cannot read costs the host, never the
    // checkout. `ProjectExecutionHost` itself decodes any object, so only a value of the wrong
    // shape entirely lands here.
    executionHost = try? container.decodeIfPresent(ProjectExecutionHost.self, forKey: .executionHost)
  }

  func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(id, forKey: .id)
    try container.encode(name, forKey: .name)
    try container.encode(folderPath, forKey: .folderPath)
    try container.encodeIfPresent(lastKnownRepositoryIdentity, forKey: .lastKnownRepositoryIdentity)
    try container.encode(sessions, forKey: .sessions)
    try container.encode(terminals, forKey: .terminals)
    try container.encode(isExpanded, forKey: .isExpanded)
    try container.encode(createdAt, forKey: .createdAt)
    try container.encodeIfPresent(icon, forKey: .icon)
    try container.encodeIfPresent(themeID, forKey: .themeID)
    if isHidden { try container.encode(true, forKey: .isHidden) }
    try container.encodeIfPresent(notificationsMuted, forKey: .notificationsMuted)
    try container.encodeIfPresent(soundOverrides, forKey: .soundOverrides)
    try container.encodeIfPresent(limitRecoveryPolicy, forKey: .limitRecoveryPolicy)
    try container.encodeIfPresent(curfewRule, forKey: .curfewRule)
    try container.encodeIfPresent(isScratchpad, forKey: .isScratchpad)
    try container.encodeIfPresent(isAdoptedForCheckoutMove, forKey: .isAdoptedForCheckoutMove)
    try container.encodeIfPresent(executionHost, forKey: .executionHost)
  }

  var folderURL: URL {
    URL(fileURLWithPath: folderPath)
  }

  /// Reads the flag without every call site having to spell the optional out.
  var isTheScratchpad: Bool { isScratchpad == true }

  /// Reads the adoption flag without every call site spelling the optional out.
  var wasAdoptedForCheckoutMove: Bool { isAdoptedForCheckoutMove == true }

  /// Whether this row holds nothing at all, and so has nothing keeping it in the sidebar.
  var holdsNothing: Bool { sessions.isEmpty && terminals.isEmpty }

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
