import Foundation
import ThreadingExtensionKit

struct ExtensionFactCell: Equatable, Hashable, Sendable {
    let subject: ExtensionFactSubject
    let key: ExtensionFactKey
}

enum ExtensionFactChange: Equatable, Sendable {
    case exact(Set<ExtensionFactCell>)
    case all
}

struct ExtensionFactsDidChange: AppEvent {
    static let name = Notification.Name("extensionFactsDidChange")
    let change: ExtensionFactChange
}

enum ExtensionFactResolutionSource: Equatable, Hashable, Sendable {
    case host
    case `extension`(identifier: String, processGeneration: String)
}

/// One independently bounded part of an atomic host-fact publication.
///
/// A complete host snapshot may exceed the registry's per-replacement limits. Keeping the
/// bounded parts explicit lets the registry validate every part before making any of them
/// visible, so a rejection cannot strand an earlier part of the same snapshot.
struct ExtensionHostFactReplacement: Sendable {
    let facts: [ExtensionFact]
    let subjects: Set<ExtensionFactSubject>
}

struct ExtensionResolvedFact: Equatable, Sendable {
    let fact: ExtensionFact
    let definition: ExtensionFactDefinition
    let source: ExtensionFactResolutionSource
    /// Host receipt time for freshness decisions. Provider time may make a fact older, never newer.
    let receivedAt: Date

    var freshnessDate: Date { min(fact.observedAt, receivedAt) }
}

enum ExtensionFactRegistryError: Error, Equatable, LocalizedError {
    case invalidDefinition(index: Int, reason: String)
    case invalidFact(index: Int, reason: String)
    case duplicateDefinition(ExtensionFactKey)
    case duplicateFact(ExtensionFactCell)
    case reservedHostKey(ExtensionFactKey)
    case hostKeyRequired(ExtensionFactKey)
    case conflictingDefinition(ExtensionFactKey)
    case missingDefinition(ExtensionFactKey)
    case incompatibleFact(ExtensionFactKey)
    case factOutsideReplacementScope(ExtensionFactSubject)
    case tooManyDefinitions(maximum: Int)
    case tooManyReplacementSubjects(maximum: Int)
    case tooManyReplacementFacts(maximum: Int)
    case tooManyFactsForSubject(maximum: Int)
    case tooManyFactsForGeneration(maximum: Int)
    case tooManyResolvedFactsForSubject(maximum: Int)

    var errorDescription: String? {
        switch self {
        case .invalidDefinition(let index, let reason):
            "Invalid fact definition at index \(index): \(reason)"
        case .invalidFact(let index, let reason):
            "Invalid fact at index \(index): \(reason)"
        case .duplicateDefinition(let key):
            "Fact definition '\(key.id)@\(key.version)' is duplicated."
        case .duplicateFact(let cell):
            "Fact '\(cell.key.id)@\(cell.key.version)' is duplicated for \(cell.subject)."
        case .reservedHostKey(let key):
            "Fact key '\(key.id)@\(key.version)' is reserved for Threading."
        case .hostKeyRequired(let key):
            "Host fact key '\(key.id)@\(key.version)' is outside a reserved host namespace."
        case .conflictingDefinition(let key):
            "Fact definition '\(key.id)@\(key.version)' conflicts with a live provider."
        case .missingDefinition(let key):
            "Fact '\(key.id)@\(key.version)' has no definition from this source."
        case .incompatibleFact(let key):
            "Fact '\(key.id)@\(key.version)' does not match its definition."
        case .factOutsideReplacementScope(let subject):
            "Fact subject \(subject) is outside the replacement scope."
        case .tooManyDefinitions(let maximum):
            "A process generation may define at most \(maximum) facts."
        case .tooManyReplacementSubjects(let maximum):
            "One replacement may name at most \(maximum) subjects."
        case .tooManyReplacementFacts(let maximum):
            "One replacement may contain at most \(maximum) facts."
        case .tooManyFactsForSubject(let maximum):
            "One source may publish at most \(maximum) facts for one subject."
        case .tooManyFactsForGeneration(let maximum):
            "A process generation may publish at most \(maximum) facts."
        case .tooManyResolvedFactsForSubject(let maximum):
            "One subject may resolve at most \(maximum) facts."
        }
    }
}

