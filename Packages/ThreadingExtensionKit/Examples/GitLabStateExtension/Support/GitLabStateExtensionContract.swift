import Foundation
import ThreadingExtensionKit

public enum GitLabStateExtensionContract {
    public static let gitLabHost = "gitlab.com"
    public static let factKey = ExtensionFactKey(id: "gitlab.mr.state", version: 1)

    public static let factDefinition = ExtensionFactDefinition(
        key: factKey,
        displayName: "GitLab merge request state",
        valueType: .string,
        subjectKinds: [.repositoryBranch],
        usages: [.filterable, .sortable, .groupable, .presentable]
    )

    public static let networkGrant = ExtensionNetworkGrant(
        host: gitLabHost,
        methods: ["GET"]
    )

    public static let manifest = ExtensionManifest(
        identifier: "codes.threading.gitlab-state",
        name: "GitLab Merge Request State",
        version: "0.1.0",
        runtime: .webAssembly,
        executable: "bin/gitlab-state.wasm",
        capabilities: [
            .factsProvide,
            .hostProjectsRead,
            .hostRepositoriesRead,
            .hostEvents,
            .networkBrokered
        ],
        factDefinitions: [factDefinition],
        networkGrants: [networkGrant]
    )

    public static let registration = ExtensionRegistration(
        factDefinitions: [factDefinition]
    )
}

public enum GitLabStateLimits {
    public static let maximumRepositories = 32
    public static let maximumConcurrentRefreshes = 4
    public static let maximumPagesPerRepository = 2
    public static let maximumMergeRequestsPerPage = 100
    public static let maximumFactsPerRepository = 128
    public static let maximumFactsPerGeneration =
        maximumRepositories * maximumFactsPerRepository
    public static let maximumAttempts = 3
    public static let retryDelays: [UInt64] = [1, 2]
    public static let eventPollSeconds: UInt64 = 30
    public static let fullRefreshSeconds: TimeInterval = 5 * 60
}

public struct GitLabRepositoryAdmission: Equatable, Sendable {
    public let admitted: [ExtensionRepositoryKey]
    public let omittedCount: Int

    public init(admitted: [ExtensionRepositoryKey], omittedCount: Int) {
        self.admitted = admitted
        self.omittedCount = omittedCount
    }
}

public enum GitLabRepositoryAdmissionPolicy {
    public static func admit(
        projects: [ExtensionProjectSnapshot]
    ) -> GitLabRepositoryAdmission {
        var repositories: Set<ExtensionRepositoryKey> = []
        for project in projects {
            guard let snapshot = project.repository,
                  snapshot.remoteHost == GitLabStateExtensionContract.gitLabHost,
                  let path = snapshot.repositoryPath else {
                continue
            }
            let repository = ExtensionRepositoryKey(
                host: GitLabStateExtensionContract.gitLabHost,
                path: path
            )
            guard ExtensionFactSubject.repository(repository)
                .validationIssues().isEmpty else {
                continue
            }
            repositories.insert(repository)
        }

        let ordered = repositories.sorted(by: repositoryOrder)
        let admitted = Array(ordered.prefix(GitLabStateLimits.maximumRepositories))
        return GitLabRepositoryAdmission(
            admitted: admitted,
            omittedCount: ordered.count - admitted.count
        )
    }

    public static func repositoryOrder(
        _ lhs: ExtensionRepositoryKey,
        _ rhs: ExtensionRepositoryKey
    ) -> Bool {
        if lhs.host != rhs.host {
            return lhs.host < rhs.host
        }
        return lhs.path < rhs.path
    }
}
