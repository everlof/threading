import Foundation
import ThreadingExtensionKit

// MARK: - Session Auxiliary Documents

/// The persisted form of a session's display panel.
///
/// `formatVersion` is decoded explicitly rather than defaulted by synthesis: absence means the
/// legacy version-zero document, while a value newer than this app is refused. That keeps a
/// future layout from being partially interpreted and then replaced by today's narrower model.
struct PersistedPanel: Codable {
  /// Raised to 2 when detached windows arrived. The bump is the point: a build that predates
  /// them cannot show a `window:` tab, and the version is what makes it say so — refusing the
  /// document with the error this decoder was built to give, rather than reading a layout it
  /// only partly understands and writing that back.
  static let currentFormatVersion = 3

  var tabs: [PersistedTab]
  var activeTabID: String?
  var observedSignature: String?
  var drawerActiveTabID: String? = nil
  var drawerOpen: Bool? = nil
  var detachedWindows: [PersistedDetachedWindow] = []

  var panelTabs: [PersistedTab] { tabs.filter { $0.host == nil } }
  var drawerTabs: [PersistedTab] { tabs.filter { $0.host == PersistedTab.drawerHost } }

  /// Every tab belonging to a detached window, whichever one — the slice the panel and drawer
  /// writers must carry through untouched.
  var detachedWindowTabs: [PersistedTab] { tabs.filter(\.namesADetachedWindow) }

  func tabs(inDetachedWindow windowID: UUID) -> [PersistedTab] {
    tabs.filter { $0.detachedWindowID == windowID }
  }

  private enum CodingKeys: String, CodingKey {
    case formatVersion
    case tabs
    case activeTabID
    case observedSignature
    case drawerActiveTabID
    case drawerOpen
    case detachedWindows
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
    detachedWindows =
      try container.decodeIfPresent([PersistedDetachedWindow].self, forKey: .detachedWindows) ?? []

    guard
      tabs.allSatisfy({
        $0.host == nil || $0.host == PersistedTab.drawerHost || $0.detachedWindowID != nil
      })
    else {
      throw DecodingError.dataCorruptedError(
        forKey: .tabs,
        in: container,
        debugDescription: "Panel tab has an unknown host"
      )
    }

    let declaredWindows = Set(detachedWindows.compactMap { UUID(uuidString: $0.id) })
    guard declaredWindows.count == detachedWindows.count else {
      throw DecodingError.dataCorruptedError(
        forKey: .detachedWindows,
        in: container,
        debugDescription: "Detached window identifiers must be valid and unique"
      )
    }
    // A tab naming a window the document does not declare would be shown by no pane and
    // dropped by the next save, which is the silent loss this validation exists to prevent.
    guard tabs.allSatisfy({ tab in
      tab.detachedWindowID.map(declaredWindows.contains) ?? true
    }) else {
      throw DecodingError.dataCorruptedError(
        forKey: .tabs,
        in: container,
        debugDescription: "Tab names a detached window the document does not declare"
      )
    }
    for window in detachedWindows {
      guard let windowID = UUID(uuidString: window.id), let activeTabID = window.activeTabID
      else { continue }
      guard tabs(inDetachedWindow: windowID).contains(where: { $0.id == activeTabID }) else {
        throw DecodingError.dataCorruptedError(
          forKey: .detachedWindows,
          in: container,
          debugDescription: "Active tab does not exist in its detached window"
        )
      }
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

  /// The version a document *needs* to be read, not the newest this build knows.
  ///
  /// A layout with no detached window is byte-identical to what version 1 always wrote, so
  /// declaring 2 on it would refuse a document an older build can read perfectly — and that
  /// build has no quarantine, so refusing means its next save wipes the panel, the drawer and
  /// every window slice. Stamping the version by what the document contains keeps the bump
  /// costing only the sessions that actually used the feature.
  var requiredFormatVersion: Int {
    if tabs.contains(where: { $0.kind == .simulator }) { return 3 }
    return detachedWindows.isEmpty && !tabs.contains(where: \.namesADetachedWindow) ? 1 : 2
  }

  func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(requiredFormatVersion, forKey: .formatVersion)
    try container.encode(tabs, forKey: .tabs)
    try container.encodeIfPresent(activeTabID, forKey: .activeTabID)
    try container.encodeIfPresent(observedSignature, forKey: .observedSignature)
    try container.encodeIfPresent(drawerActiveTabID, forKey: .drawerActiveTabID)
    try container.encodeIfPresent(drawerOpen, forKey: .drawerOpen)
    // Omitted entirely when empty, so a session that has never detached a window writes the
    // document it always wrote and the key's absence stays the ordinary case.
    if !detachedWindows.isEmpty {
      try container.encode(detachedWindows, forKey: .detachedWindows)
    }
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
    case chart
    case review
    case info
    case terminal
    case files
    case attachments
    case simulator
    case deviceLog
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
  /// The values behind a chart tab. Small enough to keep whole — a chart is capped at
  /// `ChartSpec.Limits.maximumMarks` numbers — and the only form that survives a theme change
  /// between sessions, since nothing about its appearance was stored.
  var chart: ChartSpec? = nil
  var mode: String? = nil
  var extensionIdentifier: String? = nil
  var extensionPanelID: String? = nil
  var simulatorDeviceID: String? = nil
  var compareOldPath: String? = nil
  var compareNewPath: String? = nil
  var compareOldTitle: String? = nil
  var compareNewTitle: String? = nil
  var host: String? = nil

  static let drawerHost = "drawer"

  /// A detached window's slice. Suffixed with the window's own id, because a session may have
  /// more than one and their tabs share this single flat list — the host string is what tells
  /// them apart, exactly as `drawer` separates the drawer's.
  static let detachedWindowHostPrefix = "window:"

  static func detachedWindowHost(_ windowID: UUID) -> String {
    detachedWindowHostPrefix + windowID.uuidString
  }

  /// The detached window this tab belongs to, or nil when its host is the panel or the drawer.
  ///
  /// Parsed rather than merely prefix-matched: `window:` followed by anything is a host no
  /// window will ever claim, so a tab carrying one would be invisible in every pane and dropped
  /// by the next save. Validation refuses the document instead.
  var detachedWindowID: UUID? {
    guard let host, host.hasPrefix(Self.detachedWindowHostPrefix) else { return nil }
    return UUID(uuidString: String(host.dropFirst(Self.detachedWindowHostPrefix.count)))
  }

  var namesADetachedWindow: Bool {
    host?.hasPrefix(Self.detachedWindowHostPrefix) == true
  }
}

// MARK: - Detached Window

/// One detached browser window's own state: which session tabs it holds is carried by those
/// tabs' `host`, so this records only what the window itself knows.
///
/// The frame is a string because this model stays Foundation-only — the window controller
/// converts, the way `setFrameAutosaveName` does for the main window.
struct PersistedDetachedWindow: Codable {
  var id: String
  var frame: String?
  var activeTabID: String?
  var isFullScreen: Bool?
}

/// One attachment reference in the persisted session document.
struct PersistedSessionAttachment: Codable {
  let id: String?