/// Bounded, generation-aware fact storage with synchronous reads for the render path.
///
/// Publication is atomic. Lookups never call an extension and never touch disk or the network.
@MainActor
final class ExtensionFactRegistry {
    static let maximumDefinitionsPerGeneration = ExtensionFactProviderLimits.maximumDefinitions
    static let maximumSubjectsPerReplacement =
        ExtensionFactProviderLimits.maximumSubjectsPerPublication
    static let maximumFactsPerReplacement = ExtensionFactProviderLimits.maximumFactsPerPublication
    static let maximumFactsPerSourceSubject = ExtensionFactProviderLimits.maximumFactsPerSubject
    static let maximumFactsPerGeneration = ExtensionFactProviderLimits.maximumFactsPerGeneration
    static let maximumResolvedFactsPerSubject = 128
    static let maximumExactNotificationCells = 256
    /// Facts which can change the subject joins used by any pipeline even when the extension did
    /// not reference the key as a presentation value. Exposed within the host so notification
    /// filtering follows the exact same inclusion boundary as snapshot construction.
    nonisolated static let snapshotStructuralKeys: Set<ExtensionFactKey> = [
        ExtensionHostFactKey.sessionProjectID,
        ExtensionHostFactKey.sessionBranch,
        ExtensionHostFactKey.projectRepositoryHost,
        ExtensionHostFactKey.projectRepositoryPath,
        ExtensionHostFactKey.projectBranch,
    ]

    private struct StoredFact: Equatable {
        let value: ExtensionFactValue
        let label: String?
        let status: ExtensionStatusRole?
        let icon: ExtensionImageReference?
        let observedAt: Date
        let receivedAt: Date

        init(_ fact: ExtensionFact, receivedAt: Date) {
            value = fact.value
            label = fact.label
            status = fact.status
            icon = fact.icon
            observedAt = fact.observedAt
            self.receivedAt = receivedAt
        }

        func fact(key: ExtensionFactKey, subject: ExtensionFactSubject) -> ExtensionFact {
            ExtensionFact(
                key: key,
                subject: subject,
                value: value,
                label: label,
                status: status,
                icon: icon,
                observedAt: observedAt
            )
        }

        func preservingHostObservation(ifSemanticallyEqualTo old: StoredFact?) -> StoredFact {
            guard let old,
                  value == old.value,
                  label == old.label,
                  status == old.status,
                  icon == old.icon else { return self }
            return old
        }
    }

    private struct ResolvedCell: Equatable {
        let stored: StoredFact
        let definition: ExtensionFactDefinition
        let source: ExtensionFactResolutionSource
    }

    private struct Publication {
        let source: ComponentCustomizationSource
        var definitions: [ExtensionFactKey: ExtensionFactDefinition]
        var facts: [ExtensionFactSubject: [ExtensionFactKey: StoredFact]]
        var factCount: Int

        init(source: ComponentCustomizationSource) {
            self.source = source
            definitions = [:]
            facts = [:]
            factCount = 0
        }
    }

    private var hostDefinitions: [ExtensionFactKey: ExtensionFactDefinition] = [:]
    private var hostFacts: [ExtensionFactSubject: [ExtensionFactKey: StoredFact]] = [:]
    private var publications: [SourceGeneration: Publication] = [:]
    private var resolved: [ExtensionFactSubject: [ExtensionFactKey: ResolvedCell]] = [:]
    private var revision: UInt64 = 0
    private let notificationCenter: NotificationCenter
    private let now: () -> Date

