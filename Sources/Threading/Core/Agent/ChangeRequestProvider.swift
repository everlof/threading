import Foundation

enum SourceControlProvider: String, Codable, CaseIterable, Sendable {
    case github
    case gitlab

    var displayName: String {
        switch self {
        case .github: return "GitHub"
        case .gitlab: return "GitLab"
        }
    }

    var changeRequestName: String {
        switch self {
        case .github: return L10n.string("pull request")
        case .gitlab: return L10n.string("merge request")
        }
    }

    var changeRequestTitle: String {
        switch self {
        case .github: return L10n.string("Pull request")
        case .gitlab: return L10n.string("Merge request")
        }
    }

    var changeRequestPluralName: String {
        switch self {
        case .github: return L10n.string("pull requests")
        case .gitlab: return L10n.string("merge requests")
        }
    }

    var capabilities: SourceControlProviderCapabilities {
        switch self {
        case .github:
            return SourceControlProviderCapabilities(
                createsDrafts: true,
                createsReadyRequests: true,
                reportsChecks: true,
                reportsApprovals: true,
                reportsChangesRequested: true,
                hasBrowserCreationFallback: true,
                supportsSelfHosted: false
            )
        case .gitlab:
            return SourceControlProviderCapabilities(
                createsDrafts: true,
                createsReadyRequests: true,
                reportsChecks: true,
                reportsApprovals: true,
                reportsChangesRequested: false,
                hasBrowserCreationFallback: false,
                supportsSelfHosted: false
            )
        }
    }
}

struct SourceControlProviderCapabilities: Equatable, Sendable {
    let createsDrafts: Bool
    let createsReadyRequests: Bool
    let reportsChecks: Bool
    let reportsApprovals: Bool
    let reportsChangesRequested: Bool
    let hasBrowserCreationFallback: Bool
    let supportsSelfHosted: Bool
}

enum ChangeRequestRemoteDetection: Equatable, Sendable {
    case supported(ChangeRequestRepository)
    case unsupported(message: String)
    case unrecognized
}

struct ChangeRequestRepository: Equatable, Sendable {
    let provider: SourceControlProvider
    let host: String
    let namespace: String
    let name: String

    var slug: String { "\(namespace)/\(name)" }
    var capabilities: SourceControlProviderCapabilities { provider.capabilities }

    static func detect(remote: String) -> ChangeRequestRemoteDetection {
        guard let identity = GitRemoteIdentity(remote: remote) else { return .unrecognized }
        if identity.host == GitHubDefaults.webHost,
           let repository = repository(identity: identity, provider: .github) {
            return .supported(repository)
        }
        if identity.host == GitLabDefaults.webHost,
           let repository = repository(identity: identity, provider: .gitlab) {
            return .supported(repository)
        }

        // A forge cannot be identified from arbitrary Git transport syntax alone. Recognise the
        // conventional self-hosted GitLab spelling only to make the capability refusal explicit;
        // custom-hostname forges remain unrecognised rather than being guessed as GitLab.
        if identity.host.hasPrefix("gitlab.") || identity.host.contains(".gitlab.") {
            return .unsupported(message: L10n.string(
                "Self-hosted GitLab repositories are not supported yet. Threading supports GitLab.com explicitly."
            ))
        }
        return .unrecognized
    }

    static func supported(remote: String) -> ChangeRequestRepository? {
        guard case .supported(let repository) = detect(remote: remote) else { return nil }
        return repository
    }

    static func github(remote: String) -> ChangeRequestRepository? {
        guard case .supported(let repository) = detect(remote: remote),
              repository.provider == .github else { return nil }
        return repository
    }

    static func gitlab(remote: String) -> ChangeRequestRepository? {
        guard case .supported(let repository) = detect(remote: remote),
              repository.provider == .gitlab else { return nil }
        return repository
    }

    private static func repository(
        identity: GitRemoteIdentity,
        provider: SourceControlProvider
    ) -> ChangeRequestRepository? {
        let components = identity.path.split(separator: "/", omittingEmptySubsequences: true)
        let minimumComponents = 2
        guard components.count >= minimumComponents, let name = components.last else { return nil }
        if provider == .github, components.count != minimumComponents { return nil }
        return ChangeRequestRepository(
            provider: provider,
            host: identity.host,
            namespace: components.dropLast().joined(separator: "/"),
            name: String(name)
        )
    }
}

struct ChangeRequestCloneURLs: Equatable, Sendable {
    var https: URL?
    var ssh: String?

    static let unavailable = ChangeRequestCloneURLs(https: nil, ssh: nil)
}

struct ChangeRequestProposal: Equatable, Sendable {
    var title: String
    var body: String
    var baseBranch: String
    var headBranch: String
    var isDraft: Bool
}

struct ChangeRequestChecks: Equatable, Sendable {
    enum State: String, Sendable {
        case unavailable
        case none
        case pending
        case passing
        case failing
    }

    var state: State
    var passed: Int
    var pending: Int
    var failed: Int

    static let unavailable = ChangeRequestChecks(
        state: .unavailable,
        passed: 0,
        pending: 0,
        failed: 0
    )
}

