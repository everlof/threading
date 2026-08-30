import Foundation
import ThreadingExtensionKit

/// One immutable read boundary for host-side navigator evaluation.
///
/// The registry remains main-actor isolated, but evaluation may need several facts for thousands
/// of subjects. Copying its value state once prevents one evaluation from observing facts,
/// definitions, provider generations, or structural joins from different registry revisions.
struct ExtensionFactSnapshot: Equatable, Sendable {
    typealias FactTable = [
        ExtensionFactSubject: [ExtensionFactKey: ExtensionResolvedFact]
    ]

    let revision: UInt64
    let sessionSubjects: [ExtensionFactSubject]

    private let definitionsByKey: [ExtensionFactKey: ExtensionFactDefinition]
    private let providersByKey: [ExtensionFactKey: Set<ExtensionFactResolutionSource>]
    /// The complete table is immutable and shared by every exact patch derived from this
    /// snapshot. Patch values live in a persistent balanced overlay so changing one visible fact
    /// path-copies O(log changed cells) nodes instead of triggering Dictionary's whole-table CoW.
    private let baseFacts: ExtensionFactSnapshotBaseStorage
    private let exactPatchOverlay: ExtensionFactSnapshotOverlay
    private let sessionSubjectSet: Set<ExtensionFactSubject>
    /// Reverse joins built once with a structural snapshot. Exact presentation-only changes can
    /// then identify every source row they reach without rescanning the session catalogue.
    private let sourceSessionIDsByInheritedSubject: [ExtensionFactSubject: Set<String>]

    init(
        revision: UInt64,
        sessionSubjects: [ExtensionFactSubject],
        definitionsByKey: [ExtensionFactKey: ExtensionFactDefinition],
        providersByKey: [ExtensionFactKey: Set<ExtensionFactResolutionSource>],
        factsBySubject: FactTable
    ) {
        self.revision = revision
        self.sessionSubjects = sessionSubjects
        self.definitionsByKey = definitionsByKey
        self.providersByKey = providersByKey
        baseFacts = .init(factsBySubject)
        exactPatchOverlay = .init()
        sessionSubjectSet = Set(sessionSubjects)
        sourceSessionIDsByInheritedSubject = Self.buildReverseJoins(
            sessionSubjects: sessionSubjects,
            factsBySubject: factsBySubject
        )
    }

    private init(
        revision: UInt64,
        sessionSubjects: [ExtensionFactSubject],
        definitionsByKey: [ExtensionFactKey: ExtensionFactDefinition],
        providersByKey: [ExtensionFactKey: Set<ExtensionFactResolutionSource>],
        baseFacts: ExtensionFactSnapshotBaseStorage,
        exactPatchOverlay: ExtensionFactSnapshotOverlay,
        sessionSubjectSet: Set<ExtensionFactSubject>,
        sourceSessionIDsByInheritedSubject: [ExtensionFactSubject: Set<String>]
    ) {
        self.revision = revision
        self.sessionSubjects = sessionSubjects
        self.definitionsByKey = definitionsByKey
        self.providersByKey = providersByKey
        self.baseFacts = baseFacts
        self.exactPatchOverlay = exactPatchOverlay
        self.sessionSubjectSet = sessionSubjectSet
        self.sourceSessionIDsByInheritedSubject = sourceSessionIDsByInheritedSubject
    }

    func definition(for key: ExtensionFactKey) -> ExtensionFactDefinition? {
        definitionsByKey[key]
    }

    /// Definitions are registered as part of a live generation's host authorization, before it
    /// has to publish a value for any particular subject. Presence therefore answers provider
    /// readiness without confusing an empty subject projection with an unavailable provider.
    func providers(for key: ExtensionFactKey) -> Set<ExtensionFactResolutionSource> {
        providersByKey[key] ?? []
    }

    func hasProvider(for key: ExtensionFactKey) -> Bool {
        providersByKey[key]?.isEmpty == false
    }

    func exactFact(
        _ key: ExtensionFactKey,
        for subject: ExtensionFactSubject
    ) -> ExtensionResolvedFact? {
        let cell = ExtensionFactCell(subject: subject, key: key)
        switch exactPatchOverlay.lookup(cell) {
        case .value(let fact): return fact
        case .missing: return baseFacts.facts[subject]?[key]
        }
    }

    func exactFacts(
        for subject: ExtensionFactSubject
    ) -> [ExtensionFactKey: ExtensionResolvedFact] {
        var facts = baseFacts.facts[subject] ?? [:]
        exactPatchOverlay.forEach { cell, fact in
            guard cell.subject == subject else { return }
            facts[cell.key] = fact
        }
        return facts
    }