    init(
        notificationCenter: NotificationCenter = .default,
        now: @escaping () -> Date = Date.init
    ) {
        self.notificationCenter = notificationCenter
        self.now = now
    }

    func definition(for key: ExtensionFactKey) -> ExtensionFactDefinition? {
        if let definition = hostDefinitions[key] { return definition }
        return orderedPublications().compactMap { $0.definitions[key] }.first
    }

    func exactFact(
        _ key: ExtensionFactKey,
        for subject: ExtensionFactSubject
    ) -> ExtensionResolvedFact? {
        guard let cell = resolved[subject]?[key] else { return nil }
        return ExtensionResolvedFact(
            fact: cell.stored.fact(key: key, subject: subject),
            definition: cell.definition,
            source: cell.source,
            receivedAt: cell.stored.receivedAt
        )
    }

    func exactFacts(
        for subject: ExtensionFactSubject
    ) -> [ExtensionFactKey: ExtensionResolvedFact] {
        Dictionary(uniqueKeysWithValues: (resolved[subject] ?? [:]).map { key, cell in
            (key, ExtensionResolvedFact(
                fact: cell.stored.fact(key: key, subject: subject),
                definition: cell.definition,
                source: cell.source,
                receivedAt: cell.stored.receivedAt
            ))
        })
    }

    /// Captures every input needed by one navigator evaluation under this main-actor turn.
    /// Subsequent publications mutate registry storage and advance `revision`; they cannot alter
    /// the dictionaries retained by an existing value snapshot.
    func snapshot(consuming consumedKeys: Set<ExtensionFactKey>) -> ExtensionFactSnapshot {
        let includedKeys = consumedKeys.union(Self.snapshotStructuralKeys)
        var definitions = hostDefinitions.filter { includedKeys.contains($0.key) }
        var providers = Dictionary(uniqueKeysWithValues: definitions.keys.map {
            ($0, Set([ExtensionFactResolutionSource.host]))
        })
        for publication in orderedPublications() {
            let source = ExtensionFactResolutionSource.extension(
                identifier: publication.source.extensionIdentifier,
                processGeneration: publication.source.processGeneration
            )
            for (key, definition) in publication.definitions where includedKeys.contains(key) {
                if definitions[key] == nil { definitions[key] = definition }
                providers[key, default: []].insert(source)
            }
        }
        let hostSessions = Set(hostFacts.keys.compactMap { subject -> ExtensionFactSubject? in
            guard case .session = subject else { return nil }
            return subject
        })
        let sessions = hostSessions.sorted { lhs, rhs in
            guard case let .session(left) = lhs,
                  case let .session(right) = rhs else { return false }
            return left < right
        }
        var facts: ExtensionFactSnapshot.FactTable = [:]
        for (subject, values) in resolved {
            if case .session = subject, !hostSessions.contains(subject) { continue }
            let selected = values.filter { includedKeys.contains($0.key) }
            guard !selected.isEmpty else { continue }
            facts[subject] = Dictionary(uniqueKeysWithValues: selected.map { key, cell in
                (key, ExtensionResolvedFact(
                    fact: cell.stored.fact(key: key, subject: subject),
                    definition: cell.definition,
                    source: cell.source,
                    receivedAt: cell.stored.receivedAt
                ))
            })
        }
        return ExtensionFactSnapshot(
            revision: revision,
            sessionSubjects: sessions,
            definitionsByKey: definitions,
            providersByKey: providers,
            factsBySubject: facts
        )
    }

