import CoreGraphics
import Foundation

/// The Codable wire types exchanged with a remote client. Shared between the macOS server and
/// any client so there is exactly one definition of the protocol. Kept a **parallel DTO layer**
/// rather than conformances on the app's own models: `StreamEvent`/`ContentBlock` carry
/// `[String: Any]` and cannot be made `Codable` without a migration, and a client must not
/// depend on app internals. The conversation DTOs (M4) bridge through a Codable JSON value.
///
/// Every type has a public memberwise initializer so both the server (encoding) and a client
/// (constructing test/fixture values) can build them across the module boundary.

// MARK: - REST

/// The app chrome resolved by the Mac. Colours are semantic role names (for example `ground`,
/// `label`, and `accent`) mapped to RGB/RGBA hex values. Sending resolved values rather than a
/// theme identifier means custom themes and the System theme work on clients that do not have
/// the Mac's theme library.
public struct RemoteThemeDTO: Codable, Equatable, Sendable {
    public struct Material: Codable, Equatable, Sendable {
        public struct Glow: Codable, Equatable, Sendable {
            public let color: String
            public let radius: Double
            public let opacity: Double
            public let offsetX: Double?
            public let offsetY: Double?

            public init(
                color: String,
                radius: Double,
                opacity: Double,
                offsetX: Double? = nil,
                offsetY: Double? = nil
            ) {
                self.color = color
                self.radius = radius
                self.opacity = opacity
                self.offsetX = offsetX
                self.offsetY = offsetY
            }
        }

        public let panelRadius: Double
        public let controlRadius: Double
        public let borderWidth: Double
        public let glow: Glow?

        /// The theme's multiplier for semantic app text. Optional for wire compatibility;
        /// clients receiving nil use 1. This composes with any client-side accessibility
        /// preference rather than replacing it.
        public let textScale: Double?

        /// The typeface class the Mac's chrome is set in — `default`, `serif`, `rounded` or
        /// `monospaced`. Optional on the wire in both directions: a client built before this
        /// field existed ignores it, and one built after it still decodes a payload from a Mac
        /// that predates it. A client that wants to match maps these onto its own platform's
        /// font designs; iOS has the same four.
        public let typeface: RemoteThemeTypeface?

        /// A named family the theme asks for, where it is more specific than a class. **Advisory
        /// on the wire**: it names a font installed on the *Mac*, and a phone that does not have
        /// it should fall back to `typeface` rather than substituting something close.
        public let fontFamily: String?

        public init(
            panelRadius: Double,
            controlRadius: Double,
            borderWidth: Double,
            glow: Glow? = nil,
            textScale: Double? = nil,
            typeface: RemoteThemeTypeface? = nil,
            fontFamily: String? = nil
        ) {
            self.panelRadius = panelRadius
            self.controlRadius = controlRadius
            self.borderWidth = borderWidth
            self.glow = glow
            self.textScale = textScale
            self.typeface = typeface
            self.fontFamily = fontFamily
        }
    }

    public let id: String
    public let name: String
    /// Any adaptive Mac theme is resolved before sending.
    public let mode: RemoteThemeMode
    public let colors: [String: String]
    public let material: Material

    public init(
        id: String,
        name: String,
        mode: RemoteThemeMode,
        colors: [String: String],
        material: Material
    ) {
        self.id = id
        self.name = name
        self.mode = mode
        self.colors = colors
        self.material = material
    }
}

/// A session's fully resolved terminal palette. This remains separate from app chrome because
/// terminal themes can be assigned at session/project scope even when the rest of the app uses
/// one global style.
public struct RemoteTerminalThemeDTO: Codable, Equatable, Sendable {
    public let id: String
    public let name: String
    public let foreground: String
    /// Terminal.app's "Bold Text": what SGR 1 in the default foreground draws in. Optional so a
    /// client built before the role existed still decodes a host that sends it, and so a host
    /// that does not send one still decodes here — nil means "the same as `foreground`".
    public let boldForeground: String?
    public let background: String
    public let cursor: String
    public let selection: String
    /// ANSI indices 0...15, in terminal order.
    public let ansi: [String]

    public init(
        id: String,
        name: String,
        foreground: String,
        boldForeground: String? = nil,
        background: String,
        cursor: String,
        selection: String,
        ansi: [String]
    ) {
        self.id = id
        self.name = name
        self.foreground = foreground
        self.boldForeground = boldForeground
        self.background = background
        self.cursor = cursor
        self.selection = selection
        self.ansi = ansi
    }
}

/// The choices an owner can select remotely. Every entry carries its resolved colours so a
/// client can preview a choice immediately while the Mac persists the authoritative setting.
public struct RemoteThemeCatalogDTO: Codable, Equatable, Sendable {
    public let appThemes: [RemoteThemeDTO]
    public let terminalThemes: [RemoteTerminalThemeDTO]

    public init(
        appThemes: [RemoteThemeDTO],
        terminalThemes: [RemoteTerminalThemeDTO]
    ) {
        self.appThemes = appThemes
        self.terminalThemes = terminalThemes
    }
}

/// What a session is currently showing: the runtime's own TUI in a mirrored terminal, or
/// Threading's natively rendered conversation.
///
/// This was a bare `"terminal"` / `"conversation"` string on the wire *and* in both apps, compared
/// against literals at eighty call sites. Nothing named the set of values, a misspelling was a
/// silently wrong screen rather than a build error, and the two words carry a distinction the code
/// has to keep straight: `terminal` here is the **provider's TUI**, not a shell.
///
/// It stays a string *on the wire* — a `RawRepresentable` rather than an enum — for the reason the
/// string existed in the first place: a newer Mac may show a surface this build has never heard of,
/// and a phone must decode, list and round-trip that row rather than fail the whole listing on it.
/// An unknown value therefore equals neither of the known ones and survives re-encoding intact.
public struct RemoteSessionSurface: RawRepresentable, Codable, Hashable, Sendable {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    /// The runtime's own interactive TUI, hosted in a terminal on the Mac and mirrored here.
    public static let terminal = Self(rawValue: "terminal")
    /// Threading's own conversation rendering, driven by a headless provider transport.
    public static let conversation = Self(rawValue: "conversation")

    /// The surfaces this build can host.
    public static let known: [Self] = [.terminal, .conversation]

    /// Whether this build knows what to do with the surface.
    ///
    /// Leniency runs one way on purpose: an unknown surface must not fail a *listing*, and it must
    /// not be *launched* either. An inbound request naming something this host cannot host is
    /// refused rather than guessed at.
    public var isKnown: Bool { Self.known.contains(self) }

