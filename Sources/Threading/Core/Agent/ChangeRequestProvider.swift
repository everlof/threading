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

enum ChangeRequestCheckDefaults {
    /// Provider values are data, not presentation copy. Keep an unfamiliar value useful without
    /// letting one malformed response turn a compact receipt into an unbounded line.
    static let maximumProviderValueLength = 24
    /// Three named future values plus one explicit aggregate keep a malicious or newly expanded
    /// provider enum from manufacturing hundreds of status-card rows.
    static let maximumUnknownOutcomeBucketsPerDisposition = 4

    /// REST pages use each forge's maximum ordinary page size. Five pages bounds a status-card
    /// refresh at 500 results per source while the common path remains one request.
    static let pageSize = 100
    static let maximumPages = 5
}

enum ChangeRequestCheckOutcome: Hashable, Sendable {
    enum Disposition: Int, Comparable, Sendable {
        case successful
        case nonBlocking
        case active
        case needsAttention

        static func < (lhs: Disposition, rhs: Disposition) -> Bool {
            lhs.rawValue < rhs.rawValue
        }
    }

    case passed
    case neutral
    case skipped
    case allowedFailure(original: String)
    case requested
    case queued
    case waiting
    case pending
    case running
    case inProgress
    case cancelling
    case failed
    case error
    case startupFailure
    case actionRequired
    case timedOut
    case cancelled
    case stale
    case unknownActive(String)
    case unknownTerminal(String)

    var disposition: Disposition {
        switch self {
        case .passed:
            return .successful
        case .neutral, .skipped, .allowedFailure:
            return .nonBlocking
        case .requested, .queued, .waiting, .pending, .running, .inProgress,
             .cancelling, .unknownActive:
            return .active
        case .failed, .error, .startupFailure, .actionRequired, .timedOut, .cancelled,
             .stale, .unknownTerminal:
            return .needsAttention
        }
    }

    /// Stable within a disposition so two surfaces never reshuffle the same provider response.
    fileprivate var order: Int {
        switch self {
        case .passed: 0
        case .neutral: 10
        case .skipped: 11
        case .allowedFailure: 12
        case .requested: 20
        case .queued: 21
        case .waiting: 22
        case .pending: 23
        case .running: 24
        case .inProgress: 25
        case .cancelling: 26
        case .unknownActive: 29
        case .failed: 30
        case .error: 31
        case .startupFailure: 32
        case .actionRequired: 33
        case .timedOut: 34
        case .cancelled: 35
        case .stale: 36
        case .unknownTerminal: 39
        }
    }

    fileprivate var displayLabel: String {
        switch self {
        case .passed: L10n.string("passed")
        case .neutral: L10n.string("neutral")
        case .skipped: L10n.string("skipped")
        case .allowedFailure(let original):
            L10n.format("%@ (allowed)", Self.displayProviderValue(original))
        case .requested: L10n.string("requested")
        case .queued: L10n.string("queued")
        case .waiting: L10n.string("waiting")
        case .pending: L10n.string("pending")
        case .running: L10n.string("running")
        case .inProgress: L10n.string("in progress")
        case .cancelling: L10n.string("cancelling")
        case .failed: L10n.string("failed")
        case .error: L10n.string("error")
        case .startupFailure: L10n.string("startup failed")
        case .actionRequired: L10n.string("action required")
        case .timedOut: L10n.string("timed out")
        case .cancelled: L10n.string("cancelled")
        case .stale: L10n.string("stale")
        case .unknownActive(let value), .unknownTerminal(let value):
            L10n.format("unknown (%@)", Self.displayProviderValue(value))
        }
    }

    static func boundedProviderValue(_ value: String) -> String {
        let flattened = value
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        let usable = flattened.isEmpty ? "unknown" : flattened
        return String(usable.prefix(ChangeRequestCheckDefaults.maximumProviderValueLength))
    }

    private static func displayProviderValue(_ value: String) -> String {
        switch value.lowercased() {
        case "failed", "failure": return L10n.string("failed")
        case "canceled", "cancelled": return L10n.string("cancelled")
        case "error": return L10n.string("error")
        default: return boundedProviderValue(value)
        }
    }
}