    /// Advances an existing snapshot through exact, provider-stable, nonstructural cells.
    /// Structural membership and join changes deliberately return `nil` so their caller takes a
    /// fresh atomic snapshot and reevaluates the transform.
    func patch(
        _ snapshot: ExtensionFactSnapshot,
        exactCells: Set<ExtensionFactCell>,
        consuming consumedKeys: Set<ExtensionFactKey>
    ) -> ExtensionFactSnapshotPatch? {
        guard exactCells.allSatisfy({ !Self.snapshotStructuralKeys.contains($0.key) }) else {
            return nil
        }
        for cell in exactCells {
            guard case .session = cell.subject else { continue }
            let isCurrentlyASourceSession = hostFacts[cell.subject] != nil
            guard snapshot.containsSessionSubject(cell.subject) == isCurrentlyASourceSession else {
                return nil
            }
        }

        let includedKeys = consumedKeys.union(Self.snapshotStructuralKeys)
        let relevantCells = exactCells.filter { includedKeys.contains($0.key) }
        let updates = relevantCells.map { cell in
            let fact = resolved[cell.subject]?[cell.key].map { value in
                ExtensionResolvedFact(
                    fact: value.stored.fact(key: cell.key, subject: cell.subject),
                    definition: value.definition,
                    source: value.source,
                    receivedAt: value.stored.receivedAt
                )
            }
            return ExtensionFactSnapshotCellUpdate(cell: cell, resolvedFact: fact)
        }
        return ExtensionFactSnapshotPatch(
            snapshot: snapshot.applyingExactUpdates(updates, revision: revision),
            affectedSourceSessionIDs: snapshot.affectedSourceSessionIDs(by: relevantCells)
        )
    }

    func replaceHostDefinitions(_ definitions: [ExtensionFactDefinition]) throws {
        let candidate = try validatedDefinitions(definitions, isHost: true)
        guard candidate != hostDefinitions else { return }

        let oldDefinitions = hostDefinitions
        hostDefinitions = candidate
        do {
            try validateExistingHostFacts()
            try recomputeAllResolvedWithoutPosting()
        } catch {
            hostDefinitions = oldDefinitions
            try? recomputeAllResolvedWithoutPosting()
            throw error
        }
        post(.all)
    }

    func replaceHostFacts(
        _ facts: [ExtensionFact],
        replacing subjects: Set<ExtensionFactSubject>
    ) throws {
        try replaceHostFacts([.init(facts: facts, subjects: subjects)])
    }

    /// Atomically applies an arbitrarily large host update assembled from bounded replacements.
    /// Every replacement retains the ordinary fact and subject caps; the outer collection is a
    /// staging boundary, not a way to raise them.
    func replaceHostFacts(_ replacements: [ExtensionHostFactReplacement]) throws {
        guard !replacements.isEmpty else { return }
        let receivedAt = now()
        var candidate = hostFacts
        var affectedSubjects: Set<ExtensionFactSubject> = []
        for replacement in replacements {
            let grouped = try validatedFacts(
                replacement.facts,
                replacing: replacement.subjects,
                definitions: hostDefinitions,
                isHost: true,
                receivedAt: receivedAt
            )
            for subject in replacement.subjects {
                let old = candidate[subject] ?? [:]
                let values = Dictionary(uniqueKeysWithValues: (grouped[subject] ?? [:]).map {
                    key, incoming in
                    (
                        key,
                        incoming.preservingHostObservation(ifSemanticallyEqualTo: old[key])
                    )
                })
                if values.isEmpty { candidate.removeValue(forKey: subject) }
                else { candidate[subject] = values }
            }
            try validateResolvedCaps(
                subjects: replacement.subjects,
                hostFacts: candidate,
                publications: publications
            )
            affectedSubjects.formUnion(replacement.subjects)
        }
        let before = resolvedCells(for: affectedSubjects)
        hostFacts = candidate
        recompute(subjects: affectedSubjects)
        postDifference(before: before, subjects: affectedSubjects)
    }

