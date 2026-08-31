import Foundation

struct WorkspaceMetadataSearchRecord: Hashable, Sendable {
    enum Destination: Hashable, Sendable {
        case attachment(SearchAttachmentID)
        case browserTab(SearchBrowserTabID)
    }

    let destination: Destination
    let projectID: ProjectID
    let projectName: String
    let sessionID: SessionID
    let sessionTitle: String
    let providerName: String
    let title: String
    let detail: String
    let isArchived: Bool
    let updatedAt: Date
}

/// Searches value snapshots of durable attachments and currently materialized browser tabs. It
/// performs no filesystem or controller work on a keystroke; the composition root refreshes the
/// snapshot only when opening Search or when attachment metadata changes.
final class WorkspaceMetadataSearchProvider: UniversalSearchProvider, @unchecked Sendable {
    static let maximumCandidates = 1024

    let id: SearchProviderID = .workspaceMetadata
    private let records: [WorkspaceMetadataSearchRecord]
    private let browserCoverageIsPartial: Bool
    private let attachmentCoverageIsPartial: Bool

    init(
        records: [WorkspaceMetadataSearchRecord],
        browserCoverageIsPartial: Bool = true,
        attachmentCoverageIsPartial: Bool = true
    ) {
        self.records = records.sorted {
            if $0.updatedAt != $1.updatedAt { return $0.updatedAt > $1.updatedAt }
            return Self.stableID($0) < Self.stableID($1)
        }
        self.browserCoverageIsPartial = browserCoverageIsPartial
        self.attachmentCoverageIsPartial = attachmentCoverageIsPartial
    }

    func search(_ request: SearchProviderRequest) -> AsyncStream<SearchBatch> {
        let pair = AsyncStream<SearchBatch>.makeStream(bufferingPolicy: .bufferingNewest(2))
        let task = Task(priority: .userInitiated) {
            [records, browserCoverageIsPartial, attachmentCoverageIsPartial, id] in
            var attachments: [SearchHit] = []
            var browsers: [SearchHit] = []
            let candidates = records.prefix(Self.maximumCandidates)
            for record in candidates {
                guard !Task.isCancelled else { break }
                guard Self.matches(record, query: request.query) else { continue }
                let hit = Self.hit(record, query: request.query)
                switch record.destination {
                case .attachment: attachments.append(hit)
                case .browserTab: browsers.append(hit)
                }
            }
            guard !Task.isCancelled else {
                pair.continuation.finish()
                return
            }
            attachments.sort { $0.stableOrder < $1.stableOrder }
            browsers.sort { $0.stableOrder < $1.stableOrder }
            let didCapCandidates = records.count > Self.maximumCandidates
            pair.continuation.yield(SearchBatch(
                queryGeneration: request.query.generation,
                provider: id,
                group: .destinations,
                hits: Array(browsers.prefix(UniversalSearchDefaults.maximumHitsPerGroup)),
                coverage: browserCoverageIsPartial
                    ? .partial(reason: L10n.string(
                        "Browser search covers tabs opened during this launch."
                    ))
                    : .complete,
                continuation: nil,
                isCapped: didCapCandidates
                    || browsers.count > UniversalSearchDefaults.maximumHitsPerGroup
            ))
            pair.continuation.yield(SearchBatch(
                queryGeneration: request.query.generation,
                provider: id,
                group: .files,
                hits: Array(attachments.prefix(UniversalSearchDefaults.maximumHitsPerGroup)),
                coverage: attachmentCoverageIsPartial
                    ? .partial(reason: L10n.string(
                        "Attachment search covers sessions opened during this launch."
                    ))
                    : .complete,
                continuation: nil,
                isCapped: didCapCandidates
                    || attachments.count > UniversalSearchDefaults.maximumHitsPerGroup
            ))
            pair.continuation.finish()
        }
        pair.continuation.onTermination = { _ in task.cancel() }
        return pair.stream
    }