struct ChangeRequestChecks: Equatable, Sendable {
    enum State: String, Sendable {
        case unavailable
        case none
        case pending
        case passing
        case needsAttention
    }

    struct Bucket: Equatable, Sendable {
        let outcome: ChangeRequestCheckOutcome
        let count: Int
    }

    struct Coverage: Equatable, Sendable {
        var isPartial = false
        var isCapped = false
        /// Exact number not loaded when every capped source supplied a total; nil when at least
        /// one capped source exposes only the fact that its final permitted page was full.
        var additionalCount: Int? = nil

        static let complete = Coverage()
        static let partial = Coverage(isPartial: true)

        static func capped(additionalCount: Int?) -> Coverage {
            Coverage(isCapped: true, additionalCount: additionalCount)
        }

        func merging(_ other: Coverage) -> Coverage {
            let capped = isCapped || other.isCapped
            let exactAdditional: Int?
            if !capped {
                exactAdditional = nil
            } else if (isCapped && additionalCount == nil)
                || (other.isCapped && other.additionalCount == nil) {
                exactAdditional = nil
            } else {
                exactAdditional = (additionalCount ?? 0) + (other.additionalCount ?? 0)
            }
            return Coverage(
                isPartial: isPartial || other.isPartial,
                isCapped: capped,
                additionalCount: exactAdditional
            )
        }
    }

    private let isAvailable: Bool
    let buckets: [Bucket]
    let coverage: Coverage

    init(
        outcomes: [ChangeRequestCheckOutcome: Int],
        coverage: Coverage = .complete
    ) {
        isAvailable = true
        buckets = Self.boundedOutcomes(outcomes).compactMap { outcome, count in
            count > 0 ? Bucket(outcome: outcome, count: count) : nil
        }.sorted {
            if $0.outcome.order != $1.outcome.order {
                return $0.outcome.order < $1.outcome.order
            }
            return $0.outcome.displayLabel < $1.outcome.displayLabel
        }
        self.coverage = coverage
    }

    /// Known enums have a fixed bucket count. Future or malformed provider values do not, so
    /// preserve a few useful names and combine the remainder without losing their total count.
    private static func boundedOutcomes(
        _ outcomes: [ChangeRequestCheckOutcome: Int]
    ) -> [ChangeRequestCheckOutcome: Int] {
        var canonical: [ChangeRequestCheckOutcome: Int] = [:]
        for (outcome, count) in outcomes where count > 0 {
            let bounded: ChangeRequestCheckOutcome
            switch outcome {
            case .allowedFailure(let value):
                bounded = .allowedFailure(
                    original: ChangeRequestCheckOutcome.boundedProviderValue(value)
                )
            case .unknownActive(let value):
                bounded = .unknownActive(ChangeRequestCheckOutcome.boundedProviderValue(value))
            case .unknownTerminal(let value):
                bounded = .unknownTerminal(ChangeRequestCheckOutcome.boundedProviderValue(value))
            default:
                bounded = outcome
            }
            canonical[bounded, default: 0] += count
        }

        var result: [ChangeRequestCheckOutcome: Int] = [:]
        for (outcome, count) in canonical {
            switch outcome {
            case .unknownActive, .unknownTerminal:
                break
            default:
                result[outcome] = count
            }
        }
        func appendBoundedUnknowns(
            _ entries: [(key: ChangeRequestCheckOutcome, value: Int)],
            overflow: ChangeRequestCheckOutcome
        ) {
            let ordered = entries.sorted { $0.key.displayLabel < $1.key.displayLabel }
            let limit = ChangeRequestCheckDefaults.maximumUnknownOutcomeBucketsPerDisposition
            guard ordered.count > limit else {
                for entry in ordered { result[entry.key, default: 0] += entry.value }
                return
            }
            for entry in ordered.prefix(limit - 1) {
                result[entry.key, default: 0] += entry.value
            }
            result[overflow, default: 0] += ordered.dropFirst(limit - 1).reduce(0) {
                $0 + $1.value
            }
        }

        appendBoundedUnknowns(
            Array(canonical.filter {
                if case .unknownActive = $0.key { return true }
                return false
            }),
            overflow: .unknownActive("other values")
        )
        appendBoundedUnknowns(
            Array(canonical.filter {
                if case .unknownTerminal = $0.key { return true }
                return false
            }),
            overflow: .unknownTerminal("other values")
        )
        return result
    }