    public init(from decoder: Decoder) throws {
        rawValue = try decoder.singleValueContainer().decode(String.self)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

/// Which login a session runs on, drawn the way the Mac sidebar draws it.
///
/// The host resolves the chip rather than the client, because the inputs are all on the Mac: the
/// account's chosen emoji, the login address behind its initial, and the hash that gives the disc
/// its colour. Sending the resolved glyph and hue keeps a phone row and a sidebar row showing the
/// same account the same way, instead of two hash implementations that agree until one is edited.
///
/// A discovered avatar is deliberately not carried: it would be image bytes per row, and per
/// `AccountBadge` the hashed initial is the working case rather than the fallback.
public struct RemoteSessionAccountDTO: Codable, Equatable, Sendable {
    /// The name the Mac's own account menu shows — a person's name where one can be derived,
    /// else the login address, else the CLI alias.
    public let name: String
    /// One emoji or one letter. Never a word: this is drawn in a 12-point chip.
    public let glyph: String
    /// Whether `glyph` brings its own colour, in which case `hue` is nil and the chip draws no disc.
    public let isEmoji: Bool
    /// Fraction of the colour wheel for the initial's disc, hashed from the login address so one
    /// person keeps one colour across the agents they are logged into.
    public let hue: Double?

    public let backgroundHex: String?
    public let foregroundHex: String?
    public let imageID: String?
    public let badgeHidden: Bool?
    public let displayLabel: String?
    public let email: String?
    public var visibleName: String { displayLabel ?? name }

    public init(name: String, glyph: String, isEmoji: Bool, hue: Double?,
                backgroundHex: String? = nil, foregroundHex: String? = nil,
                imageID: String? = nil, badgeHidden: Bool? = nil, displayLabel: String? = nil, email: String? = nil) {
        self.name = name
        self.backgroundHex = backgroundHex
        self.foregroundHex = foregroundHex
        self.imageID = imageID
        self.badgeHidden = badgeHidden
        self.displayLabel = displayLabel
        self.email = email
        self.glyph = glyph
        self.isEmoji = isEmoji
        self.hue = hue
    }
}

/// What one chat will do after its provider refuses a turn over an account limit.
///
/// Known actions are cases so callers cannot misspell or partially interpret them. A newer host
/// can still add an outcome without making an older phone fail to decode the whole catalogue:
/// `unknown` preserves that action and its optional account. `accountID` is the account handle
/// only; the session already supplies the runtime that qualifies it.
public enum RemoteLimitRecoveryPolicyDTO: Codable, Equatable, Sendable {
    case flagOnly
    case waitForReset
    case resumeOnBestAccount
    case resumeVia(accountID: String)
    case unknown(action: String, accountID: String?)

    private enum CodingKeys: String, CodingKey {
        case action
        case accountID
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let action = try container.decode(String.self, forKey: .action)
        let accountID = try container.decodeIfPresent(String.self, forKey: .accountID)
        switch (action, accountID) {
        case ("flagOnly", nil): self = .flagOnly
        case ("waitForReset", nil): self = .waitForReset
        case ("resumeOnBestAccount", nil): self = .resumeOnBestAccount
        case let ("resumeVia", .some(accountID)) where !accountID.isEmpty:
            self = .resumeVia(accountID: accountID)
        default:
            self = .unknown(action: action, accountID: accountID)
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(action, forKey: .action)
        try container.encodeIfPresent(accountID, forKey: .accountID)
    }

    public var action: String {
        switch self {
        case .flagOnly: return "flagOnly"
        case .waitForReset: return "waitForReset"
        case .resumeOnBestAccount: return "resumeOnBestAccount"
        case .resumeVia: return "resumeVia"
        case let .unknown(action, _): return action
        }
    }

    public var accountID: String? {
        switch self {
        case let .resumeVia(accountID): return accountID
        case let .unknown(_, accountID): return accountID
        case .flagOnly, .waitForReset, .resumeOnBestAccount: return nil
        }
    }

    public var isKnown: Bool {
        if case .unknown = self { return false }
        return true
    }
}

/// What a session is doing, as projected by the host into every remote client.
///
/// This is an enum in client code so activity decisions are exhaustive and misspellings do not
/// silently become an idle-looking row. The associated unknown case is the wire-version seam: a
/// newer Mac may add a state before an installed phone knows how to present it, and that phone
/// must still decode and list the rest of the session catalogue. Unknown values therefore survive
/// a decode/encode round trip instead of failing the whole response.
public enum RemoteSessionActivity: RawRepresentable, Codable, Equatable, Hashable, Sendable {
    case dormant
    case idle
    case working
    case awaitingUser
    case needsAttention
    case limitReached
    case unknown(String)

    public init(rawValue: String) {
        switch rawValue {
        case "dormant": self = .dormant
        case "idle": self = .idle
        case "working": self = .working
        case "awaitingUser": self = .awaitingUser
        case "needsAttention": self = .needsAttention
        case "limitReached": self = .limitReached
        default: self = .unknown(rawValue)
        }
    }

    public var rawValue: String {
        switch self {
        case .dormant: return "dormant"
        case .idle: return "idle"
        case .working: return "working"
        case .awaitingUser: return "awaitingUser"
        case .needsAttention: return "needsAttention"
        case .limitReached: return "limitReached"
        case let .unknown(rawValue): return rawValue
        }
    }

    public var isKnown: Bool {
        if case .unknown = self { return false }
        return true
    }

    public init(from decoder: Decoder) throws {
        try self.init(rawValue: decoder.singleValueContainer().decode(String.self))
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

/// What the host's participant-scoped receipt ledger can prove.
///
/// This stays separate from `RemoteSessionActivity`: working, blocking, limits and dormancy are
/// shared runtime facts, while only a completed result has a reader-specific receipt.
public enum RemoteSessionAttentionKnowledge: RawRepresentable, Codable, Equatable, Sendable {
    case read
    case unread
    case unavailable
    case unknown(String)

    public init(rawValue: String) {
        switch rawValue {
        case "read": self = .read
        case "unread": self = .unread
        case "unavailable": self = .unavailable
        default: self = .unknown(rawValue)
        }
    }

    public var rawValue: String {
        switch self {
        case .read: return "read"
        case .unread: return "unread"
        case .unavailable: return "unavailable"
        case let .unknown(rawValue): return rawValue
        }
    }

    public init(from decoder: Decoder) throws {
        self.init(rawValue: try decoder.singleValueContainer().decode(String.self))
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

/// The generation proof behind one participant's attention dot. Optional on the session row so
/// old hosts and new clients remain compatible; when present, clients never have to infer a
/// receipt from a transient UI event.
public struct RemoteSessionAttentionDTO: Codable, Equatable, Sendable {
    public let knowledge: RemoteSessionAttentionKnowledge
    public let completionGeneration: Int?
    public let seenGeneration: Int?

    public init(
        knowledge: RemoteSessionAttentionKnowledge,
        completionGeneration: Int? = nil,
        seenGeneration: Int? = nil
    ) {
        self.knowledge = knowledge
        self.completionGeneration = completionGeneration
        self.seenGeneration = seenGeneration
    }
}

/// Work that can re-enter a prompt-ready conversation without another user message.
public enum RemoteSessionContinuation: RawRepresentable, Codable, Equatable, Hashable, Sendable {
    case delegated
    case standing
    case unknown(String)

    public init(rawValue: String) {
        switch rawValue {
        case "delegated": self = .delegated
        case "standing": self = .standing
        default: self = .unknown(rawValue)
        }
    }

    public var rawValue: String {
        switch self {
        case .delegated: "delegated"
        case .standing: "standing"
        case .unknown(let value): value
        }
    }

    public init(from decoder: Decoder) throws {
        try self.init(rawValue: decoder.singleValueContainer().decode(String.self))
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

/// One session as it appears to a remote client's session list.
public struct RemoteSessionSummaryDTO: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public let title: String
    public let agentKind: String
    public let surface: RemoteSessionSurface
    public let state: RemoteSessionActivity
    /// Additive participant-scoped proof for the attention part of `state`.
    public let attention: RemoteSessionAttentionDTO?
    /// Additive so older hosts and clients safely read this as no background continuation.
    public let continuation: RemoteSessionContinuation?
    public let projectName: String
    /// Stable checkout identity for routes that must not collapse duplicate display names.
    public let projectID: String?
    /// Whether the session currently has a live surface a client can attach to.
    public let isAvailable: Bool
    /// Unix time for sorting and compact relative dates in mobile clients.
    public let lastActiveAt: Double?
    /// Pinned sessions sort ahead of the ordinary recency order on every client.
    public let isPinned: Bool
    /// Included so archived results can use the same row model as the active dashboard.
    public let isArchived: Bool
    /// Unix time of the current archive action. Optional for hosts predating archive chronology.
    public let archivedAt: Double?
    /// Optional so clients and hosts can roll forward independently.
    public let snoozedAt: Double?
    public let snoozedUntil: Double?
    public let wokeReason: String?
    public let wokeAt: Double?
    /// Whether the owner currently has at least one guest capability for this session.
    public let isShared: Bool
    /// Optional for compatibility with hosts from before remote theme propagation.
    public let terminalTheme: RemoteTerminalThemeDTO?
    /// Nil means the session inherits its project or the app-wide terminal default.
    public let terminalThemeAssignmentID: String?
    /// The human-readable result of clearing the session assignment.
    public let inheritedTerminalThemeName: String?
    /// The resolved palette that clearing the session assignment would reveal.
    public let inheritedTerminalTheme: RemoteTerminalThemeDTO?
    /// The login this session runs on, or nil when the row has nothing extra to say: a runtime
    /// without account routing, the CLI's default login, or a host predating this field.
    public let account: RemoteSessionAccountDTO?
    /// The routed account handle, including `default`. Owner-only and optional for compatibility.
    /// Clients join it to the top-level agent catalogue rather than receiving an account array
    /// on every session row.
    public let accountID: String?
    /// The resolved chat/project/app answer. Owner-only; nil on older hosts and guest shares.
    public let limitRecovery: RemoteLimitRecoveryPolicyDTO?
    /// The model this chat chose for itself, when it chose one. Nil is the account's default, and
    /// also what a host predating this field sends; a client falls back the way the Mac's own
    /// toolbar does, to `RemoteAccountChoiceDTO.defaultModelID`.
    public let model: String?

    public init(
        id: String,
        title: String,
        agentKind: String,
        surface: RemoteSessionSurface,
        state: RemoteSessionActivity,
        attention: RemoteSessionAttentionDTO? = nil,
        continuation: RemoteSessionContinuation? = nil,
        projectName: String,
        projectID: String? = nil,
        isAvailable: Bool = true,
        lastActiveAt: Double? = nil,
        isPinned: Bool = false,
        isArchived: Bool = false,
        archivedAt: Double? = nil,
        snoozedAt: Double? = nil,
        snoozedUntil: Double? = nil,
        wokeReason: String? = nil,
        wokeAt: Double? = nil,
        isShared: Bool = false,
        terminalTheme: RemoteTerminalThemeDTO? = nil,
        terminalThemeAssignmentID: String? = nil,
        inheritedTerminalThemeName: String? = nil,
        inheritedTerminalTheme: RemoteTerminalThemeDTO? = nil,
        account: RemoteSessionAccountDTO? = nil,
        accountID: String? = nil,
        limitRecovery: RemoteLimitRecoveryPolicyDTO? = nil,
        model: String? = nil
    ) {
        self.id = id
        self.title = title
        self.agentKind = agentKind
        self.surface = surface
        self.state = state
        self.attention = attention
        self.continuation = continuation
        self.projectName = projectName
        self.projectID = projectID
        self.isAvailable = isAvailable
        self.lastActiveAt = lastActiveAt
        self.isPinned = isPinned
        self.isArchived = isArchived
        self.archivedAt = archivedAt
        self.snoozedAt = snoozedAt
        self.snoozedUntil = snoozedUntil
        self.wokeReason = wokeReason
        self.wokeAt = wokeAt
        self.isShared = isShared
        self.terminalTheme = terminalTheme
        self.terminalThemeAssignmentID = terminalThemeAssignmentID
        self.inheritedTerminalThemeName = inheritedTerminalThemeName
        self.inheritedTerminalTheme = inheritedTerminalTheme
        self.account = account
        self.accountID = accountID
        self.limitRecovery = limitRecovery
        self.model = model
    }

    private enum CodingKeys: String, CodingKey {
        case id, title, agentKind, surface, state, attention, continuation, projectName, projectID, isAvailable, lastActiveAt
        case isPinned, isArchived, archivedAt, isShared
        case snoozedAt, snoozedUntil, wokeReason, wokeAt
        case terminalTheme, terminalThemeAssignmentID, inheritedTerminalThemeName
        case inheritedTerminalTheme, account, accountID, limitRecovery, model
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        title = try container.decode(String.self, forKey: .title)
        agentKind = try container.decode(String.self, forKey: .agentKind)
        surface = try container.decode(RemoteSessionSurface.self, forKey: .surface)
        state = try container.decode(RemoteSessionActivity.self, forKey: .state)
        attention = try container.decodeIfPresent(
            RemoteSessionAttentionDTO.self,
            forKey: .attention
        )
        continuation = try container.decodeIfPresent(
            RemoteSessionContinuation.self,
            forKey: .continuation
        )
        projectName = try container.decode(String.self, forKey: .projectName)
        projectID = try container.decodeIfPresent(String.self, forKey: .projectID)
        // The first wire build listed only live sessions, so a missing field means available.
        isAvailable = try container.decodeIfPresent(Bool.self, forKey: .isAvailable) ?? true
        lastActiveAt = try container.decodeIfPresent(Double.self, forKey: .lastActiveAt)
        isPinned = try container.decodeIfPresent(Bool.self, forKey: .isPinned) ?? false
        isArchived = try container.decodeIfPresent(Bool.self, forKey: .isArchived) ?? false
        archivedAt = try container.decodeIfPresent(Double.self, forKey: .archivedAt)
        snoozedAt = try container.decodeIfPresent(Double.self, forKey: .snoozedAt)
        snoozedUntil = try container.decodeIfPresent(Double.self, forKey: .snoozedUntil)
        wokeReason = try container.decodeIfPresent(String.self, forKey: .wokeReason)
        wokeAt = try container.decodeIfPresent(Double.self, forKey: .wokeAt)
        isShared = try container.decodeIfPresent(Bool.self, forKey: .isShared) ?? false
        terminalTheme = try container.decodeIfPresent(
            RemoteTerminalThemeDTO.self,
            forKey: .terminalTheme
        )
        terminalThemeAssignmentID = try container.decodeIfPresent(
            String.self,
            forKey: .terminalThemeAssignmentID
        )
        inheritedTerminalThemeName = try container.decodeIfPresent(
            String.self,
            forKey: .inheritedTerminalThemeName
        )
        inheritedTerminalTheme = try container.decodeIfPresent(
            RemoteTerminalThemeDTO.self,
            forKey: .inheritedTerminalTheme
        )
        account = try container.decodeIfPresent(
            RemoteSessionAccountDTO.self,
            forKey: .account
        )
        accountID = try container.decodeIfPresent(String.self, forKey: .accountID)
        limitRecovery = try container.decodeIfPresent(
            RemoteLimitRecoveryPolicyDTO.self,
            forKey: .limitRecovery
        )
        model = try container.decodeIfPresent(String.self, forKey: .model)
    }

    /// Derived on the client as well as the host, so a missed refresh cannot keep an expired
    /// session hidden. A backwards wall-clock step deliberately keeps it snoozed to the deadline.
    public func isSnoozed(at date: Date = Date()) -> Bool {
        guard !isArchived, let snoozedAt, let snoozedUntil,
              snoozedAt < snoozedUntil else { return false }
        return date.timeIntervalSince1970 < snoozedUntil
    }
}

/// One standalone project shell in a remote catalogue.
///
/// Kept separate from `RemoteSessionSummaryDTO`: a shell has no agent, transcript, archive,
/// workspace, permission-approval, or native-conversation lifecycle. Older clients ignore the
/// optional `RemoteMeDTO.terminals` field instead of mistaking these UUIDs for chat sessions.
public enum RemoteTerminalActivity: RawRepresentable, Codable, Equatable, Hashable, Sendable {
    case dormant
    case idle
    case working
    case unknown(String)

    public init(rawValue: String) {
        switch rawValue {
        case "dormant": self = .dormant
        case "idle": self = .idle
        case "working": self = .working
        default: self = .unknown(rawValue)
        }
    }

    public var rawValue: String {
        switch self {
        case .dormant: return "dormant"
        case .idle: return "idle"
        case .working: return "working"
        case let .unknown(rawValue): return rawValue
        }
    }

    public init(from decoder: Decoder) throws {
        try self.init(rawValue: decoder.singleValueContainer().decode(String.self))
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

public struct RemoteProjectTerminalSummaryDTO: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public let title: String
    public let projectName: String
    public let projectID: String?
    public let state: RemoteTerminalActivity
    public let isAvailable: Bool
    public let createdAt: Double?
    public let isShared: Bool
    public let terminalTheme: RemoteTerminalThemeDTO?
    public let terminalThemeAssignmentID: String?
    public let inheritedTerminalThemeName: String?
    public let inheritedTerminalTheme: RemoteTerminalThemeDTO?

    public init(
        id: String,
        title: String,
        projectName: String,
        projectID: String? = nil,
        state: RemoteTerminalActivity,
        isAvailable: Bool,
        createdAt: Double? = nil,
        isShared: Bool = false,
        terminalTheme: RemoteTerminalThemeDTO? = nil,
        terminalThemeAssignmentID: String? = nil,
        inheritedTerminalThemeName: String? = nil,
        inheritedTerminalTheme: RemoteTerminalThemeDTO? = nil
    ) {
        self.id = id
        self.title = title
        self.projectName = projectName
        self.projectID = projectID
        self.state = state
        self.isAvailable = isAvailable
        self.createdAt = createdAt
        self.isShared = isShared
        self.terminalTheme = terminalTheme
        self.terminalThemeAssignmentID = terminalThemeAssignmentID
        self.inheritedTerminalThemeName = inheritedTerminalThemeName
        self.inheritedTerminalTheme = inheritedTerminalTheme
    }
}

/// One added checkout a new remote session can run in. A branch is offered only when an added
/// checkout already stands on it, matching the Mac composer's safety rule.
public struct RemoteProjectChoiceDTO: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public let name: String
    public let branch: String?
    public let checkoutLabel: String
    /// What a chat this project is *given* rather than configured for comes up as: today, a
    /// shake report sent to the Mac. Absent from an older host, and from a client that has no
    /// business starting one.
    public let reportLaunch: RemoteReportLaunchDTO?

    public init(
        id: String,
        name: String,
        branch: String?,
        checkoutLabel: String,
        reportLaunch: RemoteReportLaunchDTO? = nil
    ) {
        self.id = id
        self.name = name
        self.branch = branch
        self.checkoutLabel = checkoutLabel
        self.reportLaunch = reportLaunch
    }
}

/// An isolated workspace a session runs in, and what becomes of it when the agent finishes.
///
/// Lossless wire enums preserve a delivery or publication value added by a newer host, while the
/// Mac maps only known values back to its own types and refuses anything it does not recognise.
public struct RemoteManagedWorkspacePlanDTO: Codable, Equatable, Sendable {
    public let delivery: RemoteManagedWorkspaceDelivery
    /// `draft` or `ready` when finishing should also open a change request; absent for local
    /// delivery, which is every workspace a phone can currently ask for.
    public let publication: RemoteManagedWorkspacePublication?

    public init(
        delivery: RemoteManagedWorkspaceDelivery,
        publication: RemoteManagedWorkspacePublication? = nil
    ) {
        self.delivery = delivery
        self.publication = publication
    }
}

/// The launch a report sent from a paired device would receive in one project.
///
/// **The Mac decides all of it and the client forwards it.** The choices are inherited from the
/// chat most recently used in that project, and the workspace comes from the owner's Remote
/// Access setting after the project's checkout and that agent's own capabilities have been
/// checked against it. A phone that picked these itself is how this route ended up starting
/// Codex on people who had not used it in weeks, and is how it could ask for a worktree this Mac
/// would then refuse.
///
/// Every field is still validated on arrival. This is a convenience for the client, not a
/// licence: `handleCreateSession` trusts the request no more than it did before.
public struct RemoteReportLaunchDTO: Codable, Equatable, Sendable {
    public let agentID: String
    /// `default`, or an alternate account handle. Absent for a runtime without logins.
    public let accountID: String?
    public let model: String?
    public let reasoningEffort: String?
    public let fastMode: Bool?
    public let permissionMode: String?
    public let surface: RemoteSessionSurface
    public let managedWorkspace: RemoteManagedWorkspacePlanDTO?

    public init(
        agentID: String,
        accountID: String? = nil,
        model: String? = nil,
        reasoningEffort: String? = nil,
        fastMode: Bool? = nil,
        permissionMode: String? = nil,
        surface: RemoteSessionSurface,
        managedWorkspace: RemoteManagedWorkspacePlanDTO? = nil
    ) {
        self.agentID = agentID
        self.accountID = accountID
        self.model = model
        self.reasoningEffort = reasoningEffort
        self.fastMode = fastMode
        self.permissionMode = permissionMode
        self.surface = surface
        self.managedWorkspace = managedWorkspace
    }
}

public struct RemoteReasoningChoiceDTO: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public let name: String

    public init(id: String, name: String) {
        self.id = id
        self.name = name
    }
}

public struct RemotePermissionModeChoiceDTO: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public let name: String
    public let detail: String

    public init(id: String, name: String, detail: String) {
        self.id = id
        self.name = name
        self.detail = detail
    }
}

public struct RemoteModelChoiceDTO: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public let name: String
    public let reasoning: [RemoteReasoningChoiceDTO]
    /// The account-effective inherited effort for this model, after the host has applied the
    /// routed login's config and validated it against the advertised reasoning levels.
    public let defaultReasoningID: String?
    /// Nil when decoded from a host predating remote speed selection.
    public let supportsFastMode: Bool?

    public init(
        id: String,
        name: String,
        reasoning: [RemoteReasoningChoiceDTO] = [],
        defaultReasoningID: String? = nil,
        supportsFastMode: Bool? = nil
    ) {
        self.id = id
        self.name = name
        self.reasoning = reasoning
        self.defaultReasoningID = defaultReasoningID
        self.supportsFastMode = supportsFastMode
    }
}

/// One rolling limit window of an account: `5h`, `7d`, or a window scoped to one model.
///
/// The phone draws these as the rings around its account disc, so this carries what a ring needs
/// and nothing a dashboard would: the fraction, the reset that makes that fraction stale, the
/// length that orders the rings, and, for a scoped window, the model ids it meters. That last
/// list is resolved on the Mac by `ModelName.scope`, so the phone matches a chat's model with a
/// lookup rather than a second copy of that rule.
public struct RemoteAccountUsageWindowDTO: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    /// The window's compact name: `5h`, `7d`, `7d Fable`.
    public let name: String
    /// Consumed fraction, 0...1. Nil when the Mac does not know it.
    public let fraction: Double?
    /// Epoch seconds. A reading whose reset has passed describes the window before it.
    public let resetsAt: Double?
    /// The window's full length in seconds, when the provider states it.
    public let windowDuration: Double?
    /// For a window scoped to a model, the ids among the account's model choices it meters. Nil
    /// for a window that meters the account as a whole.
    public let metersModelIDs: [String]?

    public init(
        id: String,
        name: String,
        fraction: Double?,
        resetsAt: Double? = nil,
        windowDuration: Double? = nil,
        metersModelIDs: [String]? = nil
    ) {
        self.id = id
        self.name = name
        self.fraction = fraction
        self.resetsAt = resetsAt
        self.windowDuration = windowDuration
        self.metersModelIDs = metersModelIDs
    }
}

/// One login available to an agent on the Mac. Only presentation-safe identity and the latest
/// normalized usage reading cross the wire; config paths and credentials never leave the host.
public struct RemoteAccountChoiceDTO: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public let name: String
    /// The login's own address, where the Mac knows one.
    ///
    /// `name` is usually derived *from* this — `AccountName.derived(fromEmail:)` reads
    /// `everlof@gmail.com` as "Everlof" — so a client showing both must check they differ. Nil
    /// for a host predating this field, for a CLI that records no address, and for the standard
    /// login of a CLI that only hashes it. Owner-only: the account catalogue is absent from
    /// every guest scope.
    public let email: String?
    public let emoji: String?
    public let presentation: RemoteSessionAccountDTO?
    public let imagePNG: Data?
    public let appearances: [String: RemoteSessionAccountDTO]?
    public let images: [String: Data]?
    public func appearance(in surface: AccountAppearanceSurface) -> RemoteSessionAccountDTO? {
        appearances?[surface.rawValue] ?? presentation
    }
    public var visibleName: String { presentation?.visibleName ?? name }
    /// For example `5h 43% · 7d 73%`.
    public let usageSummary: String?
    /// Peak consumed fraction, 0...1, so clients can tint a compact usage cue consistently.
    public let usageFraction: Double?
    public let usageError: String?
    /// Every limit window of the account, account-wide ones first, then those scoped to a model.
    /// Nil when decoded from a host predating per-window usage; a client then has only
    /// `usageFraction` to draw.
    public let usageWindows: [RemoteAccountUsageWindowDTO]?
    public let models: [RemoteModelChoiceDTO]
    public let defaultModelID: String?

    public init(
        id: String,
        name: String,
        email: String? = nil,
        emoji: String? = nil,
        presentation: RemoteSessionAccountDTO? = nil,
        imagePNG: Data? = nil,
        appearances: [String: RemoteSessionAccountDTO]? = nil,
        images: [String: Data]? = nil,
        usageSummary: String? = nil,
        usageFraction: Double? = nil,
        usageError: String? = nil,
        usageWindows: [RemoteAccountUsageWindowDTO]? = nil,
        models: [RemoteModelChoiceDTO],
        defaultModelID: String?
    ) {
        self.id = id
        self.name = name
        self.email = email
        self.emoji = emoji
        self.presentation = presentation
        self.imagePNG = imagePNG
        self.appearances = appearances
        self.images = images
        self.usageSummary = usageSummary
        self.usageFraction = usageFraction
        self.usageError = usageError
        self.usageWindows = usageWindows
        self.models = models
        self.defaultModelID = defaultModelID
    }
}

public struct RemoteAgentChoiceDTO: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public let name: String
    /// Nil when decoded from a host predating remote account selection.
    public let accounts: [RemoteAccountChoiceDTO]?
    public let models: [RemoteModelChoiceDTO]
    public let defaultModelID: String?
    public let supportsConversation: Bool
    /// Nil when decoded from a host predating remote permission-mode selection.
    public let permissionModes: [RemotePermissionModeChoiceDTO]?

    public init(
        id: String,
        name: String,
        accounts: [RemoteAccountChoiceDTO]? = nil,
        models: [RemoteModelChoiceDTO],
        defaultModelID: String?,
        supportsConversation: Bool,
        permissionModes: [RemotePermissionModeChoiceDTO]? = nil
    ) {
        self.id = id
        self.name = name
        self.accounts = accounts
        self.models = models
        self.defaultModelID = defaultModelID
        self.supportsConversation = supportsConversation
        self.permissionModes = permissionModes
    }
}

/// Choices exposed only to the interactive owner. Guest shares never learn the project list,
/// checkout paths, accounts, or launch configuration.
public struct RemoteNewSessionCatalogDTO: Codable, Equatable, Sendable {
    public let projects: [RemoteProjectChoiceDTO]
    public let agents: [RemoteAgentChoiceDTO]
    /// Whether a create request may ask for `RemoteSessionRole.manager`. Absent from a Mac
    /// built before managers could be started remotely, which a phone reads as "no": the
    /// request field would be ignored there and the chat started as an ordinary one, so the
    /// choice is only offered where it will be honoured.
    public let supportsManagerRole: Bool?

    public init(
        projects: [RemoteProjectChoiceDTO],
        agents: [RemoteAgentChoiceDTO],
        supportsManagerRole: Bool? = nil
    ) {
        self.projects = projects
        self.agents = agents
        self.supportsManagerRole = supportsManagerRole
    }
}

/// The `RemoteCreateSessionRequestDTO.role` vocabulary: what the started session is for.
///
/// Lossless at the wire boundary so a role a newer phone asks for reaches the Mac's validation
/// and is refused as an unknown role rather than collapsing the whole request into malformed
/// JSON. A manager is an ordinary session the Mac confers its project's control grant on — the
/// same thing the Mac's own New Manager template makes — so the role is one word here and the
/// authority stays on the Mac.
public enum RemoteSessionRole: RemoteLosslessStringToken {
    case chat
    case manager
    case unknown(String)

    public init(rawValue: String) {
        switch rawValue {
        case "chat": self = .chat
        case "manager": self = .manager
        default: self = .unknown(rawValue)
        }
    }

    public var rawValue: String {
        switch self {
        case .chat: return "chat"
        case .manager: return "manager"
        case let .unknown(value): return value
        }
    }
}

/// The `RemoteHostEndpointDTO.kind` vocabulary both products know today.
///
/// Unknown cases remain decodable, so a newer Mac can advertise a route an installed phone has
/// never heard of without making that phone reject the whole host payload.
///
/// What each one means, and who can see the traffic on it, is the table in
/// `docs/REMOTE_ACCESS.md` under the security model.
public enum RemoteHostEndpointKind: RemoteLosslessStringToken {
    /// `127.0.0.1`. Reachable from the Mac itself only, and never advertised to another device.
    case loopback
    /// A routable address on a network the Mac is attached to, plus its `.local` name.
    case lan
    /// The address the Mac holds on a VPN tunnel it did not set up.
    case vpn
    /// The Mac's tailnet address or `*.ts.net` name.
    case tailscale
    /// A rendezvous route through the hosted service. No address of the Mac's own.
    case hosted
    /// A public tunnel origin operated by a third party.
    ///
    /// **Legacy vocabulary. No host advertises this any more**, because the Cloudflare Quick
    /// Tunnel behind it is gone: its address changed every launch, so it could not be a route a
    /// phone remembers, and a third party terminated its TLS. The name stays because an installed
    /// phone has records that carry it and decodes this field against `known`; removing it would
    /// change what those records mean rather than what any host sends.
    case relay
    case unknown(String)

    /// Every kind this build understands. A client uses it to notice an unknown kind rather
    /// than to reject one: an endpoint it cannot classify is ignored, not fatal.
    public static let known: Set<Self> = [loopback, lan, vpn, tailscale, hosted, relay]

    /// The kinds that reach the Mac over a network the user is already on, whoever runs it.
    ///
    /// These are the three `privateOnly` admits. They are grouped rather than listed at each call
    /// site because the grouping is the policy: `lan` and `vpn` are the same door with different
    /// addresses on it, and a tailnet address is the Mac's own address too. `hosted` is not here
    /// because it is governed by sign-in rather than by the connection policy, and `relay` is not
    /// here because a third party terminates its TLS.
    public static let privateNetwork: Set<Self> = [lan, vpn, tailscale]

    public init(rawValue: String) {
        switch rawValue {
        case "loopback": self = .loopback
        case "lan": self = .lan
        case "vpn": self = .vpn
        case "tailscale": self = .tailscale
        case "hosted": self = .hosted
        case "relay": self = .relay
        default: self = .unknown(rawValue)
        }
    }

    public var rawValue: String {
        switch self {
        case .loopback: return "loopback"
        case .lan: return "lan"
        case .vpn: return "vpn"
        case .tailscale: return "tailscale"
        case .hosted: return "hosted"
        case .relay: return "relay"
        case let .unknown(value): return value
        }
    }
}

/// How a client establishes trust in what an endpoint presents.
///
/// Absent means public trust: stock system evaluation, which is what a Tailscale Serve endpoint
/// needs, because Serve holds a real certificate for the `*.ts.net` name. `pinned` means the Mac
/// presents its own self-signed identity and the client must compare the leaf certificate's
/// SHA-256 against the fingerprint it learned when it paired.
///
/// It is a field of its own rather than something inferred from `kind` because **one host
/// advertises both at once**: the LAN and VPN addresses carry the Mac's own identity while a
/// Serve endpoint carries a public one, and no phone can be asked to know which host version
/// meant which. Absent is the safe reading for an old host, which only ever advertised endpoints
/// terminated by somebody with a real certificate.
public enum RemoteHostEndpointIdentity: RemoteLosslessStringToken {
    /// The Mac's own certificate. The client checks the fingerprint and nothing else.
    case pinned
    case unknown(String)

    public init(rawValue: String) {
        switch rawValue {
        case "pinned": self = .pinned
        default: self = .unknown(rawValue)
        }
    }

    public var rawValue: String {
        switch self {
        case .pinned: return "pinned"
        case let .unknown(value): return value
        }
    }
}

/// One currently usable route to the Mac's single authenticated remote-access server.
///
/// Endpoints carry no bearer and grant nothing by themselves. A paired client combines one with
/// its device credential only after applying the host's connection policy. `kind` stays a string
/// so an older client can ignore a future transport without failing to decode the whole host;
/// `RemoteHostEndpointKind` names the values this build produces.
public struct RemoteHostEndpointDTO: Codable, Equatable, Hashable, Sendable {
    public let kind: RemoteHostEndpointKind
    public let baseURL: URL
    public let isStable: Bool
    /// `RemoteHostEndpointIdentity.pinned`, or absent for public trust. Optional so an older
    /// phone ignores it and an older Mac, which had nothing to pin, keeps meaning what it said.
    public let identity: RemoteHostEndpointIdentity?

    public init(
        kind: RemoteHostEndpointKind,
        baseURL: URL,
        isStable: Bool,
        identity: RemoteHostEndpointIdentity? = nil
    ) {
        self.kind = kind
        self.baseURL = baseURL
        self.isStable = isStable
        self.identity = identity
    }

    /// Whether this endpoint expects the client to check a fingerprint instead of a CA.
    public var expectsPinnedIdentity: Bool { identity == RemoteHostEndpointIdentity.pinned }
}

/// The connection policy an owner selected on the Mac.
///
/// Unknown values are interpreted by clients as private-only. Adding a policy in a later host
/// must never make an older phone silently route private work through a public endpoint.
///
/// **This enum outlives the setting that produced it.** The Mac's connection modes were replaced
/// by one switch per door, and the relay the other two cases named is gone, so a current host
/// always sends `privateOnly`. `relayOnly` and `preferPrivate` are legacy vocabulary: they stay on
/// the wire because an installed phone decodes this field and maps anything it does not recognise
/// to `privateOnly`; removing a case would change nothing there and deleting the enum would change
/// what those phones read. On a current client all three therefore mean the same fail-closed
/// thing, and only the ordering differs. Do not delete this without an installed base that no
/// longer sends it.
public enum RemoteHostConnectionPolicy: String, Codable, Equatable, Hashable, Sendable {
    case privateOnly
    case relayOnly
    case preferPrivate

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let raw = try container.decode(String.self)
        self = Self(rawValue: raw) ?? .privateOnly
    }
}

/// Selects validated endpoint candidates without knowing about URLSession or credentials.
/// Keeping this pure lets every native client use the same fail-closed ordering.
///
/// Three rules, and each of them has cost something:
///
/// - **`https` only.** A cleartext candidate is dropped whatever its kind, which is what kept a
///   `lan` endpoint out of use for the whole of the phase before the listener had an identity.
/// - **`privateOnly` admits every private-network kind**, not just the one this file was written
///   for. `lan`, `vpn` and `tailscale` are all addresses of the Mac on a network the user is
///   already on; before doors existed only `tailscale` could be, so only that one was listed.
/// - **No preference between the private kinds.** They tie on rank and fall to a deterministic
///   URL order, because which of a Mac's own addresses is reachable is a fact about where the
///   phone is standing, and the phone finds that out by trying them in order.
public enum RemoteHostEndpointSelection {
    public static func ordered(
        _ endpoints: [RemoteHostEndpointDTO],
        policy: RemoteHostConnectionPolicy,
        currentBaseURL: URL? = nil
    ) -> [RemoteHostEndpointDTO] {
        let valid = endpoints.filter { endpoint in
            guard let link = RemoteConnectionLink(baseURL: endpoint.baseURL, token: "candidate")
            else { return false }
            return link.baseURL.scheme?.lowercased() == "https"
        }

        let allowed: [RemoteHostEndpointDTO]
        switch policy {
        case .privateOnly:
            allowed = valid.filter { RemoteHostEndpointKind.privateNetwork.contains($0.kind) }
        case .relayOnly:
            allowed = valid.filter { $0.kind == RemoteHostEndpointKind.relay }
        case .preferPrivate:
            allowed = valid.filter {
                RemoteHostEndpointKind.privateNetwork.contains($0.kind)
                    || $0.kind == RemoteHostEndpointKind.relay
            }
        }

        return allowed.sorted { lhs, rhs in
            func rank(_ endpoint: RemoteHostEndpointDTO) -> Int {
                switch policy {
                case .privateOnly, .relayOnly:
                    // A newly advertised stable endpoint replaces a remembered unstable one
                    // without asking the user to pair the same Mac again.
                    return endpoint.isStable ? 0 : (endpoint.baseURL == currentBaseURL ? 1 : 2)
                case .preferPrivate:
                    if RemoteHostEndpointKind.privateNetwork.contains(endpoint.kind) { return 0 }
                    if endpoint.isStable { return 1 }
                    if endpoint.baseURL == currentBaseURL { return 2 }
                    return 3
                }
            }
            let left = rank(lhs)
            let right = rank(rhs)
            if left != right { return left < right }
            return lhs.baseURL.absoluteString < rhs.baseURL.absoluteString
        }
    }
}

/// The Mac serving a share. Its stable id lets an iOS client replace the existing paired-device
/// record when the user rescans a short-lived relay URL after a later launch. Owner responses may
/// also advertise several routes to that identity; guest responses deliberately omit them.
public struct RemoteHostDTO: Codable, Equatable, Sendable {
    public let id: String
    public let name: String
    public let platform: String
    public let endpoints: [RemoteHostEndpointDTO]?
    public let connectionPolicy: RemoteHostConnectionPolicy?
    /// SHA-256 over the DER of the certificate this Mac's pinned endpoints present, as 64
    /// lower-case hex characters. Absent when nothing is pinned.
    ///
    /// Hex rather than base64 because this value is read in support reports and typed into
    /// comparisons by hand, and because the QR spelling is a different length anyway: the code on
    /// the screen is the first 128 bits in base32, and `RemoteHostFingerprint` owns both. Owner
    /// responses only. A guest never learns it, for the same reason a guest never learns the
    /// endpoint list.
    public let pinnedFingerprint: String?
    /// The successor identity this Mac has minted but not yet started presenting, in the same
    /// spelling.
    ///
    /// Arriving over an already pinned connection makes it the holder of the current private key
    /// saying what the next one will be, which is what lets a certificate be replaced without
    /// every paired device re-scanning a code. A client ignores it on any other connection.
    public let nextPinnedFingerprint: String?

