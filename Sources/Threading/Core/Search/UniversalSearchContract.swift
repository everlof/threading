import Foundation

// MARK: - Bounds

/// Product and transport bounds shared by every universal-search provider.
///
/// These are correctness limits, not UI measurements. A provider may choose a smaller page, but
/// no provider may make a keystroke materialize more than these values before the coordinator has
/// had a chance to apply its own per-group budget.
enum UniversalSearchDefaults {
    static let maximumQueryUTF8Bytes = 512
    static let maximumFilters = 16
    static let maximumGroups = 8
    static let maximumHitsPerGroup = 64
    static let maximumInitialHits = 128
    static let maximumTitleUTF8Bytes = 512
    static let maximumSnippetUTF8Bytes = 1024
    static let maximumProvenanceFields = 8
}

// MARK: - Query

enum SearchScope: Hashable, Sendable {
    case view(SearchViewContext)
    case project(ProjectID)
    case everywhere
}

/// A semantic current surface. It contains only identities a search provider can revalidate;
/// controllers, views, paths to provider storage and navigation closures never enter Core.
enum SearchViewContext: Hashable, Sendable {
    case conversation(projectID: ProjectID, sessionID: SessionID)
    case agentTerminal(projectID: ProjectID, sessionID: SessionID)
    case projectTerminal(projectID: ProjectID, terminalID: TerminalID)
    case browser(projectID: ProjectID?, sessionID: SessionID?, tabID: SearchBrowserTabID?)
    case gitReview(projectID: ProjectID, sessionID: SessionID)
    case filePreview(projectID: ProjectID, sessionID: SessionID?, relativePath: String)

    var projectID: ProjectID? {
        switch self {
        case let .conversation(projectID, _),
             let .agentTerminal(projectID, _),
             let .projectTerminal(projectID, _),
             let .gitReview(projectID, _),
             let .filePreview(projectID, _, _):
            return projectID
        case let .browser(projectID, _, _):
            return projectID
        }
    }

    var sessionID: SessionID? {
        switch self {
        case let .conversation(_, sessionID),
             let .agentTerminal(_, sessionID),
             let .gitReview(_, sessionID):
            return sessionID
        case let .browser(_, sessionID, _), let .filePreview(_, sessionID, _):
            return sessionID
        case .projectTerminal:
            return nil
        }
    }
}

struct SearchQuery: Equatable, Sendable {
    let text: String
    let scope: SearchScope
    let expression: SearchExpression
    let generation: UInt64
}

struct SearchExpression: Equatable, Sendable {
    let terms: [SearchTextTerm]
    let filters: [SearchFilter]

    var positiveTerms: [SearchTextTerm] { terms.filter { !$0.isExcluded } }
    var excludedTerms: [SearchTextTerm] { terms.filter(\.isExcluded) }
}

struct SearchTextTerm: Equatable, Sendable {
    enum Match: Equatable, Sendable {
        case token
        case phrase
    }

    let text: String
    let match: Match
    let isExcluded: Bool
}

struct SearchFilter: Equatable, Sendable {
    enum Predicate: Equatable, Sendable {
        case kind(SearchFilterKind)
        case author(SearchAuthor)
        case project(String)
        case provider(String)
        case archived
        case error
        case before(Date)
        case after(Date)
    }

    let predicate: Predicate
    let isExcluded: Bool
}

enum SearchFilterKind: String, CaseIterable, Equatable, Sendable {
    case conversation
    case file
    case command
    case session
    case project
    case terminal
    case setting
    case attachment
    case browser
    case review
}

enum SearchAuthor: String, Equatable, Sendable {
    case you
    case agent
    case system
}

enum SearchQueryError: Error, Equatable, Sendable {
    case queryTooLarge(maximumUTF8Bytes: Int)
    case tooManyFilters(maximum: Int)
    case unterminatedQuote
    case danglingEscape
    case missingFilterValue(name: String)
    case unknownFilter(name: String)
    case invalidFilterValue(name: String, value: String)
}

