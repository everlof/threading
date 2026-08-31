import Foundation

/// A value snapshot of one checkout whose Git-visible path catalogue may participate in Search.
/// Absolute roots never enter a result; they stay on the host side of this provider and every
/// emitted locator contains only the persisted project identity plus a relative path.
struct WorkspaceFileSearchProject: Hashable, Sendable {
    let projectID: ProjectID
    let projectName: String
    let root: URL
    let updatedAt: Date
}

/// Adapts the existing cached `git ls-files` catalogue to universal Search. A cold checkout may
/// finish after the warm structured providers, but a keystroke never starts an unbounded file walk.
final class WorkspaceFileSearchProvider: UniversalSearchProvider, @unchecked Sendable {
    static let maximumEverywhereProjects = 12

    let id: SearchProviderID = .workspaceFile

    private let projects: [WorkspaceFileSearchProject]
    private let index: WorkspaceFileIndex

    init(projects: [WorkspaceFileSearchProject], index: WorkspaceFileIndex) {
        self.projects = projects.sorted {
            if $0.updatedAt != $1.updatedAt { return $0.updatedAt > $1.updatedAt }
            return $0.projectID.uuidString < $1.projectID.uuidString
        }
        self.index = index
    }

    convenience init(projects: [WorkspaceFileSearchProject]) {
        self.init(projects: projects, index: WorkspaceFileIndex())
    }

    func search(_ request: SearchProviderRequest) -> AsyncStream<SearchBatch> {
        let pair = AsyncStream<SearchBatch>.makeStream(bufferingPolicy: .bufferingNewest(2))
        let task = Task(priority: .userInitiated) { [projects, index, id] in
            let eligible = Self.eligibleProjects(projects, for: request.query)
            let positiveTerms = request.query.expression.positiveTerms.map(\.text)
            guard !positiveTerms.isEmpty, Self.filtersPermitFiles(request.query.expression.filters) else {
                pair.continuation.yield(SearchBatch(
                    queryGeneration: request.query.generation,
                    provider: id,
                    group: .files,
                    hits: [],
                    coverage: .complete,
                    continuation: nil,
                    isCapped: false
                ))
                pair.continuation.finish()
                return
            }

            let selected = Array(eligible.prefix(Self.maximumEverywhereProjects))
            var hits: [SearchHit] = []
            var unavailable = 0

            for project in selected {
                guard !Task.isCancelled else { break }
                let result = await Self.paths(
                    index: index,
                    root: project.root,
                    // The existing catalogue ranks one literal at a time. Use the most selective
                    // term for its bounded candidate page, then apply the complete expression
                    // below rather than pretending separate terms are one phrase.
                    query: positiveTerms.max(by: { $0.count < $1.count }) ?? ""
                )
                guard !Task.isCancelled else { break }
                switch result {
                case let .success(references):
                    hits += references.compactMap {
                        Self.hit(reference: $0, project: project, query: request.query)
                    }
                case .failure:
                    unavailable += 1
                }
                hits.sort { $0.stableOrder < $1.stableOrder }
                if hits.count > UniversalSearchDefaults.maximumHitsPerGroup {
                    hits.removeLast(hits.count - UniversalSearchDefaults.maximumHitsPerGroup)
                }
            }

            guard !Task.isCancelled else {
                pair.continuation.finish()
                return
            }
            let omitted = eligible.count - selected.count
            let coverage: SearchCoverage
            if omitted > 0 {
                coverage = .partial(reason: L10n.format(
                    "File paths searched in the %lld most recent projects — choose Project or refine the query.",
                    Int64(selected.count)
                ))
            } else if unavailable > 0 {
                coverage = .partial(reason: L10n.string(
                    "Some project file catalogues are unavailable."
                ))
            } else {
                coverage = .complete
            }
            pair.continuation.yield(SearchBatch(
                queryGeneration: request.query.generation,
                provider: id,
                group: .files,
                hits: hits,
                coverage: coverage,
                continuation: nil,
                isCapped: omitted > 0 || hits.count == UniversalSearchDefaults.maximumHitsPerGroup
            ))
            pair.continuation.finish()
        }
        pair.continuation.onTermination = { _ in task.cancel() }
        return pair.stream
    }