    public init(
        id: String,
        name: String,
        platform: String = "macOS",
        endpoints: [RemoteHostEndpointDTO]? = nil,
        connectionPolicy: RemoteHostConnectionPolicy? = nil,
        pinnedFingerprint: String? = nil,
        nextPinnedFingerprint: String? = nil
    ) {
        self.id = id
        self.name = name
        self.platform = platform
        self.endpoints = endpoints
        self.connectionPolicy = connectionPolicy
        self.pinnedFingerprint = pinnedFingerprint
        self.nextPinnedFingerprint = nextPinnedFingerprint
    }

    /// The pins a client should hold for this host, or nil when it advertises none.
    public var pinSet: RemoteHostPinSet? {
        guard let pinnedFingerprint, let current = RemoteHostPin(hex: pinnedFingerprint) else {
            return nil
        }
        return RemoteHostPinSet(
            current: current,
            next: nextPinnedFingerprint.flatMap(RemoteHostPin.init(hex:))
        )
    }
}

/// Optional REST surfaces advertised by `GET /api/me`. Raw strings keep discovery additive:
/// older clients ignore the field and newer clients can ignore feature names they do not know.
public enum RemoteRESTFeature: String, Codable, CaseIterable, Sendable {
    case usageCapacity = "usage-capacity"
    /// Owner-device search across the Mac's bounded structured and indexed providers. Results
    /// carry short-lived opaque resolution tokens rather than host-side locator identities.
    case universalSearch = "universal-search"
    case usageDashboard = "usage-dashboard"
    case hostedPeerTransport = "hosted-peer-transport"
    /// A session socket may authenticate while a create/resume transaction is still installing
    /// its live surface. The host holds that socket and completes the ordinary `hello` handshake
    /// when the surface exists, so clients never poll the complete catalogue for readiness.
    case sessionStartupHandshake = "session-startup-handshake"
    /// `attachment-thumbnail` answers: a small, bounded raster of an image or a PDF's first
    /// page, for the gallery's ledger. A phone paired with a Mac that does not say so draws the
    /// kind's glyph in each cell and asks for no bytes.
    case attachmentThumbnails = "attachment-thumbnails"
    /// The ordinary attachment route accepts authenticated HTTP byte ranges for a movie, so the
    /// phone can hand AVFoundation small pieces instead of downloading a recording into memory.
    /// Older Macs omit large movies from the list and advertise no player.
    case attachmentVideoStreaming = "attachment-video-streaming"
    /// A report sent from the paired iPhone can create a session with readable opening text and
    /// one bounded screenshot that the Mac takes into attachment custody before launch.
    case reportSessionOpening = "report-session-opening"
    /// The new-session draft may stage files before the Mac has minted the session, then name
    /// those uploads in the atomic create request that takes them into the opening prompt.
    case sessionDraftAttachmentUploads = "session-draft-attachment-uploads"
    /// `session/<id>/continuation` answers where a chat could continue on another agent, and
    /// creates that chat. A phone paired with a Mac that does not say so offers no such control
    /// and asks nothing — the alternative was one 404 per Chat Settings screen, reported as a
    /// degraded action for a Mac that is simply older.
    case sessionContinuation = "session-continuation"
}

/// The size a thumbnail is asked at, and the most a Mac will answer with.
///
/// One number on both sides: the phone draws the cell at a fixed size and asks for twice that in
/// pixels, the Mac clamps to this regardless of what was asked, so a client cannot turn the
/// thumbnail route into a second full-size route.
public enum RemoteAttachmentThumbnail {
    public static let maximumPixelDimension = 256
}

/// The largest piece of a movie one authenticated range request may return.
///
/// AVFoundation can ask for the rest of a file in one request. The resource loader walks that
/// request through bounded pieces and responds to the decoder as each one arrives, so neither
/// side ever turns "stream this movie" into "hold this movie".
public enum RemoteAttachmentVideo {
    public static let maximumChunkBytes = 1 * 1024 * 1024
}

/// A device-bound hosted rendezvous credential issued by the paired Mac. The ordinary remote
/// capability remains separate and still authorizes every HTTP/WebSocket operation after the
/// direct tunnel reaches the Mac's loopback server.
public struct RemoteHostedDeviceCredentialDTO: Codable, Equatable, Sendable {
    public let serviceURL: String
    public let hostID: String
    public let deviceID: String
    public let credential: String
    /// Milliseconds since Unix epoch, matching the hosted service contract.
    public let expiresAt: Double

    public init(
        serviceURL: String,
        hostID: String,
        deviceID: String,
        credential: String,
        expiresAt: Double
    ) {
        self.serviceURL = serviceURL
        self.hostID = hostID
        self.deviceID = deviceID
        self.credential = credential
        self.expiresAt = expiresAt
    }
}

public struct RemoteHostedDeviceCredentialRequestDTO: Codable, Equatable, Sendable {
    public init() {}
}

// MARK: - Usage dashboard

/// Provider-neutral token categories. Reasoning is included in output and must not be added to
/// `processed` a second time.
public struct RemoteUsageTokenCountsDTO: Codable, Equatable, Sendable {
    public let uncachedInput: Int64
    public let cachedInput: Int64
    public let cacheWrite: Int64
    public let output: Int64
    public let reasoning: Int64

    public init(
        uncachedInput: Int64,
        cachedInput: Int64,
        cacheWrite: Int64,
        output: Int64,
        reasoning: Int64
    ) {
        self.uncachedInput = uncachedInput
        self.cachedInput = cachedInput
        self.cacheWrite = cacheWrite
        self.output = output
        self.reasoning = reasoning
    }

    public var processed: Int64 { uncachedInput + cachedInput + cacheWrite + output }
}

public struct RemoteUsageCostQualityDTO: Codable, Equatable, Sendable {
    public let providerReportedUSD: Double
    public let catalogPricedUSD: Double
    public let unpricedTokens: Int64
    public let cacheSavingsUSD: Double

    public init(
        providerReportedUSD: Double,
        catalogPricedUSD: Double,
        unpricedTokens: Int64,
        cacheSavingsUSD: Double
    ) {
        self.providerReportedUSD = providerReportedUSD
        self.catalogPricedUSD = catalogPricedUSD
        self.unpricedTokens = unpricedTokens
        self.cacheSavingsUSD = cacheSavingsUSD
    }

    public var totalUSD: Double { providerReportedUSD + catalogPricedUSD }
}

public enum RemoteUsageBreakdownKindDTO: String, Codable, CaseIterable, Sendable {
    case models
    case projects
    case accounts
    case providers
}

public struct RemoteUsageBreakdownRowDTO: Codable, Equatable, Sendable {
    public let title: String
    public let tokens: Int64
    public let costUSD: Double
    public let records: Int

    public init(title: String, tokens: Int64, costUSD: Double, records: Int) {
        self.title = title
        self.tokens = tokens
        self.costUSD = costUSD
        self.records = records
    }
}

public struct RemoteUsageBreakdownDTO: Codable, Equatable, Sendable {
    public let kind: RemoteUsageBreakdownKindDTO
    public let rows: [RemoteUsageBreakdownRowDTO]
    public let omittedRowCount: Int
    public let omittedTokens: Int64
    public let omittedCostUSD: Double
    public let omittedRecords: Int

    public init(
        kind: RemoteUsageBreakdownKindDTO,
        rows: [RemoteUsageBreakdownRowDTO],
        omittedRowCount: Int,
        omittedTokens: Int64,
        omittedCostUSD: Double,
        omittedRecords: Int
    ) {
        self.kind = kind
        self.rows = rows
        self.omittedRowCount = omittedRowCount
        self.omittedTokens = omittedTokens
        self.omittedCostUSD = omittedCostUSD
        self.omittedRecords = omittedRecords
    }
}

public struct RemoteUsageProviderDTO: Codable, Equatable, Sendable {
    public let id: String
    public let name: String
    public let tokens: RemoteUsageTokenCountsDTO
    public let costUSD: Double
    public let records: Int
    public let styleIndex: Int

    public init(
        id: String,
        name: String,
        tokens: RemoteUsageTokenCountsDTO,
        costUSD: Double,
        records: Int,
        styleIndex: Int
    ) {
        self.id = id
        self.name = name
        self.tokens = tokens
        self.costUSD = costUSD
        self.records = records
        self.styleIndex = styleIndex
    }
}

public struct RemoteUsageChartPointDTO: Codable, Equatable, Sendable {
    public let at: Double
    public let value: Double

    public init(at: Double, value: Double) {
        self.at = at
        self.value = value
    }
}

public struct RemoteUsageChartSeriesDTO: Codable, Equatable, Sendable {
    public let id: String
    public let title: String?
    public let isOther: Bool
    public let styleIndex: Int
    public let points: [RemoteUsageChartPointDTO]

    public init(
        id: String,
        title: String?,
        isOther: Bool,
        styleIndex: Int,
        points: [RemoteUsageChartPointDTO]
    ) {
        self.id = id
        self.title = title
        self.isOther = isOther
        self.styleIndex = styleIndex
        self.points = points
    }
}

public struct RemoteUsageMetricProjectionDTO: Codable, Equatable, Sendable {
    public let providers: [RemoteUsageProviderDTO]
    public let chartSeries: [RemoteUsageChartSeriesDTO]