    func replaceDefinitions(
        _ definitions: [ExtensionFactDefinition],
        from source: ComponentCustomizationSource
    ) throws {
        let candidateDefinitions = try validatedDefinitions(definitions, isHost: false)
        try validateDefinitionConflicts(candidateDefinitions, excluding: SourceGeneration(source))

        let key = SourceGeneration(source)
        var publication = publications[key] ?? Publication(source: source)
        let oldPublication = publication
        publication.definitions = candidateDefinitions
        try validateFacts(publication.facts, against: candidateDefinitions)

        var candidatePublications = publications
        candidatePublications[key] = publication
        let subjects = Set(oldPublication.facts.keys).union(publication.facts.keys)
        try validateResolvedCaps(
            subjects: subjects,
            hostFacts: hostFacts,
            publications: candidatePublications
        )
        guard oldPublication.definitions != candidateDefinitions else { return }
        publications = candidatePublications
        recompute(subjects: subjects)
        post(.all)
    }

    func replaceFacts(
        _ facts: [ExtensionFact],
        replacing subjects: Set<ExtensionFactSubject>,
        from source: ComponentCustomizationSource
    ) throws {
        let key = SourceGeneration(source)
        let receivedAt = now()
        var publication = publications[key] ?? Publication(source: source)
        let grouped = try validatedFacts(
            facts,
            replacing: subjects,
            definitions: publication.definitions,
            isHost: false,
            receivedAt: receivedAt
        )
        let replacedCount = subjects.reduce(into: 0) { count, subject in
            count += publication.facts[subject]?.count ?? 0
        }
        let replacementCount = grouped.values.reduce(into: 0) { $0 += $1.count }
        let candidateCount = publication.factCount - replacedCount + replacementCount
        guard candidateCount <= Self.maximumFactsPerGeneration else {
            throw ExtensionFactRegistryError.tooManyFactsForGeneration(
                maximum: Self.maximumFactsPerGeneration
            )
        }
        for subject in subjects {
            if let values = grouped[subject], !values.isEmpty {
                publication.facts[subject] = values
            } else {
                publication.facts.removeValue(forKey: subject)
            }
        }
        publication.factCount = candidateCount

        var candidatePublications = publications
        candidatePublications[key] = publication
        try validateResolvedCaps(
            subjects: subjects,
            hostFacts: hostFacts,
            publications: candidatePublications
        )
        let before = resolvedCells(for: subjects)
        publications = candidatePublications
        recompute(subjects: subjects)
        postDifference(before: before, subjects: subjects)
    }

    func removeGeneration(extensionIdentifier: String, processGeneration: String) {
        let key = SourceGeneration(
            extensionIdentifier: extensionIdentifier,
            processGeneration: processGeneration
        )
        guard let removed = publications.removeValue(forKey: key) else { return }
        let subjects = Set(removed.facts.keys)
        let before = resolvedCells(for: subjects)
        recompute(subjects: subjects)
        if removed.definitions.isEmpty {
            postDifference(before: before, subjects: subjects)
        } else {
            post(.all)
        }
    }

    private func validatedDefinitions(
        _ definitions: [ExtensionFactDefinition],
        isHost: Bool
    ) throws -> [ExtensionFactKey: ExtensionFactDefinition] {
        guard definitions.count <= Self.maximumDefinitionsPerGeneration else {
            throw ExtensionFactRegistryError.tooManyDefinitions(
                maximum: Self.maximumDefinitionsPerGeneration
            )
        }
        var result: [ExtensionFactKey: ExtensionFactDefinition] = [:]
        for (index, definition) in definitions.enumerated() {
            do { try definition.validate() }
            catch let error as ExtensionValidationError {
                throw ExtensionFactRegistryError.invalidDefinition(
                    index: index,
                    reason: error.issues.map(\.description).joined(separator: "; ")
                )
            }
            if isHost, !ExtensionHostFactKey.isReserved(definition.key) {
                throw ExtensionFactRegistryError.hostKeyRequired(definition.key)
            }
            if !isHost, ExtensionHostFactKey.isReserved(definition.key) {
                throw ExtensionFactRegistryError.reservedHostKey(definition.key)
            }
            guard result.updateValue(definition, forKey: definition.key) == nil else {
                throw ExtensionFactRegistryError.duplicateDefinition(definition.key)
            }
        }
        return result
    }

