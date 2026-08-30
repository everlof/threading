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

enum WorkspaceNavigatorRegisteredFactChoice: Equatable, Sendable {
    case available(ExtensionFactDefinition)
    case unavailable(ExtensionFactKey)

    var key: ExtensionFactKey {
        switch self {
        case .available(let definition): definition.key
        case .unavailable(let key): key
        }
    }
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
    typealias StalenessTimerScheduler = @MainActor (
        _ interval: TimeInterval,
        _ fire: @escaping @MainActor @Sendable () -> Void
    ) -> @MainActor @Sendable () -> Void

    static let maximumDefinitionsPerGeneration = ExtensionFactProviderLimits.maximumDefinitions
    static let maximumSubjectsPerReplacement =
        ExtensionFactProviderLimits.maximumSubjectsPerPublication
    static let maximumFactsPerReplacement = ExtensionFactProviderLimits.maximumFactsPerPublication
    static let maximumFactsPerSourceSubject = ExtensionFactProviderLimits.maximumFactsPerSubject
    static let maximumFactsPerGeneration = ExtensionFactProviderLimits.maximumFactsPerGeneration
    static let maximumResolvedFactsPerSubject = 128
    static let maximumExactNotificationCells = 256
    /// Extension observations are advisory cache entries, never perpetual authority. Providers
    /// cannot lengthen this host-owned window; the current GitLab reference refreshes every five
    /// minutes, so three missed full-refresh opportunities make its last value unknown.
    static let maximumProviderFactAge: TimeInterval = 15 * 60
    /// An ordinary install exposes tens or hundreds of definitions. The deterministic stress
    /// boundary is 5,000 live winning definitions, while every rendered picker remains capped at
    /// 128 value rows. Registry mutations are occasional; menu opening reads this cached model.
    static let registeredFactCatalogStressDefinitionCount = 5_000
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

        var freshnessDate: Date { min(observedAt, receivedAt) }

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

    private struct StalenessDeadline {
        let cell: ExtensionFactCell
        let date: Date
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

    private struct RegisteredFactCatalogCache {
        var winningDefinitions: [ExtensionFactKey: ExtensionFactDefinition] = [:]
        var providersByKey: [
            ExtensionFactKey: Set<ExtensionFactResolutionSource>
        ] = [:]
        var prefixesByUsage: [ExtensionFactUsage: [ExtensionFactDefinition]] = [:]
    }

    private var hostDefinitions: [ExtensionFactKey: ExtensionFactDefinition] = [:]
    private var hostFacts: [ExtensionFactSubject: [ExtensionFactKey: StoredFact]] = [:]
    private var publications: [SourceGeneration: Publication] = [:]
    private var registeredFactCatalogCache = RegisteredFactCatalogCache()
    private var resolved: [ExtensionFactSubject: [ExtensionFactKey: ResolvedCell]] = [:]
    /// Only the winning provider cell for each resolved key needs a deadline. When it expires,
    /// recomputing that subject either selects the next fresh provider or removes the value.
    private var stalenessDeadlines: [
        ExtensionFactSubject: [ExtensionFactKey: Date]
    ] = [:]
    private var stalenessDeadlineCount = 0
    /// Lazy-invalidated min-heap. Replacements push only changed winning cells; an old heap entry
    /// is ignored once it no longer matches `stalenessDeadlines`.
    private var stalenessDeadlineHeap: [StalenessDeadline] = []
    private var nextStalenessDeadline: Date?
    private var armedStalenessDeadline: Date?
    private var cancelStalenessTimer: (@MainActor @Sendable () -> Void)?
    private var stalenessTimerArmSequence: UInt64 = 0
    private var revision: UInt64 = 0
    private let notificationCenter: NotificationCenter
    private let now: () -> Date
    private let stalenessTimerScheduler: StalenessTimerScheduler
    private var localeObserver: NSObjectProtocol?

    init(
        notificationCenter: NotificationCenter = .default,
        now: @escaping () -> Date = Date.init,
        stalenessTimerScheduler: @escaping StalenessTimerScheduler = { interval, fire in
            let timer = Timer(timeInterval: interval, repeats: false) { _ in
                Task { @MainActor in fire() }
            }
            timer.tolerance = min(1, interval * 0.1)
            RunLoop.main.add(timer, forMode: .common)
            return { timer.invalidate() }
        }
    ) {
        self.notificationCenter = notificationCenter
        self.now = now
        self.stalenessTimerScheduler = stalenessTimerScheduler
        localeObserver = notificationCenter.addObserver(
            forName: NSLocale.currentLocaleDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.rebuildRegisteredFactCatalog()
            }
        }
    }

