import Foundation

/// Sanitized git identity. No checkout path, git-directory path, credentials, or complete remote
/// URL crosses the extension boundary.
public struct ExtensionRepositorySnapshot: Codable, Equatable, Sendable {
    public let remoteHost: String?
    public let repositoryPath: String?
    public let branch: String?
    public let headRevision: String?

    public init(
        remoteHost: String? = nil,
        repositoryPath: String? = nil,
        branch: String? = nil,
        headRevision: String? = nil
    ) {
        self.remoteHost = remoteHost
        self.repositoryPath = repositoryPath
        self.branch = branch
        self.headRevision = headRevision
    }
}

public struct ExtensionProjectSnapshot: Codable, Equatable, Sendable {
    public static let currentVersion = 1

    public let version: Int
    public let id: String
    public let displayName: String
    public let repository: ExtensionRepositorySnapshot?

    public init(
        version: Int = Self.currentVersion,
        id: String,
        displayName: String,
        repository: ExtensionRepositorySnapshot? = nil
    ) {
        self.version = version
        self.id = id
        self.displayName = displayName
        self.repository = repository
    }
}

public struct ExtensionSessionActivity: RawRepresentable, Codable, Hashable, Sendable,
    ExpressibleByStringLiteral
{
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public init(stringLiteral value: String) {
        rawValue = value
    }

    public static let dormant: Self = "dormant"
    public static let idle: Self = "idle"
    public static let working: Self = "working"
    public static let needsAttention: Self = "needs-attention"
}

/// The detailed vocabulary published by `session.activity.detailed`.
///
/// This remains distinct from `ExtensionSessionActivity`, whose four values are frozen into the
/// v1 sanitized session snapshot. A raw-value type keeps future host values decodable while these
/// named constants prevent navigator authors from having to reproduce Threading's wire spelling.
public struct ExtensionSessionDetailedActivity: RawRepresentable, Codable, Hashable, Sendable,
    ExpressibleByStringLiteral
{
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public init(stringLiteral value: String) {
        rawValue = value
    }

    public static let dormant: Self = "dormant"
    public static let idle: Self = "idle"
    public static let working: Self = "working"
    public static let readyWithBackgroundWork: Self = "ready-with-background-work"
    public static let awaitingUser: Self = "awaiting-user"
    public static let needsAttention: Self = "needs-attention"
    public static let limitReached: Self = "limit-reached"
}

public struct ExtensionSessionSnapshot: Codable, Equatable, Sendable {
    public static let currentVersion = 1

    public let version: Int
    public let id: String
    public let projectID: String
    public let providerID: String
    public let accountID: String?
    public let displayTitle: String
    public let activity: ExtensionSessionActivity
    public let branch: String?
    public let isSideChat: Bool
    public let isArchived: Bool
    public let usesNativeUI: Bool

    public init(
        version: Int = Self.currentVersion,
        id: String,
        projectID: String,
        providerID: String,
        accountID: String? = nil,
        displayTitle: String,
        activity: ExtensionSessionActivity,
        branch: String? = nil,
        isSideChat: Bool,
        isArchived: Bool,
        usesNativeUI: Bool
    ) {
        self.version = version
        self.id = id
        self.projectID = projectID
        self.providerID = providerID
        self.accountID = accountID
        self.displayTitle = displayTitle
        self.activity = activity
        self.branch = branch
        self.isSideChat = isSideChat
        self.isArchived = isArchived
        self.usesNativeUI = usesNativeUI
    }
}

/// A snapshot and the event cursor observed atomically with it.
///
/// Start event polling after this cursor so changes between the snapshot request and the first
/// event read are not lost.
public struct ExtensionProjectSnapshotPage: Codable, Equatable, Sendable {
    public let cursor: Int64
    public let projects: [ExtensionProjectSnapshot]

    public init(cursor: Int64, projects: [ExtensionProjectSnapshot]) {
        self.cursor = cursor
        self.projects = projects
    }
}

public struct ExtensionProjectSnapshotResult: Codable, Equatable, Sendable {
    public let cursor: Int64
    public let project: ExtensionProjectSnapshot

    public init(cursor: Int64, project: ExtensionProjectSnapshot) {
        self.cursor = cursor
        self.project = project
    }
}

public struct ExtensionSessionSnapshotPage: Codable, Equatable, Sendable {
    public let cursor: Int64
    public let sessions: [ExtensionSessionSnapshot]

    public init(cursor: Int64, sessions: [ExtensionSessionSnapshot]) {
        self.cursor = cursor
        self.sessions = sessions
    }
}

public struct ExtensionSessionSnapshotResult: Codable, Equatable, Sendable {
    public let cursor: Int64
    public let session: ExtensionSessionSnapshot

    public init(cursor: Int64, session: ExtensionSessionSnapshot) {
        self.cursor = cursor
        self.session = session
    }
}

public struct ExtensionHostEventKind: RawRepresentable, Codable, Hashable, Sendable,
    ExpressibleByStringLiteral
{
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public init(stringLiteral value: String) {
        rawValue = value
    }

    public static let projectChanged: Self = "project.changed"
    public static let projectRemoved: Self = "project.removed"
    public static let sessionChanged: Self = "session.changed"
    public static let sessionRemoved: Self = "session.removed"
    public static let providerChanged: Self = "provider.changed"
    public static let accountChanged: Self = "account.changed"
    public static let accountRemoved: Self = "account.removed"
}

public struct ExtensionHostEvent: Codable, Equatable, Sendable {
    public let cursor: Int64
    public let kind: ExtensionHostEventKind
    public let entityID: String
    public let projectID: String?
    public let recordedAt: Date

    public init(
        cursor: Int64,
        kind: ExtensionHostEventKind,
        entityID: String,
        projectID: String? = nil,
        recordedAt: Date = Date()
    ) {
        self.cursor = cursor
        self.kind = kind
        self.entityID = entityID
        self.projectID = projectID
        self.recordedAt = recordedAt
    }
}

public struct ExtensionHostEventPage: Codable, Equatable, Sendable {
    public let events: [ExtensionHostEvent]
    public let nextCursor: Int64
    public let hasMore: Bool

    public init(
        events: [ExtensionHostEvent],
        nextCursor: Int64,
        hasMore: Bool
    ) {
        self.events = events
        self.nextCursor = nextCursor
        self.hasMore = hasMore
    }
}