    public init(
        providers: [RemoteUsageProviderDTO],
        chartSeries: [RemoteUsageChartSeriesDTO]
    ) {
        self.providers = providers
        self.chartSeries = chartSeries
    }
}

public struct RemoteUsageRangeDTO: Codable, Equatable, Sendable {
    public let days: Int
    public let start: Double
    public let end: Double
    public let tokens: RemoteUsageTokenCountsDTO
    public let records: Int
    public let cost: RemoteUsageCostQualityDTO
    public let activeDayCount: Int
    public let costMetric: RemoteUsageMetricProjectionDTO
    public let tokenMetric: RemoteUsageMetricProjectionDTO
    public let breakdowns: [RemoteUsageBreakdownDTO]

    public init(
        days: Int,
        start: Double,
        end: Double,
        tokens: RemoteUsageTokenCountsDTO,
        records: Int,
        cost: RemoteUsageCostQualityDTO,
        activeDayCount: Int,
        costMetric: RemoteUsageMetricProjectionDTO,
        tokenMetric: RemoteUsageMetricProjectionDTO,
        breakdowns: [RemoteUsageBreakdownDTO]
    ) {
        self.days = days
        self.start = start
        self.end = end
        self.tokens = tokens
        self.records = records
        self.cost = cost
        self.activeDayCount = activeDayCount
        self.costMetric = costMetric
        self.tokenMetric = tokenMetric
        self.breakdowns = breakdowns
    }
}

public struct RemoteUsageCoverageDTO: Codable, Equatable, Sendable {
    public let runtimeID: String
    public let runtimeName: String
    public let state: RemoteUsageCoverageState
    public let sourceCount: Int
    public let recordCount: Int
    public let detail: String?

    public init(
        runtimeID: String,
        runtimeName: String,
        state: RemoteUsageCoverageState,
        sourceCount: Int,
        recordCount: Int,
        detail: String?
    ) {
        self.runtimeID = runtimeID
        self.runtimeName = runtimeName
        self.state = state
        self.sourceCount = sourceCount
        self.recordCount = recordCount
        self.detail = detail
    }
}

public struct RemoteUsageLimitSeriesSummaryDTO: Codable, Equatable, Sendable, Identifiable {
    public let accountID: String?
    public let id: String
    public let runtimeName: String
    public let accountName: String
    public let windowLabel: String
    public let currentFraction: Double?
    public let resetsAt: Double?
    /// The full provider window length, when known. Together with `resetsAt`, this lets a
    /// renderer place the current clock position on the usage bar without receiving history.
    public let windowDuration: Double?
    /// Nil means the provider did not report inventory; zero is authoritative empty inventory.
    public let bankedResetCount: Int?
    public let nextBankedResetExpiresAt: Double?
    /// Optional for compatibility with hosts that exposed inventory before redemption existed.
    public let canRedeemBankedReset: Bool?

    public init(
        id: String,
        accountID: String? = nil,
        runtimeName: String,
        accountName: String,
        windowLabel: String,
        currentFraction: Double?,
        resetsAt: Double?,
        windowDuration: Double? = nil,
        bankedResetCount: Int?,
        nextBankedResetExpiresAt: Double?,
        canRedeemBankedReset: Bool? = nil
    ) {
        self.id = id
        self.accountID = accountID
        self.runtimeName = runtimeName
        self.accountName = accountName
        self.windowLabel = windowLabel
        self.currentFraction = currentFraction
        self.resetsAt = resetsAt
        self.windowDuration = windowDuration
        self.bankedResetCount = bankedResetCount
        self.nextBankedResetExpiresAt = nextBankedResetExpiresAt
        self.canRedeemBankedReset = canRedeemBankedReset
    }

    public var title: String { "\(runtimeName) · \(accountName) · \(windowLabel)" }
}

/// The authoritative offer a paired owner reviews before sending the mutation.
public struct RemoteBankedUsageResetOfferDTO: Codable, Equatable, Sendable {
    public let seriesID: String
    public let accountName: String
    public let availableCount: Int
    /// Opaque binding over the host account and selected provider credit. Raw identities stay on
    /// the Mac; the phone returns this unchanged after confirmation.
    public let offerFingerprint: String
    public let selectedCreditTitle: String?
    public let selectedCreditExpiresAt: Double?
    public let letsProviderChooseCredit: Bool
    public let eligibleWindowLabels: [String]
    public let owedContinuationCount: Int

    public init(
        seriesID: String,
        accountName: String,
        availableCount: Int,
        offerFingerprint: String,
        selectedCreditTitle: String?,
        selectedCreditExpiresAt: Double?,
        letsProviderChooseCredit: Bool,
        eligibleWindowLabels: [String],
        owedContinuationCount: Int
    ) {
        self.seriesID = seriesID
        self.accountName = accountName
        self.availableCount = availableCount
        self.offerFingerprint = offerFingerprint
        self.selectedCreditTitle = selectedCreditTitle
        self.selectedCreditExpiresAt = selectedCreditExpiresAt
        self.letsProviderChooseCredit = letsProviderChooseCredit
        self.eligibleWindowLabels = eligibleWindowLabels
        self.owedContinuationCount = owedContinuationCount
    }
}

/// Repeats the reviewed selection so the host can fail closed if inventory changed between the
/// phone's confirmation and the app-server preflight.
public struct RemoteBankedUsageResetRequestDTO: Codable, Equatable, Sendable {
    public let seriesID: String
    public let availableCount: Int
    public let offerFingerprint: String
    public let letsProviderChooseCredit: Bool

    public init(
        seriesID: String,
        availableCount: Int,
        offerFingerprint: String,
        letsProviderChooseCredit: Bool
    ) {
        self.seriesID = seriesID
        self.availableCount = availableCount
        self.offerFingerprint = offerFingerprint
        self.letsProviderChooseCredit = letsProviderChooseCredit
    }
}

public enum RemoteBankedUsageResetOutcome: String, Codable, Equatable, Sendable {
    case reset
    case alreadyRedeemed
    case nothingToReset
    case noCredit
}

public struct RemoteBankedUsageResetResponseDTO: Codable, Equatable, Sendable {
    public let outcome: RemoteBankedUsageResetOutcome
    public let remainingCreditCount: Int?
    public let releasedContinuationCount: Int
    public let hasVerifiedHeadroom: Bool
    public let continuationReleaseFailed: Bool

    public init(
        outcome: RemoteBankedUsageResetOutcome,
        remainingCreditCount: Int?,
        releasedContinuationCount: Int,
        hasVerifiedHeadroom: Bool,
        continuationReleaseFailed: Bool
    ) {
        self.outcome = outcome
        self.remainingCreditCount = remainingCreditCount
        self.releasedContinuationCount = releasedContinuationCount
        self.hasVerifiedHeadroom = hasVerifiedHeadroom
        self.continuationReleaseFailed = continuationReleaseFailed
    }
}

/// The bounded `GET /api/usage` response. The limit index is one page; `nextLimitCursor` is
/// passed back unchanged to request the next page.
public struct RemoteUsageDashboardDTO: Codable, Equatable, Sendable {
    public let isBuilding: Bool
    public let builtAt: Double?
    public let pricingCatalogVersion: String?
    public let ranges: [RemoteUsageRangeDTO]
    public let coverage: [RemoteUsageCoverageDTO]
    public let limitSeries: [RemoteUsageLimitSeriesSummaryDTO]
    public let nextLimitCursor: String?
    public let omittedLimitSeriesCount: Int
    public let preparedAt: Double

    public init(
        isBuilding: Bool,
        builtAt: Double?,
        pricingCatalogVersion: String?,
        ranges: [RemoteUsageRangeDTO],
        coverage: [RemoteUsageCoverageDTO],
        limitSeries: [RemoteUsageLimitSeriesSummaryDTO],
        nextLimitCursor: String?,
        omittedLimitSeriesCount: Int,
        preparedAt: Double
    ) {
        self.isBuilding = isBuilding
        self.builtAt = builtAt
        self.pricingCatalogVersion = pricingCatalogVersion
        self.ranges = ranges
        self.coverage = coverage
        self.limitSeries = limitSeries
        self.nextLimitCursor = nextLimitCursor
        self.omittedLimitSeriesCount = omittedLimitSeriesCount
        self.preparedAt = preparedAt
    }
}

public struct RemoteUsageLimitPointDTO: Codable, Equatable, Sendable {
    public let at: Double
    public let fraction: Double
    public let segment: Int

    public init(at: Double, fraction: Double, segment: Int) {
        self.at = at
        self.fraction = fraction
        self.segment = segment
    }
}

public struct RemoteUsageLimitProjectionDTO: Codable, Equatable, Sendable {
    public let observedAt: Double
    public let observedFraction: Double
    public let resetsAt: Double
    public let projectedFractionAtReset: Double
    public let projectedExhaustionAt: Double?
    public let bankedResetExpiresAt: Double?

    public init(
        observedAt: Double,
        observedFraction: Double,
        resetsAt: Double,
        projectedFractionAtReset: Double,
        projectedExhaustionAt: Double?,
        bankedResetExpiresAt: Double?
    ) {
        self.observedAt = observedAt
        self.observedFraction = observedFraction
        self.resetsAt = resetsAt
        self.projectedFractionAtReset = projectedFractionAtReset
        self.projectedExhaustionAt = projectedExhaustionAt
        self.bankedResetExpiresAt = bankedResetExpiresAt
    }
}

public struct RemoteUsageLimitResetDTO: Codable, Equatable, Sendable, Identifiable {
    public let id: String
    public let detectedAt: Double
    public let previousObservedAt: Double
    public let cause: RemoteUsageLimitResetCause
    public let restoredFraction: Double
    public let elapsedFraction: Double
    public let paceGainFraction: Double

    public init(
        id: String,
        detectedAt: Double,
        previousObservedAt: Double,
        cause: RemoteUsageLimitResetCause,
        restoredFraction: Double,
        elapsedFraction: Double,
        paceGainFraction: Double
    ) {
        self.id = id
        self.detectedAt = detectedAt
        self.previousObservedAt = previousObservedAt
        self.cause = cause
        self.restoredFraction = restoredFraction
        self.elapsedFraction = elapsedFraction
        self.paceGainFraction = paceGainFraction
    }
}

/// One selected and already-downsampled limit range. Historical reset markers remain distinct
/// from current banked-reset inventory and projected/expiry timestamps.
public struct RemoteUsageLimitDTO: Codable, Equatable, Sendable {
    public let series: RemoteUsageLimitSeriesSummaryDTO
    public let days: Int
    public let start: Double
    public let end: Double
    public let observed: [RemoteUsageLimitPointDTO]
    public let resets: [RemoteUsageLimitResetDTO]
    public let recordedResetCount: Int
    public let restoredPaceFraction: Double
    public let projection: RemoteUsageLimitProjectionDTO?
    public let preparedAt: Double

    public init(
        series: RemoteUsageLimitSeriesSummaryDTO,
        days: Int,
        start: Double,
        end: Double,
        observed: [RemoteUsageLimitPointDTO],
        resets: [RemoteUsageLimitResetDTO],
        recordedResetCount: Int,
        restoredPaceFraction: Double,
        projection: RemoteUsageLimitProjectionDTO?,
        preparedAt: Double
    ) {
        self.series = series
        self.days = days
        self.start = start
        self.end = end
        self.observed = observed
        self.resets = resets
        self.recordedResetCount = recordedResetCount
        self.restoredPaceFraction = restoredPaceFraction
        self.projection = projection
        self.preparedAt = preparedAt
    }
}

/// The `GET /api/me` payload: the protocol the server speaks, what this share is, and the remote
/// targets it reaches. The protocol pair is included so a client can verify compatibility even
/// on a request the server chose to answer.
public struct RemoteMeDTO: Codable, Equatable, Sendable {
    public struct Share: Codable, Equatable, Sendable {
        public let label: String
        public let scope: RemoteShareScope
        public let capability: RemoteAdvertisedCapability
        /// Independently granted per chat member. An interactive guest may collaborate without
        /// this right, or be trusted to review requests caused by their work.
        public let canApprovePermissions: Bool
        public let expiresAt: Double?
        public let memberID: String?
        public let displayName: String?

        public init(
            label: String,
            scope: RemoteShareScope,
            capability: RemoteAdvertisedCapability,
            canApprovePermissions: Bool = false,
            expiresAt: Double?,
            memberID: String? = nil,
            displayName: String? = nil
        ) {
            self.label = label
            self.scope = scope
            self.capability = capability
            self.canApprovePermissions = canApprovePermissions
            self.expiresAt = expiresAt
            self.memberID = memberID
            self.displayName = displayName
        }

        private enum CodingKeys: String, CodingKey {
            case label, scope, capability, canApprovePermissions, expiresAt
            case memberID, displayName
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            label = try container.decode(String.self, forKey: .label)
            scope = try container.decode(RemoteShareScope.self, forKey: .scope)
            capability = try container.decode(RemoteAdvertisedCapability.self, forKey: .capability)
            canApprovePermissions = try container.decodeIfPresent(
                Bool.self,
                forKey: .canApprovePermissions
            ) ?? false
            expiresAt = try container.decodeIfPresent(Double.self, forKey: .expiresAt)
            memberID = try container.decodeIfPresent(String.self, forKey: .memberID)
            displayName = try container.decodeIfPresent(String.self, forKey: .displayName)
        }
    }

    public let serverProtocol: RemoteProtocolInfo
    public let share: Share
    public let sessions: [RemoteSessionSummaryDTO]
    /// Standalone shells this capability reaches. Optional keeps older hosts and clients
    /// mutually decodable while preserving the session/terminal identity boundary.
    public let terminals: [RemoteProjectTerminalSummaryDTO]?
    /// Optional so a version-1 client can still decode a response from the first macOS build.
    public let host: RemoteHostDTO?
    /// Optional so new clients retain their local fallback against an older host.
    public let theme: RemoteThemeDTO?
    /// Present only for an interactive owner share. Older clients ignore it.
    public let themeCatalog: RemoteThemeCatalogDTO?
    /// Archived sessions remain out of guest payloads and the active list.
    public let archivedSessions: [RemoteSessionSummaryDTO]?
    /// Present only for an interactive owner, which is the only share that may create tasks.
    public let newSessionCatalog: RemoteNewSessionCatalogDTO?
    /// Optional host-wide reads available to this authorization. Guest responses omit it.
    public let features: [String]?
    /// Which edition of the catalogue this is. A client sends it back as `If-None-Match` and
    /// compares it against the revision every `sessionsChanged` delta carries. Absent from an
    /// older host, which a client reads as "always fetch in full".
    public let revision: RemoteCatalogueRevisionDTO?

    public init(
        serverProtocol: RemoteProtocolInfo,
        share: Share,
        sessions: [RemoteSessionSummaryDTO],
        terminals: [RemoteProjectTerminalSummaryDTO]? = nil,
        host: RemoteHostDTO? = nil,
        theme: RemoteThemeDTO? = nil,
        themeCatalog: RemoteThemeCatalogDTO? = nil,
        archivedSessions: [RemoteSessionSummaryDTO]? = nil,
        newSessionCatalog: RemoteNewSessionCatalogDTO? = nil,
        features: [String]? = nil,
        revision: RemoteCatalogueRevisionDTO? = nil
    ) {
        self.serverProtocol = serverProtocol
        self.share = share
        self.sessions = sessions
        self.terminals = terminals
        self.host = host
        self.theme = theme
        self.themeCatalog = themeCatalog
        self.archivedSessions = archivedSessions
        self.newSessionCatalog = newSessionCatalog
        self.features = features
        self.revision = revision
    }
}

/// Selects the app chrome shared by the Mac and its paired devices.
public struct RemoteSetAppThemeRequestDTO: Codable, Equatable, Sendable {
    public let themeID: String

    public init(themeID: String) {
        self.themeID = themeID
    }
}

/// Selects one session's terminal palette. Nil clears the session override so it inherits.
public struct RemoteSetTerminalThemeRequestDTO: Codable, Equatable, Sendable {
    public let themeID: String?

    public init(themeID: String?) {
        self.themeID = themeID
    }
}

public struct RemoteCreateShareRequestDTO: Codable, Equatable, Sendable {
    public let capability: RemoteCapability
    /// An independent, chat-scoped right. Ignored unless capability is `interact`.
    public let canApprovePermissions: Bool

    public init(capability: RemoteCapability, canApprovePermissions: Bool = false) {
        self.capability = capability
        self.canApprovePermissions = canApprovePermissions
    }

    private enum CodingKeys: String, CodingKey {
        case capability, canApprovePermissions
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        capability = try container.decode(RemoteCapability.self, forKey: .capability)
        canApprovePermissions = try container.decodeIfPresent(
            Bool.self,
            forKey: .canApprovePermissions
        ) ?? false
    }
}

public struct RemoteCreateShareResponseDTO: Codable, Equatable, Sendable {
    public let url: String
    public let capability: RemoteAdvertisedCapability
    public let canApprovePermissions: Bool
    /// Expiry of the unused invitation. An accepted membership has no timer.
    public let expiresAt: Double
    public let me: RemoteMeDTO

    public init(
        url: String,
        capability: RemoteAdvertisedCapability,
        canApprovePermissions: Bool = false,
        expiresAt: Double,
        me: RemoteMeDTO
    ) {
        self.url = url
        self.capability = capability
        self.canApprovePermissions = canApprovePermissions
        self.expiresAt = expiresAt
        self.me = me
    }
}

public struct RemoteAcceptInvitationRequestDTO: Codable, Equatable, Sendable {
    public let displayName: String

    public init(displayName: String) {
        self.displayName = displayName
    }
}

public struct RemoteAcceptInvitationResponseDTO: Codable, Equatable, Sendable {
    /// A fresh device-bound membership bearer. It replaces the single-use invite fragment.
    public let accessToken: String
    public let me: RemoteMeDTO

