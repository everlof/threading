import Foundation

/// A presentation-free copy of one navigable destination. The live model is copied into these
/// values on the main actor; matching never reads `ProjectStore` or mutable session state.
struct NavigationSearchRecord: Hashable, Sendable {
    enum Destination: Hashable, Sendable {
        case project(ProjectID)
        case session(projectID: ProjectID, sessionID: SessionID)
        case terminal(projectID: ProjectID, terminalID: TerminalID)
        case archivedSession(projectID: ProjectID, sessionID: SessionID)
    }

    let destination: Destination
    let title: String
    let projectName: String
    let providerName: String?
    let branch: String?
    let searchableMetadata: [String]
    let updatedAt: Date

    init(
        destination: Destination,
        title: String,
        projectName: String,
        providerName: String? = nil,
        branch: String? = nil,
        searchableMetadata: [String] = [],
        updatedAt: Date
    ) {
        self.destination = destination
        self.title = title
        self.projectName = projectName
        self.providerName = providerName
        self.branch = branch
        self.searchableMetadata = searchableMetadata
        self.updatedAt = updatedAt
    }

    func replacingProjectName(_ projectName: String) -> NavigationSearchRecord {
        let title: String
        if case .project = destination {
            title = projectName
        } else {
            title = self.title
        }
        return NavigationSearchRecord(
            destination: destination,
            title: title,
            projectName: projectName,
            providerName: providerName,
            branch: branch,
            searchableMetadata: searchableMetadata,
            updatedAt: updatedAt
        )
    }
}

/// Immutable, warm structured index. Construction belongs on a background task when the project
/// catalogue changes; opening Search only takes this value and performs bounded candidate work.
struct NavigationSearchIndex: Sendable {
    static let maximumCandidates = 512

    private struct IndexedRecord: Sendable {
        let record: NavigationSearchRecord
        let normalizedTitle: String
        let normalizedProject: String
        let normalizedProvider: String?
        let normalizedMetadata: [String]
        let identifierValues: [String]
        let searchableText: String
    }

    private let records: [IndexedRecord]
    private let postings: [String: [Int]]
    private let exactIdentifiers: [String: [Int]]

    var recordCount: Int { records.count }

    init(records sourceRecords: [NavigationSearchRecord]) {
        let records = sourceRecords.sorted {
            if $0.updatedAt != $1.updatedAt { return $0.updatedAt > $1.updatedAt }
            return Self.stableIdentifier(for: $0.destination)
                < Self.stableIdentifier(for: $1.destination)
        }.map(Self.indexedRecord)
        var postings: [String: [Int]] = [:]
        var exactIdentifiers: [String: [Int]] = [:]

        for (index, record) in records.enumerated() {
            for identifier in record.identifierValues {
                exactIdentifiers[identifier, default: []].append(index)
            }

            var keys: Set<String> = []
            for token in Self.tokens(in: record.searchableText) {
                for length in 1 ... min(2, token.count) {
                    keys.insert("p:\(token.prefix(length))")
                }
            }
            for trigram in Self.trigrams(in: record.searchableText) {
                keys.insert("t:\(trigram)")
            }
            for key in keys {
                postings[key, default: []].append(index)
            }
        }

        self.records = records
        self.postings = postings
        self.exactIdentifiers = exactIdentifiers
    }

    fileprivate func search(_ query: SearchQuery) -> NavigationSearchResult {
        let positiveTerms = query.expression.positiveTerms
            .map { Self.normalized($0.text) }
            .filter { !$0.isEmpty }
        let excludedTerms = query.expression.excludedTerms
            .map { Self.normalized($0.text) }
            .filter { !$0.isEmpty }

        let exactMatches = positiveTerms.flatMap { exactIdentifiers[$0] ?? [] }
        let candidateSource: [Int]
        var didCapCandidates = false

        if positiveTerms.isEmpty {
            candidateSource = Array(records.indices.prefix(Self.maximumCandidates))
            didCapCandidates = records.count > candidateSource.count
        } else {
            let availablePostings = positiveTerms.compactMap { term -> [Int]? in
                guard let key = Self.lookupKey(for: term) else { return nil }
                return postings[key]
            }
            if availablePostings.count != positiveTerms.count {
                candidateSource = exactMatches
            } else {
                let rarest = availablePostings.min { $0.count < $1.count } ?? []
                candidateSource = exactMatches + rarest
                didCapCandidates = rarest.count > Self.maximumCandidates
            }
        }

        var seen: Set<Int> = []
        var destinationHits: [SearchHit] = []
        var archivedHits: [SearchHit] = []
        let candidateLimit = Self.maximumCandidates + exactMatches.count

        for index in candidateSource.prefix(candidateLimit) {
            if Task.isCancelled { break }
            guard seen.insert(index).inserted else { continue }
            let indexed = records[index]
            guard Self.matchesScope(indexed.record, scope: query.scope),
                  Self.matchesFilters(indexed, filters: query.expression.filters),
                  positiveTerms.allSatisfy({ indexed.searchableText.contains($0) }),
                  !excludedTerms.contains(where: { indexed.searchableText.contains($0) })
            else {
                continue
            }

            let hit = Self.hit(for: indexed, positiveTerms: positiveTerms)
            switch indexed.record.destination {
            case .archivedSession:
                archivedHits.append(hit)
            case .project, .session, .terminal:
                destinationHits.append(hit)
            }
        }

        destinationHits.sort { $0.stableOrder < $1.stableOrder }
        archivedHits.sort { $0.stableOrder < $1.stableOrder }
        return NavigationSearchResult(
            destinations: Array(destinationHits.prefix(UniversalSearchDefaults.maximumHitsPerGroup)),
            archived: Array(archivedHits.prefix(UniversalSearchDefaults.maximumHitsPerGroup)),
            isCapped: didCapCandidates
                || destinationHits.count > UniversalSearchDefaults.maximumHitsPerGroup
                || archivedHits.count > UniversalSearchDefaults.maximumHitsPerGroup
        )
    }