    func containsSessionSubject(_ subject: ExtensionFactSubject) -> Bool {
        sessionSubjectSet.contains(subject)
    }

    /// Applies a provider-stable, nonstructural registry edge without rebuilding the immutable
    /// session/join projection. Callers must fall back to a complete snapshot for structural or
    /// provider changes; keeping that distinction explicit is what makes the ordinary repaint
    /// path O(changed) rather than O(all sessions).
    func applyingExactUpdates(
        _ updates: [ExtensionFactSnapshotCellUpdate],
        revision: UInt64
    ) -> ExtensionFactSnapshot {
        var overlay = exactPatchOverlay
        for update in updates {
            overlay = overlay.inserting(update.resolvedFact, for: update.cell)
        }
        return .init(
            revision: revision,
            sessionSubjects: sessionSubjects,
            definitionsByKey: definitionsByKey,
            providersByKey: providersByKey,
            baseFacts: baseFacts,
            exactPatchOverlay: overlay,
            sessionSubjectSet: sessionSubjectSet,
            sourceSessionIDsByInheritedSubject: sourceSessionIDsByInheritedSubject
        )
    }

    func affectedSourceSessionIDs(
        by cells: Set<ExtensionFactCell>
    ) -> Set<String> {
        cells.reduce(into: Set<String>()) { result, cell in
            switch cell.subject {
            case .session(let id):
                if sessionSubjectSet.contains(cell.subject) { result.insert(id) }
            case .project, .repository, .repositoryBranch:
                result.formUnion(sourceSessionIDsByInheritedSubject[cell.subject] ?? [])
            case .terminal:
                break
            }
        }
    }

    /// Resolves one value using the same exact → repository-branch → repository precedence as
    /// the live registry resolver, but entirely within this immutable revision.
    func fact(
        _ key: ExtensionFactKey,
        for subject: ExtensionFactSubject
    ) -> ExtensionResolvedFact? {
        if let exact = exactFact(key, for: subject) { return exact }

        switch subject {
        case let .session(id):
            guard let project = projectSubject(for: .session(id)) else { return nil }
            return inheritedFact(
                key,
                repository: repository(for: project),
                branch: string(ExtensionHostFactKey.sessionBranch, for: .session(id))
            )
        case .project:
            return inheritedFact(
                key,
                repository: repository(for: subject),
                branch: string(ExtensionHostFactKey.projectBranch, for: subject)
            )
        case .terminal, .repository, .repositoryBranch:
            return nil
        }
    }

    /// The only session-to-project structural edge available to a pipeline. It is derived from
    /// the public host fact rather than a model object, so project scope cannot bypass the fact
    /// contract or observe a newer project index than the values beside it.
    func projectSubject(
        for session: ExtensionFactSubject
    ) -> ExtensionFactSubject? {
        guard case .session = session,
              let projectID = string(ExtensionHostFactKey.sessionProjectID, for: session)
        else {
            return nil
        }
        return .project(projectID)
    }

    private func inheritedFact(
        _ key: ExtensionFactKey,
        repository: ExtensionRepositoryKey?,
        branch: String?
    ) -> ExtensionResolvedFact? {
        guard let repository else { return nil }
        if let branch {
            let branchSubject = ExtensionFactSubject.repositoryBranch(
                repository: repository,
                branch: branch
            )
            if branchSubject.validationIssues().isEmpty,
               let fact = exactFact(key, for: branchSubject)
            {
                return fact
            }
        }
        return exactFact(key, for: .repository(repository))
    }

    private func repository(for project: ExtensionFactSubject) -> ExtensionRepositoryKey? {
        guard case .project = project,
              case let .string(host)? = exactFact(
                  ExtensionHostFactKey.projectRepositoryHost,
                  for: project
              )?.fact.value,
              case let .string(path)? = exactFact(
                  ExtensionHostFactKey.projectRepositoryPath,
                  for: project
              )?.fact.value else { return nil }

        let repository = ExtensionRepositoryKey(host: host, path: path)
        guard ExtensionFactSubject.repository(repository).validationIssues().isEmpty else {
            return nil
        }
        return repository
    }

    private func string(
        _ key: ExtensionFactKey,
        for subject: ExtensionFactSubject
    ) -> String? {
        guard case let .string(value)? = exactFact(key, for: subject)?.fact.value else {
            return nil
        }
        return value
    }