enum SearchQueryParser {
    static func parse(
        _ text: String,
        scope: SearchScope,
        generation: UInt64
    ) -> Result<SearchQuery, SearchQueryError> {
        guard text.utf8.count <= UniversalSearchDefaults.maximumQueryUTF8Bytes else {
            return .failure(.queryTooLarge(
                maximumUTF8Bytes: UniversalSearchDefaults.maximumQueryUTF8Bytes
            ))
        }

        switch lex(text) {
        case let .failure(error):
            return .failure(error)
        case let .success(lexemes):
            var terms: [SearchTextTerm] = []
            var filters: [SearchFilter] = []
            for lexeme in lexemes {
                if let separator = lexeme.value.firstIndex(of: ":") {
                    let name = String(lexeme.value[..<separator]).lowercased()
                    let value = String(lexeme.value[lexeme.value.index(after: separator)...])
                    guard !value.isEmpty else {
                        return .failure(.missingFilterValue(name: name))
                    }
                    switch filter(name: name, value: value, isExcluded: lexeme.isExcluded) {
                    case let .failure(error):
                        return .failure(error)
                    case let .success(filter):
                        filters.append(filter)
                        guard filters.count <= UniversalSearchDefaults.maximumFilters else {
                            return .failure(.tooManyFilters(
                                maximum: UniversalSearchDefaults.maximumFilters
                            ))
                        }
                    }
                } else {
                    terms.append(SearchTextTerm(
                        text: lexeme.value,
                        match: lexeme.wasQuoted ? .phrase : .token,
                        isExcluded: lexeme.isExcluded
                    ))
                }
            }
            return .success(SearchQuery(
                text: text,
                scope: scope,
                expression: SearchExpression(terms: terms, filters: filters),
                generation: generation
            ))
        }
    }

    private struct Lexeme: Equatable {
        let value: String
        let wasQuoted: Bool
        let isExcluded: Bool
    }

    private static func lex(_ text: String) -> Result<[Lexeme], SearchQueryError> {
        var result: [Lexeme] = []
        var value = ""
        var isQuoted = false
        var wasQuoted = false
        var isEscaping = false
        var isExcluded = false

        func appendCurrent() {
            guard !value.isEmpty else {
                wasQuoted = false
                isExcluded = false
                return
            }
            result.append(Lexeme(
                value: value,
                wasQuoted: wasQuoted,
                isExcluded: isExcluded
            ))
            value = ""
            wasQuoted = false
            isExcluded = false
        }

        for character in text {
            if isEscaping {
                value.append(character)
                isEscaping = false
                continue
            }
            if character == "\\" {
                isEscaping = true
                continue
            }
            if character == "\"" {
                isQuoted.toggle()
                wasQuoted = true
                continue
            }
            if character.isWhitespace, !isQuoted {
                appendCurrent()
                continue
            }
            if character == "-", value.isEmpty, !wasQuoted, !isExcluded {
                isExcluded = true
                continue
            }
            value.append(character)
        }

        guard !isEscaping else { return .failure(.danglingEscape) }
        guard !isQuoted else { return .failure(.unterminatedQuote) }
        if isExcluded, value.isEmpty {
            value = "-"
            isExcluded = false
        }
        appendCurrent()
        return .success(result)
    }

    private static func filter(
        name: String,
        value: String,
        isExcluded: Bool
    ) -> Result<SearchFilter, SearchQueryError> {
        let normalized = value.lowercased()
        let predicate: SearchFilter.Predicate
        switch name {
        case "type":
            guard let kind = SearchFilterKind(rawValue: normalized) else {
                return .failure(.invalidFilterValue(name: name, value: value))
            }
            predicate = .kind(kind)
        case "from":
            guard let author = SearchAuthor(rawValue: normalized), author != .system else {
                return .failure(.invalidFilterValue(name: name, value: value))
            }
            predicate = .author(author)
        case "project":
            predicate = .project(value)
        case "provider":
            predicate = .provider(value)
        case "is":
            guard normalized == "archived" else {
                return .failure(.invalidFilterValue(name: name, value: value))
            }
            predicate = .archived
        case "has":
            guard normalized == "error" else {
                return .failure(.invalidFilterValue(name: name, value: value))
            }
            predicate = .error
        case "before":
            guard let date = date(value) else {
                return .failure(.invalidFilterValue(name: name, value: value))
            }
            predicate = .before(date)
        case "after":
            guard let date = date(value) else {
                return .failure(.invalidFilterValue(name: name, value: value))
            }
            predicate = .after(date)
        default:
            return .failure(.unknownFilter(name: name))
        }
        return .success(SearchFilter(predicate: predicate, isExcluded: isExcluded))
    }

    private static func date(_ value: String) -> Date? {
        let timestamp = ISO8601DateFormatter()
        if let date = timestamp.date(from: value) { return date }

        let day = ISO8601DateFormatter()
        day.formatOptions = [.withFullDate]
        return day.date(from: value)
    }
}

// MARK: - Results

struct SearchHitID: RawRepresentable, Hashable, Sendable, CustomStringConvertible {
    let rawValue: String
    init(rawValue: String) { self.rawValue = rawValue }
    var description: String { rawValue }
}

struct SearchProviderID: RawRepresentable, Hashable, Sendable, CustomStringConvertible {
    let rawValue: String
    init(rawValue: String) { self.rawValue = rawValue }
    var description: String { rawValue }