    private static func matches(_ record: WorkspaceMetadataSearchRecord, query: SearchQuery) -> Bool {
        let inScope: Bool
        switch query.scope {
        case .everywhere:
            inScope = true
        case let .project(projectID):
            inScope = record.projectID == projectID
        case let .view(context):
            inScope = context.sessionID == record.sessionID
        }
        guard inScope else { return false }

        let corpus = normalized([
            record.title, record.detail, record.projectName, record.sessionTitle,
            record.providerName, stableID(record),
        ].joined(separator: " \u{1f} "))
        let positive = query.expression.positiveTerms.map { normalized($0.text) }
        let excluded = query.expression.excludedTerms.map { normalized($0.text) }
        guard positive.allSatisfy(corpus.contains),
              !excluded.contains(where: corpus.contains) else { return false }

        return query.expression.filters.allSatisfy { filter in
            let matches: Bool
            switch filter.predicate {
            case let .kind(kind):
                switch record.destination {
                case .attachment: matches = kind == .attachment || kind == .file
                case .browserTab: matches = kind == .browser
                }
            case let .project(value): matches = normalized(record.projectName).contains(normalized(value))
            case let .provider(value): matches = normalized(record.providerName).contains(normalized(value))
            case .archived: matches = record.isArchived
            case let .before(date): matches = record.updatedAt < date
            case let .after(date): matches = record.updatedAt > date
            case .author, .error: matches = false
            }
            return filter.isExcluded ? !matches : matches
        }
    }

    private static func hit(
        _ record: WorkspaceMetadataSearchRecord,
        query: SearchQuery
    ) -> SearchHit {
        let normalizedTitle = normalized(record.title)
        let terms = query.expression.positiveTerms.map { normalized($0.text) }
        let tier: SearchScoreTier
        if terms.contains(normalizedTitle) {
            tier = .exactMetadata
        } else if terms.contains(where: normalizedTitle.hasPrefix) {
            tier = .metadataPrefix
        } else {
            tier = .literalText
        }

        let rawID = stableID(record)
        let hitID = SearchHitID(rawValue: "workspace-metadata:\(rawID)")
        let kind: SearchHitKind
        let locator: SearchLocator
        let group: SearchResultGroup
        switch record.destination {
        case let .attachment(attachmentID):
            kind = .attachment
            locator = .attachment(
                projectID: record.projectID,
                sessionID: record.sessionID,
                attachmentID: attachmentID
            )
            group = .files
        case let .browserTab(tabID):
            kind = .browserTab
            locator = .browserTab(
                projectID: record.projectID,
                sessionID: record.sessionID,
                tabID: tabID
            )
            group = .destinations
        }
        return SearchHit(
            id: hitID,
            provider: .workspaceMetadata,
            kind: kind,
            title: record.title,
            snippet: SearchSnippet(text: record.detail, matches: []),
            provenance: SearchProvenance(
                projectID: record.projectID,
                projectName: record.projectName,
                sessionID: record.sessionID,
                sessionTitle: record.sessionTitle,
                provider: record.providerName,
                timestamp: record.updatedAt,
                isArchived: record.isArchived
            ),
            stableOrder: SearchStableOrder(
                group: group,
                scoreTier: tier,
                recency: record.updatedAt,
                title: record.title,
                stableID: hitID
            ),
            locator: locator
        )
    }

    private static func stableID(_ record: WorkspaceMetadataSearchRecord) -> String {
        let child: String
        switch record.destination {
        case let .attachment(id): child = "attachment:\(id.rawValue)"
        case let .browserTab(id): child = "browser:\(id.rawValue)"
        }
        return "\(record.projectID.uuidString):\(record.sessionID.uuidString):\(child)"
    }

    private static func normalized(_ value: String) -> String {
        value.folding(
            options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
            locale: Locale(identifier: "en_US_POSIX")
        ).lowercased()
    }
}