    private func validatedFacts(
        _ facts: [ExtensionFact],
        replacing subjects: Set<ExtensionFactSubject>,
        definitions: [ExtensionFactKey: ExtensionFactDefinition],
        isHost: Bool,
        receivedAt: Date
    ) throws -> [ExtensionFactSubject: [ExtensionFactKey: StoredFact]] {
        guard facts.count <= Self.maximumFactsPerReplacement else {
            throw ExtensionFactRegistryError.tooManyReplacementFacts(
                maximum: Self.maximumFactsPerReplacement
            )
        }
        guard subjects.count <= Self.maximumSubjectsPerReplacement else {
            throw ExtensionFactRegistryError.tooManyReplacementSubjects(
                maximum: Self.maximumSubjectsPerReplacement
            )
        }
        var grouped: [ExtensionFactSubject: [ExtensionFactKey: StoredFact]] = [:]
        for (index, fact) in facts.enumerated() {
            do { try fact.validate() }
            catch let error as ExtensionValidationError {
                throw ExtensionFactRegistryError.invalidFact(
                    index: index,
                    reason: error.issues.map(\.description).joined(separator: "; ")
                )
            }
            guard subjects.contains(fact.subject) else {
                throw ExtensionFactRegistryError.factOutsideReplacementScope(fact.subject)
            }
            if isHost, !ExtensionHostFactKey.isReserved(fact.key) {
                throw ExtensionFactRegistryError.hostKeyRequired(fact.key)
            }
            if !isHost, ExtensionHostFactKey.isReserved(fact.key) {
                throw ExtensionFactRegistryError.reservedHostKey(fact.key)
            }
            guard let definition = definitions[fact.key] else {
                throw ExtensionFactRegistryError.missingDefinition(fact.key)
            }
            guard definition.valueType == fact.value.type,
                  definition.subjectKinds.contains(fact.subject.kind) else {
                throw ExtensionFactRegistryError.incompatibleFact(fact.key)
            }
            let cell = ExtensionFactCell(subject: fact.subject, key: fact.key)
            guard grouped[fact.subject, default: [:]].updateValue(
                StoredFact(fact, receivedAt: receivedAt),
                forKey: fact.key
            ) == nil else {
                throw ExtensionFactRegistryError.duplicateFact(cell)
            }
        }
        guard grouped.values.allSatisfy({ $0.count <= Self.maximumFactsPerSourceSubject }) else {
            throw ExtensionFactRegistryError.tooManyFactsForSubject(
                maximum: Self.maximumFactsPerSourceSubject
            )
        }
        return grouped
    }

    private func validateDefinitionConflicts(
        _ definitions: [ExtensionFactKey: ExtensionFactDefinition],
        excluding excluded: SourceGeneration
    ) throws {
        for publication in publications where publication.key != excluded {
            for (key, definition) in definitions {
                guard let other = publication.value.definitions[key] else { continue }
                guard definition.valueType == other.valueType,
                      definition.subjectKinds == other.subjectKinds else {
                    throw ExtensionFactRegistryError.conflictingDefinition(key)
                }
            }
        }
    }

    private func validateFacts(
        _ facts: [ExtensionFactSubject: [ExtensionFactKey: StoredFact]],
        against definitions: [ExtensionFactKey: ExtensionFactDefinition]
    ) throws {
        for (subject, values) in facts {
            for (key, value) in values {
                guard let definition = definitions[key] else {
                    throw ExtensionFactRegistryError.missingDefinition(key)
                }
                guard definition.valueType == value.value.type,
                      definition.subjectKinds.contains(subject.kind) else {
                    throw ExtensionFactRegistryError.incompatibleFact(key)
                }
            }
        }
    }

    private func validateExistingHostFacts() throws {
        try validateFacts(hostFacts, against: hostDefinitions)
    }

