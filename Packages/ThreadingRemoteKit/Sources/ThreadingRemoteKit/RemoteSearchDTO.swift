import Foundation

/// Hard transport limits shared by the Mac and every remote search client.
public enum RemoteSearchWireLimits {
    public static let maximumQueryUTF8Bytes = 512
    public static let maximumVisibleHits = 128
    public static let maximumGroups = 8
    public static let maximumHitsPerGroup = 64
    public static let maximumTitleUTF8Bytes = 512
    public static let maximumSnippetUTF8Bytes = 1024
    public static let maximumConversationRows = 41
    public static let maximumFileLines = 41
    public static let resultTokenLifetimeSeconds: TimeInterval = 60
}

public enum RemoteSearchScopeKindDTO: String, Codable, CaseIterable, Sendable {
    case everywhere
    case project
    case session
}

/// A client names only catalogue identities it has already been allowed to see. Current clients
/// send a stable project id plus its display name; the name-only fallback keeps an older client
/// safe by accepting it only when it resolves uniquely. The Mac revalidates every identity before
/// a provider is allowed to run.
public struct RemoteSearchRequestDTO: Codable, Equatable, Sendable {
    public let query: String
    public let scope: RemoteSearchScopeKindDTO
    public let projectID: String?
    public let projectName: String?
    public let sessionID: String?
    public let generation: UInt64

    public init(
        query: String,
        scope: RemoteSearchScopeKindDTO = .everywhere,
        projectID: String? = nil,
        projectName: String? = nil,
        sessionID: String? = nil,
        generation: UInt64
    ) {
        self.query = query
        self.scope = scope
        self.projectID = projectID
        self.projectName = projectName
        self.sessionID = sessionID
        self.generation = generation
    }
}

public enum RemoteSearchGroupDTO: String, Codable, CaseIterable, Sendable {
    case destinations
    case currentView
    case conversations
    case files
    case settings
    case archived
}

public enum RemoteSearchHitKindDTO: String, Codable, CaseIterable, Sendable {
    case project
    case session
    case projectTerminal
    case conversationMessage
    case toolSummary
    case file
    case projectText
    case command
    case setting
    case archivedSession
    case attachment
    case browserTab
    case gitReview
}

public struct RemoteSearchTextRangeDTO: Codable, Equatable, Sendable {
    public let utf16Location: Int
    public let utf16Length: Int

    public init(utf16Location: Int, utf16Length: Int) {
        self.utf16Location = utf16Location
        self.utf16Length = utf16Length
    }
}

public struct RemoteSearchSnippetDTO: Codable, Equatable, Sendable {
    public let text: String
    public let matches: [RemoteSearchTextRangeDTO]

    public init(text: String, matches: [RemoteSearchTextRangeDTO] = []) {
        self.text = text
        self.matches = matches
    }
}

public struct RemoteSearchProvenanceDTO: Codable, Equatable, Sendable {
    public let projectName: String?
    public let sessionTitle: String?
    public let provider: String?
    public let author: String?
    public let branch: String?
    public let relativePath: String?
    public let timestamp: TimeInterval?
    public let isArchived: Bool

    public init(
        projectName: String? = nil,
        sessionTitle: String? = nil,
        provider: String? = nil,
        author: String? = nil,
        branch: String? = nil,
        relativePath: String? = nil,
        timestamp: TimeInterval? = nil,
        isArchived: Bool = false
    ) {
        self.projectName = projectName
        self.sessionTitle = sessionTitle
        self.provider = provider
        self.author = author
        self.branch = branch
        self.relativePath = relativePath
        self.timestamp = timestamp
        self.isArchived = isArchived
    }
}

/// `token` is the only routing authority crossing the wire. It is process-, device-, generation-
/// and time-bound by the Mac; every other field is display-only and must never be reparsed.
public struct RemoteSearchHitDTO: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public let token: String
    public let group: RemoteSearchGroupDTO
    public let kind: RemoteSearchHitKindDTO
    public let title: String
    public let snippet: RemoteSearchSnippetDTO?
    public let provenance: RemoteSearchProvenanceDTO

    public init(
        id: String,
        token: String,
        group: RemoteSearchGroupDTO,
        kind: RemoteSearchHitKindDTO,
        title: String,
        snippet: RemoteSearchSnippetDTO?,
        provenance: RemoteSearchProvenanceDTO
    ) {
        self.id = id
        self.token = token
        self.group = group
        self.kind = kind
        self.title = title
        self.snippet = snippet
        self.provenance = provenance
    }
}

public enum RemoteSearchCoverageKindDTO: String, Codable, CaseIterable, Sendable {
    case complete
    case partial
    case indexing
    case unavailable
}

public struct RemoteSearchCoverageDTO: Codable, Equatable, Sendable {
    public let kind: RemoteSearchCoverageKindDTO
    public let detail: String?
    public let indexed: Int?
    public let total: Int?

    public init(
        kind: RemoteSearchCoverageKindDTO,
        detail: String? = nil,
        indexed: Int? = nil,
        total: Int? = nil
    ) {
        self.kind = kind
        self.detail = detail
        self.indexed = indexed
        self.total = total
    }
}

