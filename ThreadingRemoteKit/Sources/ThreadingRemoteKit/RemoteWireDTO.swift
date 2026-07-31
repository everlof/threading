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
            typeface: String? = nil,
            fontFamily: String? = nil
        ) {
            self.panelRadius = panelRadius
            self.controlRadius = controlRadius
            self.borderWidth = borderWidth
            self.glow = glow
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
    public let background: String
    public let cursor: String
    public let selection: String
    /// ANSI indices 0...15, in terminal order.
    public let ansi: [String]

    public init(
        id: String,
        name: String,
        foreground: String,
        background: String,
        cursor: String,
        selection: String,
        ansi: [String]
    ) {
        self.id = id
        self.name = name
        self.foreground = foreground
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

/// One session as it appears to a remote client's session list.
public struct RemoteSessionSummaryDTO: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public let title: String
    public let agentKind: String
    /// "terminal" or "conversation".
    public let surface: String
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

    public init(
        id: String,
        title: String,
        agentKind: String,
        surface: String,
        state: String,
        projectName: String,
        isAvailable: Bool = true,
        lastActiveAt: Double? = nil,
        isPinned: Bool = false,
        isArchived: Bool = false,
        isShared: Bool = false,
        terminalTheme: RemoteTerminalThemeDTO? = nil,
        terminalThemeAssignmentID: String? = nil,
        inheritedTerminalThemeName: String? = nil,
        inheritedTerminalTheme: RemoteTerminalThemeDTO? = nil
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
        self.isShared = isShared
        self.terminalTheme = terminalTheme
        self.terminalThemeAssignmentID = terminalThemeAssignmentID
        self.inheritedTerminalThemeName = inheritedTerminalThemeName
        self.inheritedTerminalTheme = inheritedTerminalTheme
    }

    private enum CodingKeys: String, CodingKey {
        case id, title, agentKind, surface, state, projectName, isAvailable, lastActiveAt
        case isPinned, isArchived, isShared
        case terminalTheme, terminalThemeAssignmentID, inheritedTerminalThemeName
        case inheritedTerminalTheme
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        title = try container.decode(String.self, forKey: .title)
        agentKind = try container.decode(String.self, forKey: .agentKind)
        surface = try container.decode(String.self, forKey: .surface)
        state = try container.decode(String.self, forKey: .state)
        projectName = try container.decode(String.self, forKey: .projectName)
        // The first wire build listed only live sessions, so a missing field means available.
        isAvailable = try container.decodeIfPresent(Bool.self, forKey: .isAvailable) ?? true
        lastActiveAt = try container.decodeIfPresent(Double.self, forKey: .lastActiveAt)
        isPinned = try container.decodeIfPresent(Bool.self, forKey: .isPinned) ?? false
        isArchived = try container.decodeIfPresent(Bool.self, forKey: .isArchived) ?? false
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
    }
}

/// One added checkout a new remote session can run in. A branch is offered only when an added
/// checkout already stands on it, matching the Mac composer's safety rule.
public struct RemoteProjectChoiceDTO: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public let name: String
    public let branch: String?
    public let checkoutLabel: String

    public init(id: String, name: String, branch: String?, checkoutLabel: String) {
        self.id = id
        self.name = name
        self.branch = branch
        self.checkoutLabel = checkoutLabel
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

public struct RemoteModelChoiceDTO: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public let name: String
    public let reasoning: [RemoteReasoningChoiceDTO]
    public let defaultReasoningID: String?

    public init(
        id: String,
        name: String,
        reasoning: [RemoteReasoningChoiceDTO] = [],
        defaultReasoningID: String? = nil
    ) {
        self.id = id
        self.name = name
        self.reasoning = reasoning
        self.defaultReasoningID = defaultReasoningID
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

    public init(
        id: String,
        name: String,
        accounts: [RemoteAccountChoiceDTO]? = nil,
        models: [RemoteModelChoiceDTO],
        defaultModelID: String?,
        supportsConversation: Bool
    ) {
        self.id = id
        self.name = name
        self.accounts = accounts
        self.models = models
        self.defaultModelID = defaultModelID
        self.supportsConversation = supportsConversation
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

/// The Mac serving a share. Its stable id lets an iOS client replace the existing paired-device
/// record when the user rescans a short-lived relay URL after a later launch.
public struct RemoteHostDTO: Codable, Equatable, Sendable {
    public let id: String
    public let name: String
    public let platform: String

    public init(id: String, name: String, platform: String = "macOS") {
        self.id = id
        self.name = name
        self.platform = platform
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

    public init(
        serverProtocol: RemoteProtocolInfo,
        share: Share,
        sessions: [RemoteSessionSummaryDTO],
        host: RemoteHostDTO? = nil,
        theme: RemoteThemeDTO? = nil,
        themeCatalog: RemoteThemeCatalogDTO? = nil,
        archivedSessions: [RemoteSessionSummaryDTO]? = nil,
        newSessionCatalog: RemoteNewSessionCatalogDTO? = nil
    ) {
        self.serverProtocol = serverProtocol
        self.share = share
        self.sessions = sessions
        self.host = host
        self.theme = theme
        self.themeCatalog = themeCatalog
        self.archivedSessions = archivedSessions
        self.newSessionCatalog = newSessionCatalog
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
    /// "terminal" or "conversation".
    public let surface: String
    public let prompt: String

    public init(
        projectID: String,
        agentKind: String,
        accountHandle: String? = nil,
        model: String? = nil,
        reasoningEffort: String? = nil,
        surface: String,
        prompt: String
    ) {
        self.projectID = projectID
        self.agentKind = agentKind
        self.accountHandle = accountHandle
        self.model = model
        self.reasoningEffort = reasoningEffort
        self.surface = surface
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

public struct RemoteSetSessionSurfaceRequestDTO: Codable, Equatable, Sendable {
    /// `terminal` is the agent's original UI; `conversation` is Threading's Native UI.
    public let surface: String

    public init(surface: String) {
        self.surface = surface
    }
}

// MARK: - Git review

/// The four comparisons exposed by the compact mobile review sheet.
///
/// The Mac owns the git checkout and resolves these modes. A phone receives only the bounded,
/// parsed result, never a path it can use to reach the host filesystem directly.
public enum RemoteGitReviewMode: String, Codable, Equatable, CaseIterable, Sendable {
    case unstaged
    case staged
    case branch
    case lastTurn
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

/// One image or PDF that passed between the two parties during a session.
///
/// The path is relative to whatever the host resolved it against — the checkout for a file that
/// lives there, the host's own attachment store for one it took custody of — and is opaque to the
/// phone, which only ever hands it back. File bytes are fetched separately so the list remains
/// cheap and the phone never receives visual files it has not chosen to preview.
public struct RemoteAttachmentDTO: Codable, Equatable, Identifiable, Sendable {
    public let path: String
    public let name: String
    /// `image` or `pdf`.
    public let kind: String
    public let byteCount: Int64
    public let modifiedAt: Date?

    /// `agent` or `user`. Optional because a host from before provenance was recorded sends no
    /// such field, and a phone that guessed would be labelling rows with an answer nobody gave.
    public let origin: String?

    public var id: String { path }

    public init(
        path: String,
        name: String,
        kind: String,
        byteCount: Int64,
        modifiedAt: Date? = nil,
        origin: String? = nil
    ) {
        self.path = path
        self.name = name
        self.kind = kind
        self.byteCount = byteCount
        self.modifiedAt = modifiedAt
        self.origin = origin
    }
}

/// The current bounded attachment list for a session.
public struct RemoteAttachmentsDTO: Codable, Equatable, Sendable {
    public let attachments: [RemoteAttachmentDTO]

    public init(attachments: [RemoteAttachmentDTO]) {
        self.attachments = attachments
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
    public let surface: String     // "terminal" | "conversation"
    public let capability: String  // "view" | "interact"
    public let cols: Int
    public let rows: Int
    public let title: String
    public let theme: RemoteThemeDTO?
    public let terminalTheme: RemoteTerminalThemeDTO?

    public init(
        surface: String,
        capability: String,
        cols: Int,
        rows: Int,
        title: String,
        theme: RemoteThemeDTO? = nil,
        terminalTheme: RemoteTerminalThemeDTO? = nil
    ) {
        self.type = "hello"
        self.surface = surface
        self.capability = capability
        self.cols = cols
        self.rows = rows
        self.title = title
        self.theme = theme
        self.terminalTheme = terminalTheme
    }
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

/// A hint that the session catalogue changed. The event deliberately carries no sessions:
/// every subscriber may have a different share scope, so each client re-fetches its own
/// authorised `/api/me` snapshot instead of receiving somebody else's catalogue.
public struct RemoteSessionsChangedDTO: Codable, Equatable, Sendable {
    public let type: String

    public init() {
        self.type = "sessionsChanged"
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
    public let memberID: String
    public let displayName: String
    /// `typing` or `idle`.
    public let state: String
    public let updatedAt: Double

    public var id: String { memberID }

    public init(
        memberID: String,
        displayName: String,
        state: String,
        updatedAt: Double = Date().timeIntervalSince1970
    ) {
        self.type = "presence"
        self.memberID = memberID
        self.displayName = displayName
        self.state = state
        self.updatedAt = updatedAt
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
    case agentMessage
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
        self.createdAt = createdAt
    }
}

public struct RemoteNotificationRegistrationDTO: Codable, Equatable, Sendable {
    public let deviceToken: String
    /// "sandbox" for a development build, "production" for TestFlight/App Store.
    public let environment: String
    public let enabledKinds: [RemoteNotificationKind]

    public init(
        deviceToken: String,
        environment: String,
        enabledKinds: [RemoteNotificationKind]
    ) {
        self.deviceToken = deviceToken
        self.environment = environment
        self.enabledKinds = enabledKinds
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
public struct RemoteErrorDTO: Codable, Equatable, Sendable {
    public let type: String        // "error"
    public let code: String

    public init(code: String) {
        self.type = "error"
        self.code = code
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

/// A provider-neutral row in the native conversation surface. The Mac has already normalised
/// Claude and Codex into this vocabulary, so mobile clients do not need either provider parser.
public struct RemoteConversationRowDTO: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    /// "user", "assistant", "thinking", "tool", or "notice".
    public let kind: String
    public let text: String?
    public let toolName: String?
    public let summary: String?
    public let result: String?
    public let isError: Bool

    public init(
        id: String,
        kind: String,
        text: String? = nil,
        toolName: String? = nil,
        summary: String? = nil,
        result: String? = nil,
        isError: Bool = false
    ) {
        self.id = id
        self.kind = kind
        self.text = text
        self.toolName = toolName
        self.summary = summary
        self.result = result
        self.isError = isError
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
    public let permission: RemotePermissionRequestDTO?
    /// Monotonically increasing within one live conversation mirror.
    public let revision: Int
    /// True when the host has rows before the first row in this window.
    public let hasEarlier: Bool

    public init(
        rows: [RemoteConversationRowDTO],
        streamingText: String = "",
        canSend: Bool,
        permission: RemotePermissionRequestDTO? = nil,
        revision: Int = 0,
        hasEarlier: Bool = false
    ) {
        self.type = "conversation"
        self.rows = rows
        self.streamingText = streamingText
        self.canSend = canSend
        self.permission = permission
        self.revision = revision
        self.hasEarlier = hasEarlier
    }

    private enum CodingKeys: String, CodingKey {
        case type, rows, streamingText, canSend, permission, revision, hasEarlier
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

    public init(
        type: String,
        token: String? = nil,
        device: String? = nil,
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
        limit: Int? = nil
    ) {
        self.type = type
        self.token = token
        self.device = device
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
    }
}