    static let currentSurface = Self(rawValue: "current-surface")
    static let navigation = Self(rawValue: "navigation")
    static let transcript = Self(rawValue: "transcript")
    static let workspaceFile = Self(rawValue: "workspace-file")
    static let workspaceMetadata = Self(rawValue: "workspace-metadata")
    static let registry = Self(rawValue: "registry")
    static let projectText = Self(rawValue: "project-text")
}

enum SearchResultGroup: Int, CaseIterable, Comparable, Hashable, Sendable {
    case destinations
    case currentView
    case conversations
    case files
    case settings
    case archived

    static func < (lhs: SearchResultGroup, rhs: SearchResultGroup) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

enum SearchHitKind: Hashable, Sendable {
    case project
    case session
    case projectTerminal
    case conversationMessage(SearchAuthor)
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

enum SearchScoreTier: Int, CaseIterable, Comparable, Hashable, Sendable {
    case exactIdentifier
    case exactMetadata
    case metadataPrefix
    case literalText
    case fuzzyMetadata

    static func < (lhs: SearchScoreTier, rhs: SearchScoreTier) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

struct SearchStableOrder: Hashable, Sendable, Comparable {
    let group: SearchResultGroup
    let scoreTier: SearchScoreTier
    /// A UNIX timestamp. Higher values sort first, but only after group and score tier.
    let recency: TimeInterval
    let normalizedTitle: String
    let stableID: SearchHitID

    init(
        group: SearchResultGroup,
        scoreTier: SearchScoreTier,
        recency: Date?,
        title: String,
        stableID: SearchHitID
    ) {
        self.group = group
        self.scoreTier = scoreTier
        self.recency = recency?.timeIntervalSince1970 ?? 0
        normalizedTitle = title.folding(
            options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
            locale: Locale(identifier: "en_US_POSIX")
        )
        self.stableID = stableID
    }

    static func < (lhs: SearchStableOrder, rhs: SearchStableOrder) -> Bool {
        if lhs.group != rhs.group { return lhs.group < rhs.group }
        if lhs.scoreTier != rhs.scoreTier { return lhs.scoreTier < rhs.scoreTier }
        if lhs.recency != rhs.recency { return lhs.recency > rhs.recency }
        if lhs.normalizedTitle != rhs.normalizedTitle {
            return lhs.normalizedTitle < rhs.normalizedTitle
        }
        return lhs.stableID.rawValue < rhs.stableID.rawValue
    }
}

struct SearchTextRange: Hashable, Sendable {
    let utf16Location: Int
    let utf16Length: Int

    var isValid: Bool { utf16Location >= 0 && utf16Length > 0 }
}

struct SearchSnippet: Hashable, Sendable {
    let text: String
    let matches: [SearchTextRange]
}

struct SearchProvenance: Hashable, Sendable {
    let projectID: ProjectID?
    let projectName: String?
    let sessionID: SessionID?
    let sessionTitle: String?
    let provider: String?
    let author: SearchAuthor?
    let branch: String?
    let relativePath: String?
    let timestamp: Date?
    let isArchived: Bool

    init(
        projectID: ProjectID? = nil,
        projectName: String? = nil,
        sessionID: SessionID? = nil,
        sessionTitle: String? = nil,
        provider: String? = nil,
        author: SearchAuthor? = nil,
        branch: String? = nil,
        relativePath: String? = nil,
        timestamp: Date? = nil,
        isArchived: Bool = false
    ) {
        self.projectID = projectID
        self.projectName = projectName
        self.sessionID = sessionID
        self.sessionTitle = sessionTitle
        self.provider = provider
        self.author = author
        self.branch = branch
        self.relativePath = relativePath
        self.timestamp = timestamp
        self.isArchived = isArchived
    }
}

struct SearchSourceID: RawRepresentable, Hashable, Sendable {
    let rawValue: String
    init(rawValue: String) { self.rawValue = rawValue }
}

struct SearchSourceRecordID: RawRepresentable, Hashable, Sendable {
    let rawValue: String
    init(rawValue: String) { self.rawValue = rawValue }
}

struct SearchBrowserTabID: RawRepresentable, Hashable, Sendable {
    let rawValue: String
    init(rawValue: String) { self.rawValue = rawValue }
}

struct SearchAttachmentID: RawRepresentable, Hashable, Sendable {
    let rawValue: String
    init(rawValue: String) { self.rawValue = rawValue }
}

struct SearchConversationLocator: Hashable, Sendable {
    let projectID: ProjectID
    let sessionID: SessionID
    let sourceID: SearchSourceID
    let recordID: SearchSourceRecordID
    let sourceGeneration: UInt64
    let match: SearchTextRange?
}

struct SearchFileLocation: Hashable, Sendable {
    let relativePath: String
    let line: Int?
    let column: Int?
    let matchLength: Int?
    let lineFingerprint: UInt64?