    private static func paths(
        index: WorkspaceFileIndex,
        root: URL,
        query: String
    ) async -> Result<[WorkspaceFileReference], WorkspaceFileSearchFailure> {
        await withCheckedContinuation { continuation in
            index.search(root: root, query: query) { result in
                continuation.resume(returning: result)
            }
        }
    }

    private static func eligibleProjects(
        _ projects: [WorkspaceFileSearchProject],
        for query: SearchQuery
    ) -> [WorkspaceFileSearchProject] {
        projects.filter { project in
            let isInScope: Bool
            switch query.scope {
            case .everywhere:
                isInScope = true
            case let .project(projectID):
                isInScope = project.projectID == projectID
            case let .view(context):
                isInScope = context.projectID == project.projectID
            }
            guard isInScope else { return false }
            return query.expression.filters.allSatisfy { filter in
                guard case let .project(value) = filter.predicate else { return true }
                let matches = normalized(project.projectName).contains(normalized(value))
                return filter.isExcluded ? !matches : matches
            }
        }
    }

    private static func filtersPermitFiles(_ filters: [SearchFilter]) -> Bool {
        filters.allSatisfy { filter in
            let matches: Bool
            switch filter.predicate {
            case let .kind(kind): matches = kind == .file
            case .project: matches = true
            case let .provider(value): matches = normalized("Git").contains(normalized(value))
            case .author, .archived, .error, .before, .after: matches = false
            }
            return filter.isExcluded ? !matches : matches
        }
    }

    private static func hit(
        reference: WorkspaceFileReference,
        project: WorkspaceFileSearchProject,
        query: SearchQuery
    ) -> SearchHit? {
        let normalizedPath = normalized(reference.path)
        let excluded = query.expression.excludedTerms.map { normalized($0.text) }
        guard !excluded.contains(where: normalizedPath.contains) else { return nil }

        let name = (reference.path as NSString).lastPathComponent
        let normalizedName = normalized(name)
        let terms = query.expression.positiveTerms.map { normalized($0.text) }
        guard terms.allSatisfy({ normalizedPath.contains($0) }) else { return nil }

        let tier: SearchScoreTier
        if terms.contains(normalizedName) {
            tier = .exactMetadata
        } else if terms.contains(where: normalizedName.hasPrefix) {
            tier = .metadataPrefix
        } else {
            tier = .literalText
        }
        let hitID = SearchHitID(rawValue: "workspace-file:\(project.projectID.uuidString):\(reference.path)")
        return SearchHit(
            id: hitID,
            provider: .workspaceFile,
            kind: .file,
            title: name,
            snippet: SearchSnippet(text: reference.path, matches: []),
            provenance: SearchProvenance(
                projectID: project.projectID,
                projectName: project.projectName,
                provider: "Git",
                relativePath: reference.path,
                timestamp: project.updatedAt
            ),
            stableOrder: SearchStableOrder(
                group: .files,
                scoreTier: tier,
                recency: project.updatedAt,
                title: reference.path,
                stableID: hitID
            ),
            locator: .workspaceFile(
                projectID: project.projectID,
                sessionID: nil,
                location: SearchFileLocation(
                    relativePath: reference.path,
                    line: nil,
                    column: nil,
                    matchLength: nil
                )
            )
        )
    }

    private static func normalized(_ value: String) -> String {
        value.folding(
            options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
            locale: Locale(identifier: "en_US_POSIX")
        ).lowercased()
    }
}

@MainActor
enum WorkspaceFileSearchProjection {
    static func projects(_ projects: [Project]) -> [WorkspaceFileSearchProject] {
        projects.map { project in
            let newestSession = project.sessions.map(\.lastUsedAt).max()
            return WorkspaceFileSearchProject(
                projectID: project.id,
                projectName: project.name,
                root: project.folderURL,
                updatedAt: max(project.createdAt, newestSession ?? project.createdAt)
            )
        }
    }
}