    private static func indexedRecord(_ record: NavigationSearchRecord) -> IndexedRecord {
        let title = normalized(record.title)
        let project = normalized(record.projectName)
        let provider = record.providerName.map(normalized)
        let metadata = record.searchableMetadata.map(normalized)
        let identifiers = identifierValues(for: record.destination).map(normalized)
        let searchable = ([title, project] + [provider, record.branch.map(normalized)].compactMap { $0 }
            + metadata + identifiers).joined(separator: " \u{1f} ")
        return IndexedRecord(
            record: record,
            normalizedTitle: title,
            normalizedProject: project,
            normalizedProvider: provider,
            normalizedMetadata: metadata,
            identifierValues: identifiers,
            searchableText: searchable
        )
    }

    private static func identifierValues(for destination: NavigationSearchRecord.Destination) -> [String] {
        switch destination {
        case let .project(projectID):
            return [projectID.uuidString]
        case let .session(projectID, sessionID),
             let .archivedSession(projectID, sessionID):
            return [projectID.uuidString, sessionID.uuidString]
        case let .terminal(projectID, terminalID):
            return [projectID.uuidString, terminalID.uuidString]
        }
    }

    private static func normalized(_ value: String) -> String {
        value.folding(
            options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
            locale: Locale(identifier: "en_US_POSIX")
        ).lowercased()
    }

    private static func tokens(in value: String) -> [Substring] {
        value.split { !$0.isLetter && !$0.isNumber }
    }

    private static func trigrams(in value: String) -> Set<String> {
        let scalars = Array(value.unicodeScalars)
        guard scalars.count >= 3 else { return [] }
        var result: Set<String> = []
        result.reserveCapacity(scalars.count - 2)
        for index in 0 ..< (scalars.count - 2) {
            result.insert(String(String.UnicodeScalarView(scalars[index ... index + 2])))
        }
        return result
    }

    private static func lookupKey(for term: String) -> String? {
        let scalars = Array(term.unicodeScalars)
        guard !scalars.isEmpty else { return nil }
        if scalars.count < 3 { return "p:\(term)" }
        return "t:\(String(String.UnicodeScalarView(scalars[0 ... 2])))"
    }

    private static func matchesScope(_ record: NavigationSearchRecord, scope: SearchScope) -> Bool {
        let projectID: ProjectID
        switch record.destination {
        case let .project(value), let .session(value, _), let .terminal(value, _),
             let .archivedSession(value, _):
            projectID = value
        }
        switch scope {
        case .everywhere:
            return true
        case let .project(expected):
            return projectID == expected
        case let .view(context):
            return context.projectID == nil || context.projectID == projectID
        }
    }

    private static func matchesFilters(_ record: IndexedRecord, filters: [SearchFilter]) -> Bool {
        filters.allSatisfy { filter in
            let matches: Bool
            switch filter.predicate {
            case let .kind(kind):
                switch record.record.destination {
                case .project: matches = kind == .project
                case .session, .archivedSession: matches = kind == .session
                case .terminal: matches = kind == .terminal
                }
            case let .project(value):
                matches = record.normalizedProject.contains(normalized(value))
            case let .provider(value):
                matches = record.normalizedProvider?.contains(normalized(value)) == true
            case .archived:
                if case .archivedSession = record.record.destination { matches = true } else { matches = false }
            case let .before(date):
                matches = record.record.updatedAt < date
            case let .after(date):
                matches = record.record.updatedAt > date
            case .author, .error:
                matches = false
            }
            return filter.isExcluded ? !matches : matches
        }
    }

