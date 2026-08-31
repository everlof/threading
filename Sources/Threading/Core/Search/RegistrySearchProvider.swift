import Foundation

/// Searches the same value catalogue as the command palette. Activation still returns through
/// `HostCommandPlane`, which re-enumerates and revalidates availability before doing anything.
struct RegistrySearchProvider: UniversalSearchProvider {
    static let maximumCatalogEntries = 2500

    let id: SearchProviderID = .registry
    let descriptors: [HostCommandDescriptor]

    init(descriptors: [HostCommandDescriptor]) {
        self.descriptors = Array(descriptors.prefix(Self.maximumCatalogEntries))
    }

    func search(_ request: SearchProviderRequest) -> AsyncStream<SearchBatch> {
        let pair = AsyncStream<SearchBatch>.makeStream(bufferingPolicy: .bufferingNewest(2))
        let task = Task.detached(priority: .userInitiated) {
            let result = Self.hits(descriptors: descriptors, query: request.query)
            guard !Task.isCancelled else {
                pair.continuation.finish()
                return
            }
            pair.continuation.yield(SearchBatch(
                queryGeneration: request.query.generation,
                provider: id,
                group: .destinations,
                hits: result.commands,
                coverage: .complete,
                continuation: nil,
                isCapped: result.isCapped
            ))
            if !result.settings.isEmpty {
                pair.continuation.yield(SearchBatch(
                    queryGeneration: request.query.generation,
                    provider: id,
                    group: .settings,
                    hits: result.settings,
                    coverage: .complete,
                    continuation: nil,
                    isCapped: result.isCapped
                ))
            }
            pair.continuation.finish()
        }
        pair.continuation.onTermination = { _ in task.cancel() }
        return pair.stream
    }

    private struct Result: Sendable {
        let commands: [SearchHit]
        let settings: [SearchHit]
        let isCapped: Bool
    }

    private static func hits(
        descriptors: [HostCommandDescriptor],
        query: SearchQuery
    ) -> Result {
        let positive = query.expression.positiveTerms.map { normalized($0.text) }.filter { !$0.isEmpty }
        let excluded = query.expression.excludedTerms.map { normalized($0.text) }.filter { !$0.isEmpty }
        guard !positive.isEmpty || !query.expression.filters.isEmpty else {
            return Result(commands: [], settings: [], isCapped: false)
        }
        var commands: [SearchHit] = []
        var settings: [SearchHit] = []
        var matchingCount = 0

        for (index, descriptor) in descriptors.enumerated() {
            if index.isMultiple(of: 128), Task.isCancelled { break }
            guard descriptor.availability.isAvailable,
                  matchesFilters(descriptor, filters: query.expression.filters) else { continue }

            let metadata = searchableMetadata(descriptor)
            guard positive.allSatisfy({ metadata.contains($0) }),
                  !excluded.contains(where: { metadata.contains($0) }) else { continue }
            matchingCount += 1
            let hit = hit(descriptor, positiveTerms: positive)
            if case .settings = descriptor.origin {
                settings.append(hit)
            } else {
                commands.append(hit)
            }
        }

        commands.sort { $0.stableOrder < $1.stableOrder }
        settings.sort { $0.stableOrder < $1.stableOrder }
        let maximum = UniversalSearchDefaults.maximumHitsPerGroup
        return Result(
            commands: Array(commands.prefix(maximum)),
            settings: Array(settings.prefix(maximum)),
            isCapped: descriptors.count == maximumCatalogEntries
                || matchingCount > commands.prefix(maximum).count + settings.prefix(maximum).count
        )
    }

    private static func matchesFilters(
        _ descriptor: HostCommandDescriptor,
        filters: [SearchFilter]
    ) -> Bool {
        filters.allSatisfy { filter in
            let matches: Bool
            switch filter.predicate {
            case let .kind(kind):
                if case .settings = descriptor.origin {
                    matches = kind == .setting
                } else {
                    matches = kind == .command
                }
            case let .provider(value):
                matches = providerName(descriptor).map(normalized)?.contains(normalized(value)) == true
            case let .project(value):
                if case .projectScript = descriptor.origin {
                    matches = descriptor.group.normalizedContains(value)
                } else {
                    matches = false
                }
            case .author, .archived, .error, .before, .after:
                matches = false
            }
            return filter.isExcluded ? !matches : matches
        }
    }

    private static func searchableMetadata(_ descriptor: HostCommandDescriptor) -> String {
        ([
            descriptor.id,
            descriptor.title,
            descriptor.detail,
            descriptor.group,
            descriptor.shortcut,
            providerName(descriptor),
        ].compactMap { $0 } + descriptor.keywords)
            .map(normalized)
            .joined(separator: " \u{1f} ")
    }

    private static func providerName(_ descriptor: HostCommandDescriptor) -> String? {
        switch descriptor.origin {
        case .builtIn: return "Threading"
        case let .extensionCommand(_, name, _): return name
        case .projectScript: return "Project Scripts"
        case .settings: return "Settings"
        }
    }

    private static func hit(
        _ descriptor: HostCommandDescriptor,
        positiveTerms: [String]
    ) -> SearchHit {
        let isSetting: Bool
        let group: SearchResultGroup
        let kind: SearchHitKind
        let locator: SearchLocator
        if case .settings = descriptor.origin {
            isSetting = true
            group = .settings
            kind = .setting
            locator = .setting(destinationID: descriptor.id)
        } else {
            isSetting = false
            group = .destinations
            kind = .command
            locator = .command(descriptor.id)
        }

        let title = normalized(descriptor.title)
        let id = normalized(descriptor.id)
        let tier: SearchScoreTier
        if positiveTerms.contains(id) {
            tier = .exactIdentifier
        } else if positiveTerms.contains(title) {
            tier = .exactMetadata
        } else if positiveTerms.contains(where: { title.hasPrefix($0) }) {
            tier = .metadataPrefix
        } else {
            tier = .literalText
        }

        let hitID = SearchHitID(rawValue: "registry:\(isSetting ? "setting" : "command"):\(descriptor.id)")
        return SearchHit(
            id: hitID,
            provider: .registry,
            kind: kind,
            title: descriptor.title,
            snippet: descriptor.detail.map { SearchSnippet(text: $0, matches: []) },
            provenance: SearchProvenance(provider: providerName(descriptor)),
            stableOrder: SearchStableOrder(
                group: group,
                scoreTier: tier,
                recency: nil,
                title: descriptor.title,
                stableID: hitID
            ),
            locator: locator
        )
    }

    private static func normalized(_ value: String) -> String {
        value.folding(
            options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
            locale: Locale(identifier: "en_US_POSIX")
        ).lowercased()
    }
}

private extension String {
    func normalizedContains(_ other: String) -> Bool {
        folding(
            options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
            locale: Locale(identifier: "en_US_POSIX")
        ).lowercased().contains(
            other.folding(
                options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
                locale: Locale(identifier: "en_US_POSIX")
            ).lowercased()
        )
    }
}
