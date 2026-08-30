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
    private let factsBySubject: FactTable

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
        self.factsBySubject = factsBySubject
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
        factsBySubject[subject]?[key]
    }

    func exactFacts(
        for subject: ExtensionFactSubject
    ) -> [ExtensionFactKey: ExtensionResolvedFact] {
        factsBySubject[subject] ?? [:]
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
}