    deinit {
        if let localeObserver {
            notificationCenter.removeObserver(localeObserver)
        }
    }

    func definition(for key: ExtensionFactKey) -> ExtensionFactDefinition? {
        registeredFactCatalogCache.winningDefinitions[key]
    }

    nonisolated static func isRegisteredFactDefinitionEligible(
        _ definition: ExtensionFactDefinition,
        for usage: ExtensionFactUsage
    ) -> Bool {
        let resolvableKinds: Set<ExtensionFactSubjectKind> = [
            .session, .repositoryBranch, .repository,
        ]
        return definition.usages.contains(usage)
            && !definition.subjectKinds.isDisjoint(with: resolvableKinds)
    }

    /// Returns `None`'s bounded fact-row model. A selected key is retained even when its winning
    /// definition disappears or becomes ineligible, so the menu can always show and clear it.
    func registeredFactChoices(
        for usage: ExtensionFactUsage,
        selectedKey: ExtensionFactKey?
    ) -> [WorkspaceNavigatorRegisteredFactChoice] {
        let maximum = ExtensionWorkspaceNavigatorPipeline.maximumRegisteredFactChoicesPerOption
        let definitions = registeredFactCatalogCache.prefixesByUsage[usage] ?? []

        guard let selectedKey else {
            return definitions.map(WorkspaceNavigatorRegisteredFactChoice.available)
        }
        guard let selectedRawDefinition = registeredFactCatalogCache
            .winningDefinitions[selectedKey],
              Self.isRegisteredFactDefinitionEligible(selectedRawDefinition, for: usage) else {
            return definitions.prefix(maximum - 1).map(
                WorkspaceNavigatorRegisteredFactChoice.available
            ) + [.unavailable(selectedKey)]
        }
        let selectedDefinition = registeredFactCatalogDefinition(selectedRawDefinition)

        guard !definitions.contains(where: { $0.key == selectedKey }) else {
            return definitions.map(WorkspaceNavigatorRegisteredFactChoice.available)
        }
        var admitted = definitions
        if admitted.count == maximum {
            admitted[maximum - 1] = selectedDefinition
        } else {
            admitted.append(selectedDefinition)
        }
        admitted.sort(by: registeredFactDefinitionLessThan)
        return admitted.map(WorkspaceNavigatorRegisteredFactChoice.available)
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
        return Dictionary(uniqueKeysWithValues: (resolved[subject] ?? [:]).map { key, cell in
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
        settleStalenessIfNeeded(at: now())
        let includedKeys = consumedKeys.union(Self.snapshotStructuralKeys)
        let definitions = Dictionary(uniqueKeysWithValues: includedKeys.compactMap { key in
            registeredFactCatalogCache.winningDefinitions[key].map { (key, $0) }
        })
        let providers = Dictionary(uniqueKeysWithValues: includedKeys.compactMap { key in
            registeredFactCatalogCache.providersByKey[key].map { (key, $0) }
        })
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
        settleStalenessIfNeeded(at: now())
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
        let referenceDate = publications.isEmpty ? Date.distantPast : now()
        settleStalenessIfNeeded(at: referenceDate)
        let candidate = try validatedDefinitions(definitions, isHost: true)
        guard candidate != hostDefinitions else { return }

        let oldDefinitions = hostDefinitions
        hostDefinitions = candidate
        do {
            try validateExistingHostFacts()
            try recomputeAllResolvedWithoutPosting(at: referenceDate)
        } catch {
            hostDefinitions = oldDefinitions
            try? recomputeAllResolvedWithoutPosting(at: referenceDate)
            throw error
        }
        rebuildRegisteredFactCatalog()
        scheduleStalenessTimer(at: referenceDate)
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
        settleStalenessIfNeeded(at: receivedAt)
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
                publications: publications,
                at: receivedAt
            )
            affectedSubjects.formUnion(replacement.subjects)
        }
        let before = resolvedCells(for: affectedSubjects)
        hostFacts = candidate
        recompute(subjects: affectedSubjects, at: receivedAt)
        scheduleStalenessTimer(at: receivedAt)
        postDifference(before: before, subjects: affectedSubjects)
    }