struct ChangeRequestReviews: Equatable, Sendable {
    var approvals: Int
    var changesRequested: Int
    var requested: Int

    static let empty = ChangeRequestReviews(approvals: 0, changesRequested: 0, requested: 0)
}

struct ChangeRequestSummary: Equatable, Sendable {
    let number: Int
    var title: String
    var body: String
    let url: URL
    var isDraft: Bool
    var isMerged: Bool
    var baseBranch: String
    var headBranch: String
    var headRevision: String
    var checks: ChangeRequestChecks
    var reviews: ChangeRequestReviews
}

struct ChangeRequestRepositoryStatus: Equatable, Sendable {
    let repository: ChangeRequestRepository
    let defaultBranch: String
    let branch: String
    let changeRequest: ChangeRequestSummary?
    let checks: ChangeRequestChecks
    var cloneURLs: ChangeRequestCloneURLs = .unavailable
    var capabilities: SourceControlProviderCapabilities { repository.capabilities }
}

enum ChangeRequestReadOutcome: Equatable, Sendable {
    case loaded(ChangeRequestRepositoryStatus)
    case failed(message: String)
}

enum ChangeRequestLifecycleState: Equatable, Sendable {
    case open
    case closed(merged: Bool)
}

struct ChangeRequestLifecycle: Equatable, Sendable {
    let number: Int
    let state: ChangeRequestLifecycleState
    let headBranch: String
    let headRevision: String
}

enum ChangeRequestLifecycleOutcome: Equatable, Sendable {
    case loaded(ChangeRequestLifecycle)
    case failed(message: String)
}

enum ChangeRequestCredentialSource: String, Codable, Sendable {
    case githubApp = "app"
    case ghCLI = "gh-cli"
    case gitCredential = "git-credential"
    case glabCLI = "glab-cli"

    init(_ tier: GitHubCredential.Tier) {
        switch tier {
        case .app: self = .githubApp
        case .ghCLI: self = .ghCLI
        case .gitCredential: self = .gitCredential
        case .anonymous: preconditionFailure("Anonymous access is not a write credential")
        }
    }
}

enum ChangeRequestDefaults {
    static let titleLimit = 256
    static let bodyLimit = 60_000
}

enum ChangeRequestWriteOutcome: Equatable, Sendable {
    case created(ChangeRequestSummary, credential: ChangeRequestCredentialSource)
    case webForm(URL, message: String)
    case failed(message: String)
}

enum ChangeRequestProviderReadiness: Equatable, Sendable {
    case ready(credential: ChangeRequestCredentialSource)
    case unavailable(message: String)
}

protocol ChangeRequestProviderClient: Sendable {
    var provider: SourceControlProvider { get }

    func automaticCreationReadiness(
        repository: ChangeRequestRepository
    ) async -> ChangeRequestProviderReadiness
    func discover(
        repository: ChangeRequestRepository,
        branch: String,
        headRevision: String
    ) async -> ChangeRequestReadOutcome
    func lifecycle(
        repository: ChangeRequestRepository,
        number: Int
    ) async -> ChangeRequestLifecycleOutcome
    func create(
        repository: ChangeRequestRepository,
        proposal: ChangeRequestProposal
    ) async -> ChangeRequestWriteOutcome
}

/// The forge boundary used by Git Review and managed workspaces. It contains only the operations
/// those two workflows share today; local Git push/ref work remains in `ChangeRequestGit`.
struct ChangeRequestProviderRegistry: Sendable {
    private let github: any ChangeRequestProviderClient
    private let gitlab: any ChangeRequestProviderClient

    init(
        github: any ChangeRequestProviderClient,
        gitlab: any ChangeRequestProviderClient
    ) {
        self.github = github
        self.gitlab = gitlab
    }

    @MainActor
    static func live() -> ChangeRequestProviderRegistry {
        ChangeRequestProviderRegistry(
            github: GitHubPullRequestClient.live(),
            gitlab: GitLabChangeRequestClient.live()
        )
    }

    func automaticCreationReadiness(
        repository: ChangeRequestRepository
    ) async -> ChangeRequestProviderReadiness {
        await client(for: repository).automaticCreationReadiness(repository: repository)
    }

    func discover(
        repository: ChangeRequestRepository,
        branch: String,
        headRevision: String
    ) async -> ChangeRequestReadOutcome {
        await client(for: repository).discover(
            repository: repository,
            branch: branch,
            headRevision: headRevision
        )
    }

    func lifecycle(
        repository: ChangeRequestRepository,
        number: Int
    ) async -> ChangeRequestLifecycleOutcome {
        await client(for: repository).lifecycle(repository: repository, number: number)
    }

    func create(
        repository: ChangeRequestRepository,
        proposal: ChangeRequestProposal
    ) async -> ChangeRequestWriteOutcome {
        await client(for: repository).create(repository: repository, proposal: proposal)
    }

    private func client(for repository: ChangeRequestRepository) -> any ChangeRequestProviderClient {
        switch repository.provider {
        case .github: return github
        case .gitlab: return gitlab
        }
    }
}
