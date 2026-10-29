import Foundation

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
  let agentSources: [AttachmentAgentSource]?

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
    case agentSources
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
    agentSources: [AttachmentAgentSource]? = nil,
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
    self.agentSources = agentSources
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
    agentSources = try container.decodeIfPresent([AttachmentAgentSource].self, forKey: .agentSources)
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