    public init(accessToken: String, me: RemoteMeDTO) {
        self.accessToken = accessToken
        self.me = me
    }
}

public struct RemoteRevokeSharesRequestDTO: Codable, Equatable, Sendable {
    public init() {}
}

/// The one content-bearing item a phone report may hand to a newly created Mac session.
///
/// JPEG is fixed rather than declared by the client, and the byte ceiling is the public-report
/// preview ceiling. The same reviewed preview can therefore go to either destination without a
/// second image policy or a filename controlled by the network.
public struct RemoteReportScreenshotDTO: Codable, Equatable, Sendable {
    public let jpegBase64: String

    public init(jpegBase64: String) {
        self.jpegBase64 = jpegBase64
    }
}

public enum RemoteReportScreenshotPolicy {
    public static func jpegData(from screenshot: RemoteReportScreenshotDTO) -> Data? {
        guard let data = Data(base64Encoded: screenshot.jpegBase64, options: []),
              data.count >= 3,
              data.count <= PublicIssueReportPolicy.maximumScreenshotPreviewBytes,
              data.starts(with: [0xFF, 0xD8, 0xFF])
        else {
            return nil
        }
        return data
    }
}

/// An all-or-nothing report opening understood by current Mac hosts.
///
/// The request's legacy `prompt` is empty when this value is present. A Mac predating this DTO
/// ignores the unknown field and refuses that empty prompt instead of launching a session that
/// silently lost the screenshot or received its base64 as prose.
public struct RemoteReportSessionOpeningDTO: Codable, Equatable, Sendable {
    public let prompt: String
    public let screenshot: RemoteReportScreenshotDTO?

    public init(prompt: String, screenshot: RemoteReportScreenshotDTO? = nil) {
        self.prompt = prompt
        self.screenshot = screenshot
    }
}

public struct RemoteCreateSessionRequestDTO: Codable, Equatable, Sendable {
    public let projectID: String
    public let agentKind: String
    /// `default`, an alternate account handle, or nil for older clients.
    public let accountHandle: String?
    public let model: String?
    public let reasoningEffort: String?
    public let fastMode: Bool?
    public let permissionMode: String?
    public let surface: RemoteSessionSurface
    /// An isolated worktree to run in, normally the one the catalogue's `reportLaunch` offered.
    /// Absent means the project's own checkout, which is what every client asked for before
    /// this field existed.
    public let managedWorkspace: RemoteManagedWorkspacePlanDTO?
    /// `RemoteSessionRole.chat` or `.manager`. Absent is a chat, which is what every client
    /// asked for before this field existed.
    public let role: RemoteSessionRole?
    /// A paired-iPhone report's atomic opening. When present, `prompt` must be empty.
    public let reportOpening: RemoteReportSessionOpeningDTO?
    /// The client-minted draft UUID used to scope uploads before a session exists. It has no
    /// authority of its own: every upload is also bound to the paired device, and the server
    /// claims the ids below against this exact scope during creation.
    public let openingAttachmentScopeID: String?
    /// Completed staged uploads to take into attachment custody before launching the session.
    /// Nil is the legacy request and an empty array carries no files.
    public let openingAttachmentUploadIDs: [String]?
    /// New clients ask for the one changed row. Absent keeps the original full-catalogue response
    /// for older clients whose decoder requires `me`.
    public let compactResponse: Bool?
    public let prompt: String

    public init(
        projectID: String,
        agentKind: String,
        accountHandle: String? = nil,
        model: String? = nil,
        reasoningEffort: String? = nil,
        fastMode: Bool? = nil,
        permissionMode: String? = nil,
        surface: RemoteSessionSurface,
        managedWorkspace: RemoteManagedWorkspacePlanDTO? = nil,
        role: RemoteSessionRole? = nil,
        reportOpening: RemoteReportSessionOpeningDTO? = nil,
        openingAttachmentScopeID: String? = nil,
        openingAttachmentUploadIDs: [String]? = nil,
        compactResponse: Bool? = nil,
        prompt: String
    ) {
        self.projectID = projectID
        self.agentKind = agentKind
        self.accountHandle = accountHandle
        self.model = model
        self.reasoningEffort = reasoningEffort
        self.fastMode = fastMode
        self.permissionMode = permissionMode
        self.surface = surface
        self.managedWorkspace = managedWorkspace
        self.role = role
        self.reportOpening = reportOpening
        self.openingAttachmentScopeID = openingAttachmentScopeID
        self.openingAttachmentUploadIDs = openingAttachmentUploadIDs
        self.compactResponse = compactResponse
        self.prompt = prompt
    }
}

public enum RemoteSessionStartupState: String, Codable, Equatable, Sendable {
    /// The durable row exists and its launch transaction owns bringing the live surface up.
    case starting
    case ready
}

public struct RemoteCreateSessionResponseDTO: Codable, Equatable, Sendable {
    public let sessionID: String
    /// The legacy response. Still emitted when an older client does not request a compact row.
    public let me: RemoteMeDTO?
    /// The O(changed) response requested by current clients.
    public let session: RemoteSessionSummaryDTO?
    /// Present with a compact response so the client never infers readiness from a stale row.
    public let startup: RemoteSessionStartupState?

    public init(sessionID: String, me: RemoteMeDTO) {
        self.sessionID = sessionID
        self.me = me
        session = nil
        startup = nil
    }

    public init(
        sessionID: String,
        session: RemoteSessionSummaryDTO,
        startup: RemoteSessionStartupState
    ) {
        self.sessionID = sessionID
        me = nil
        self.session = session
        self.startup = startup
    }
}

public struct RemoteRenameSessionRequestDTO: Codable, Equatable, Sendable {
    public let title: String

    public init(title: String) {
        self.title = title
    }
}

public struct RemoteSetSessionPinnedRequestDTO: Codable, Equatable, Sendable {
    public let isPinned: Bool

    public init(isPinned: Bool) {
        self.isPinned = isPinned
    }
}

public struct RemoteSetSessionArchivedRequestDTO: Codable, Equatable, Sendable {
    public let isArchived: Bool

    public init(isArchived: Bool) {
        self.isArchived = isArchived
    }
}

/// A Unix deadline snoozes; nil reverses it. The host remains authoritative for the start time
/// and current activity snapshot, so clients cannot forge a stale-failure boundary.
public struct RemoteSetSessionSnoozeRequestDTO: Codable, Equatable, Sendable {
    public let snoozedUntil: Double?

    public init(snoozedUntil: Double?) {
        self.snoozedUntil = snoozedUntil
    }
}

public struct RemoteSetSessionSurfaceRequestDTO: Codable, Equatable, Sendable {
    public let surface: RemoteSessionSurface

    public init(surface: RemoteSessionSurface) {
        self.surface = surface
    }
}

/// Moves a resumable conversation to another login of the same runtime.
public struct RemoteMoveSessionAccountRequestDTO: Codable, Equatable, Sendable {
    public let accountID: String

    public init(accountID: String) {
        self.accountID = accountID
    }
}

/// One place a conversation could continue when the destination is another provider.
///
/// The Mac owns eligibility — whether the source has anything recorded to hand over, whether the
/// destination runtime can receive it, whether the scoped history tool is enabled — so a phone
/// never reproduces that rule from a catalogue it happens to hold. Owner-only, like the account
/// catalogue these names come from.
public struct RemoteContinuationDestinationDTO: Codable, Equatable, Identifiable, Sendable {
    public let agentID: String
    public let agentName: String
    /// Nil for a runtime whose logins Threading does not route, which then has exactly one.
    public let accountID: String?
    /// The login's display name, absent for the same reason `accountID` is.
    public let accountName: String?
    public let emoji: String?

    /// Stable within one options response, which is the only place these are listed.
    public var id: String {
        [agentID, accountID].compactMap { $0 }.joined(separator: "/")
    }

    public init(
        agentID: String,
        agentName: String,
        accountID: String? = nil,
        accountName: String? = nil,
        emoji: String? = nil
    ) {
        self.agentID = agentID
        self.agentName = agentName
        self.accountID = accountID
        self.accountName = accountName
        self.emoji = emoji
    }
}

/// The answer to "where could this conversation continue". An empty list is the whole answer a
/// client needs: the control is absent, exactly as the Mac's own menu item is.
public struct RemoteSessionContinuationOptionsDTO: Codable, Equatable, Sendable {
    public let destinations: [RemoteContinuationDestinationDTO]

    public init(destinations: [RemoteContinuationDestinationDTO]) {
        self.destinations = destinations
    }
}

/// Continues a conversation on another provider. Deliberately not the account move: the source
/// session and its transcript stay where they are, and the destination is a new conversation
/// whose first turn reads a frozen, provider-neutral snapshot of this one.
public struct RemoteContinueSessionRequestDTO: Codable, Equatable, Sendable {
    public let agentID: String
    /// Omitted for a runtime without account routing.
    public let accountID: String?

    public init(agentID: String, accountID: String? = nil) {
        self.agentID = agentID
        self.accountID = accountID
    }
}

/// The destination the Mac created, plus the snapshot that now contains it.
public struct RemoteContinueSessionResponseDTO: Codable, Equatable, Sendable {
    public let sessionID: String
    public let me: RemoteMeDTO

    public init(sessionID: String, me: RemoteMeDTO) {
        self.sessionID = sessionID
        self.me = me
    }
}

/// Sets the chat-scoped answer for the next account-limit refusal.
public struct RemoteSetSessionLimitRecoveryRequestDTO: Codable, Equatable, Sendable {
    public let policy: RemoteLimitRecoveryPolicyDTO

    public init(policy: RemoteLimitRecoveryPolicyDTO) {
        self.policy = policy
    }
}

// MARK: - Git review

/// The five working-copy comparisons exposed by the compact mobile review sheet. Commit history
/// is navigation rather than a checkout comparison and remains a desktop review surface.
///
/// The Mac owns the git checkout and resolves these modes. A phone receives only the bounded,
/// parsed result, never a path it can use to reach the host filesystem directly.
public enum RemoteGitReviewMode: String, Codable, Equatable, CaseIterable, Sendable {
    case uncommitted
    case unstaged
    case staged
    case lastTurn
    case branch
}

public struct RemoteGitDiffLineDTO: Codable, Equatable, Sendable {
    public let kind: RemoteDiffLineKind
    public let text: String
    public let oldNumber: Int?
    public let newNumber: Int?

    public init(
        kind: RemoteDiffLineKind,
        text: String,
        oldNumber: Int?,
        newNumber: Int?
    ) {
        self.kind = kind
        self.text = text
        self.oldNumber = oldNumber
        self.newNumber = newNumber
    }
}

public struct RemoteGitHunkDTO: Codable, Equatable, Sendable {
    public let header: String
    public let lines: [RemoteGitDiffLineDTO]

    public init(header: String, lines: [RemoteGitDiffLineDTO]) {
        self.header = header
        self.lines = lines
    }
}

public struct RemoteGitFileDiffDTO: Codable, Equatable, Identifiable, Sendable {
    public let path: String
    public let change: RemoteGitFileChange
    public let renamedFrom: String?
    public let hunks: [RemoteGitHunkDTO]
    public let added: Int
    public let removed: Int
    /// True when the host shortened this file's line payload for the remote surface.
    public let isTruncated: Bool

    public var id: String { path }

    public init(
        path: String,
        change: RemoteGitFileChange,
        renamedFrom: String? = nil,
        hunks: [RemoteGitHunkDTO],
        added: Int,
        removed: Int,
        isTruncated: Bool = false
    ) {
        self.path = path
        self.change = change
        self.renamedFrom = renamedFrom
        self.hunks = hunks
        self.added = added
        self.removed = removed
        self.isTruncated = isTruncated
    }
}

/// One authoritative read of a checkout comparison.
///
/// `message` carries an empty state or a recoverable git failure. Returning that state as the
/// same successful wire shape lets the sheet keep its mode picker and retry affordance visible.
public struct RemoteGitReviewSnapshotDTO: Codable, Equatable, Sendable {
    public let mode: RemoteGitReviewMode
    public let files: [RemoteGitFileDiffDTO]
    public let message: String?
    public let messageLocalization: RemoteLocalizedTextDTO?

    public init(
        mode: RemoteGitReviewMode,
        files: [RemoteGitFileDiffDTO],
        message: String? = nil,
        messageLocalization: RemoteLocalizedTextDTO? = nil
    ) {
        self.mode = mode
        self.files = files
        self.message = message
        self.messageLocalization = messageLocalization
    }

    public var added: Int { files.reduce(0) { $0 + $1.added } }
    public var removed: Int { files.reduce(0) { $0 + $1.removed } }
}

/// Repository-relative paths tracked by git or present as non-ignored untracked files.
public struct RemoteRepositoryFilesDTO: Codable, Equatable, Sendable {
    public let paths: [String]
    public let isTruncated: Bool

    public init(paths: [String], isTruncated: Bool = false) {
        self.paths = paths
        self.isTruncated = isTruncated
    }
}

/// A bounded source-file projection for the mobile file browser.
public struct RemoteRepositoryFileDTO: Codable, Equatable, Identifiable, Sendable {
    public let path: String
    public let content: String?
    public let isBinary: Bool
    public let isTruncated: Bool

    public var id: String { path }

    public init(
        path: String,
        content: String?,
        isBinary: Bool,
        isTruncated: Bool = false
    ) {
        self.path = path
        self.content = content
        self.isBinary = isBinary
        self.isTruncated = isTruncated
    }
}

/// One durable attachment that passed between the two parties during a session.
///
/// The path is relative to whatever the host resolved it against — the checkout for a file that
/// lives there, the host's own attachment store for one it took custody of — and is opaque to the
/// phone, which only ever hands it back. File bytes are fetched separately so the list remains
/// cheap and the phone never receives visual files it has not chosen to preview.
public struct RemoteAttachmentDTO: Codable, Equatable, Identifiable, Sendable {
    /// Opaque host-minted identity. It is safe to return to attachment endpoints and notification
    /// routes; `path` is presentation metadata only.
    public let id: String
    public let path: String
    public let name: String
    /// Lossless so a phone from before a kind existed still decodes the row and falls into its
    /// default presentation instead of refusing the whole list.
    public let kind: RemoteAttachmentKind
    public let byteCount: Int64
    public let modifiedAt: Date?

    /// `agent` or `user`. Optional because a host from before provenance was recorded sends no
    /// such field, and a phone that guessed would be labelling rows with an answer nobody gave.
    public let origin: RemoteAttachmentOrigin?

    public init(
        path: String,
        name: String,
        kind: RemoteAttachmentKind,
        byteCount: Int64,
        modifiedAt: Date? = nil,
        origin: RemoteAttachmentOrigin? = nil,
        id: String? = nil
    ) {
        self.id = id ?? path
        self.path = path
        self.name = name
        self.kind = kind
        self.byteCount = byteCount
        self.modifiedAt = modifiedAt
        self.origin = origin
    }

    private enum CodingKeys: String, CodingKey {
        case id, path, name, kind, byteCount, modifiedAt, origin
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let path = try container.decode(String.self, forKey: .path)
        id = try container.decodeIfPresent(String.self, forKey: .id) ?? path
        self.path = path
        name = try container.decode(String.self, forKey: .name)
        kind = try container.decode(RemoteAttachmentKind.self, forKey: .kind)
        byteCount = try container.decode(Int64.self, forKey: .byteCount)
        modifiedAt = try container.decodeIfPresent(Date.self, forKey: .modifiedAt)
        origin = try container.decodeIfPresent(RemoteAttachmentOrigin.self, forKey: .origin)
    }
}

/// The current bounded attachment list for a session.
public struct RemoteAttachmentsDTO: Codable, Equatable, Sendable {
    public let attachments: [RemoteAttachmentDTO]

    public init(attachments: [RemoteAttachmentDTO]) {
        self.attachments = attachments
    }
}

/// One chunk of a file a composing client is handing to the host.
///
/// The transfer is chunk-shaped from its first version even though a phone normally re-encodes
/// an image small enough to send in one request. A single-shot upload is simply chunk 0 of 1, so
/// full-fidelity transfer later is additive on the client — more chunks — rather than a second
/// route and a changed contract. The bytes are base64 inside the same JSON body every other
/// mutation here uses; at these sizes one decoding path is worth more than the 33% it costs.
public struct RemoteAttachmentUploadRequestDTO: Codable, Equatable, Sendable {
    /// The host-minted id returned by chunk 0, and nil on chunk 0 itself.
    ///
    /// The client does not choose it. An id it minted would be a name for a slot on the Mac
    /// supplied by the network, which is the shape that lets one connection append to another's
    /// staged file or claim an upload it never made.
    public let uploadID: String?
    /// The file as the person sees it named. Presentation only: the host re-derives the
    /// extension it trusts from `mediaType` and never resolves this against a directory.
    public let name: String
    /// The uniform type identifier the client believes it is sending.
    public let mediaType: String
    /// The complete file's size, declared up front so the host can refuse an oversized transfer
    /// on its first chunk instead of after storing most of it.
    public let totalBytes: Int
    public let chunkIndex: Int
    public let chunkCount: Int
    /// This chunk's bytes, base64-encoded.
    public let chunk: String

    public init(
        uploadID: String? = nil,
        name: String,
        mediaType: String,
        totalBytes: Int,
        chunkIndex: Int,
        chunkCount: Int,
        chunk: String
    ) {
        self.uploadID = uploadID
        self.name = name
        self.mediaType = mediaType
        self.totalBytes = totalBytes
        self.chunkIndex = chunkIndex
        self.chunkCount = chunkCount
        self.chunk = chunk
    }
}

/// Bounds on composer uploads that both sides have to agree about.
///
/// The host enforces every one of these; the client reads them so it can refuse a file *before*
/// spending a transfer on it and say why, rather than watching a 400 come back. Neither number
/// may drift: `RemoteAttachmentUploadLimitsTests` asserts each against the host-side policy that
/// actually does the refusing.
public enum RemoteAttachmentUploadLimits {
    /// The largest single file, matching the ceiling the download side already applies.
    public static let maximumBytesPerFile = 24 * 1024 * 1024

    /// How many staged files one message may carry, and so how many the strip holds.
    public static let maximumPerMessage = 8