    func replaceDefinitions(
        _ definitions: [ExtensionFactDefinition],
        from source: ComponentCustomizationSource
    ) throws {
        let referenceDate = now()
        settleStalenessIfNeeded(at: referenceDate)
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
            publications: candidatePublications,
            at: referenceDate
        )
        guard oldPublication.definitions != candidateDefinitions else { return }
        publications = candidatePublications
        rebuildRegisteredFactCatalog()
        recompute(subjects: subjects, at: referenceDate)
        scheduleStalenessTimer(at: referenceDate)
        post(.all)
    }

    func replaceFacts(
        _ facts: [ExtensionFact],
        replacing subjects: Set<ExtensionFactSubject>,
        from source: ComponentCustomizationSource
    ) throws {
        let key = SourceGeneration(source)
        let receivedAt = now()
        settleStalenessIfNeeded(at: receivedAt)
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
            publications: candidatePublications,
            at: receivedAt
        )
        let before = resolvedCells(for: subjects)
        publications = candidatePublications
        recompute(subjects: subjects, at: receivedAt)
        scheduleStalenessTimer(at: receivedAt)
        postDifference(before: before, subjects: subjects)
    }

    func removeGeneration(extensionIdentifier: String, processGeneration: String) {
        let referenceDate = now()
        settleStalenessIfNeeded(at: referenceDate)
        let key = SourceGeneration(
            extensionIdentifier: extensionIdentifier,
            processGeneration: processGeneration
        )
        guard let removed = publications.removeValue(forKey: key) else { return }
        if !removed.definitions.isEmpty { rebuildRegisteredFactCatalog() }
        let subjects = Set(removed.facts.keys)
        let before = resolvedCells(for: subjects)
        recompute(subjects: subjects, at: referenceDate)
        scheduleStalenessTimer(at: referenceDate)
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

    private func rebuildRegisteredFactCatalog() {
        var winning = hostDefinitions
        var providers = Dictionary(uniqueKeysWithValues: hostDefinitions.keys.map {
            ($0, Set([ExtensionFactResolutionSource.host]))
        })
        for publication in orderedPublications() {
            let source = ExtensionFactResolutionSource.extension(
                identifier: publication.source.extensionIdentifier,
                processGeneration: publication.source.processGeneration
            )
            for (key, definition) in publication.definitions where winning[key] == nil {
                winning[key] = definition
            }
            for key in publication.definitions.keys {
                providers[key, default: []].insert(source)
            }
        }
        var prefixesByUsage: [ExtensionFactUsage: [ExtensionFactDefinition]] = [:]
        for eligibleUsage in [ExtensionFactUsage.groupable, .sortable] {
            prefixesByUsage[eligibleUsage] = boundedRegisteredFactPrefix(
                winning.values.map(registeredFactCatalogDefinition),
                usage: eligibleUsage
            )
        }
        registeredFactCatalogCache = .init(
            winningDefinitions: winning,
            providersByKey: providers,
            prefixesByUsage: prefixesByUsage
        )
    }

    private func registeredFactCatalogDefinition(
        _ definition: ExtensionFactDefinition
    ) -> ExtensionFactDefinition {
        guard hostDefinitions[definition.key] != nil else { return definition }
        return ExtensionFactDefinition(
            key: definition.key,
            displayName: L10n.string(definition.displayName),
            valueType: definition.valueType,
            subjectKinds: definition.subjectKinds,
            usages: definition.usages
        )
    }

    /// Selects only the rows the UI can render. Once the prefix reaches 128, every later
    /// definition compares only against that bounded ordered array; no full eligible list or
    /// unbounded menu model is retained.
    private func boundedRegisteredFactPrefix<S: Sequence>(
        _ definitions: S,
        usage: ExtensionFactUsage
    ) -> [ExtensionFactDefinition] where S.Element == ExtensionFactDefinition {
        let maximum = ExtensionWorkspaceNavigatorPipeline.maximumRegisteredFactChoicesPerOption
        var admitted: [ExtensionFactDefinition] = []
        admitted.reserveCapacity(maximum)
        for definition in definitions where Self.isRegisteredFactDefinitionEligible(
            definition,
            for: usage
        ) {
            if admitted.count < maximum {
                admitted.append(definition)
                if admitted.count == maximum {
                    admitted.sort(by: registeredFactDefinitionLessThan)
                }
                continue
            }
            guard let worst = admitted.last,
                  registeredFactDefinitionLessThan(definition, worst) else { continue }
            let insertion = admitted.firstIndex {
                registeredFactDefinitionLessThan(definition, $0)
            } ?? admitted.endIndex
            admitted.insert(definition, at: insertion)
            admitted.removeLast()
        }
        if admitted.count < maximum {
            admitted.sort(by: registeredFactDefinitionLessThan)
        }
        return admitted
    }

    private func registeredFactDefinitionLessThan(
        _ lhs: ExtensionFactDefinition,
        _ rhs: ExtensionFactDefinition
    ) -> Bool {
        let nameOrder = lhs.displayName.localizedCaseInsensitiveCompare(rhs.displayName)
        if nameOrder != .orderedSame { return nameOrder == .orderedAscending }
        if lhs.key.id != rhs.key.id { return lhs.key.id < rhs.key.id }
        return lhs.key.version < rhs.key.version
    }

    private func resolvedCells(
        for subject: ExtensionFactSubject,
        hostFacts candidateHostFacts: [ExtensionFactSubject: [ExtensionFactKey: StoredFact]],
        publications candidatePublications: [SourceGeneration: Publication],
        at referenceDate: Date,
        includingStaleProviderFacts: Bool = false
    ) -> [ExtensionFactKey: ResolvedCell] {
        var result: [ExtensionFactKey: ResolvedCell] = [:]
        for (key, stored) in candidateHostFacts[subject] ?? [:] {
            guard let definition = hostDefinitions[key] else { continue }
            result[key] = ResolvedCell(stored: stored, definition: definition, source: .host)
        }
        for publication in orderedPublications(candidatePublications) {
            for (key, stored) in publication.facts[subject] ?? [:] where result[key] == nil {
                guard let definition = publication.definitions[key] else { continue }
                guard includingStaleProviderFacts
                        || isFreshProviderFact(stored, at: referenceDate) else { continue }
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
        publications candidatePublications: [SourceGeneration: Publication],
        at referenceDate: Date
    ) throws {
        for subject in subjects where resolvedCells(
            for: subject,
            hostFacts: candidateHostFacts,
            publications: candidatePublications,
            at: referenceDate,
            includingStaleProviderFacts: true
        ).count > Self.maximumResolvedFactsPerSubject {
            throw ExtensionFactRegistryError.tooManyResolvedFactsForSubject(
                maximum: Self.maximumResolvedFactsPerSubject
            )
        }
    }

    private func recompute(subjects: Set<ExtensionFactSubject>, at referenceDate: Date) {
        for subject in subjects {
            let values = resolvedCells(
                for: subject,
                hostFacts: hostFacts,
                publications: publications,
                at: referenceDate
            )
            if values.isEmpty { resolved.removeValue(forKey: subject) }
            else { resolved[subject] = values }

            let oldDeadlines = stalenessDeadlines[subject] ?? [:]
            let deadlines = Dictionary(uniqueKeysWithValues: values.compactMap {
                key, cell -> (ExtensionFactKey, Date)? in
                guard case .extension = cell.source else { return nil }
                return (
                    key,
                    cell.stored.freshnessDate.addingTimeInterval(
                        Self.maximumProviderFactAge
                    )
                )
            })
            stalenessDeadlineCount += deadlines.count - oldDeadlines.count
            if deadlines.isEmpty { stalenessDeadlines.removeValue(forKey: subject) }
            else { stalenessDeadlines[subject] = deadlines }
            for (key, deadline) in deadlines where oldDeadlines[key] != deadline {
                pushStalenessDeadline(.init(
                    cell: .init(subject: subject, key: key),
                    date: deadline
                ))
            }
        }
    }

    private func recomputeAllResolvedWithoutPosting(at referenceDate: Date) throws {
        let subjects = Set(hostFacts.keys).union(publications.values.flatMap { $0.facts.keys })
        try validateResolvedCaps(
            subjects: subjects,
            hostFacts: hostFacts,
            publications: publications,
            at: referenceDate
        )
        resolved.removeAll(keepingCapacity: true)
        stalenessDeadlines.removeAll(keepingCapacity: true)
        stalenessDeadlineCount = 0
        stalenessDeadlineHeap.removeAll(keepingCapacity: true)
        recompute(subjects: subjects, at: referenceDate)
    }

    /// Deterministic test and wall-clock catch-up boundary. Correctness comes from stored
    /// instants; the timer only makes the comparison happen without a read.
    func refreshStaleness() {
        let referenceDate = now()
        settleStalenessIfNeeded(at: referenceDate)
        scheduleStalenessTimer(at: referenceDate)
    }

    var stalenessDeadlineIndexCounts: (active: Int, indexed: Int) {
        (stalenessDeadlineCount, stalenessDeadlineHeap.count)
    }

    private func isFreshProviderFact(_ fact: StoredFact, at referenceDate: Date) -> Bool {
        referenceDate < fact.freshnessDate.addingTimeInterval(Self.maximumProviderFactAge)
    }

    private func settleStalenessIfNeeded(at referenceDate: Date) {
        guard let nextStalenessDeadline,
              nextStalenessDeadline <= referenceDate else { return }
        var subjects: Set<ExtensionFactSubject> = []
        while let deadline = firstValidStalenessDeadline(), deadline.date <= referenceDate {
            _ = popStalenessDeadline()
            subjects.insert(deadline.cell.subject)
        }
        guard !subjects.isEmpty else {
            scheduleStalenessTimer(at: referenceDate)
            return
        }
        let before = resolvedCells(for: subjects)
        recompute(subjects: subjects, at: referenceDate)
        scheduleStalenessTimer(at: referenceDate)
        postDifference(before: before, subjects: subjects)
    }

    private func scheduleStalenessTimer(at referenceDate: Date) {
        compactStalenessDeadlineHeapIfNeeded()
        nextStalenessDeadline = firstValidStalenessDeadline()?.date
        guard armedStalenessDeadline != nextStalenessDeadline else { return }
        cancelStalenessTimer?()
        cancelStalenessTimer = nil
        armedStalenessDeadline = nil
        stalenessTimerArmSequence &+= 1
        guard let nextStalenessDeadline else { return }
        let interval = max(0.05, nextStalenessDeadline.timeIntervalSince(referenceDate))
        let armSequence = stalenessTimerArmSequence
        armedStalenessDeadline = nextStalenessDeadline
        cancelStalenessTimer = stalenessTimerScheduler(interval) { [weak self] in
            guard let self,
                  self.stalenessTimerArmSequence == armSequence,
                  self.armedStalenessDeadline == nextStalenessDeadline else { return }
            self.armedStalenessDeadline = nil
            self.cancelStalenessTimer = nil
            self.refreshStaleness()
        }
    }

    private func currentStalenessDeadline(for cell: ExtensionFactCell) -> Date? {
        stalenessDeadlines[cell.subject]?[cell.key]
    }

    private func firstValidStalenessDeadline() -> StalenessDeadline? {
        while let first = stalenessDeadlineHeap.first,
              currentStalenessDeadline(for: first.cell) != first.date {
            _ = popStalenessDeadline()
        }
        return stalenessDeadlineHeap.first
    }

    private func pushStalenessDeadline(_ deadline: StalenessDeadline) {
        stalenessDeadlineHeap.append(deadline)
        var index = stalenessDeadlineHeap.count - 1
        while index > 0 {
            let parent = (index - 1) / 2
            guard stalenessDeadlineHeap[index].date
                    < stalenessDeadlineHeap[parent].date else { break }
            stalenessDeadlineHeap.swapAt(index, parent)
            index = parent
        }
    }

    @discardableResult
    private func popStalenessDeadline() -> StalenessDeadline? {
        guard !stalenessDeadlineHeap.isEmpty else { return nil }
        if stalenessDeadlineHeap.count == 1 { return stalenessDeadlineHeap.removeLast() }
        let first = stalenessDeadlineHeap[0]
        stalenessDeadlineHeap[0] = stalenessDeadlineHeap.removeLast()
        var index = 0
        while true {
            let left = index * 2 + 1
            guard left < stalenessDeadlineHeap.count else { break }
            let right = left + 1
            let child = right < stalenessDeadlineHeap.count
                && stalenessDeadlineHeap[right].date < stalenessDeadlineHeap[left].date
                ? right
                : left
            guard stalenessDeadlineHeap[child].date
                    < stalenessDeadlineHeap[index].date else { break }
            stalenessDeadlineHeap.swapAt(index, child)
            index = child
        }
        return first
    }

    /// Lazy invalidation keeps ordinary replacements O(changed log retained). Bound the debris
    /// so a long-lived provider refreshing the same cells cannot grow the heap without limit.
    private func compactStalenessDeadlineHeapIfNeeded() {
        let maximumLazyEntries = max(512, stalenessDeadlineCount * 2)
        guard stalenessDeadlineHeap.count > maximumLazyEntries else { return }
        stalenessDeadlineHeap = stalenessDeadlines.flatMap { subject, deadlines in
            deadlines.map { key, date in
                StalenessDeadline(cell: .init(subject: subject, key: key), date: date)
            }
        }
        guard stalenessDeadlineHeap.count > 1 else { return }
        for index in stride(
            from: stalenessDeadlineHeap.count / 2 - 1,
            through: 0,
            by: -1
        ) {
            var parent = index
            while true {
                let left = parent * 2 + 1
                guard left < stalenessDeadlineHeap.count else { break }
                let right = left + 1
                let child = right < stalenessDeadlineHeap.count
                    && stalenessDeadlineHeap[right].date
                        < stalenessDeadlineHeap[left].date
                    ? right
                    : left
                guard stalenessDeadlineHeap[child].date
                        < stalenessDeadlineHeap[parent].date else { break }
                stalenessDeadlineHeap.swapAt(parent, child)
                parent = child
            }
        }
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