    private static func hit(for record: IndexedRecord, positiveTerms: [String]) -> SearchHit {
        let identifier = stableIdentifier(for: record.record.destination)
        let hitID = SearchHitID(rawValue: "navigation:\(identifier)")
        let isArchived: Bool
        let group: SearchResultGroup
        let kind: SearchHitKind
        let locator: SearchLocator
        let projectID: ProjectID
        let sessionID: SessionID?

        switch record.record.destination {
        case let .project(value):
            projectID = value
            sessionID = nil
            isArchived = false
            group = .destinations
            kind = .project
            locator = .project(value)
        case let .session(project, session):
            projectID = project
            sessionID = session
            isArchived = false
            group = .destinations
            kind = .session
            locator = .session(projectID: project, sessionID: session)
        case let .terminal(project, terminal):
            projectID = project
            sessionID = nil
            isArchived = false
            group = .destinations
            kind = .projectTerminal
            locator = .projectTerminal(projectID: project, terminalID: terminal)
        case let .archivedSession(project, session):
            projectID = project
            sessionID = session
            isArchived = true
            group = .archived
            kind = .archivedSession
            locator = .archivedSession(projectID: project, sessionID: session)
        }

        let tier: SearchScoreTier
        if positiveTerms.contains(where: { record.identifierValues.contains($0) }) {
            tier = .exactIdentifier
        } else if positiveTerms.contains(record.normalizedTitle)
            || positiveTerms.contains(record.normalizedProject)
        {
            tier = .exactMetadata
        } else if positiveTerms.contains(where: {
            record.normalizedTitle.hasPrefix($0) || record.normalizedProject.hasPrefix($0)
        }) {
            tier = .metadataPrefix
        } else {
            tier = .literalText
        }

        return SearchHit(
            id: hitID,
            provider: .navigation,
            kind: kind,
            title: record.record.title,
            snippet: nil,
            provenance: SearchProvenance(
                projectID: projectID,
                projectName: record.record.projectName,
                sessionID: sessionID,
                sessionTitle: sessionID == nil ? nil : record.record.title,
                provider: record.record.providerName,
                branch: record.record.branch,
                timestamp: record.record.updatedAt,
                isArchived: isArchived
            ),
            stableOrder: SearchStableOrder(
                group: group,
                scoreTier: tier,
                recency: record.record.updatedAt,
                title: record.record.title,
                stableID: hitID
            ),
            locator: locator
        )
    }

    private static func stableIdentifier(for destination: NavigationSearchRecord.Destination) -> String {
        switch destination {
        case let .project(projectID):
            return "project:\(projectID.uuidString)"
        case let .session(_, sessionID):
            return "session:\(sessionID.uuidString)"
        case let .terminal(_, terminalID):
            return "terminal:\(terminalID.uuidString)"
        case let .archivedSession(_, sessionID):
            return "archived:\(sessionID.uuidString)"
        }
    }
}

private struct NavigationSearchResult: Sendable {
    let destinations: [SearchHit]
    let archived: [SearchHit]
    let isCapped: Bool
}

struct NavigationSearchProvider: UniversalSearchProvider {
    let id: SearchProviderID = .navigation
    let index: NavigationSearchIndex
    let coverage: SearchCoverage

    init(index: NavigationSearchIndex, coverage: SearchCoverage = .complete) {
        self.index = index
        self.coverage = coverage
    }

    func search(_ request: SearchProviderRequest) -> AsyncStream<SearchBatch> {
        let pair = AsyncStream<SearchBatch>.makeStream(bufferingPolicy: .bufferingNewest(2))
        let task = Task.detached(priority: .userInitiated) {
            let result = index.search(request.query)
            guard !Task.isCancelled else {
                pair.continuation.finish()
                return
            }
            // Keep one empty batch when the provider has no results so coverage remains
            // observable. When another navigation group has hits, an empty Destinations batch
            // is only visual noise and must not become a heading.
            if !result.destinations.isEmpty || result.archived.isEmpty {
                pair.continuation.yield(SearchBatch(
                    queryGeneration: request.query.generation,
                    provider: id,
                    group: .destinations,
                    hits: result.destinations,
                    coverage: coverage,
                    continuation: nil,
                    isCapped: result.isCapped
                ))
            }
            if !result.archived.isEmpty {
                pair.continuation.yield(SearchBatch(
                    queryGeneration: request.query.generation,
                    provider: id,
                    group: .archived,
                    hits: result.archived,
                    coverage: coverage,
                    continuation: nil,
                    isCapped: result.isCapped
                ))
            }
            pair.continuation.finish()
        }
        pair.continuation.onTermination = { _ in task.cancel() }
        return pair.stream
    }
}
