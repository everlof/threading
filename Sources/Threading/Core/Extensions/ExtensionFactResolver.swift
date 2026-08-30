import Foundation
import ThreadingExtensionKit

/// Resolves one navigator fact from exact storage plus boundary-safe repository inheritance.
///
/// Reads are synchronous dictionary lookups. The resolver does not retain checkout paths, copy
/// inherited facts onto row subjects, or perform IPC, filesystem, process, or network work.
@MainActor
final class ExtensionFactResolver {
    private let registry: ExtensionFactRegistry

    init(registry: ExtensionFactRegistry) {
        self.registry = registry
    }

    /// Resolution order is exact subject, exact repository branch, then exact repository.
    ///
    /// Project facts deliberately do not inherit to sessions. Terminal rows remain exact-only
    /// because a terminal's current directory can name a different repository than its project.
    func fact(
        _ key: ExtensionFactKey,
        for subject: ExtensionFactSubject
    ) -> ExtensionResolvedFact? {
        if let exact = registry.exactFact(key, for: subject) { return exact }

        switch subject {
        case .session(let id):
            guard let projectID = string(
                ExtensionHostFactKey.sessionProjectID,
                for: .session(id)
            ) else { return nil }
            let project = ExtensionFactSubject.project(projectID)
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
               let fact = registry.exactFact(key, for: branchSubject) {
                return fact
            }
        }
        return registry.exactFact(key, for: .repository(repository))
    }

    private func repository(for project: ExtensionFactSubject) -> ExtensionRepositoryKey? {
        guard case .string(let host) = registry.exactFact(
            ExtensionHostFactKey.projectRepositoryHost,
            for: project
        )?.fact.value,
        case .string(let path) = registry.exactFact(
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
        guard case .string(let value) = registry.exactFact(key, for: subject)?.fact.value else {
            return nil
        }
        return value
    }
}
