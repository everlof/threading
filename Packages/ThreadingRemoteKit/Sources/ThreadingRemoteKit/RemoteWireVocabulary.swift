import Foundation

/// A string token sent by the host that an older client must be able to preserve even when a
/// newer host adds a case. Concrete enums keep decisions exhaustive for known values while the
/// shared codec keeps their wire representation as the original single JSON string.
public protocol RemoteLosslessStringToken:
    RawRepresentable, Codable, Equatable, Hashable, Sendable where RawValue == String {}

public extension RemoteLosslessStringToken {
    init(from decoder: Decoder) throws {
        let rawValue = try decoder.singleValueContainer().decode(String.self)
        guard let value = Self(rawValue: rawValue) else {
            throw DecodingError.dataCorrupted(
                .init(codingPath: decoder.codingPath, debugDescription: "Invalid remote token")
            )
        }
        self = value
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

public enum RemoteThemeMode: RemoteLosslessStringToken {
    case light
    case dark
    case unknown(String)

    public init(rawValue: String) {
        switch rawValue {
        case "light": self = .light
        case "dark": self = .dark
        default: self = .unknown(rawValue)
        }
    }

    public var rawValue: String {
        switch self {
        case .light: return "light"
        case .dark: return "dark"
        case let .unknown(value): return value
        }
    }
}

public enum RemoteThemeTypeface: RemoteLosslessStringToken {
    case `default`
    case serif
    case rounded
    case monospaced
    case unknown(String)

    public init(rawValue: String) {
        switch rawValue {
        case "default": self = .default
        case "serif": self = .serif
        case "rounded": self = .rounded
        case "monospaced": self = .monospaced
        default: self = .unknown(rawValue)
        }
    }

    public var rawValue: String {
        switch self {
        case .default: return "default"
        case .serif: return "serif"
        case .rounded: return "rounded"
        case .monospaced: return "monospaced"
        case let .unknown(value): return value
        }
    }
}

public enum RemoteManagedWorkspaceDelivery: RemoteLosslessStringToken {
    case mergeAndCleanUp
    case keepForReview
    case unknown(String)

    public init(rawValue: String) {
        switch rawValue {
        case "mergeAndCleanUp": self = .mergeAndCleanUp
        case "keepForReview": self = .keepForReview
        default: self = .unknown(rawValue)
        }
    }

    public var rawValue: String {
        switch self {
        case .mergeAndCleanUp: return "mergeAndCleanUp"
        case .keepForReview: return "keepForReview"
        case let .unknown(value): return value
        }
    }

    public var isKnown: Bool {
        if case .unknown = self { return false }
        return true
    }
}

public enum RemoteManagedWorkspacePublication: RemoteLosslessStringToken {
    case draft
    case ready
    case unknown(String)

    public init(rawValue: String) {
        switch rawValue {
        case "draft": self = .draft
        case "ready": self = .ready
        default: self = .unknown(rawValue)
        }
    }

    public var rawValue: String {
        switch self {
        case .draft: return "draft"
        case .ready: return "ready"
        case let .unknown(value): return value
        }
    }

    public var isKnown: Bool {
        if case .unknown = self { return false }
        return true
    }
}

public enum RemoteUsageLimitResetCause: RemoteLosslessStringToken {
    case scheduled
    case provider
    case bankedCredit
    case unknown(String)

    public init(rawValue: String) {
        switch rawValue {
        case "scheduled": self = .scheduled
        case "provider": self = .provider
        case "bankedCredit": self = .bankedCredit
        default: self = .unknown(rawValue)
        }
    }

    public var rawValue: String {
        switch self {
        case .scheduled: return "scheduled"
        case .provider: return "provider"
        case .bankedCredit: return "bankedCredit"
        case let .unknown(value): return value
        }
    }
}

public enum RemoteUsageCoverageState: RemoteLosslessStringToken {
    case complete
    case partial
    case unavailable
    case failed
    case unknown(String)

    public init(rawValue: String) {
        switch rawValue {
        case "complete": self = .complete
        case "partial": self = .partial
        case "unavailable": self = .unavailable
        case "failed": self = .failed
        default: self = .unknown(rawValue)
        }
    }

    public var rawValue: String {
        switch self {
        case .complete: return "complete"
        case .partial: return "partial"
        case .unavailable: return "unavailable"
        case .failed: return "failed"
        case let .unknown(value): return value
        }
    }
}

public enum RemoteShareScope: RemoteLosslessStringToken {
    case all
    case session
    case terminal
    case unknown(String)

    public init(rawValue: String) {
        switch rawValue {
        case "all": self = .all
        case "session": self = .session
        case "terminal": self = .terminal
        default: self = .unknown(rawValue)
        }
    }

    public var rawValue: String {
        switch self {
        case .all: return "all"
        case .session: return "session"
        case .terminal: return "terminal"
        case let .unknown(value): return value
        }
    }
}

/// Capability as advertised by a host. Client mutations use the closed `RemoteCapability`
/// instead, so an unknown request is rejected while a future host response remains decodable.
public enum RemoteAdvertisedCapability: RemoteLosslessStringToken {
    case view
    case interact
    case unknown(String)

    public init(rawValue: String) {
        switch rawValue {
        case "view": self = .view
        case "interact": self = .interact
        default: self = .unknown(rawValue)
        }
    }

    public init(_ capability: RemoteCapability) {
        switch capability {
        case .view: self = .view
        case .interact: self = .interact
        }
    }

    public var rawValue: String {
        switch self {
        case .view: return "view"
        case .interact: return "interact"
        case let .unknown(value): return value
        }
    }

    public var knownCapability: RemoteCapability? {
        switch self {
        case .view: return .view
        case .interact: return .interact
        case .unknown: return nil
        }
    }
}

public enum RemoteDeviceApprovalState: RemoteLosslessStringToken {
    case pendingApproval
    case denied
    case unknown(String)

    public init(rawValue: String) {
        switch rawValue {
        case "pendingApproval": self = .pendingApproval
        case "denied": self = .denied
        default: self = .unknown(rawValue)
        }
    }

    public var rawValue: String {
        switch self {
        case .pendingApproval: return "pendingApproval"
        case .denied: return "denied"
        case let .unknown(value): return value
        }
    }
}

public enum RemoteNotificationEnvironment: String, Codable, Equatable, Hashable, Sendable {
    case sandbox
    case production
}

public enum RemoteNotificationDelivery: RemoteLosslessStringToken {
    case push
    case live
    case unknown(String)

    public init(rawValue: String) {
        switch rawValue {
        case "push": self = .push
        case "live": self = .live
        default: self = .unknown(rawValue)
        }
    }

    public var rawValue: String {
        switch self {
        case .push: return "push"
        case .live: return "live"
        case let .unknown(value): return value
        }
    }
}

/// Optional notification behavior a receiving device explicitly advertises.
///
/// Lossless decoding lets a newer phone register through an older-compatible Mac build without
/// making an unrelated notification preference unreadable. A sender acts only on known cases.
public enum RemoteNotificationCapability: RemoteLosslessStringToken {
    case turnCompletionPreview
    case notificationRetraction
    case unknown(String)

    public init(rawValue: String) {
        switch rawValue {
        case "turnCompletionPreview": self = .turnCompletionPreview
        case "notificationRetraction": self = .notificationRetraction
        default: self = .unknown(rawValue)
        }
    }

    public var rawValue: String {
        switch self {
        case .turnCompletionPreview: return "turnCompletionPreview"
        case .notificationRetraction: return "notificationRetraction"
        case let .unknown(value): return value
        }
    }
}

// MARK: - Remote content

public enum RemoteDiffLineKind: RemoteLosslessStringToken {
    case context
    case addition
    case removal
    case unknown(String)

    public init(rawValue: String) {
        switch rawValue {
        case "context": self = .context
        case "addition": self = .addition
        case "removal": self = .removal
        default: self = .unknown(rawValue)
        }
    }

    public var rawValue: String {
        switch self {
        case .context: return "context"
        case .addition: return "addition"
        case .removal: return "removal"
        case let .unknown(value): return value
        }
    }
}

public enum RemoteGitFileChange: RemoteLosslessStringToken {
    case modified
    case added
    case deleted
    case untracked
    case renamed
    case binary
    case unknown(String)

    public init(rawValue: String) {
        switch rawValue {
        case "modified": self = .modified
        case "added": self = .added
        case "deleted": self = .deleted
        case "untracked": self = .untracked
        case "renamed": self = .renamed
        case "binary": self = .binary
        default: self = .unknown(rawValue)
        }
    }

    public var rawValue: String {
        switch self {
        case .modified: return "modified"
        case .added: return "added"
        case .deleted: return "deleted"
        case .untracked: return "untracked"
        case .renamed: return "renamed"
        case .binary: return "binary"
        case let .unknown(value): return value
        }
    }
}

public enum RemoteAttachmentKind: RemoteLosslessStringToken {
    case image
    case pdf
    case html
    case archive
    case document
    case diagram
    case video
    case media
    case text
    case unknown(String)

    public init(rawValue: String) {
        switch rawValue {
        case "image": self = .image
        case "pdf": self = .pdf
        case "html": self = .html
        case "archive": self = .archive
        case "document": self = .document
        case "diagram": self = .diagram
        case "video": self = .video
        case "media": self = .media
        case "text": self = .text
        default: self = .unknown(rawValue)
        }
    }

    public var rawValue: String {
        switch self {
        case .image: return "image"
        case .pdf: return "pdf"
        case .html: return "html"
        case .archive: return "archive"
        case .document: return "document"
        case .diagram: return "diagram"
        case .video: return "video"
        case .media: return "media"
        case .text: return "text"
        case let .unknown(value): return value
        }
    }
}

public enum RemoteAttachmentOrigin: RemoteLosslessStringToken {
    case agent
    case user
    case unknown(String)

    public init(rawValue: String) {
        switch rawValue {
        case "agent": self = .agent
        case "user": self = .user
        default: self = .unknown(rawValue)
        }
    }

    public var rawValue: String {
        switch self {
        case .agent: return "agent"
        case .user: return "user"
        case let .unknown(value): return value
        }
    }
}

public enum RemoteComposerCapabilityKind: RemoteLosslessStringToken {
    case command
    case skill
    case unknown(String)

    public init(rawValue: String) {
        switch rawValue {
        case "command": self = .command
        case "skill": self = .skill
        default: self = .unknown(rawValue)
        }
    }

    public var rawValue: String {
        switch self {
        case .command: return "command"
        case .skill: return "skill"
        case let .unknown(value): return value
        }
    }
}

public enum RemoteComposerCapabilityTrigger: RemoteLosslessStringToken {
    case slash
    case dollar
    case unknown(String)

    public init(rawValue: String) {
        switch rawValue {
        case "slash": self = .slash
        case "dollar": self = .dollar
        default: self = .unknown(rawValue)
        }
    }

    public var rawValue: String {
        switch self {
        case .slash: return "slash"
        case .dollar: return "dollar"
        case let .unknown(value): return value
        }
    }
}

public enum RemoteComposerCapabilityPresentation: RemoteLosslessStringToken {
    case turn
    case command
    case unknown(String)

    public init(rawValue: String) {
        switch rawValue {
        case "turn": self = .turn
        case "command": self = .command
        default: self = .unknown(rawValue)
        }
    }

    public var rawValue: String {
        switch self {
        case .turn: return "turn"
        case .command: return "command"
        case let .unknown(value): return value
        }
    }
}

public enum RemoteConversationContextKind: RemoteLosslessStringToken {
    case reference
    case comment
    case unknown(String)

    public init(rawValue: String) {
        switch rawValue {
        case "reference": self = .reference
        case "comment": self = .comment
        default: self = .unknown(rawValue)
        }
    }

    public var rawValue: String {
        switch self {
        case .reference: return "reference"
        case .comment: return "comment"
        case let .unknown(value): return value
        }
    }
}

public enum RemoteConversationContextSource: RemoteLosslessStringToken {
    case message
    case code
    case attachment
    case workspaceFile
    case session
    case unknown(String)

    public init(rawValue: String) {
        switch rawValue {
        case "message": self = .message
        case "code": self = .code
        case "attachment": self = .attachment
        case "workspaceFile": self = .workspaceFile
        case "session": self = .session
        default: self = .unknown(rawValue)
        }
    }

    public var rawValue: String {
        switch self {
        case .message: return "message"
        case .code: return "code"
        case .attachment: return "attachment"
        case .workspaceFile: return "workspaceFile"
        case .session: return "session"
        case let .unknown(value): return value
        }
    }
}

public enum RemoteConversationRowKind: RemoteLosslessStringToken {
    case user
    case assistant
    case thinking
    case tool
    case notice
    case unknown(String)

    public init(rawValue: String) {
        switch rawValue {
        case "user": self = .user
        case "assistant": self = .assistant
        case "thinking": self = .thinking
        case "tool": self = .tool
        case "notice": self = .notice
        default: self = .unknown(rawValue)
        }
    }

    public var rawValue: String {
        switch self {
        case .user: return "user"
        case .assistant: return "assistant"
        case .thinking: return "thinking"
        case .tool: return "tool"
        case .notice: return "notice"
        case let .unknown(value): return value
        }
    }
}

// MARK: - Routes

/// Fixed path components shared by the remote client and host router.
///
/// `CaseIterable` so the cross-boundary round-trip test can walk every action: a new case that
/// nobody wired into both ends becomes a compile error in that test's exhaustive switch rather
/// than an untested route.
public enum RemoteSessionRouteAction: String, CaseIterable, Codable, Equatable, Hashable, Sendable {
    case resume
    case theme
    case rename
    case pinned
    case archived
    case snoozed
    case surface
    case account
    /// Cross-provider continuation: `GET` lists where this conversation could continue, `POST`
    /// creates the destination. A different verb from `account`, which moves one native
    /// transcript between logins of the same runtime.
    case continuation
    case limitRecovery = "limit-recovery"
    case share
    case unshare
    case gitReview = "git-review"
    case repositoryFiles = "repository-files"
    case repositoryFile = "repository-file"
    case attachments
    case attachment
    case attachmentThumbnail = "attachment-thumbnail"
    case attachmentUpload = "attachment-upload"
    case workspace
    case browserPreview = "browser-preview"
    case extensionPanel = "extension-panel"
    case extensionPanelResource = "extension-panel-resource"
}

public enum RemoteTerminalRouteAction: String, CaseIterable, Codable, Equatable, Hashable, Sendable {
    case resume
    case share
    case unshare
}

/// Every top-level REST route on the remote door.
///
/// The route strings used to be spelled twice — once as literals the client appended onto its
/// base URL, once as rooted path constants the host matched — so a rename could pass both
/// suites and still break the phone. One owner makes that fail closed: the client builds from
/// `rawValue`, the host matches `absolutePath` or `prefix`, and neither can move alone.
///
/// The raw value carries no leading slash because that is the form a client appends; the host's
/// rooted spelling is derived rather than stored, so the two cannot disagree.
public enum RemoteRoute: String, CaseIterable, Sendable {
    case me = "api/me"
    case search = "api/search"
    case usage = "api/usage"
    case usageLimit = "api/usage/limit"
    case session = "api/session"
    case terminal = "api/terminal"
    case theme = "api/theme"
    case notifications = "api/notifications"
    case diagnostics = "api/diagnostics"
    case localDiagnosticsCapture = "api/local-diagnostics/capture"
    case invitationAcceptance = "api/invitations/accept"
    case hostedDeviceCredential = "api/hosted-device-credential"
    case settings = "api/settings"

    /// The rooted path a host matches an incoming request against.
    public var absolutePath: String { "/" + rawValue }

    /// The rooted path plus its separator, for a route that owns a subtree — `/api/session/…`.
    public var prefix: String { absolutePath + "/" }
}

/// Every websocket route on the remote door, in the same one-owner shape as `RemoteRoute`.
public enum RemoteSocketRoute: String, CaseIterable, Sendable {
    case events = "ws/events"
    case session = "ws/session"
    case terminal = "ws/terminal"

    /// The rooted path a host matches an incoming upgrade against.
    public var absolutePath: String { "/" + rawValue }

    /// The rooted path plus its separator, for the two routes that address an id underneath.
    public var prefix: String { absolutePath + "/" }

    /// The component form a client builds with, since `URL.appendingPathComponent` takes one
    /// segment at a time and each id appended after these must stay separately escaped.
    public var pathComponents: [String] { rawValue.split(separator: "/").map(String.init) }
}

/// The request headers the remote protocol defines.
///
/// Lowercase because that is what the host stores: `MCPConnection` lowercases every header name
/// as it parses, so a client may send any casing and the comparison still holds. Naming them
/// here keeps a client from inventing a sixth spelling of a header the host never reads.
public enum RemoteHeader: String, CaseIterable, Sendable {
    case device = "x-threading-device"
    case client = "x-threading-client"
    case requestID = "x-threading-request-id"
    case protocolVersion = "x-threading-protocol"
    case protocolMinimum = "x-threading-protocol-min"
}

/// What a client calls itself in `RemoteHeader.client`.
///
/// Lowercase for the same reason as the headers: the host lowercases the value before comparing
/// it, so this is the normalized form both ends can agree on without a third spelling.
public enum RemoteClientKind: String, CaseIterable, Sendable {
    case iOS = "threading-ios"
    case web = "threading-web"
}

// MARK: - Collaboration

/// Presence projected by the host. Unknown values remain decodable across host/client skew.
public enum RemotePresenceState: RemoteLosslessStringToken {
    case viewing
    case typing
    case left
    /// Legacy client spelling accepted by hosts before they normalize it to `viewing`.
    case idle
    case unknown(String)

    public init(rawValue: String) {
        switch rawValue {
        case "viewing": self = .viewing
        case "typing": self = .typing
        case "left": self = .left
        case "idle": self = .idle
        default: self = .unknown(rawValue)
        }
    }

    public var rawValue: String {
        switch self {
        case .viewing: return "viewing"
        case .typing: return "typing"
        case .left: return "left"
        case .idle: return "idle"
        case let .unknown(value): return value
        }
    }
}

/// The closed presence vocabulary a client may send to a host.
public enum RemotePresenceUpdate: String, Codable, Equatable, Hashable, Sendable {
    case typing
    case idle
}

public enum RemotePermissionDecision: String, Codable, Equatable, Hashable, Sendable {
    case allow
    case deny
}

public enum RemoteMobileApplicationState: RemoteLosslessStringToken {
    case active
    case inactive
    case background
    case unknown(String)

    public init(rawValue: String) {
        switch rawValue {
        case "active": self = .active
        case "inactive": self = .inactive
        case "background": self = .background
        default: self = .unknown(rawValue)
        }
    }

    public var rawValue: String {
        switch self {
        case .active: return "active"
        case .inactive: return "inactive"
        case .background: return "background"
        case let .unknown(value): return value
        }
    }
}

public enum RemoteMobileConnectionState: RemoteLosslessStringToken {
    case idle
    case connecting
    case online
    case offline
    case unknown(String)

    public init(rawValue: String) {
        switch rawValue {
        case "idle": self = .idle
        case "connecting": self = .connecting
        case "online": self = .online
        case "offline": self = .offline
        default: self = .unknown(rawValue)
        }
    }

    public var rawValue: String {
        switch self {
        case .idle: return "idle"
        case .connecting: return "connecting"
        case .online: return "online"
        case .offline: return "offline"
        case let .unknown(value): return value
        }
    }
}

public enum RemoteMobileDiagnosticsScreenshotKind: RemoteLosslessStringToken {
    case current
    case incident
    case unknown(String)

    public init(rawValue: String) {
        switch rawValue {
        case "current": self = .current
        case "incident": self = .incident
        default: self = .unknown(rawValue)
        }
    }

    public var rawValue: String {
        switch self {
        case .current: return "current"
        case .incident: return "incident"
        case let .unknown(value): return value
        }
    }
}

public enum RemoteCollaborationRole: RemoteLosslessStringToken {
    case owner
    case member
    case unknown(String)

    public init(rawValue: String) {
        switch rawValue {
        case "owner": self = .owner
        case "member": self = .member
        default: self = .unknown(rawValue)
        }
    }

    public var rawValue: String {
        switch self {
        case .owner: return "owner"
        case .member: return "member"
        case let .unknown(value): return value
        }
    }
}

/// The closed input-control vocabulary a client may send to a host.
public enum RemoteInputControlAction: String, Codable, Equatable, Hashable, Sendable {
    case collaborative
    case focused
    case handoff
    case reclaim
    case request
}

/// An input-control event projected by the host.
public enum RemoteInputControlEventAction: RemoteLosslessStringToken {
    case modeChanged
    case handedOff
    case reclaimed
    case requested
    case released
    case unknown(String)

    public init(rawValue: String) {
        switch rawValue {
        case "modeChanged": self = .modeChanged
        case "handedOff": self = .handedOff
        case "reclaimed": self = .reclaimed
        case "requested": self = .requested
        case "released": self = .released
        default: self = .unknown(rawValue)
        }
    }

    public var rawValue: String {
        switch self {
        case .modeChanged: return "modeChanged"
        case .handedOff: return "handedOff"
        case .reclaimed: return "reclaimed"
        case .requested: return "requested"
        case .released: return "released"
        case let .unknown(value): return value
        }
    }
}