    private static func buildReverseJoins(
        sessionSubjects: [ExtensionFactSubject],
        factsBySubject: FactTable
    ) -> [ExtensionFactSubject: Set<String>] {
        func string(_ key: ExtensionFactKey, for subject: ExtensionFactSubject) -> String? {
            guard case let .string(value)? = factsBySubject[subject]?[key]?.fact.value else {
                return nil
            }
            return value
        }

        var result: [ExtensionFactSubject: Set<String>] = [:]
        for subject in sessionSubjects {
            guard case let .session(sessionID) = subject,
                  let projectID = string(ExtensionHostFactKey.sessionProjectID, for: subject)
            else { continue }
            let project = ExtensionFactSubject.project(projectID)
            result[project, default: []].insert(sessionID)
            guard let host = string(ExtensionHostFactKey.projectRepositoryHost, for: project),
                  let path = string(ExtensionHostFactKey.projectRepositoryPath, for: project)
            else { continue }
            let repository = ExtensionRepositoryKey(host: host, path: path)
            let repositorySubject = ExtensionFactSubject.repository(repository)
            guard repositorySubject.validationIssues().isEmpty else { continue }
            result[repositorySubject, default: []].insert(sessionID)
            let branches = [
                string(ExtensionHostFactKey.sessionBranch, for: subject),
                string(ExtensionHostFactKey.projectBranch, for: project),
            ].compactMap { $0 }
            for branch in Set(branches) {
                let branchSubject = ExtensionFactSubject.repositoryBranch(
                    repository: repository,
                    branch: branch
                )
                guard branchSubject.validationIssues().isEmpty else { continue }
                result[branchSubject, default: []].insert(sessionID)
            }
        }
        return result
    }

    /// Test seam proving an exact patch retains the immutable catalogue rather than copying it.
    var baseStorageIdentityForTesting: ObjectIdentifier {
        ObjectIdentifier(baseFacts)
    }

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.revision == rhs.revision
            && lhs.sessionSubjects == rhs.sessionSubjects
            && lhs.definitionsByKey == rhs.definitionsByKey
            && lhs.providersByKey == rhs.providersByKey
            && lhs.baseFacts.facts == rhs.baseFacts.facts
            && lhs.exactPatchOverlay == rhs.exactPatchOverlay
            && lhs.sessionSubjectSet == rhs.sessionSubjectSet
            && lhs.sourceSessionIDsByInheritedSubject == rhs.sourceSessionIDsByInheritedSubject
    }
}

private final class ExtensionFactSnapshotBaseStorage: @unchecked Sendable {
    let facts: ExtensionFactSnapshot.FactTable

    init(_ facts: ExtensionFactSnapshot.FactTable) {
        self.facts = facts
    }
}

/// An immutable AVL map from exact cells to replacement facts. A stored `nil` is a tombstone;
/// absence means the lookup should continue into the immutable base table.
private struct ExtensionFactSnapshotOverlay: Equatable, Sendable {
    enum Lookup {
        case missing
        case value(ExtensionResolvedFact?)
    }

    private final class Node: @unchecked Sendable {
        let cell: ExtensionFactCell
        let fact: ExtensionResolvedFact?
        let left: Node?
        let right: Node?
        let height: Int

        init(
            cell: ExtensionFactCell,
            fact: ExtensionResolvedFact?,
            left: Node? = nil,
            right: Node? = nil
        ) {
            self.cell = cell
            self.fact = fact
            self.left = left
            self.right = right
            height = max(left?.height ?? 0, right?.height ?? 0) + 1
        }
    }

    private let root: Node?

    init() {
        root = nil
    }

    private init(root: Node?) {
        self.root = root
    }

    func lookup(_ cell: ExtensionFactCell) -> Lookup {
        var node = root
        while let current = node {
            switch Self.compare(cell, current.cell) {
            case .orderedSame: return .value(current.fact)
            case .orderedAscending: node = current.left
            case .orderedDescending: node = current.right
            }
        }
        return .missing
    }

    func inserting(
        _ fact: ExtensionResolvedFact?,
        for cell: ExtensionFactCell
    ) -> Self {
        .init(root: Self.inserting(root, cell: cell, fact: fact))
    }

    func forEach(_ body: (ExtensionFactCell, ExtensionResolvedFact?) -> Void) {
        Self.forEach(root, body)
    }