    init(
        relativePath: String,
        line: Int?,
        column: Int?,
        matchLength: Int?,
        lineFingerprint: UInt64? = nil
    ) {
        self.relativePath = relativePath
        self.line = line
        self.column = column
        self.matchLength = matchLength
        self.lineFingerprint = lineFingerprint
    }
}

enum SearchSourceFingerprint {
    /// Stable and deliberately non-cryptographic: this is an ephemeral stale-locator fence, not
    /// a persisted identity or a value that crosses the remote capability boundary.
    static func text(_ value: String) -> UInt64 {
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in value.utf8 {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        return hash
    }
}

/// Internal routing authority. Presentation text is never reparsed to decide where a hit lands.
enum SearchLocator: Hashable, Sendable {
    case project(ProjectID)
    case session(projectID: ProjectID, sessionID: SessionID)
    case projectTerminal(projectID: ProjectID, terminalID: TerminalID)
    case archivedSession(projectID: ProjectID, sessionID: SessionID)
    case conversation(SearchConversationLocator)
    case workspaceFile(projectID: ProjectID, sessionID: SessionID?, location: SearchFileLocation)
    case command(String)
    case setting(destinationID: String)
    case attachment(projectID: ProjectID, sessionID: SessionID, attachmentID: SearchAttachmentID)
    case browserTab(projectID: ProjectID?, sessionID: SessionID?, tabID: SearchBrowserTabID)
    case gitReview(projectID: ProjectID, sessionID: SessionID, location: SearchFileLocation)
}

struct SearchHit: Identifiable, Hashable, Sendable {
    let id: SearchHitID
    let provider: SearchProviderID
    let kind: SearchHitKind
    let title: String
    let snippet: SearchSnippet?
    let provenance: SearchProvenance
    let stableOrder: SearchStableOrder
    let locator: SearchLocator

    var scoreTier: SearchScoreTier { stableOrder.scoreTier }
}

enum SearchCoverage: Equatable, Sendable {
    case complete
    case partial(reason: String)
    case indexing(indexed: Int, total: Int?)
    case unavailable(reason: String)
}

struct SearchContinuation: Hashable, Sendable {
    let opaqueValue: String
    let provider: SearchProviderID
    let queryGeneration: UInt64
    let expiresAt: Date
}

struct SearchBatch: Equatable, Sendable {
    let queryGeneration: UInt64
    let provider: SearchProviderID
    let group: SearchResultGroup
    let hits: [SearchHit]
    let coverage: SearchCoverage
    let continuation: SearchContinuation?
    let isCapped: Bool
}

// MARK: - Client eligibility

struct SearchClientCapabilities: OptionSet, Hashable, Sendable {
    let rawValue: UInt64

    static let project = Self(rawValue: 1 << 0)
    static let session = Self(rawValue: 1 << 1)
    static let projectTerminal = Self(rawValue: 1 << 2)
    static let archivedSession = Self(rawValue: 1 << 3)
    static let conversationWindow = Self(rawValue: 1 << 4)
    static let workspaceFile = Self(rawValue: 1 << 5)
    static let command = Self(rawValue: 1 << 6)
    static let setting = Self(rawValue: 1 << 7)
    static let attachment = Self(rawValue: 1 << 8)
    static let browserTab = Self(rawValue: 1 << 9)
    static let gitReview = Self(rawValue: 1 << 10)

    static let macOS: Self = [
        .project, .session, .projectTerminal, .archivedSession, .conversationWindow,
        .workspaceFile, .command, .setting, .attachment, .browserTab, .gitReview,
    ]

    static let remoteIOS: Self = [
        .project, .session, .projectTerminal, .archivedSession, .conversationWindow,
        .workspaceFile, .attachment, .browserTab,
    ]
}

extension SearchLocator {
    var requiredClientCapability: SearchClientCapabilities {
        switch self {
        case .project: return .project
        case .session: return .session
        case .projectTerminal: return .projectTerminal
        case .archivedSession: return .archivedSession
        case .conversation: return .conversationWindow
        case .workspaceFile: return .workspaceFile
        case .command: return .command
        case .setting: return .setting
        case .attachment: return .attachment
        case .browserTab: return .browserTab
        case .gitReview: return .gitReview
        }
    }
}

extension SearchHit {
    func isEligible(for capabilities: SearchClientCapabilities) -> Bool {
        capabilities.contains(locator.requiredClientCapability)
    }
}