    /// The file extensions a composing client should offer to pick from.
    ///
    /// These mirror the host's own built-in attachment kinds, so the picker greys out a file the
    /// upload would refuse rather than letting somebody choose it, wait for a transfer, and then
    /// be told no. It is deliberately the *static* set: the host also admits extensions an
    /// installed extension registered and ambiguous ones it probes by content, and neither is
    /// knowable from a phone. Offering less than the host accepts is safe; offering more is the
    /// bug this list exists to prevent, and `RemoteAttachmentUploadLimitsTests` proves every
    /// entry is one the host would keep.
    public static let offeredFileExtensions: [String] = [
        // Images
        "png", "jpg", "jpeg", "gif", "webp", "heic", "heif", "tif", "tiff", "bmp",
        // Documents the pane previews natively
        "pdf", "html", "htm",
        // Movies the host player opens natively
        "mov", "mp4", "m4v",
        // Archives
        "zip", "tar", "gz", "tgz", "bz2", "tbz2", "xz", "txz", "7z", "rar",
        // Open document formats
        "odt", "ods", "odp", "docx", "xlsx", "pptx", "rtf",
        // Diagram sources
        "dot", "gv", "mmd", "mermaid",
    ]
}

/// What a composing client sends, and how much of a file it puts in one request.
public enum RemoteAttachmentUploadClientDefaults {
    /// Raw bytes per chunk.
    ///
    /// Sized against the host's 1 MB whole-request ceiling with base64's 4/3 inflation and the
    /// JSON envelope both accounted for: 512 KB of file becomes about 683 KB of payload, which
    /// leaves the rest of the budget for the name, the type and the framing. The host does not
    /// read this value — it enforces its own request bound — so the two are kept honest by a
    /// test rather than by a shared constant neither side could own.
    public static let chunkBytes = 512 * 1024

    /// The longest edge a photo is re-encoded to before sending, unless full fidelity is asked
    /// for. A modern phone photo is several times this in each direction and many megabytes on
    /// disk; an agent reading a screenshot or a photo of a whiteboard needs neither.
    public static let downscaledMaximumDimension: CGFloat = 2048

    /// JPEG quality for that re-encode. High enough that text in a photographed screen stays
    /// readable, which is the case that actually matters here.
    public static let downscaledCompressionQuality: CGFloat = 0.8
}

/// What the host has of one upload so far.
///
/// `receivedBytes` lets a client that lost a response resume without guessing: re-sending the
/// chunk the host already has returns this unchanged rather than appending it twice.
public struct RemoteAttachmentUploadResponseDTO: Codable, Equatable, Sendable {
    public let uploadID: String
    public let receivedBytes: Int
    /// Whether every declared chunk has arrived. Only a complete upload may be named by a prompt.
    public let isComplete: Bool

    public init(uploadID: String, receivedBytes: Int, isComplete: Bool) {
        self.uploadID = uploadID
        self.receivedBytes = receivedBytes
        self.isComplete = isComplete
    }
}

/// One Mac-owned browser tab exposed to an owner device's read-only Workspace.
///
/// The phone deliberately receives display state rather than a URL it should load itself:
/// cookies, authentication, history, permission grants, and MCP automation all remain in the
/// Mac's existing browser.
public struct RemoteBrowserTabDTO: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public let title: String
    public let displayURL: String?
    public let isActive: Bool
    public let isPrivate: Bool
    public let canPreview: Bool

    public init(
        id: String,
        title: String,
        displayURL: String?,
        isActive: Bool,
        isPrivate: Bool,
        canPreview: Bool
    ) {
        self.id = id
        self.title = title
        self.displayURL = displayURL
        self.isActive = isActive
        self.isPrivate = isPrivate
        self.canPreview = canPreview
    }
}

/// Authoritative session Workspace state fetched after a live invalidation.
public struct RemoteWorkspaceDTO: Codable, Equatable, Sendable {
    public let browserTabs: [RemoteBrowserTabDTO]
    public let latestActivityID: String?

    public init(browserTabs: [RemoteBrowserTabDTO], latestActivityID: String? = nil) {
        self.browserTabs = browserTabs
        self.latestActivityID = latestActivityID
    }
}

/// The state a device is in while it awaits approval or after denial, returned as a 403 body.
public struct RemoteDeviceStateDTO: Codable, Equatable, Sendable {
    public let state: RemoteDeviceApprovalState
    /// Seconds the client should wait before polling `/api/me` again.
    public let retryAfter: Double?

    public init(state: RemoteDeviceApprovalState, retryAfter: Double?) {
        self.state = state
        self.retryAfter = retryAfter
    }
}

/// The body of a `426 Upgrade Required`: the server refused a client whose protocol it cannot
/// serve, and says which side is behind so the client shows the right message.
public struct RemoteUpgradeRequiredDTO: Codable, Equatable, Sendable {
    public let error: String
    public let update: RemoteUpdateTarget
    public let serverProtocol: RemoteProtocolInfo
    public let message: String

    public init(update: RemoteUpdateTarget, serverProtocol: RemoteProtocolInfo = RemoteProtocolInfo(), message: String) {
        error = "protocolMismatch"
        self.update = update
        self.serverProtocol = serverProtocol
        self.message = message
    }
}

// MARK: - WebSocket (server → client)

/// Sent once, immediately after a socket authenticates, describing the surface it is watching.
public struct RemoteHelloDTO: Codable, Equatable, Sendable {
    public let type: String // "hello"
    public let surface: RemoteSessionSurface
    public let capability: RemoteAdvertisedCapability
    public let cols: Int
    public let rows: Int
    public let title: String
    public let theme: RemoteThemeDTO?
    public let terminalTheme: RemoteTerminalThemeDTO?
    /// Additive WebSocket behavior this host understands. An older host omits the field, so a
    /// newer client can keep its legacy behavior instead of waiting for an acknowledgement that
    /// will never arrive.
    public let features: [String]?

    public init(
        surface: RemoteSessionSurface,
        capability: RemoteAdvertisedCapability,
        cols: Int,
        rows: Int,
        title: String,
        theme: RemoteThemeDTO? = nil,
        terminalTheme: RemoteTerminalThemeDTO? = nil,
        features: [String]? = nil
    ) {
        type = "hello"
        self.surface = surface
        self.capability = capability
        self.cols = cols
        self.rows = rows
        self.title = title
        self.theme = theme
        self.terminalTheme = terminalTheme
        self.features = features
    }
}

/// Optional WebSocket behavior negotiated through `RemoteHelloDTO.features`.
public enum RemoteWebSocketFeature: String, Codable, CaseIterable, Sendable {
    /// The host sends viewing/join/leave state in addition to transient typing state.
    case presenceRoster
    /// Prompt submission carries a request id and receives an idempotent result.
    case submitAcknowledgement
    /// A terminal client may compose locally and submit one complete line atomically.
    case atomicTerminalSubmission
    /// Direct terminal input may carry one sampled request id and receive a content-free host
    /// admission acknowledgement. Clients keep ordinary input fire-and-forget when absent.
    case terminalInputLatencyProbe
    /// Human attention is a separate app-owned action and never prompt text or PTY input.
    case attentionRequests
    /// The host can make one person the writer without discarding anybody else's draft.
    case focusedInputControl
    /// Native conversation rows and prompt submissions carry structured references/comments.
    case conversationContextAttachments
    /// The host closes initial terminal replay plus the first phone-owned resize with an
    /// ordered ready frame. A client that sees this feature can reveal on that boundary rather
    /// than guessing from network silence.
    case terminalHydrationBoundary
    /// An authenticated session socket may leave the live mirror without closing, then attach
    /// again later. While parked it receives no terminal output or collaboration traffic and
    /// owns no viewport; the transport alone remains warm.
    case sessionConnectionParking
    /// A composing client may hand the host file bytes and submit them beside its prompt.
    ///
    /// Advertised only when the connection could actually use it. Uploading is an owner-scope
    /// write into the host's own attachment custody, so a view-only or guest connection never
    /// sees the feature and never renders an attach affordance it would be refused for.
    case composerAttachmentUploads
    /// A direct terminal client may place uploaded files in the session workspace and insert
    /// their quoted paths into the PTY without submitting the current TUI line.
    case terminalAttachmentInsertion
    /// The host publishes provider-owned run-plan summaries and serves checklist rows in pages.
    case runPlanProgress
}

// MARK: - Run plan progress

public enum RemoteRunPlanStepStatus: String, Codable, Equatable, Sendable {
    case pending
    case inProgress
    case completed
}

public struct RemoteRunPlanStepDTO: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public let providerID: String?
    public let title: String
    public let status: RemoteRunPlanStepStatus

    public init(id: String, providerID: String? = nil, title: String, status: RemoteRunPlanStepStatus) {
        self.id = id
        self.providerID = providerID
        self.title = title
        self.status = status
    }
}

public struct RemoteRunPlanSummaryDTO: Codable, Equatable, Sendable {
    public let activeTitle: String?
    public let current: Int
    public let completed: Int
    public let active: Int
    public let total: Int

    public init(activeTitle: String?, current: Int, completed: Int, active: Int, total: Int) {
        self.activeTitle = activeTitle
        self.current = current
        self.completed = completed
        self.active = active
        self.total = total
    }
}

/// A nil summary is the authoritative turn-end clear.
public struct RemoteRunPlanUpdateDTO: Codable, Equatable, Sendable {
    public let type: String
    public let revision: Int
    public let plan: RemoteRunPlanSummaryDTO?

    public init(revision: Int, plan: RemoteRunPlanSummaryDTO?) {
        type = "runPlan"
        self.revision = revision
        self.plan = plan
    }
}

public struct RemoteRunPlanPageDTO: Codable, Equatable, Sendable {
    public let type: String
    public let revision: Int
    public let offset: Int
    public let total: Int
    public let steps: [RemoteRunPlanStepDTO]

    public init(revision: Int, offset: Int, total: Int, steps: [RemoteRunPlanStepDTO]) {
        type = "runPlanPage"
        self.revision = revision
        self.offset = offset
        self.total = total
        self.steps = steps
    }
}

/// A live theme change while a session is already open.
public struct RemoteThemeUpdateDTO: Codable, Equatable, Sendable {
    public let type: String
    public let theme: RemoteThemeDTO
    public let terminalTheme: RemoteTerminalThemeDTO

    public init(theme: RemoteThemeDTO, terminalTheme: RemoteTerminalThemeDTO) {
        type = "theme"
        self.theme = theme
        self.terminalTheme = terminalTheme
    }
}

/// A live app-chrome change for clients on the session dashboard.
public struct RemoteAppThemeUpdateDTO: Codable, Equatable, Sendable {
    public let type: String
    public let theme: RemoteThemeDTO

    public init(theme: RemoteThemeDTO) {
        type = "appTheme"
        self.theme = theme
    }
}

/// Fences the authenticated dashboard event stream against the `/api/me` snapshot already held
/// by the client. Registering the subscriber and capturing this edition are one main-actor step;
/// later scoped deltas are sequenced within `streamID`.
public struct RemoteCatalogueStreamHelloDTO: Codable, Equatable, Sendable {
    public let type: String
    public let streamID: String
    public let revision: RemoteCatalogueRevisionDTO

    public init(streamID: String, revision: RemoteCatalogueRevisionDTO) {
        type = "catalogueHello"
        self.streamID = streamID
        self.revision = revision
    }
}

/// Local-diagnostics request sent over the already-authenticated app-events socket.
///
/// The request id binds the following REST upload to the paired device that owns this socket.
/// `screenshotPolicy` is deliberately a closed vocabulary so the phone never accepts an
/// arbitrary capture instruction from the network.
public struct RemoteMobileDiagnosticsCaptureRequestDTO: Codable, Equatable, Sendable {
    public enum ScreenshotPolicy: String, Codable, Equatable, Sendable {
        case none
        case latestIncident
        case current
    }

    public let type: String
    public let requestID: String
    public let screenshotPolicy: ScreenshotPolicy

    public init(requestID: String, screenshotPolicy: ScreenshotPolicy) {
        type = "mobileDiagnosticsCaptureRequest"
        self.requestID = requestID
        self.screenshotPolicy = screenshotPolicy
    }
}

/// A bounded, structured snapshot of the iOS client's operational state.
///
/// This intentionally reuses the content-free diagnostic record vocabulary. It does not carry
/// prompts, terminal output, paths, URLs, bearer tokens, notification text, or arbitrary log
/// strings. The screenshot is the sole visual-content exception and requires the phone's
/// separate automatic-screenshot opt-in when it comes from an error boundary.
public struct RemoteMobileDiagnosticsCaptureDTO: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 1

    public let schemaVersion: Int
    public let captureID: String
    public let requestID: String
    public let capturedAt: String
    public let appVersion: String
    public let appBuild: String
    public let operatingSystem: String
    public let deviceModel: String
    public let applicationState: RemoteMobileApplicationState
    public let connectionState: RemoteMobileConnectionState
    public let activeEndpointKind: RemoteHostEndpointKind
    public let pairedHostCount: Int
    public let visibleSessionCount: Int
    public let diagnostics: [RemoteDiagnosticRecord]
    public let screenshotJPEGBase64: String?
    public let screenshotKind: RemoteMobileDiagnosticsScreenshotKind?

    public init(
        schemaVersion: Int = Self.currentSchemaVersion,
        captureID: String,
        requestID: String,
        capturedAt: String,
        appVersion: String,
        appBuild: String,
        operatingSystem: String,
        deviceModel: String,
        applicationState: RemoteMobileApplicationState,
        connectionState: RemoteMobileConnectionState,
        activeEndpointKind: RemoteHostEndpointKind,
        pairedHostCount: Int,
        visibleSessionCount: Int,
        diagnostics: [RemoteDiagnosticRecord],
        screenshotJPEGBase64: String?,
        screenshotKind: RemoteMobileDiagnosticsScreenshotKind?
    ) {
        self.schemaVersion = schemaVersion
        self.captureID = captureID
        self.requestID = requestID
        self.capturedAt = capturedAt
        self.appVersion = appVersion
        self.appBuild = appBuild
        self.operatingSystem = operatingSystem
        self.deviceModel = deviceModel
        self.applicationState = applicationState
        self.connectionState = connectionState
        self.activeEndpointKind = activeEndpointKind
        self.pairedHostCount = pairedHostCount
        self.visibleSessionCount = visibleSessionCount
        self.diagnostics = diagnostics
        self.screenshotJPEGBase64 = screenshotJPEGBase64
        self.screenshotKind = screenshotKind
    }
}

public struct RemoteMobileDiagnosticsCaptureUploadRequestDTO: Codable, Equatable, Sendable {
    public let capture: RemoteMobileDiagnosticsCaptureDTO

    public init(capture: RemoteMobileDiagnosticsCaptureDTO) {
        self.capture = capture
    }
}

public struct RemoteMobileDiagnosticsCaptureUploadResponseDTO: Codable, Equatable, Sendable {
    public let captureID: String
    public let storedAt: String

    public init(captureID: String, storedAt: String) {
        self.captureID = captureID
        self.storedAt = storedAt
    }
}

/// A scoped session-catalogue change. Row-only mutations carry one already-authorised summary so
/// clients can update in O(changed) work. Structural mutations leave both delta fields nil and
/// ask the client to fetch its own authoritative `/api/me` snapshot.
public struct RemoteSessionsChangedDTO: Codable, Equatable, Sendable {
    public let type: String
    public let session: RemoteSessionSummaryDTO?
    public let removedSessionID: String?
    public let terminal: RemoteProjectTerminalSummaryDTO?
    public let removedTerminalID: String?
    /// The catalogue edition this change produced. A client that applies the delta adopts it, so
    /// its next conditional `/api/me` can be answered `304`; a client that receives a delta while
    /// holding no catalogue, or from an older host that sends none, refreshes in full as before.
    public let revision: RemoteCatalogueRevisionDTO?
    /// Additive per-connection continuity. Hidden rows do not consume a sequence number, so a
    /// scoped client learns nothing about catalogue changes outside its authorization.
    public let streamID: String?
    public let sequence: UInt64?

    public init(
        session: RemoteSessionSummaryDTO? = nil,
        removedSessionID: String? = nil,
        terminal: RemoteProjectTerminalSummaryDTO? = nil,
        removedTerminalID: String? = nil,
        revision: RemoteCatalogueRevisionDTO? = nil,
        streamID: String? = nil,
        sequence: UInt64? = nil
    ) {
        type = "sessionsChanged"
        self.session = session
        self.removedSessionID = removedSessionID
        self.terminal = terminal
        self.removedTerminalID = removedTerminalID
        self.revision = revision
        self.streamID = streamID
        self.sequence = sequence
    }

    public func framed(streamID: String, sequence: UInt64) -> Self {
        Self(
            session: session,
            removedSessionID: removedSessionID,
            terminal: terminal,
            removedTerminalID: removedTerminalID,
            revision: revision,
            streamID: streamID,
            sequence: sequence
        )
    }
}

/// The canonical catalogue row after a live session attach attempted its durable read receipt.
/// The originating phone applies this directly; delivery to its dashboard no longer depends on
/// a second best-effort socket event.
public struct RemoteSessionVisitedDTO: Codable, Equatable, Sendable {
    public let type: String
    public let session: RemoteSessionSummaryDTO
    public let revision: RemoteCatalogueRevisionDTO
    public let receiptCommitted: Bool

    public init(
        session: RemoteSessionSummaryDTO,
        revision: RemoteCatalogueRevisionDTO,
        receiptCommitted: Bool
    ) {
        type = "sessionVisited"
        self.session = session
        self.revision = revision
        self.receiptCommitted = receiptCommitted
    }
}

/// A small owner-only invalidation for companion surfaces outside the primary terminal/chat.
///
/// `activityID` is present only for a meaningful new surface the phone may want to hint. A nil
/// value refreshes an already-visible Follow view without manufacturing unread attention for
/// every browser click, scroll, or form fill.
public enum RemoteWorkspaceKind: String, Codable, Equatable, Sendable {
    case browser
}

public struct RemoteWorkspaceChangedDTO: Codable, Equatable, Sendable {
    public let type: String
    public let kind: RemoteWorkspaceKind
    public let activityID: String?
    public let occurredAt: Double

    public init(
        kind: RemoteWorkspaceKind,
        activityID: String? = nil,
        occurredAt: Double = Date().timeIntervalSince1970
    ) {
        type = "workspaceChanged"
        self.kind = kind
        self.activityID = activityID
        self.occurredAt = occurredAt
    }
}