    static func == (lhs: Self, rhs: Self) -> Bool {
        var left: [(ExtensionFactCell, ExtensionResolvedFact?)] = []
        var right: [(ExtensionFactCell, ExtensionResolvedFact?)] = []
        lhs.forEach { left.append(($0, $1)) }
        rhs.forEach { right.append(($0, $1)) }
        guard left.count == right.count else { return false }
        return zip(left, right).allSatisfy { lhsEntry, rhsEntry in
            lhsEntry.0 == rhsEntry.0 && lhsEntry.1 == rhsEntry.1
        }
    }

    private static func inserting(
        _ node: Node?,
        cell: ExtensionFactCell,
        fact: ExtensionResolvedFact?
    ) -> Node {
        guard let node else { return .init(cell: cell, fact: fact) }
        let replacement: Node
        switch compare(cell, node.cell) {
        case .orderedSame:
            replacement = .init(
                cell: cell,
                fact: fact,
                left: node.left,
                right: node.right
            )
        case .orderedAscending:
            replacement = .init(
                cell: node.cell,
                fact: node.fact,
                left: inserting(node.left, cell: cell, fact: fact),
                right: node.right
            )
        case .orderedDescending:
            replacement = .init(
                cell: node.cell,
                fact: node.fact,
                left: node.left,
                right: inserting(node.right, cell: cell, fact: fact)
            )
        }
        return balanced(replacement)
    }

    private static func balanced(_ node: Node) -> Node {
        let balance = (node.left?.height ?? 0) - (node.right?.height ?? 0)
        if balance > 1, let left = node.left {
            if (left.left?.height ?? 0) < (left.right?.height ?? 0) {
                return rotateRight(.init(
                    cell: node.cell,
                    fact: node.fact,
                    left: rotateLeft(left),
                    right: node.right
                ))
            }
            return rotateRight(node)
        }
        if balance < -1, let right = node.right {
            if (right.right?.height ?? 0) < (right.left?.height ?? 0) {
                return rotateLeft(.init(
                    cell: node.cell,
                    fact: node.fact,
                    left: node.left,
                    right: rotateRight(right)
                ))
            }
            return rotateLeft(node)
        }
        return node
    }

    private static func rotateLeft(_ node: Node) -> Node {
        guard let pivot = node.right else { return node }
        let newLeft = Node(
            cell: node.cell,
            fact: node.fact,
            left: node.left,
            right: pivot.left
        )
        return .init(
            cell: pivot.cell,
            fact: pivot.fact,
            left: newLeft,
            right: pivot.right
        )
    }

    private static func rotateRight(_ node: Node) -> Node {
        guard let pivot = node.left else { return node }
        let newRight = Node(
            cell: node.cell,
            fact: node.fact,
            left: pivot.right,
            right: node.right
        )
        return .init(
            cell: pivot.cell,
            fact: pivot.fact,
            left: pivot.left,
            right: newRight
        )
    }

    private static func forEach(
        _ node: Node?,
        _ body: (ExtensionFactCell, ExtensionResolvedFact?) -> Void
    ) {
        guard let node else { return }
        forEach(node.left, body)
        body(node.cell, node.fact)
        forEach(node.right, body)
    }

    private static func compare(
        _ lhs: ExtensionFactCell,
        _ rhs: ExtensionFactCell
    ) -> ComparisonResult {
        let lhsSubject = subjectSortKey(lhs.subject)
        let rhsSubject = subjectSortKey(rhs.subject)
        if lhsSubject != rhsSubject {
            return lhsSubject.lexicographicallyPrecedes(rhsSubject)
                ? .orderedAscending
                : .orderedDescending
        }
        if lhs.key.id != rhs.key.id {
            return lhs.key.id < rhs.key.id ? .orderedAscending : .orderedDescending
        }
        if lhs.key.version != rhs.key.version {
            return lhs.key.version < rhs.key.version ? .orderedAscending : .orderedDescending
        }
        return .orderedSame
    }

    private static func subjectSortKey(_ subject: ExtensionFactSubject) -> [String] {
        switch subject {
        case .session(let id): ["0", id]
        case .project(let id): ["1", id]
        case .terminal(let id): ["2", id]
        case .repository(let repository): ["3", repository.host, repository.path]
        case .repositoryBranch(let repository, let branch):
            ["4", repository.host, repository.path, branch]
        }
    }
}

struct ExtensionFactSnapshotCellUpdate: Sendable {
    let cell: ExtensionFactCell
    let resolvedFact: ExtensionResolvedFact?
}

struct ExtensionFactSnapshotPatch: Sendable {
    let snapshot: ExtensionFactSnapshot
    let affectedSourceSessionIDs: Set<String>
}