    private func orderedPublications(
        _ values: [SourceGeneration: Publication]? = nil
    ) -> [Publication] {
        Array((values ?? publications).values).sorted { lhs, rhs in
            if lhs.source.order != rhs.source.order { return lhs.source.order < rhs.source.order }
            if lhs.source.extensionIdentifier != rhs.source.extensionIdentifier {
                return lhs.source.extensionIdentifier < rhs.source.extensionIdentifier
            }
            return lhs.source.processGeneration < rhs.source.processGeneration
        }
    }

    private func resolvedCells(
        for subject: ExtensionFactSubject,
        hostFacts candidateHostFacts: [ExtensionFactSubject: [ExtensionFactKey: StoredFact]],
        publications candidatePublications: [SourceGeneration: Publication]
    ) -> [ExtensionFactKey: ResolvedCell] {
        var result: [ExtensionFactKey: ResolvedCell] = [:]
        for (key, stored) in candidateHostFacts[subject] ?? [:] {
            guard let definition = hostDefinitions[key] else { continue }
            result[key] = ResolvedCell(stored: stored, definition: definition, source: .host)
        }
        for publication in orderedPublications(candidatePublications) {
            for (key, stored) in publication.facts[subject] ?? [:] where result[key] == nil {
                guard let definition = publication.definitions[key] else { continue }
                result[key] = ResolvedCell(
                    stored: stored,
                    definition: definition,
                    source: .extension(
                        identifier: publication.source.extensionIdentifier,
                        processGeneration: publication.source.processGeneration
                    )
                )
            }
        }
        return result
    }

    private func validateResolvedCaps(
        subjects: Set<ExtensionFactSubject>,
        hostFacts candidateHostFacts: [ExtensionFactSubject: [ExtensionFactKey: StoredFact]],
        publications candidatePublications: [SourceGeneration: Publication]
    ) throws {
        for subject in subjects where resolvedCells(
            for: subject,
            hostFacts: candidateHostFacts,
            publications: candidatePublications
        ).count > Self.maximumResolvedFactsPerSubject {
            throw ExtensionFactRegistryError.tooManyResolvedFactsForSubject(
                maximum: Self.maximumResolvedFactsPerSubject
            )
        }
    }

    private func recompute(subjects: Set<ExtensionFactSubject>) {
        for subject in subjects {
            let values = resolvedCells(
                for: subject,
                hostFacts: hostFacts,
                publications: publications
            )
            if values.isEmpty { resolved.removeValue(forKey: subject) }
            else { resolved[subject] = values }
        }
    }

    private func recomputeAllResolvedWithoutPosting() throws {
        let subjects = Set(hostFacts.keys).union(publications.values.flatMap { $0.facts.keys })
        try validateResolvedCaps(
            subjects: subjects,
            hostFacts: hostFacts,
            publications: publications
        )
        resolved.removeAll(keepingCapacity: true)
        recompute(subjects: subjects)
    }

    private func resolvedCells(
        for subjects: Set<ExtensionFactSubject>
    ) -> [ExtensionFactSubject: [ExtensionFactKey: ResolvedCell]] {
        Dictionary(uniqueKeysWithValues: subjects.map { ($0, resolved[$0] ?? [:]) })
    }

    private func postDifference(
        before: [ExtensionFactSubject: [ExtensionFactKey: ResolvedCell]],
        subjects: Set<ExtensionFactSubject>
    ) {
        var changed: Set<ExtensionFactCell> = []
        for subject in subjects {
            let old = before[subject] ?? [:]
            let new = resolved[subject] ?? [:]
            for key in Set(old.keys).union(new.keys) where old[key] != new[key] {
                changed.insert(.init(subject: subject, key: key))
            }
        }
        guard !changed.isEmpty else { return }
        if changed.count > Self.maximumExactNotificationCells { post(.all) }
        else { post(.exact(changed)) }
    }

    private func post(_ change: ExtensionFactChange) {
        revision &+= 1
        notificationCenter.post(ExtensionFactsDidChange(change: change))
    }
}