/// Ephemeral participant activity. Presence is advisory, never a write lock or authority.
public struct RemotePresenceDTO: Codable, Equatable, Identifiable, Sendable {
    public let type: String
    /// One live socket. Unlike `memberID`, this distinguishes two devices or tabs belonging to
    /// the same participant and makes a single disconnect safe to remove.
    public let presenceID: String?
    public let memberID: String
    public let displayName: String
    public let deviceName: String?
    public let surface: RemoteSessionSurface?
    /// Older clients may still send `idle`; newer hosts normalize it to `viewing`.
    public let state: RemotePresenceState
    public let updatedAt: Double

    public var id: String { presenceID ?? memberID }

    public init(
        presenceID: String? = nil,
        memberID: String,
        displayName: String,
        deviceName: String? = nil,
        surface: RemoteSessionSurface? = nil,
        state: RemotePresenceState,
        updatedAt: Double = Date().timeIntervalSince1970
    ) {
        type = "presence"
        self.presenceID = presenceID
        self.memberID = memberID
        self.displayName = displayName
        self.deviceName = deviceName
        self.surface = surface
        self.state = state
        self.updatedAt = updatedAt
    }
}

/// One person who can be asked for input in this chat, including accepted members who are not
/// currently online. `id` is routing identity, while `displayName` is presentation only.
public struct RemoteCollaborationParticipantDTO: Codable, Equatable, Identifiable, Sendable {
    public static let ownerID = "owner"

    public let id: String
    public let displayName: String
    public let role: RemoteCollaborationRole
    public let isOnline: Bool

    public init(
        id: String,
        displayName: String,
        role: RemoteCollaborationRole,
        isOnline: Bool
    ) {
        self.id = id
        self.displayName = displayName
        self.role = role
        self.isOnline = isOnline
    }
}

/// The complete recipient picker state for the authenticated participant watching one chat.
public struct RemoteCollaborationParticipantsDTO: Codable, Equatable, Sendable {
    public let type: String
    public let participants: [RemoteCollaborationParticipantDTO]

    public init(participants: [RemoteCollaborationParticipantDTO]) {
        type = "collaborationParticipants"
        self.participants = participants
    }
}

/// Whether every interactive participant may send, or one participant owns new input.
public enum RemoteInputControlMode: String, Codable, Equatable, Sendable {
    case collaborative
    case focused
}

/// The host-authoritative, viewer-specific control state for one shared chat.
///
/// `canWrite` is deliberately explicit. A client must not infer authority from a display name
/// or from presence, and an older client that ignores this frame is still checked by the host.
public struct RemoteInputControlStateDTO: Codable, Equatable, Sendable {
    public let type: String
    public let mode: RemoteInputControlMode
    public let controllerID: String?
    public let controllerDisplayName: String?
    public let currentParticipantID: String
    public let canWrite: Bool
    public let canManage: Bool
    public let canHandOff: Bool
    public let participants: [RemoteCollaborationParticipantDTO]
    public let revision: Int

    public init(
        mode: RemoteInputControlMode,
        controllerID: String? = nil,
        controllerDisplayName: String? = nil,
        currentParticipantID: String,
        canWrite: Bool,
        canManage: Bool,
        canHandOff: Bool,
        participants: [RemoteCollaborationParticipantDTO],
        revision: Int
    ) {
        type = "inputControl"
        self.mode = mode
        self.controllerID = controllerID
        self.controllerDisplayName = controllerDisplayName
        self.currentParticipantID = currentParticipantID
        self.canWrite = canWrite
        self.canManage = canManage
        self.canHandOff = canHandOff
        self.participants = participants
        self.revision = revision
    }
}

public enum RemoteInputControlResultStatus: String, Codable, Equatable, Sendable {
    case applied
    case delivered
    case forbidden
    case unavailable
    case rejected
}

/// Receipt for changing, handing off, reclaiming, or requesting input control.
public struct RemoteInputControlResultDTO: Codable, Equatable, Sendable {
    public let type: String
    public let requestID: String
    public let status: RemoteInputControlResultStatus

    public init(requestID: String, status: RemoteInputControlResultStatus) {
        type = "inputControlResult"
        self.requestID = requestID
        self.status = status
    }
}

/// Quiet collaboration activity. It never becomes prompt text or a terminal write.
public struct RemoteInputControlEventDTO: Codable, Equatable, Identifiable, Sendable {
    public let type: String
    public let id: String
    public let action: RemoteInputControlEventAction
    public let actorID: String
    public let actorDisplayName: String
    public let targetID: String?
    public let targetDisplayName: String?
    public let createdAt: Double

    public init(
        id: String = UUID().uuidString.lowercased(),
        action: RemoteInputControlEventAction,
        actorID: String,
        actorDisplayName: String,
        targetID: String? = nil,
        targetDisplayName: String? = nil,
        createdAt: Double = Date().timeIntervalSince1970
    ) {
        type = "inputControlEvent"
        self.id = id
        self.action = action
        self.actorID = actorID
        self.actorDisplayName = actorDisplayName
        self.targetID = targetID
        self.targetDisplayName = targetDisplayName
        self.createdAt = createdAt
    }
}

public enum RemoteAttentionRequestStatus: String, Codable, Equatable, Sendable {
    case delivered
    case unavailable
    case rateLimited
    case rejected
}

/// The acknowledgement for a human-only attention request. It is deliberately distinct from a
/// prompt result: receiving this type can never imply that Claude, Codex, or a PTY was written.
public struct RemoteAttentionRequestResultDTO: Codable, Equatable, Sendable {
    public let type: String
    public let requestID: String
    public let status: RemoteAttentionRequestStatus

    public init(requestID: String, status: RemoteAttentionRequestStatus) {
        type = "attentionResult"
        self.requestID = requestID
        self.status = status
    }
}

/// Quiet, in-chat collaboration activity emitted after a human attention request was deliverable.
/// It is not a conversation row and is never replayed into an agent transcript.
public struct RemoteAttentionEventDTO: Codable, Equatable, Identifiable, Sendable {
    public let type: String
    public let id: String
    public let requestID: String
    public let senderID: String
    public let senderDisplayName: String
    public let recipientID: String
    public let recipientDisplayName: String
    public let note: String?
    public let createdAt: Double

    public init(
        id: String = UUID().uuidString.lowercased(),
        requestID: String,
        senderID: String,
        senderDisplayName: String,
        recipientID: String,
        recipientDisplayName: String,
        note: String? = nil,
        createdAt: Double = Date().timeIntervalSince1970
    ) {
        type = "attention"
        self.id = id
        self.requestID = requestID
        self.senderID = senderID
        self.senderDisplayName = senderDisplayName
        self.recipientID = recipientID
        self.recipientDisplayName = recipientDisplayName
        self.note = note
        self.createdAt = createdAt
    }
}

/// Shared client/host bound for the optional note attached to an attention request.
public enum RemoteAttentionDefaults {
    public static let maximumNoteUTF8Bytes = 500
}

public enum RemotePromptSubmissionStatus: String, Codable, Equatable, Sendable {
    case accepted
    case busy
    case rejected
    case unavailable
    case conflict
}

/// The authoritative result for one prompt request. The request id lets a client retry the same
/// submission after a lost socket without creating a second agent turn.
public struct RemotePromptSubmissionResultDTO: Codable, Equatable, Sendable {
    public let type: String
    public let requestID: String
    public let status: RemotePromptSubmissionStatus

    public init(requestID: String, status: RemotePromptSubmissionStatus) {
        type = "submitResult"
        self.requestID = requestID
        self.status = status
    }
}

/// A rate-limited acknowledgement for one sampled direct-terminal input write.
///
/// The ordinary input stream remains fire-and-forget. A current client adds a request id to at
/// most one input every few seconds so diagnostics can distinguish phone/network delay from the
/// Mac main-queue admission that precedes the PTY write. Neither the request nor this reply
/// carries the input bytes.
public struct RemoteTerminalInputProbeResultDTO: Codable, Equatable, Sendable {
    public let type: String
    public let requestID: String
    public let accepted: Bool

    public init(requestID: String, accepted: Bool) {
        type = "inputProbeResult"
        self.requestID = requestID
        self.accepted = accepted
    }
}

/// The active PTY size. An interactive phone owns this grid while its terminal is visible;
/// view-only clients follow it, just as they follow the Mac's grid when no controller is active.
public struct RemoteResizeDTO: Codable, Equatable, Sendable {
    public let type: String // "resize"
    public let cols: Int
    public let rows: Int

    public init(cols: Int, rows: Int) {
        type = "resize"
        self.cols = cols
        self.rows = rows
    }
}

/// Closes one terminal attach transaction after every replay/repaint byte and a final screen
/// seed have been queued for this client.
///
/// `requestID` is the id the client put on its current pre-reveal viewport generation. It prevents
/// a delayed ready frame from an earlier grid from revealing a newer hydration transaction.
/// View-only clients do not lease a grid and therefore receive a boundary without an id.
public struct RemoteTerminalReadyDTO: Codable, Equatable, Sendable {
    public let type: String // "terminalReady"
    public let requestID: String?

    public init(requestID: String? = nil) {
        type = "terminalReady"
        self.requestID = requestID
    }
}

/// A create/resume socket has authenticated and is waiting on that session's live surface.
/// This is progress, not the surface handshake: `hello` remains the one authoritative attach.
public struct RemoteSessionStartingDTO: Codable, Equatable, Sendable {
    public let type: String

    public init() {
        type = "sessionStarting"
    }
}

/// Confirms that a session socket has left the live mirror and is now transport-only.
///
/// The acknowledgement is ordered before any later resumed `hello`, which lets a client discard
/// bytes that were already in flight when it asked to park without ever mixing them into the
/// resumed renderer.
public struct RemoteSessionParkedDTO: Codable, Equatable, Sendable {
    public let type: String

    public init() {
        type = "sessionParked"
    }
}

/// The terminal title changed after the initial hello (usually through OSC 0/2).
public struct RemoteTitleDTO: Codable, Equatable, Sendable {
    public let type: String // "title"
    public let title: String

    public init(title: String) {
        type = "title"
        self.title = title
    }
}

// MARK: - Notifications

public enum RemoteNotificationKind: String, Codable, CaseIterable, Sendable {
    case sharedSession
    case permissionRequest
    case agentQuestion
    case turnCompleted
    case agentMessage
    case attentionRequest
}

/// The authenticated in-app destination a notification opens.
///
/// This is deliberately a closed host vocabulary rather than a URL supplied by an agent or an
/// extension. The notification only names an object Threading already owns; each client maps the
/// same destination to its own navigation idiom (a display-pane tab on Mac, a pushed detail on
/// iPhone). Associated identifiers are opaque and are validated again inside the named session
/// before anything is shown.
public struct RemoteNotificationDestinationDTO: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Equatable, Sendable {
        case session
        case attachment
        case browserTab
        case extensionPanel
    }

    public let kind: Kind
    public let attachmentID: String?
    public let browserTabID: String?
    public let extensionIdentifier: String?
    public let extensionPanelID: String?

    public init(
        kind: Kind,
        attachmentID: String? = nil,
        browserTabID: String? = nil,
        extensionIdentifier: String? = nil,
        extensionPanelID: String? = nil
    ) {
        self.kind = kind
        self.attachmentID = attachmentID
        self.browserTabID = browserTabID
        self.extensionIdentifier = extensionIdentifier
        self.extensionPanelID = extensionPanelID
    }

    public static let session = Self(kind: .session)

    public static func attachment(id: String) -> Self {
        Self(kind: .attachment, attachmentID: id)
    }

    public static func browserTab(id: String) -> Self {
        Self(kind: .browserTab, browserTabID: id)
    }

    public static func extensionPanel(extensionIdentifier: String, panelID: String) -> Self {
        Self(
            kind: .extensionPanel,
            extensionIdentifier: extensionIdentifier,
            extensionPanelID: panelID
        )
    }

    /// A malformed route is never partially interpreted as a broader one. Callers either use
    /// this exact destination or fall back to the session explicitly.
    public var isValid: Bool {
        switch kind {
        case .session:
            return attachmentID == nil && browserTabID == nil
                && extensionIdentifier == nil && extensionPanelID == nil
        case .attachment:
            return attachmentID?.isEmpty == false && browserTabID == nil
                && extensionIdentifier == nil && extensionPanelID == nil
        case .browserTab:
            return attachmentID == nil && browserTabID?.isEmpty == false
                && extensionIdentifier == nil && extensionPanelID == nil
        case .extensionPanel:
            return attachmentID == nil && browserTabID == nil
                && extensionIdentifier?.isEmpty == false && extensionPanelID?.isEmpty == false
        }
    }
}

/// A bundle-localized alternative to notification fallback text.
///
/// The fallback remains in the event for older clients and for notification kinds whose text is
/// user-authored. APNs and current live clients use this key when it is present, so the receiving
/// iPhone — rather than the sending Mac — chooses the display language.
public struct RemoteLocalizedTextDTO: Codable, Equatable, Sendable {
    public let key: String
    public let arguments: [String]

    public init(key: String, arguments: [String] = []) {
        self.key = key
        self.arguments = arguments
    }
}

/// The provider-neutral payload used both on the live events socket and inside an APNs push.
/// It carries no bearer, project path, tool arguments, or diff: lock-screen content stays
/// intentionally smaller than the authenticated session view it opens.
public struct RemoteNotificationEventDTO: Codable, Equatable, Identifiable, Sendable {
    public let type: String
    public let id: String
    public let kind: RemoteNotificationKind
    public let hostID: String
    public let sessionID: String
    public let title: String
    public let body: String
    public let titleLocalization: RemoteLocalizedTextDTO?
    public let bodyLocalization: RemoteLocalizedTextDTO?
    public let destination: RemoteNotificationDestinationDTO
    public let createdAt: Double
    /// Stable within one host process and session. Absent for older senders and notification
    /// kinds that are not produced by an agent-turn boundary.
    public let turnGeneration: UInt64?

    public init(
        id: String = UUID().uuidString.lowercased(),
        kind: RemoteNotificationKind,
        hostID: String,
        sessionID: String,
        title: String,
        body: String,
        titleLocalization: RemoteLocalizedTextDTO? = nil,
        bodyLocalization: RemoteLocalizedTextDTO? = nil,
        destination: RemoteNotificationDestinationDTO = .session,
        createdAt: Double = Date().timeIntervalSince1970,
        turnGeneration: UInt64? = nil
    ) {
        type = "notification"
        self.id = id
        self.kind = kind
        self.hostID = hostID
        self.sessionID = sessionID
        self.title = title
        self.body = body
        self.titleLocalization = titleLocalization
        self.bodyLocalization = bodyLocalization
        self.destination = destination
        self.createdAt = createdAt
        self.turnGeneration = turnGeneration
    }

    /// The same event without the field a hosted broker older than its sender will refuse.
    ///
    /// The generation is a sender-side delivery fact: it decides which pending or accepted work
    /// an arriving completion supersedes, and every one of those decisions is taken on the Mac
    /// before the push leaves. No receiver reads it, so omitting it costs a recipient nothing —
    /// while sending it to a service whose key list predates it costs the entire notification.
    public func omittingTurnGeneration() -> RemoteNotificationEventDTO {
        guard turnGeneration != nil else { return self }
        return RemoteNotificationEventDTO(
            id: id,
            kind: kind,
            hostID: hostID,
            sessionID: sessionID,
            title: title,
            body: body,
            titleLocalization: titleLocalization,
            bodyLocalization: bodyLocalization,
            destination: destination,
            createdAt: createdAt,
            turnGeneration: nil
        )
    }

    private enum CodingKeys: String, CodingKey {
        case type, id, kind, hostID, sessionID, title, body
        case titleLocalization, bodyLocalization, destination, createdAt, turnGeneration
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        type = try container.decode(String.self, forKey: .type)
        id = try container.decode(String.self, forKey: .id)
        kind = try container.decode(RemoteNotificationKind.self, forKey: .kind)
        hostID = try container.decode(String.self, forKey: .hostID)
        sessionID = try container.decode(String.self, forKey: .sessionID)
        title = try container.decode(String.self, forKey: .title)
        body = try container.decode(String.self, forKey: .body)
        titleLocalization = try container.decodeIfPresent(
            RemoteLocalizedTextDTO.self,
            forKey: .titleLocalization
        )
        bodyLocalization = try container.decodeIfPresent(
            RemoteLocalizedTextDTO.self,
            forKey: .bodyLocalization
        )
        destination = try container.decodeIfPresent(
            RemoteNotificationDestinationDTO.self,
            forKey: .destination
        ) ?? .session
        createdAt = try container.decode(Double.self, forKey: .createdAt)
        turnGeneration = try container.decodeIfPresent(UInt64.self, forKey: .turnGeneration)
    }
}

public struct RemoteNotificationRegistrationDTO: Codable, Equatable, Sendable {
    public let deviceToken: String
    /// Opaque recipient binding minted by the hosted service under this phone's device
    /// credential. The Mac never needs the corresponding APNs token for hosted delivery.
    public let hostedRegistrationID: String?
    public let environment: RemoteNotificationEnvironment
    public let enabledKinds: [RemoteNotificationKind]
    /// Kinds that may make sound on this device. Nil preserves the behavior of an older client;
    /// an empty array is an explicit request for quiet delivery.
    public let soundEnabledKinds: [RemoteNotificationKind]?
    /// Optional by design: an older phone advertises no newer delivery behavior.
    public let capabilities: [RemoteNotificationCapability]?
    /// Per-device consent. Missing is always false, including for a capability-aware device.
    public let includesResponsePreviews: Bool?

    public init(
        deviceToken: String,
        hostedRegistrationID: String? = nil,
        environment: RemoteNotificationEnvironment,
        enabledKinds: [RemoteNotificationKind],
        soundEnabledKinds: [RemoteNotificationKind]? = nil,
        capabilities: [RemoteNotificationCapability]? = nil,
        includesResponsePreviews: Bool? = nil
    ) {
        self.deviceToken = deviceToken
        self.hostedRegistrationID = hostedRegistrationID
        self.environment = environment
        self.enabledKinds = enabledKinds
        self.soundEnabledKinds = soundEnabledKinds
        self.capabilities = capabilities
        self.includesResponsePreviews = includesResponsePreviews
    }
}