  /// The directory `relativePath` resolves against. Still written under its original key: it held
  /// only checkouts before the store could take custody of a copy, and every payload already
  /// written says `projectRoot`.
  let root: String
  let relativePath: String

  /// Both absent in payloads written before provenance was recorded, which is why neither is
  /// required — a missing origin is read as `agent`, the only kind that could have been stored.
  let sourcePath: String?

  /// Nil when the payload names a kind this build has no case for — a document written by a
  /// newer build. Kind is advisory here anyway (every read re-derives it from the file), so an
  /// unknown value costs the reader nothing it can use; what it must not cost is the *list*,
  /// which is what a strict decode did: `Array` decoding is all-or-nothing, `loadIfNeeded`
  /// swallows the throw, and the next `admit` persists the freshly recorded rows over a payload
  /// that still held every older one.
  let kind: SessionAttachment.Kind?
  let origin: SessionAttachment.Origin?

  /// Written only when true, and read as false when absent: every payload predating the
  /// configurable scope holds files that passed the narrow rule, so the absent case is a fact
  /// about those files rather than a gap. Keeping the key out of the common row also keeps a
  /// checkout's own document identical to what earlier builds wrote.
  let isOutsideProject: Bool?
  let isImmutableSnapshot: Bool?
  let turnID: String?
  /// Optional for forward-compatible decoding and migration of documents written before turns
  /// were visible in the attachment chronology.
  let turnPlacement: SessionAttachment.TurnPlacement?
  let referencedAt: Date

  private enum CodingKeys: String, CodingKey {
    case root = "projectRoot"
    case id
    case relativePath
    case sourcePath
    case kind
    case origin
    case isOutsideProject
    case isImmutableSnapshot
    case turnID
    case turnPlacement
    case referencedAt
  }

  init(
    id: String?,
    root: String,
    relativePath: String,
    sourcePath: String?,
    kind: SessionAttachment.Kind?,
    origin: SessionAttachment.Origin?,
    isOutsideProject: Bool?,
    isImmutableSnapshot: Bool?,
    turnID: String?,
    turnPlacement: SessionAttachment.TurnPlacement?,
    referencedAt: Date
  ) {
    self.id = id
    self.root = root
    self.relativePath = relativePath
    self.sourcePath = sourcePath
    self.kind = kind
    self.origin = origin
    self.isOutsideProject = isOutsideProject
    self.isImmutableSnapshot = isImmutableSnapshot
    self.turnID = turnID
    self.turnPlacement = turnPlacement
    self.referencedAt = referencedAt
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    id = try container.decodeIfPresent(String.self, forKey: .id)
    root = try container.decode(String.self, forKey: .root)
    relativePath = try container.decode(String.self, forKey: .relativePath)
    sourcePath = try container.decodeIfPresent(String.self, forKey: .sourcePath)
    // Read as strings and mapped by hand: an unknown raw value is a *newer build's* row, not
    // corruption, and it reads as nil rather than throwing the whole array away.
    kind = (try container.decodeIfPresent(String.self, forKey: .kind))
      .flatMap(SessionAttachment.Kind.init(rawValue:))
    origin = (try container.decodeIfPresent(String.self, forKey: .origin))
      .flatMap(SessionAttachment.Origin.init(rawValue:))
    isOutsideProject = try container.decodeIfPresent(Bool.self, forKey: .isOutsideProject)
    isImmutableSnapshot = try container.decodeIfPresent(Bool.self, forKey: .isImmutableSnapshot)
    turnID = try container.decodeIfPresent(String.self, forKey: .turnID)
    turnPlacement = (try container.decodeIfPresent(String.self, forKey: .turnPlacement))
      .flatMap(SessionAttachment.TurnPlacement.init(rawValue:))
    referencedAt = try container.decode(Date.self, forKey: .referencedAt)
  }
}

/// A versioned attachment document with an explicit legacy-array migration.
struct PersistedSessionAttachments: Codable {
  static let currentFormatVersion = 3

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
    guard (1...Self.currentFormatVersion).contains(version) else {
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