public struct RemoteSearchGroupResultDTO: Codable, Equatable, Identifiable, Sendable {
    public var id: RemoteSearchGroupDTO { group }
    public let group: RemoteSearchGroupDTO
    public let hits: [RemoteSearchHitDTO]
    public let coverage: [RemoteSearchCoverageDTO]
    public let isCapped: Bool

    public init(
        group: RemoteSearchGroupDTO,
        hits: [RemoteSearchHitDTO],
        coverage: [RemoteSearchCoverageDTO],
        isCapped: Bool
    ) {
        self.group = group
        self.hits = hits
        self.coverage = coverage
        self.isCapped = isCapped
    }
}

public struct RemoteSearchResponseDTO: Codable, Equatable, Sendable {
    public let generation: UInt64
    public let groups: [RemoteSearchGroupResultDTO]
    public let isComplete: Bool

    public init(
        generation: UInt64,
        groups: [RemoteSearchGroupResultDTO],
        isComplete: Bool
    ) {
        self.generation = generation
        self.groups = groups
        self.isComplete = isComplete
    }
}

public struct RemoteSearchResolveRequestDTO: Codable, Equatable, Sendable {
    public let token: String

    public init(token: String) {
        self.token = token
    }
}

public enum RemoteSearchResolutionKindDTO: String, Codable, CaseIterable, Sendable {
    case project
    case session
    case projectTerminal
    case archivedSession
    case conversation
    case file
    case attachment
    case browserTab
}

public struct RemoteSearchConversationRowDTO: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public let kind: String
    public let author: String?
    public let title: String?
    public let body: String
    public let timestamp: TimeInterval?
    public let isError: Bool

    public init(
        id: String,
        kind: String,
        author: String? = nil,
        title: String? = nil,
        body: String,
        timestamp: TimeInterval? = nil,
        isError: Bool = false
    ) {
        self.id = id
        self.kind = kind
        self.author = author
        self.title = title
        self.body = body
        self.timestamp = timestamp
        self.isError = isError
    }
}

public struct RemoteSearchConversationWindowDTO: Codable, Equatable, Sendable {
    public let sessionID: String
    public let sessionTitle: String
    public let projectName: String
    public let rows: [RemoteSearchConversationRowDTO]
    public let anchorRowID: String
    public let anchorMatch: RemoteSearchTextRangeDTO?
    public let hasEarlier: Bool
    public let hasLater: Bool

    public init(
        sessionID: String,
        sessionTitle: String,
        projectName: String,
        rows: [RemoteSearchConversationRowDTO],
        anchorRowID: String,
        anchorMatch: RemoteSearchTextRangeDTO?,
        hasEarlier: Bool,
        hasLater: Bool
    ) {
        self.sessionID = sessionID
        self.sessionTitle = sessionTitle
        self.projectName = projectName
        self.rows = rows
        self.anchorRowID = anchorRowID
        self.anchorMatch = anchorMatch
        self.hasEarlier = hasEarlier
        self.hasLater = hasLater
    }
}

public struct RemoteSearchFileLineDTO: Codable, Equatable, Identifiable, Sendable {
    public var id: Int { number }
    public let number: Int
    public let text: String
    public let match: RemoteSearchTextRangeDTO?

    public init(number: Int, text: String, match: RemoteSearchTextRangeDTO? = nil) {
        self.number = number
        self.text = text
        self.match = match
    }
}

public struct RemoteSearchFileWindowDTO: Codable, Equatable, Sendable {
    public let projectName: String
    public let relativePath: String
    public let lines: [RemoteSearchFileLineDTO]
    public let anchorLine: Int?
    public let hasEarlier: Bool
    public let hasLater: Bool

    public init(
        projectName: String,
        relativePath: String,
        lines: [RemoteSearchFileLineDTO],
        anchorLine: Int? = nil,
        hasEarlier: Bool,
        hasLater: Bool
    ) {
        self.projectName = projectName
        self.relativePath = relativePath
        self.lines = lines
        self.anchorLine = anchorLine
        self.hasEarlier = hasEarlier
        self.hasLater = hasLater
    }
}

/// The resolved destination remains typed. Only the fields for `kind` are populated; conversation
/// and file landings carry bounded read-only windows so the phone never asks for host paths.
public struct RemoteSearchResolutionDTO: Codable, Equatable, Sendable {
    public let kind: RemoteSearchResolutionKindDTO
    public let projectID: String?
    public let projectName: String?
    public let sessionID: String?
    public let terminalID: String?
    public let attachmentID: String?
    public let browserTabID: String?
    public let conversation: RemoteSearchConversationWindowDTO?
    public let file: RemoteSearchFileWindowDTO?

    public init(
        kind: RemoteSearchResolutionKindDTO,
        projectID: String? = nil,
        projectName: String? = nil,
        sessionID: String? = nil,
        terminalID: String? = nil,
        attachmentID: String? = nil,
        browserTabID: String? = nil,
        conversation: RemoteSearchConversationWindowDTO? = nil,
        file: RemoteSearchFileWindowDTO? = nil
    ) {
        self.kind = kind
        self.projectID = projectID
        self.projectName = projectName
        self.sessionID = sessionID
        self.terminalID = terminalID
        self.attachmentID = attachmentID
        self.browserTabID = browserTabID
        self.conversation = conversation
        self.file = file
    }
}