/// Removes one previously delivered Threading notification without carrying any notification
/// copy. The event id is the `UNNotificationRequest` identifier on the receiving phone.
public struct RemoteNotificationRetractionDTO: Codable, Equatable, Sendable {
    public let type: String
    public let hostID: String
    public let sessionID: String
    public let eventID: String
    public let kind: RemoteNotificationKind

    public init(
        hostID: String,
        sessionID: String,
        eventID: String,
        kind: RemoteNotificationKind
    ) {
        type = "notificationRetraction"
        self.hostID = hostID
        self.sessionID = sessionID
        self.eventID = eventID
        self.kind = kind
    }
}

public struct RemoteNotificationRegistrationResponseDTO: Codable, Equatable, Sendable {
    public let delivery: RemoteNotificationDelivery

    public init(delivery: RemoteNotificationDelivery) {
        self.delivery = delivery
    }
}

/// An in-band error, e.g. an interact action attempted on a view-only share.
/// Which clause of the viewport guard refused a `viewport` message.
///
/// The guard has five reasons to say no and used to say only "invalidViewport", so a phone
/// whose grid the host rejected could report neither what it asked for nor why it was refused.
/// The cases are structural tokens rather than sentences: they cross the wire, reach a
/// share-safe journal, and must never carry anything a person wrote.
public enum RemoteViewportRefusal: String, Codable, Sendable {
    case missingSize
    case columnsOutOfRange
    case rowsOutOfRange
    case unroutedConnection
    case malformedSessionID

    /// The accepted grid. Stated here so the host and the client agree on one bound.
    public static let columns = 20 ... 240
    public static let rows = 4 ... 160
}

/// Stable failure vocabulary for the REST transport.
///
/// `RemoteErrorDTO.code` remains a string so an older client can preserve a future code it does
/// not know. The host constructs REST failures through this enum so adding a refusal is an
/// explicit protocol decision rather than an English HTTP reason phrase that URLSession drops.
public enum RemoteRESTErrorCode: String, Codable, CaseIterable, Sendable {
    case badRequest
    case unauthorized
    case forbidden
    case notFound
    case conflict
    case unprocessableRequest
    case rateLimited
    case serviceUnavailable
    case serverFailure

    case invalidRequestID
    case requestIDReused
    case replayCacheBusy
    case responseTooLarge
    case hostNotReady

    case unknownLaunchChoice
    case unknownAccount
    case unknownModel
    case unknownReasoningEffort
    case unknownPermissionMode
    case unsupportedSpeed
    case unsupportedSurface
    case unknownRole
    case unsupportedWorkspace
    case invalidReportOpening
    case invalidOpeningAttachments

    case invalidDeviceToken
    case localDiagnosticsDisabled
    case captureNotRequested
    case invalidInvitation
    case ownerAccessRequired
    case invalidDevice
    case hostedServiceUnavailable

    case unknownTheme
    case unknownSetting
    case settingNotMutable
    case invalidSettingValue
    case storageExhausted
    case persistenceUnavailable
    case unsupportedValue
    case archiveAlreadyChanging
    case archiveAccountUnavailable
    case archiveCommandUnavailable
    case archiveCommandRejected
    case invalidSnoozeDeadline
    case unsupportedRuntime
    case unsupportedAccount
    case accountMoveRefused
    case continuationRefused
    case unsupportedRecovery
    case sharingNotAvailable
}

public struct RemoteErrorDTO: Codable, Equatable, Sendable {
    public let type: String // "error"
    public let code: String
    /// A bounded machine token qualifying `code`, such as the guard clause that refused. It is
    /// optional because a host from before this field simply omits it.
    public let detail: String?

    public init(code: String, detail: String? = nil) {
        type = "error"
        self.code = code
        self.detail = detail
    }

    public init(code: RemoteRESTErrorCode, detail: String? = nil) {
        self.init(code: code.rawValue, detail: detail)
    }
}

/// The session's mirror is ending. `update` is set only when the reason is a protocol mismatch,
/// naming the side that must update.
public struct RemoteEndedDTO: Codable, Equatable, Sendable {
    public let type: String // "ended"
    public let reason: String
    public let update: RemoteUpdateTarget?

    public init(reason: String, update: RemoteUpdateTarget? = nil) {
        type = "ended"
        self.reason = reason
        self.update = update
    }
}

// MARK: - Native conversation

/// One command or skill the live Mac session says a conversation composer may invoke. Paths,
/// skill bodies, and provider credentials never cross the wire; submission is resolved again
/// against the Mac's current authoritative catalog.
public struct RemoteComposerCapabilityDTO: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public let name: String
    public let displayName: String
    public let description: String
    public let argumentHint: String
    public let aliases: [String]
    public let kind: RemoteComposerCapabilityKind
    /// `true` lets an unclassified initial Claude row remain discoverable in `/skills` until
    /// the provider publishes authoritative skill membership. Missing means `kind == "skill"`
    /// for compatibility with older peers.
    public let isAvailableInSkillCatalog: Bool?
    public let trigger: RemoteComposerCapabilityTrigger
    /// Presentation only; execution remains on the Mac.
    public let presentation: RemoteComposerCapabilityPresentation
    public let isEnabled: Bool
    public let unavailableReason: String?

    public init(
        id: String,
        name: String,
        displayName: String,
        description: String,
        argumentHint: String,
        aliases: [String] = [],
        kind: RemoteComposerCapabilityKind,
        isAvailableInSkillCatalog: Bool? = nil,
        trigger: RemoteComposerCapabilityTrigger,
        presentation: RemoteComposerCapabilityPresentation,
        isEnabled: Bool = true,
        unavailableReason: String? = nil
    ) {
        self.id = id
        self.name = name
        self.displayName = displayName
        self.description = description
        self.argumentHint = argumentHint
        self.aliases = aliases
        self.kind = kind
        self.isAvailableInSkillCatalog = isAvailableInSkillCatalog
        self.trigger = trigger
        self.presentation = presentation
        self.isEnabled = isEnabled
        self.unavailableReason = unavailableReason
    }

    public var invocationText: String {
        (trigger == .dollar ? "$" : "/") + name
    }

    public var canBrowseAsSkill: Bool {
        isAvailableInSkillCatalog ?? (kind == .skill)
    }

    /// The same secondary text every visual and accessibility presentation should announce.
    /// A disabled reason supersedes the ordinary description because it explains the action the
    /// person cannot currently take.
    public var presentationDetail: String {
        unavailableReason ?? description
    }
}

/// A provider-neutral row in the native conversation surface. The Mac has already normalised
/// Claude and Codex into this vocabulary, so mobile clients do not need either provider parser.
public struct RemoteConversationContextAttachmentDTO: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public let kind: RemoteConversationContextKind
    public let source: RemoteConversationContextSource
    public let title: String
    public let excerpt: String?
    public let comment: String?
    public let locator: String?
    public let lineStart: Int?
    public let lineEnd: Int?

    public init(
        id: String,
        kind: RemoteConversationContextKind,
        source: RemoteConversationContextSource,
        title: String,
        excerpt: String? = nil,
        comment: String? = nil,
        locator: String? = nil,
        lineStart: Int? = nil,
        lineEnd: Int? = nil
    ) {
        self.id = id
        self.kind = kind
        self.source = source
        self.title = title
        self.excerpt = excerpt
        self.comment = comment
        self.locator = locator
        self.lineStart = lineStart
        self.lineEnd = lineEnd
    }
}

public struct RemoteConversationRowDTO: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public let kind: RemoteConversationRowKind
    public let text: String?
    public let toolName: String?
    public let summary: String?
    public let result: String?
    public let isError: Bool
    /// Additive so older peers decode the rest of the row unchanged.
    public let contextAttachments: [RemoteConversationContextAttachmentDTO]?

    public init(
        id: String,
        kind: RemoteConversationRowKind,
        text: String? = nil,
        toolName: String? = nil,
        summary: String? = nil,
        result: String? = nil,
        isError: Bool = false,
        contextAttachments: [RemoteConversationContextAttachmentDTO]? = nil
    ) {
        self.id = id
        self.kind = kind
        self.text = text
        self.toolName = toolName
        self.summary = summary
        self.result = result
        self.isError = isError
        self.contextAttachments = contextAttachments
    }
}

/// The authoritative conversation snapshot. Native turns are modest in row count and snapshots
/// make reconnect, replay, tool-result attachment, and streamed-placeholder replacement one
/// idempotent operation for every client.
public struct RemoteConversationSnapshotDTO: Codable, Equatable, Sendable {
    public let type: String
    public let rows: [RemoteConversationRowDTO]
    public let streamingText: String
    public let canSend: Bool
    public let composerCapabilities: [RemoteComposerCapabilityDTO]
    public let permission: RemotePermissionRequestDTO?
    /// Monotonically increasing within one live conversation mirror.
    public let revision: Int
    /// True when the host has rows before the first row in this window.
    public let hasEarlier: Bool

    public init(
        rows: [RemoteConversationRowDTO],
        streamingText: String = "",
        canSend: Bool,
        composerCapabilities: [RemoteComposerCapabilityDTO] = [],
        permission: RemotePermissionRequestDTO? = nil,
        revision: Int = 0,
        hasEarlier: Bool = false
    ) {
        type = "conversation"
        self.rows = rows
        self.streamingText = streamingText
        self.canSend = canSend
        self.composerCapabilities = composerCapabilities
        self.permission = permission
        self.revision = revision
        self.hasEarlier = hasEarlier
    }

    private enum CodingKeys: String, CodingKey {
        case type, rows, streamingText, canSend, composerCapabilities, permission, revision
        case hasEarlier
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        type = try container.decodeIfPresent(String.self, forKey: .type) ?? "conversation"
        rows = try container.decodeIfPresent(
            [RemoteConversationRowDTO].self,
            forKey: .rows
        ) ?? []
        streamingText = try container.decodeIfPresent(
            String.self,
            forKey: .streamingText
        ) ?? ""
        canSend = try container.decodeIfPresent(Bool.self, forKey: .canSend) ?? false
        composerCapabilities = try container.decodeIfPresent(
            [RemoteComposerCapabilityDTO].self,
            forKey: .composerCapabilities
        ) ?? []
        permission = try container.decodeIfPresent(
            RemotePermissionRequestDTO.self,
            forKey: .permission
        )
        revision = try container.decodeIfPresent(Int.self, forKey: .revision) ?? 0
        hasEarlier = try container.decodeIfPresent(Bool.self, forKey: .hasEarlier) ?? false
    }
}

/// The live update after an initial conversation snapshot.
///
/// Timeline rows only append or gain a result while a process is alive, so the wire can name
/// those two operations directly. Full snapshots remain the recovery path when a client's base
/// revision no longer matches.
public struct RemoteConversationDeltaDTO: Codable, Equatable, Sendable {
    public let type: String
    public let baseRevision: Int
    public let revision: Int
    public let appendedRows: [RemoteConversationRowDTO]
    public let updatedRows: [RemoteConversationRowDTO]
    public let streamingText: String
    public let canSend: Bool
    /// Nil means this delta leaves the catalog unchanged.
    public let composerCapabilities: [RemoteComposerCapabilityDTO]?
    public let permission: RemotePermissionRequestDTO?
    /// Nil means a live update does not change the client's pagination boundary.
    public let hasEarlier: Bool?

    public init(
        baseRevision: Int,
        revision: Int,
        appendedRows: [RemoteConversationRowDTO] = [],
        updatedRows: [RemoteConversationRowDTO] = [],
        streamingText: String,
        canSend: Bool,
        composerCapabilities: [RemoteComposerCapabilityDTO]? = nil,
        permission: RemotePermissionRequestDTO? = nil,
        hasEarlier: Bool? = nil
    ) {
        type = "conversationDelta"
        self.baseRevision = baseRevision
        self.revision = revision
        self.appendedRows = appendedRows
        self.updatedRows = updatedRows
        self.streamingText = streamingText
        self.canSend = canSend
        self.composerCapabilities = composerCapabilities
        self.permission = permission
        self.hasEarlier = hasEarlier
    }
}

/// An older, prepend-only page. Page rows use the same stable ids as live rows, so a page
/// arriving across a live update can be merged idempotently.
public struct RemoteConversationPageDTO: Codable, Equatable, Sendable {
    public let type: String
    public let rows: [RemoteConversationRowDTO]
    public let beforeRowID: String?
    public let hasEarlier: Bool

    public init(
        rows: [RemoteConversationRowDTO],
        beforeRowID: String?,
        hasEarlier: Bool
    ) {
        type = "conversationPage"
        self.rows = rows
        self.beforeRowID = beforeRowID
        self.hasEarlier = hasEarlier
    }
}

/// A line in the edit preview attached to a permission request.
public struct RemotePermissionDiffLineDTO: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public let kind: RemoteDiffLineKind
    public let text: String

    public init(id: String, kind: RemoteDiffLineKind, text: String) {
        self.id = id
        self.kind = kind
        self.text = text
    }
}

/// The one permission decision currently awaiting the user in a native conversation.
public struct RemotePermissionRequestDTO: Codable, Equatable, Identifiable, Sendable {
    public let type: String
    public let id: String
    public let toolName: String
    public let summary: String
    public let filePath: String?
    public let diff: [RemotePermissionDiffLineDTO]
    /// False when the host could not send the full evidence needed for an informed decision.
    /// The request stays visible, but clients must direct the user back to the Mac.
    public let canDecide: Bool
    public let unavailableReason: String?

    public init(
        id: String,
        toolName: String,
        summary: String,
        filePath: String? = nil,
        diff: [RemotePermissionDiffLineDTO] = [],
        canDecide: Bool = true,
        unavailableReason: String? = nil
    ) {
        type = "permission"
        self.id = id
        self.toolName = toolName
        self.summary = summary
        self.filePath = filePath
        self.diff = diff
        self.canDecide = canDecide
        self.unavailableReason = unavailableReason
    }

    private enum CodingKeys: String, CodingKey {
        case type, id, toolName, summary, filePath, diff, canDecide, unavailableReason
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        type = try container.decodeIfPresent(String.self, forKey: .type) ?? "permission"
        id = try container.decode(String.self, forKey: .id)
        toolName = try container.decode(String.self, forKey: .toolName)
        summary = try container.decode(String.self, forKey: .summary)
        filePath = try container.decodeIfPresent(String.self, forKey: .filePath)
        diff = try container.decodeIfPresent(
            [RemotePermissionDiffLineDTO].self,
            forKey: .diff
        ) ?? []
        canDecide = try container.decodeIfPresent(Bool.self, forKey: .canDecide) ?? true
        unavailableReason = try container.decodeIfPresent(String.self, forKey: .unavailableReason)
    }
}

// MARK: - WebSocket (client → server)

/// The union of everything a client can send, decoded permissively: `type` discriminates and
/// the rest are optional so one struct covers auth, input, submit and permission answers. The
/// `auth` frame carries the client's protocol pair for negotiation.
public struct RemoteClientMessage: Codable, Equatable, Sendable {
    public let type: String
    public let token: String?
    public let device: String?
    /// What to call this device in the Mac's sharing pane — "iPhone", "Safari on macOS".
    ///
    /// Additive and optional: a client that predates it simply omits it and the Mac falls back
    /// to the pseudonymous device id, so this needs no protocol bump. It is a label and never an
    /// identity — `device` is what authorization is bound to — and it arrives from the network,
    /// so the host normalises and bounds it exactly as it does a member's display name.
    public let deviceName: String?
    /// How many bytes of terminal replay this client can usefully retain when it joins.
    ///
    /// Additive and optional, so it needs no protocol bump: a client that predates it omits the
    /// field and receives the host's whole ring exactly as before. It is a statement about the
    /// client's own emulator — a renderer keeping a short scrollback parses a long replay only
    /// to trim most of it away — and never an entitlement, so the host bounds it the way it
    /// bounds every inbound value rather than replaying whatever number arrives.
    public let replayBudget: Int?
    public let protocolVersion: Int?
    public let protocolMinimum: Int?
    public let data: String?
    public let text: String?
    public let id: String?
    public let decision: String?
    public let state: String?
    public let cols: Int?
    public let rows: Int?
    public let beforeRowID: String?
    public let limit: Int?
    public let offset: Int?
    public let revision: Int?
    /// Stable human recipient for an app-owned attention request. It is never parsed from `text`.
    public let recipientID: String?
    /// Idempotency key for a prompt submission. Kept separate from `id`, which names permission
    /// cards and other domain objects.
    public let requestID: String?
    /// Structured references/comments submitted by a capable conversation client.
    public let contextAttachments: [RemoteConversationContextAttachmentDTO]?
    /// Completed uploads to hand over with this prompt, in the order the person attached them.
    ///
    /// Ids, never paths: the bytes already crossed over a separate authenticated route and the
    /// host resolves each id inside the routed session. A client never learns where the file
    /// landed, so it cannot name one it did not upload or one belonging to another session.
    public let attachmentUploadIDs: [String]?

    public init(
        type: String,
        token: String? = nil,
        device: String? = nil,
        deviceName: String? = nil,
        replayBudget: Int? = nil,
        protocolVersion: Int? = nil,
        protocolMinimum: Int? = nil,
        data: String? = nil,
        text: String? = nil,
        id: String? = nil,
        decision: String? = nil,
        state: String? = nil,
        cols: Int? = nil,
        rows: Int? = nil,
        beforeRowID: String? = nil,
        limit: Int? = nil,
        offset: Int? = nil,
        revision: Int? = nil,
        recipientID: String? = nil,
        requestID: String? = nil,
        contextAttachments: [RemoteConversationContextAttachmentDTO]? = nil,
        attachmentUploadIDs: [String]? = nil
    ) {
        self.type = type
        self.token = token
        self.device = device
        self.deviceName = deviceName
        self.replayBudget = replayBudget
        self.protocolVersion = protocolVersion
        self.protocolMinimum = protocolMinimum
        self.data = data
        self.text = text
        self.id = id
        self.decision = decision
        self.state = state
        self.cols = cols
        self.rows = rows
        self.beforeRowID = beforeRowID
        self.limit = limit
        self.offset = offset
        self.revision = revision
        self.recipientID = recipientID
        self.requestID = requestID
        self.contextAttachments = contextAttachments
        self.attachmentUploadIDs = attachmentUploadIDs
    }
}
