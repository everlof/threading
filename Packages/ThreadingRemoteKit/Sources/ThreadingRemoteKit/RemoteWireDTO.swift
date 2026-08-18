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
        public let typeface: String?

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
            typeface: String? = nil,
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
    /// Resolved `light` or `dark`; any adaptive Mac theme is resolved before sending.
    public let mode: String
    public let colors: [String: String]
    public let material: Material

    public init(
        id: String,
        name: String,
        mode: String,
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

    public init(name: String, glyph: String, isEmoji: Bool, hue: Double?) {
        self.name = name
        self.glyph = glyph
        self.isEmoji = isEmoji
        self.hue = hue
    }
}

/// One session as it appears to a remote client's session list.
public struct RemoteSessionSummaryDTO: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public let title: String
    public let agentKind: String
    public let surface: RemoteSessionSurface
    /// The activity state — "dormant" / "idle" / "working" / "needsAttention".
    public let state: String
    public let projectName: String
    /// Whether the session currently has a live surface a client can attach to.
    public let isAvailable: Bool
    /// Unix time for sorting and compact relative dates in mobile clients.
    public let lastActiveAt: Double?
    /// Pinned sessions sort ahead of the ordinary recency order on every client.
    public let isPinned: Bool
    /// Included so archived results can use the same row model as the active dashboard.
    public let isArchived: Bool
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

    public init(
        id: String,
        title: String,
        agentKind: String,
        surface: RemoteSessionSurface,
        state: String,
        projectName: String,
        isAvailable: Bool = true,
        lastActiveAt: Double? = nil,
        isPinned: Bool = false,
        isArchived: Bool = false,
        snoozedAt: Double? = nil,
        snoozedUntil: Double? = nil,
        wokeReason: String? = nil,
        wokeAt: Double? = nil,
        isShared: Bool = false,
        terminalTheme: RemoteTerminalThemeDTO? = nil,
        terminalThemeAssignmentID: String? = nil,
        inheritedTerminalThemeName: String? = nil,
        inheritedTerminalTheme: RemoteTerminalThemeDTO? = nil,
        account: RemoteSessionAccountDTO? = nil
    ) {
        self.id = id
        self.title = title
        self.agentKind = agentKind
        self.surface = surface
        self.state = state
        self.projectName = projectName
        self.isAvailable = isAvailable
        self.lastActiveAt = lastActiveAt
        self.isPinned = isPinned
        self.isArchived = isArchived
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
    }

    private enum CodingKeys: String, CodingKey {
        case id, title, agentKind, surface, state, projectName, isAvailable, lastActiveAt
        case isPinned, isArchived, isShared
        case snoozedAt, snoozedUntil, wokeReason, wokeAt
        case terminalTheme, terminalThemeAssignmentID, inheritedTerminalThemeName
        case inheritedTerminalTheme, account
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        title = try container.decode(String.self, forKey: .title)
        agentKind = try container.decode(String.self, forKey: .agentKind)
        surface = try container.decode(RemoteSessionSurface.self, forKey: .surface)
        state = try container.decode(String.self, forKey: .state)
        projectName = try container.decode(String.self, forKey: .projectName)
        // The first wire build listed only live sessions, so a missing field means available.
        isAvailable = try container.decodeIfPresent(Bool.self, forKey: .isAvailable) ?? true
        lastActiveAt = try container.decodeIfPresent(Double.self, forKey: .lastActiveAt)
        isPinned = try container.decodeIfPresent(Bool.self, forKey: .isPinned) ?? false
        isArchived = try container.decodeIfPresent(Bool.self, forKey: .isArchived) ?? false
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
    }

    /// Derived on the client as well as the host, so a missed refresh cannot keep an expired
    /// session hidden. A backwards wall-clock step deliberately keeps it snoozed to the deadline.
    public func isSnoozed(at date: Date = Date()) -> Bool {
        guard !isArchived, let snoozedAt, let snoozedUntil,
              snoozedAt < snoozedUntil else { return false }
        return date.timeIntervalSince1970 < snoozedUntil
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
/// Strings rather than closed enumerations for the same reason `surface` was: a host that grows
/// a third delivery must not make an older client fail to decode the whole catalogue. The Mac
/// maps them back to its own types and refuses what it does not recognise.
public struct RemoteManagedWorkspacePlanDTO: Codable, Equatable, Sendable {
    /// `mergeAndCleanUp` or `keepForReview`.
    public let delivery: String
    /// `draft` or `ready` when finishing should also open a change request; absent for local
    /// delivery, which is every workspace a phone can currently ask for.
    public let publication: String?

    public init(delivery: String, publication: String? = nil) {
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

/// One login available to an agent on the Mac. Only presentation-safe identity and the latest
/// normalized usage reading cross the wire; config paths and credentials never leave the host.
public struct RemoteAccountChoiceDTO: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public let name: String
    public let emoji: String?
    /// For example `5h 43% · 7d 73%`.
    public let usageSummary: String?
    /// Peak consumed fraction, 0...1, so clients can tint a compact usage cue consistently.
    public let usageFraction: Double?
    public let usageError: String?
    public let models: [RemoteModelChoiceDTO]
    public let defaultModelID: String?

    public init(
        id: String,
        name: String,
        emoji: String? = nil,
        usageSummary: String? = nil,
        usageFraction: Double? = nil,
        usageError: String? = nil,
        models: [RemoteModelChoiceDTO],
        defaultModelID: String?
    ) {
        self.id = id
        self.name = name
        self.emoji = emoji
        self.usageSummary = usageSummary
        self.usageFraction = usageFraction
        self.usageError = usageError
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

    public init(projects: [RemoteProjectChoiceDTO], agents: [RemoteAgentChoiceDTO]) {
        self.projects = projects
        self.agents = agents
    }
}

/// The `RemoteHostEndpointDTO.kind` vocabulary both products know today.
///
/// These are constants rather than an enum on purpose. `kind` is a `String` on the wire so a
/// newer Mac can advertise a route an installed phone has never heard of and that phone still
/// decodes the host instead of failing the whole payload — an enum with a synthesized `Codable`
/// would take that leniency away. The constants exist so the two products stop spelling the same
/// words in a dozen places, and so a reader can see the whole vocabulary at once.
///
/// What each one means, and who can see the traffic on it, is the table in
/// `docs/REMOTE_ACCESS.md` under the security model.
public enum RemoteHostEndpointKind {
    /// `127.0.0.1`. Reachable from the Mac itself only, and never advertised to another device.
    public static let loopback = "loopback"
    /// A routable address on a network the Mac is attached to, plus its `.local` name.
    public static let lan = "lan"
    /// The address the Mac holds on a VPN tunnel it did not set up.
    public static let vpn = "vpn"
    /// The Mac's tailnet address or `*.ts.net` name.
    public static let tailscale = "tailscale"
    /// A rendezvous route through the hosted service. No address of the Mac's own.
    public static let hosted = "hosted"
    /// A public tunnel origin operated by a third party.
    public static let relay = "relay"

    /// Every kind this build understands. A client uses it to notice an unknown kind rather
    /// than to reject one: an endpoint it cannot classify is ignored, not fatal.
    public static let known: Set<String> = [loopback, lan, vpn, tailscale, hosted, relay]
}

/// One currently usable route to the Mac's single authenticated remote-access server.
///
/// Endpoints carry no bearer and grant nothing by themselves. A paired client combines one with
/// its device credential only after applying the host's connection policy. `kind` stays a string
/// so an older client can ignore a future transport without failing to decode the whole host;
/// `RemoteHostEndpointKind` names the values this build produces.
public struct RemoteHostEndpointDTO: Codable, Equatable, Hashable, Sendable {
    public let kind: String
    public let baseURL: URL
    public let isStable: Bool

    public init(kind: String, baseURL: URL, isStable: Bool) {
        self.kind = kind
        self.baseURL = baseURL
        self.isStable = isStable
    }
}

/// The connection policy an owner selected on the Mac.
///
/// Unknown values are interpreted by clients as private-only. Adding a policy in a later host
/// must never make an older phone silently route private work through a public endpoint.
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
            allowed = valid.filter { $0.kind == RemoteHostEndpointKind.tailscale }
        case .relayOnly:
            allowed = valid.filter { $0.kind == RemoteHostEndpointKind.relay }
        case .preferPrivate:
            allowed = valid.filter {
                $0.kind == RemoteHostEndpointKind.tailscale
                    || $0.kind == RemoteHostEndpointKind.relay
            }
        }

        return allowed.sorted { lhs, rhs in
            func rank(_ endpoint: RemoteHostEndpointDTO) -> Int {
                switch policy {
                case .privateOnly, .relayOnly:
                    // A newly advertised stable endpoint replaces a remembered quick-tunnel
                    // address without asking the user to pair the same Mac again.
                    return endpoint.isStable ? 0 : (endpoint.baseURL == currentBaseURL ? 1 : 2)
                case .preferPrivate:
                    if endpoint.kind == RemoteHostEndpointKind.tailscale { return 0 }
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

    public init(
        id: String,
        name: String,
        platform: String = "macOS",
        endpoints: [RemoteHostEndpointDTO]? = nil,
        connectionPolicy: RemoteHostConnectionPolicy? = nil
    ) {
        self.id = id
        self.name = name
        self.platform = platform
        self.endpoints = endpoints
        self.connectionPolicy = connectionPolicy
    }
}

/// Optional REST surfaces advertised by `GET /api/me`. Raw strings keep discovery additive:
/// older clients ignore the field and newer clients can ignore feature names they do not know.
public enum RemoteRESTFeature: String, Codable, CaseIterable, Sendable {
    case usageDashboard = "usage-dashboard"
    case hostedPeerTransport = "hosted-peer-transport"
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
    public let state: String
    public let sourceCount: Int
    public let recordCount: Int
    public let detail: String?

    public init(
        runtimeID: String,
        runtimeName: String,
        state: String,
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
    public let id: String
    public let runtimeName: String
    public let accountName: String
    public let windowLabel: String
    public let currentFraction: Double?
    public let resetsAt: Double?
    /// Nil means the provider did not report inventory; zero is authoritative empty inventory.
    public let bankedResetCount: Int?
    public let nextBankedResetExpiresAt: Double?

    public init(
        id: String,
        runtimeName: String,
        accountName: String,
        windowLabel: String,
        currentFraction: Double?,
        resetsAt: Double?,
        bankedResetCount: Int?,
        nextBankedResetExpiresAt: Double?
    ) {
        self.id = id
        self.runtimeName = runtimeName
        self.accountName = accountName
        self.windowLabel = windowLabel
        self.currentFraction = currentFraction
        self.resetsAt = resetsAt
        self.bankedResetCount = bankedResetCount
        self.nextBankedResetExpiresAt = nextBankedResetExpiresAt
    }

    public var title: String { "\(runtimeName) · \(accountName) · \(windowLabel)" }
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
    /// `scheduled`, `provider`, or `bankedCredit`.
    public let cause: String
    public let restoredFraction: Double
    public let elapsedFraction: Double
    public let paceGainFraction: Double

    public init(
        id: String,
        detectedAt: Double,
        previousObservedAt: Double,
        cause: String,
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

/// The `GET /api/me` payload: the protocol the server speaks, what this share is, and the
/// sessions it reaches. The protocol pair is included so a client can verify compatibility even
/// on a request the server chose to answer.
public struct RemoteMeDTO: Codable, Equatable, Sendable {
    public struct Share: Codable, Equatable, Sendable {
        public let label: String
        /// "all" for a My Devices share, "session" for a guest share of one session.
        public let scope: String
        public let capability: String
        /// Independently granted per chat member. An interactive guest may collaborate without
        /// this right, or be trusted to review requests caused by their work.
        public let canApprovePermissions: Bool
        public let expiresAt: Double?
        public let memberID: String?
        public let displayName: String?

        public init(
            label: String,
            scope: String,
            capability: String,
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
            scope = try container.decode(String.self, forKey: .scope)
            capability = try container.decode(String.self, forKey: .capability)
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

    public init(
        serverProtocol: RemoteProtocolInfo,
        share: Share,
        sessions: [RemoteSessionSummaryDTO],
        host: RemoteHostDTO? = nil,
        theme: RemoteThemeDTO? = nil,
        themeCatalog: RemoteThemeCatalogDTO? = nil,
        archivedSessions: [RemoteSessionSummaryDTO]? = nil,
        newSessionCatalog: RemoteNewSessionCatalogDTO? = nil,
        features: [String]? = nil
    ) {
        self.serverProtocol = serverProtocol
        self.share = share
        self.sessions = sessions
        self.host = host
        self.theme = theme
        self.themeCatalog = themeCatalog
        self.archivedSessions = archivedSessions
        self.newSessionCatalog = newSessionCatalog
        self.features = features
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
    /// "view" or "interact".
    public let capability: String
    /// An independent, chat-scoped right. Ignored unless capability is `interact`.
    public let canApprovePermissions: Bool

    public init(capability: String, canApprovePermissions: Bool = false) {
        self.capability = capability
        self.canApprovePermissions = canApprovePermissions
    }

    private enum CodingKeys: String, CodingKey {
        case capability, canApprovePermissions
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        capability = try container.decode(String.self, forKey: .capability)
        canApprovePermissions = try container.decodeIfPresent(
            Bool.self,
            forKey: .canApprovePermissions
        ) ?? false
    }
}

public struct RemoteCreateShareResponseDTO: Codable, Equatable, Sendable {
    public let url: String
    public let capability: String
    public let canApprovePermissions: Bool
    /// Expiry of the unused invitation. An accepted membership has no timer.
    public let expiresAt: Double
    public let me: RemoteMeDTO

    public init(
        url: String,
        capability: String,
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
        self.prompt = prompt
    }
}

public struct RemoteCreateSessionResponseDTO: Codable, Equatable, Sendable {
    public let sessionID: String
    public let me: RemoteMeDTO

    public init(sessionID: String, me: RemoteMeDTO) {
        self.sessionID = sessionID
        self.me = me
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
    /// `context`, `addition`, or `removal`.
    public let kind: String
    public let text: String
    public let oldNumber: Int?
    public let newNumber: Int?

    public init(
        kind: String,
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
    /// `modified`, `added`, `deleted`, `untracked`, `renamed`, or `binary`.
    public let change: String
    public let renamedFrom: String?
    public let hunks: [RemoteGitHunkDTO]
    public let added: Int
    public let removed: Int
    /// True when the host shortened this file's line payload for the remote surface.
    public let isTruncated: Bool

    public var id: String { path }

    public init(
        path: String,
        change: String,
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
    /// `image`, `pdf`, `html`, `archive`, `document`, `diagram`, or `media`. A string rather
    /// than an enum on purpose: a phone from before a kind existed still decodes the row and
    /// falls into its default presentation, instead of refusing the whole list — which is
    /// exactly what happened when `media` was added, and why nothing here had to change for a
    /// phone that predates it.
    public let kind: String
    public let byteCount: Int64
    public let modifiedAt: Date?

    /// `agent` or `user`. Optional because a host from before provenance was recorded sends no
    /// such field, and a phone that guessed would be labelling rows with an answer nobody gave.
    public let origin: String?

    public init(
        path: String,
        name: String,
        kind: String,
        byteCount: Int64,
        modifiedAt: Date? = nil,
        origin: String? = nil,
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
        kind = try container.decode(String.self, forKey: .kind)
        byteCount = try container.decode(Int64.self, forKey: .byteCount)
        modifiedAt = try container.decodeIfPresent(Date.self, forKey: .modifiedAt)
        origin = try container.decodeIfPresent(String.self, forKey: .origin)
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
    /// "pendingApproval" or "denied".
    public let state: String
    /// Seconds the client should wait before polling `/api/me` again.
    public let retryAfter: Double?

    public init(state: String, retryAfter: Double?) {
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
        self.error = "protocolMismatch"
        self.update = update
        self.serverProtocol = serverProtocol
        self.message = message
    }
}

// MARK: - WebSocket (server → client)

/// Sent once, immediately after a socket authenticates, describing the surface it is watching.
public struct RemoteHelloDTO: Codable, Equatable, Sendable {
    public let type: String        // "hello"
    public let surface: RemoteSessionSurface
    public let capability: String  // "view" | "interact"
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
        capability: String,
        cols: Int,
        rows: Int,
        title: String,
        theme: RemoteThemeDTO? = nil,
        terminalTheme: RemoteTerminalThemeDTO? = nil,
        features: [String]? = nil
    ) {
        self.type = "hello"
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
    /// Human attention is a separate app-owned action and never prompt text or PTY input.
    case attentionRequests
    /// The host can make one person the writer without discarding anybody else's draft.
    case focusedInputControl
    /// Native conversation rows and prompt submissions carry structured references/comments.
    case conversationContextAttachments
    /// A composing client may hand the host file bytes and submit them beside its prompt.
    ///
    /// Advertised only when the connection could actually use it. Uploading is an owner-scope
    /// write into the host's own attachment custody, so a view-only or guest connection never
    /// sees the feature and never renders an attach affordance it would be refused for.
    case composerAttachmentUploads
}

/// A live theme change while a session is already open.
public struct RemoteThemeUpdateDTO: Codable, Equatable, Sendable {
    public let type: String
    public let theme: RemoteThemeDTO
    public let terminalTheme: RemoteTerminalThemeDTO

    public init(theme: RemoteThemeDTO, terminalTheme: RemoteTerminalThemeDTO) {
        self.type = "theme"
        self.theme = theme
        self.terminalTheme = terminalTheme
    }
}

/// A live app-chrome change for clients on the session dashboard.
public struct RemoteAppThemeUpdateDTO: Codable, Equatable, Sendable {
    public let type: String
    public let theme: RemoteThemeDTO

    public init(theme: RemoteThemeDTO) {
        self.type = "appTheme"
        self.theme = theme
    }
}

/// A scoped session-catalogue change. Row-only mutations carry one already-authorised summary so
/// clients can update in O(changed) work. Structural mutations leave both delta fields nil and
/// ask the client to fetch its own authoritative `/api/me` snapshot.
public struct RemoteSessionsChangedDTO: Codable, Equatable, Sendable {
    public let type: String
    public let session: RemoteSessionSummaryDTO?
    public let removedSessionID: String?

    public init(
        session: RemoteSessionSummaryDTO? = nil,
        removedSessionID: String? = nil
    ) {
        self.type = "sessionsChanged"
        self.session = session
        self.removedSessionID = removedSessionID
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
        self.type = "workspaceChanged"
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
    /// `viewing`, `typing`, or `left`. Older clients may still send `idle`.
    public let state: String
    public let updatedAt: Double

    public var id: String { presenceID ?? memberID }

    public init(
        presenceID: String? = nil,
        memberID: String,
        displayName: String,
        deviceName: String? = nil,
        surface: RemoteSessionSurface? = nil,
        state: String,
        updatedAt: Double = Date().timeIntervalSince1970
    ) {
        self.type = "presence"
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
    public let role: String
    public let isOnline: Bool

    public init(id: String, displayName: String, role: String, isOnline: Bool) {
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
        self.type = "collaborationParticipants"
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
        self.type = "inputControl"
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
        self.type = "inputControlResult"
        self.requestID = requestID
        self.status = status
    }
}

/// Quiet collaboration activity. It never becomes prompt text or a terminal write.
public struct RemoteInputControlEventDTO: Codable, Equatable, Identifiable, Sendable {
    public let type: String
    public let id: String
    /// `modeChanged`, `handedOff`, `reclaimed`, `requested`, or `released`.
    public let action: String
    public let actorID: String
    public let actorDisplayName: String
    public let targetID: String?
    public let targetDisplayName: String?
    public let createdAt: Double

    public init(
        id: String = UUID().uuidString.lowercased(),
        action: String,
        actorID: String,
        actorDisplayName: String,
        targetID: String? = nil,
        targetDisplayName: String? = nil,
        createdAt: Double = Date().timeIntervalSince1970
    ) {
        self.type = "inputControlEvent"
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
        self.type = "attentionResult"
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
        self.type = "attention"
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
        self.type = "submitResult"
        self.requestID = requestID
        self.status = status
    }
}

/// The active PTY size. An interactive phone owns this grid while its terminal is visible;
/// view-only clients follow it, just as they follow the Mac's grid when no controller is active.
public struct RemoteResizeDTO: Codable, Equatable, Sendable {
    public let type: String        // "resize"
    public let cols: Int
    public let rows: Int

    public init(cols: Int, rows: Int) {
        self.type = "resize"
        self.cols = cols
        self.rows = rows
    }
}

/// The terminal title changed after the initial hello (usually through OSC 0/2).
public struct RemoteTitleDTO: Codable, Equatable, Sendable {
    public let type: String        // "title"
    public let title: String

    public init(title: String) {
        self.type = "title"
        self.title = title
    }
}

// MARK: - Notifications

public enum RemoteNotificationKind: String, Codable, CaseIterable, Sendable {
    case sharedSession
    case permissionRequest
    case agentQuestion
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
        createdAt: Double = Date().timeIntervalSince1970
    ) {
        self.type = "notification"
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
    }

    private enum CodingKeys: String, CodingKey {
        case type, id, kind, hostID, sessionID, title, body
        case titleLocalization, bodyLocalization, destination, createdAt
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
    }
}

public struct RemoteNotificationRegistrationDTO: Codable, Equatable, Sendable {
    public let deviceToken: String
    /// "sandbox" for a development build, "production" for TestFlight/App Store.
    public let environment: String
    public let enabledKinds: [RemoteNotificationKind]
    /// Kinds that may make sound on this device. Nil preserves the behavior of an older client;
    /// an empty array is an explicit request for quiet delivery.
    public let soundEnabledKinds: [RemoteNotificationKind]?

    public init(
        deviceToken: String,
        environment: String,
        enabledKinds: [RemoteNotificationKind],
        soundEnabledKinds: [RemoteNotificationKind]? = nil
    ) {
        self.deviceToken = deviceToken
        self.environment = environment
        self.enabledKinds = enabledKinds
        self.soundEnabledKinds = soundEnabledKinds
    }
}

public struct RemoteNotificationRegistrationResponseDTO: Codable, Equatable, Sendable {
    /// "push" when this Mac can reach APNs, otherwise "live".
    public let delivery: String

    public init(delivery: String) {
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
    public static let columns = 20...240
    public static let rows = 4...160
}

public struct RemoteErrorDTO: Codable, Equatable, Sendable {
    public let type: String        // "error"
    public let code: String
    /// A bounded machine token qualifying `code`, such as the guard clause that refused. It is
    /// optional because a host from before this field simply omits it.
    public let detail: String?

    public init(code: String, detail: String? = nil) {
        self.type = "error"
        self.code = code
        self.detail = detail
    }
}

/// The session's mirror is ending. `update` is set only when the reason is a protocol mismatch,
/// naming the side that must update.
public struct RemoteEndedDTO: Codable, Equatable, Sendable {
    public let type: String        // "ended"
    public let reason: String
    public let update: RemoteUpdateTarget?

    public init(reason: String, update: RemoteUpdateTarget? = nil) {
        self.type = "ended"
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
    /// "command" or "skill".
    public let kind: String
    /// `true` lets an unclassified initial Claude row remain discoverable in `/skills` until
    /// the provider publishes authoritative skill membership. Missing means `kind == "skill"`
    /// for compatibility with older peers.
    public let isAvailableInSkillCatalog: Bool?
    /// "slash" or "dollar".
    public let trigger: String
    /// "turn" or "command"; presentation only, execution remains on the Mac.
    public let presentation: String
    public let isEnabled: Bool
    public let unavailableReason: String?

    public init(
        id: String,
        name: String,
        displayName: String,
        description: String,
        argumentHint: String,
        aliases: [String] = [],
        kind: String,
        isAvailableInSkillCatalog: Bool? = nil,
        trigger: String,
        presentation: String,
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
        (trigger == "dollar" ? "$" : "/") + name
    }

    public var canBrowseAsSkill: Bool {
        isAvailableInSkillCatalog ?? (kind == "skill")
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
    /// "reference" or "comment".
    public let kind: String
    /// "message", "code", "attachment", "workspaceFile", or "session".
    public let source: String
    public let title: String
    public let excerpt: String?
    public let comment: String?
    public let locator: String?
    public let lineStart: Int?
    public let lineEnd: Int?

    public init(
        id: String,
        kind: String,
        source: String,
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
    /// "user", "assistant", "thinking", "tool", or "notice".
    public let kind: String
    public let text: String?
    public let toolName: String?
    public let summary: String?
    public let result: String?
    public let isError: Bool
    /// Additive so older peers decode the rest of the row unchanged.
    public let contextAttachments: [RemoteConversationContextAttachmentDTO]?

    public init(
        id: String,
        kind: String,
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
        self.type = "conversation"
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
        self.type = "conversationDelta"
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
        self.type = "conversationPage"
        self.rows = rows
        self.beforeRowID = beforeRowID
        self.hasEarlier = hasEarlier
    }
}

/// A line in the edit preview attached to a permission request.
public struct RemotePermissionDiffLineDTO: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    /// "context", "addition", or "removal".
    public let kind: String
    public let text: String

    public init(id: String, kind: String, text: String) {
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
        self.type = "permission"
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
        recipientID: String? = nil,
        requestID: String? = nil,
        contextAttachments: [RemoteConversationContextAttachmentDTO]? = nil,
        attachmentUploadIDs: [String]? = nil
    ) {
        self.type = type
        self.token = token
        self.device = device
        self.deviceName = deviceName
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
        self.recipientID = recipientID
        self.requestID = requestID
        self.contextAttachments = contextAttachments
        self.attachmentUploadIDs = attachmentUploadIDs
    }
}