    /// Compatibility initializer for fixtures and projections that still speak the former four
    /// buckets. Provider adapters use the outcome initializer so no wire state is collapsed.
    init(state: State, passed: Int, skipped: Int = 0, pending: Int, failed: Int) {
        isAvailable = state != .unavailable
        var outcomes: [ChangeRequestCheckOutcome: Int] = [:]
        outcomes[.passed] = passed
        outcomes[.skipped] = skipped
        outcomes[.pending] = pending
        outcomes[.failed] = failed
        buckets = outcomes.compactMap { outcome, count in
            count > 0 ? Bucket(outcome: outcome, count: count) : nil
        }.sorted { $0.outcome.order < $1.outcome.order }
        coverage = .complete
    }

    private init(unavailable: Void) {
        isAvailable = false
        buckets = []
        coverage = .complete
    }

    static let unavailable = ChangeRequestChecks(unavailable: ())

    var state: State {
        guard isAvailable else { return .unavailable }
        if count(disposition: .needsAttention) > 0 { return .needsAttention }
        if count(disposition: .active) > 0 { return .pending }
        return buckets.isEmpty ? .none : .passing
    }

    /// Attention outranks activity in the headline state, but an adverse result beside a still
    /// running check must not stop refreshes. Poll from the underlying fact, not its projection.
    var shouldPoll: Bool { count(disposition: .active) > 0 || coverage.isPartial }
    var totalCount: Int { buckets.reduce(0) { $0 + $1.count } }
    var passed: Int { count(of: .passed) }
    var skipped: Int { count(of: .skipped) }
    var pending: Int { count(disposition: .active) }
    var failed: Int { count(disposition: .needsAttention) }

    func count(of outcome: ChangeRequestCheckOutcome) -> Int {
        buckets.first { $0.outcome == outcome }?.count ?? 0
    }

    func count(disposition: ChangeRequestCheckOutcome.Disposition) -> Int {
        buckets.lazy.filter { $0.outcome.disposition == disposition }.reduce(0) {
            $0 + $1.count
        }
    }

    func merging(_ other: ChangeRequestChecks) -> ChangeRequestChecks {
        guard isAvailable else {
            guard other.isAvailable else { return .unavailable }
            return ChangeRequestChecks(
                outcomes: Dictionary(uniqueKeysWithValues: other.buckets.map {
                    ($0.outcome, $0.count)
                }),
                coverage: other.coverage.merging(.partial)
            )
        }
        guard other.isAvailable else {
            return ChangeRequestChecks(
                outcomes: Dictionary(uniqueKeysWithValues: buckets.map {
                    ($0.outcome, $0.count)
                }),
                coverage: coverage.merging(.partial)
            )
        }

        var outcomes = Dictionary(uniqueKeysWithValues: buckets.map { ($0.outcome, $0.count) })
        for bucket in other.buckets {
            outcomes[bucket.outcome, default: 0] += bucket.count
        }
        return ChangeRequestChecks(outcomes: outcomes, coverage: coverage.merging(other.coverage))
    }
}

enum ChangeRequestCheckPresentation {
    static func fragments(for checks: ChangeRequestChecks) -> [String] {
        guard checks.state != .unavailable else { return [L10n.string("Checks unavailable")] }

        var fragments = checks.buckets.map {
            L10n.format("%lld %@", Int64($0.count), $0.outcome.displayLabel)
        }
        if fragments.isEmpty { fragments.append(L10n.string("No checks")) }

        if checks.coverage.isPartial {
            fragments.append(L10n.string("summary incomplete"))
        }
        if checks.coverage.isCapped {
            if let additional = checks.coverage.additionalCount, additional > 0 {
                fragments.append(L10n.format("%lld more not loaded", Int64(additional)))
            } else {
                fragments.append(L10n.string("more results not loaded"))
            }
        }
        return fragments
    }

    static func text(for checks: ChangeRequestChecks) -> String {
        fragments(for: checks).joined(separator: " · ")
    }
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
