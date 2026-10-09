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
    let nameHistory: [SessionNameHistory.Entry]
    let updatedAt: Date

    init(
        destination: Destination,
        title: String,
        projectName: String,
        providerName: String? = nil,
        branch: String? = nil,
        searchableMetadata: [String] = [],
        nameHistory: [SessionNameHistory.Entry] = [],
        updatedAt: Date
    ) {
        self.destination = destination
        self.title = title
        self.projectName = projectName
        self.providerName = providerName
        self.branch = branch
        self.searchableMetadata = searchableMetadata
        self.nameHistory = Array(nameHistory.prefix(SessionNameHistory.maximumEntries))
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
            nameHistory: nameHistory,
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
        let currentSearchableText: String
        let historicalNames: [HistoricalName]
        let searchableText: String
    }

    private struct HistoricalName: Sendable {
        let entry: SessionNameHistory.Entry
        let normalizedName: String
        let normalizedOffsetsMatchOriginal: Bool
    }

    private struct Match {
        let recordIndex: Int
        let historicalName: HistoricalName?
        let stableOrder: SearchStableOrder
    }

    private struct NameCandidate {
        let index: Int
        let isHistorical: Bool
        let recency: Date

        static func precedes(_ lhs: Self, _ rhs: Self) -> Bool {
            if lhs.isHistorical != rhs.isHistorical { return !lhs.isHistorical }
            if lhs.recency != rhs.recency { return lhs.recency > rhs.recency }
            return lhs.index < rhs.index
        }
    }

    private let records: [IndexedRecord]
    private let postings: [String: [Int]]
    private let exactIdentifiers: [String: [Int]]
    private let exactNames: [String: [Int]]
    private let namePostings: [String: [Int]]

    var recordCount: Int { records.count }

    init(records sourceRecords: [NavigationSearchRecord]) {
        let records = sourceRecords.sorted {
            if $0.updatedAt != $1.updatedAt { return $0.updatedAt > $1.updatedAt }
            return Self.stableIdentifier(for: $0.destination)
                < Self.stableIdentifier(for: $1.destination)
        }.map(Self.indexedRecord)
        var postings: [String: [Int]] = [:]
        var exactIdentifiers: [String: [Int]] = [:]
        var nameCandidates: [String: [NameCandidate]] = [:]
        var namePostings: [String: [Int: NameCandidate]] = [:]

        for (index, record) in records.enumerated() {
            for identifier in record.identifierValues {
                exactIdentifiers[identifier, default: []].append(index)
            }
            for name in Set([record.normalizedTitle, record.normalizedProject]) where !name.isEmpty {
                let candidate = NameCandidate(
                    index: index, isHistorical: false, recency: record.record.updatedAt
                )
                nameCandidates[name, default: []].append(candidate)
                Self.addNamePostings(name, candidate: candidate, to: &namePostings)
            }
            for name in record.historicalNames {
                let candidate = NameCandidate(
                    index: index, isHistorical: true, recency: name.entry.lastSeenAt
                )
                nameCandidates[name.normalizedName, default: []].append(candidate)
                Self.addNamePostings(name.normalizedName, candidate: candidate, to: &namePostings)
            }

            for key in Self.postingKeys(in: record.searchableText) {
                postings[key, default: []].append(index)
            }
        }

        self.records = records
        self.postings = postings
        self.exactIdentifiers = exactIdentifiers
        exactNames = nameCandidates.mapValues { candidates in
            candidates.sorted(by: NameCandidate.precedes).map(\.index)
        }
        self.namePostings = namePostings.mapValues { candidates in
            candidates.values.sorted(by: NameCandidate.precedes).map(\.index)
        }
    }

    fileprivate func search(_ query: SearchQuery) -> NavigationSearchResult {
        let positiveTerms = query.expression.positiveTerms
            .map { Self.normalized($0.text) }
            .filter { !$0.isEmpty }
        let excludedTerms = query.expression.excludedTerms
            .map { Self.normalized($0.text) }
            .filter { !$0.isEmpty }

        let exactMatches = positiveTerms.compactMap { exactIdentifiers[$0] }
            .min { $0.count < $1.count } ?? []
        let nameMatches = positiveTerms.compactMap { exactNames[$0] }
            .min { $0.count < $1.count } ?? []
        let partialNameMatches = positiveTerms.compactMap { term -> [Int]? in
            Self.lookupKey(for: term).flatMap { namePostings[$0] }
        }.min { $0.count < $1.count } ?? []
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
                candidateSource = rarest
                didCapCandidates = rarest.count > Self.maximumCandidates
            }
        }

        // Exact names get first access to the fixed candidate budget. Historical buckets are
        // ordered by when that name was visible, not by unrelated later conversation activity.
        var seen: Set<Int> = []
        var candidates: [Int] = []
        candidates.reserveCapacity(Self.maximumCandidates)
        for source in [exactMatches, nameMatches, partialNameMatches, candidateSource] {
            didCapCandidates = didCapCandidates || source.count > Self.maximumCandidates
            for index in source.prefix(Self.maximumCandidates) {
                guard candidates.count < Self.maximumCandidates else {
                    didCapCandidates = true
                    break
                }
                guard seen.insert(index).inserted else { continue }
                candidates.append(index)
            }
        }
        var destinationMatches: [Match] = []
        var archivedMatches: [Match] = []

        for index in candidates {
            if Task.isCancelled { break }
            let indexed = records[index]
            guard Self.matchesScope(indexed.record, scope: query.scope),
                  Self.matchesFilters(indexed, filters: query.expression.filters),
                  positiveTerms.allSatisfy({ indexed.searchableText.contains($0) }),
                  !excludedTerms.contains(where: { indexed.searchableText.contains($0) })
            else {
                continue
            }

            let currentMatches = positiveTerms.allSatisfy { indexed.currentSearchableText.contains($0) }
            let currentTier = Self.currentTier(for: indexed, terms: positiveTerms)
            let historicalName = Self.historicalMatch(
                for: indexed, positiveTerms: positiveTerms, currentTier: currentTier
            )
            guard currentMatches || historicalName != nil else { continue }
            let group: SearchResultGroup
            if case .archivedSession = indexed.record.destination { group = .archived }
            else { group = .destinations }
            let tier = historicalName.map {
                min(currentTier, Self.metadataTier(names: [$0.normalizedName], terms: positiveTerms))
            } ?? currentTier
            let identifier = Self.stableIdentifier(for: indexed.record.destination)
            let match = Match(
                recordIndex: index,
                historicalName: historicalName,
                stableOrder: SearchStableOrder(
                    group: group,
                    scoreTier: tier,
                    isHistoricalNameMatch: historicalName != nil,
                    recency: historicalName?.entry.lastSeenAt ?? indexed.record.updatedAt,
                    title: indexed.record.title,
                    stableID: SearchHitID(rawValue: "navigation:\(identifier)")
                )
            )
            switch indexed.record.destination {
            case .archivedSession:
                archivedMatches.append(match)
            case .project, .session, .terminal:
                destinationMatches.append(match)
            }
        }

        destinationMatches.sort { $0.stableOrder < $1.stableOrder }
        archivedMatches.sort { $0.stableOrder < $1.stableOrder }
        // Localization, provenance and snippet ranges are built only for the bounded result
        // page, after candidate ranking. Most of the scored candidates never become rows.
        let destinationHits = destinationMatches.prefix(UniversalSearchDefaults.maximumHitsPerGroup).map {
            Self.hit(for: records[$0.recordIndex], match: $0, positiveTerms: positiveTerms)
        }
        let archivedHits = archivedMatches.prefix(UniversalSearchDefaults.maximumHitsPerGroup).map {
            Self.hit(for: records[$0.recordIndex], match: $0, positiveTerms: positiveTerms)
        }
        return NavigationSearchResult(
            destinations: destinationHits,
            archived: archivedHits,
            isCapped: didCapCandidates
                || destinationMatches.count > UniversalSearchDefaults.maximumHitsPerGroup
                || archivedMatches.count > UniversalSearchDefaults.maximumHitsPerGroup
        )
    }

    private static func indexedRecord(_ record: NavigationSearchRecord) -> IndexedRecord {
        let title = normalized(record.title)
        let project = normalized(record.projectName)
        let provider = record.providerName.map(normalized)
        let metadata = record.searchableMetadata.map(normalized)
        let identifiers = identifierValues(for: record.destination).map(normalized)
        let currentSearchable = ([title, project] + [provider, record.branch.map(normalized)].compactMap { $0 }
            + metadata + identifiers).joined(separator: " \u{1f} ")
        let history = record.nameHistory.map {
            HistoricalName(
                entry: $0,
                normalizedName: normalized($0.name),
                normalizedOffsetsMatchOriginal: $0.name.unicodeScalars.allSatisfy(\.isASCII)
            )
        }
        let searchable = ([currentSearchable] + history.map(\.normalizedName)).joined(separator: " \u{1f} ")
        return IndexedRecord(
            record: record,
            normalizedTitle: title,
            normalizedProject: project,
            normalizedProvider: provider,
            normalizedMetadata: metadata,
            identifierValues: identifiers,
            currentSearchableText: currentSearchable,
            historicalNames: history,
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

    private static func postingKeys(in value: String) -> Set<String> {
        var keys: Set<String> = []
        for token in tokens(in: value) {
            for length in 1 ... min(2, token.count) {
                keys.insert("p:\(token.prefix(length))")
            }
        }
        for trigram in trigrams(in: value) { keys.insert("t:\(trigram)") }
        return keys
    }

    private static func addNamePostings(
        _ name: String,
        candidate: NameCandidate,
        to postings: inout [String: [Int: NameCandidate]]
    ) {
        for key in postingKeys(in: name) {
            if let existing = postings[key]?[candidate.index],
               !NameCandidate.precedes(candidate, existing) { continue }
            postings[key, default: [:]][candidate.index] = candidate
        }
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

    private static func metadataTier(names: [String], terms: [String]) -> SearchScoreTier {
        if names.contains(where: { terms.contains($0) }) { return .exactMetadata }
        if names.contains(where: { name in terms.contains { name.hasPrefix($0) } }) {
            return .metadataPrefix
        }
        return .literalText
    }

    private static func currentTier(for record: IndexedRecord, terms: [String]) -> SearchScoreTier {
        if terms.contains(where: { record.identifierValues.contains($0) }) { return .exactIdentifier }
        return metadataTier(names: [record.normalizedTitle, record.normalizedProject], terms: terms)
    }

    private static func historicalMatch(
        for record: IndexedRecord,
        positiveTerms: [String],
        currentTier: SearchScoreTier
    ) -> HistoricalName? {
        guard !positiveTerms.isEmpty else { return nil }
        let missingTerms = positiveTerms.filter { !record.currentSearchableText.contains($0) }
        var best: HistoricalName?
        var bestTier = SearchScoreTier.fuzzyMetadata
        for name in record.historicalNames {
            guard missingTerms.allSatisfy({ name.normalizedName.contains($0) }),
                  positiveTerms.contains(where: { name.normalizedName.contains($0) }) else { continue }
            let tier = metadataTier(names: [name.normalizedName], terms: positiveTerms)
            if let previous = best, tier == bestTier {
                if name.entry.lastSeenAt < previous.entry.lastSeenAt { continue }
                if name.entry.lastSeenAt == previous.entry.lastSeenAt,
                   name.normalizedName >= previous.normalizedName { continue }
            } else if tier > bestTier {
                continue
            }
            best = name
            bestTier = tier
        }
        guard let best else { return nil }
        if missingTerms.isEmpty, currentTier <= bestTier { return nil }
        return best
    }

    private static func historicalSnippet(
        for name: HistoricalName,
        terms: [String]
    ) -> SearchSnippet {
        let text = L10n.format("Previously %@", name.entry.name)
        let source = text as NSString
        let nameRange = source.range(of: name.entry.name, options: .backwards)
        guard nameRange.location != NSNotFound else { return SearchSnippet(text: text, matches: []) }
        let normalizedName = name.normalizedName as NSString
        let matches = terms.compactMap { term -> SearchTextRange? in
            // ASCII normalization preserves UTF-16 offsets. Use the already-normalized index
            // text there; Unicode names retain the original-string collation path below.
            if name.normalizedOffsetsMatchOriginal {
                let range = normalizedName.range(of: term)
                guard range.location != NSNotFound else { return nil }
                return SearchTextRange(
                    utf16Location: nameRange.location + range.location, utf16Length: range.length
                )
            }
            let range = source.range(
                of: term,
                options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
                range: nameRange
            )
            guard range.location != NSNotFound else { return nil }
            return SearchTextRange(utf16Location: range.location, utf16Length: range.length)
        }
        return SearchSnippet(text: text, matches: matches)
    }

    private static func hit(
        for record: IndexedRecord,
        match: Match,
        positiveTerms: [String]
    ) -> SearchHit {
        let hitID = match.stableOrder.stableID
        let isArchived: Bool
        let kind: SearchHitKind
        let locator: SearchLocator
        let projectID: ProjectID
        let sessionID: SessionID?

        switch record.record.destination {
        case let .project(value):
            projectID = value
            sessionID = nil
            isArchived = false
            kind = .project
            locator = .project(value)
        case let .session(project, session):
            projectID = project
            sessionID = session
            isArchived = false
            kind = .session
            locator = .session(projectID: project, sessionID: session)
        case let .terminal(project, terminal):
            projectID = project
            sessionID = nil
            isArchived = false
            kind = .projectTerminal
            locator = .projectTerminal(projectID: project, terminalID: terminal)
        case let .archivedSession(project, session):
            projectID = project
            sessionID = session
            isArchived = true
            kind = .archivedSession
            locator = .archivedSession(projectID: project, sessionID: session)
        }

        return SearchHit(
            id: hitID,
            provider: .navigation,
            kind: kind,
            title: record.record.title,
            snippet: match.historicalName.map { historicalSnippet(for: $0, terms: positiveTerms) },
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
            stableOrder: match.stableOrder,
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
