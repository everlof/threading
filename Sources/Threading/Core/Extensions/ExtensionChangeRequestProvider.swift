import Foundation
import ThreadingExtensionKit

/// Adapts a validated extension process response to Threading's provider-neutral domain model.
/// Local Git and every write remain outside this adapter.
struct ExtensionChangeRequestProviderClient: ChangeRequestReadProvider {
    let provider: SourceControlProvider

    func discover(
        repository: ChangeRequestRepository,
        branch: String,
        headRevision: String
    ) async -> ChangeRequestReadOutcome {
        guard let extensionIdentifier = provider.extensionIdentifier,
              let connectionID = repository.connectionID else {
            return .failed(message: L10n.string("The source-control connection is unavailable."))
        }
        let requestRepository = ExtensionSourceControlRepository(
            host: repository.host,
            namespace: repository.namespace,
            name: repository.name,
            branch: branch,
            headRevision: headRevision
        )
        let result = await invoke(
            extensionIdentifier: extensionIdentifier,
            connectionID: connectionID,
            operation: .discover,
            repository: requestRepository
        )
        switch result {
        case .failure(let error):
            return .failed(message: error.localizedDescription)
        case .success(let response):
            if let error = response.error { return .failed(message: error.message) }
            guard let defaultBranch = response.defaultBranch else {
                return .failed(message: L10n.string(
                    "The provider returned no default branch."
                ))
            }
            let summary: ChangeRequestSummary?
            if let extensionSummary = response.changeRequest {
                guard matches(
                    extensionSummary,
                    branch: branch,
                    headRevision: headRevision
                ), await webURLIsInsideConnection(
                    extensionSummary.webURL,
                    connectionID: connectionID,
                    extensionIdentifier: extensionIdentifier
                ) else {
                    return .failed(message: L10n.string(
                        "The provider returned a change request outside the requested repository state."
                    ))
                }
                summary = makeSummary(extensionSummary)
            } else {
                summary = nil
            }
            return .loaded(ChangeRequestRepositoryStatus(
                repository: repository,
                defaultBranch: defaultBranch,
                branch: branch,
                changeRequest: summary,
                checks: summary?.checks ?? .unavailable
            ))
        }
    }

    func lifecycle(
        repository: ChangeRequestRepository,
        number: Int
    ) async -> ChangeRequestLifecycleOutcome {
        guard let extensionIdentifier = provider.extensionIdentifier,
              let connectionID = repository.connectionID else {
            return .failed(message: L10n.string("The source-control connection is unavailable."))
        }
        // The lifecycle contract carries repository coordinates but intentionally no local path.
        let requestRepository = ExtensionSourceControlRepository(
            host: repository.host,
            namespace: repository.namespace,
            name: repository.name,
            branch: "unknown",
            headRevision: "unknown"
        )
        let result = await invoke(
            extensionIdentifier: extensionIdentifier,
            connectionID: connectionID,
            operation: .lifecycle,
            repository: requestRepository,
            number: number
        )
        switch result {
        case .failure(let error):
            return .failed(message: error.localizedDescription)
        case .success(let response):
            if let error = response.error { return .failed(message: error.message) }
            guard let summary = response.changeRequest, summary.number == number else {
                return .failed(message: L10n.string(
                    "The provider returned no matching change-request lifecycle."
                ))
            }
            let state: ChangeRequestLifecycleState
            switch summary.lifecycle.normalized {
            case .open, .draft: state = .open
            case .merged: state = .closed(merged: true)
            case .closed: state = .closed(merged: false)
            case .unknown:
                return .failed(message: L10n.string(
                    "The provider returned an unknown change-request lifecycle."
                ))
            }
            return .loaded(ChangeRequestLifecycle(
                number: number,
                state: state,
                headBranch: summary.headBranch,
                headRevision: summary.headRevision
            ))
        }
    }

    private func invoke(
        extensionIdentifier: String,
        connectionID: String,
        operation: ExtensionSourceControlOperation,
        repository: ExtensionSourceControlRepository,
        number: Int? = nil
    ) async -> Result<ExtensionSourceControlResponse, Error> {
        await withCheckedContinuation { continuation in
            Task { @MainActor in
                ExtensionManager.shared.invokeSourceControl(
                    extensionIdentifier: extensionIdentifier,
                    providerID: providerLocalID,
                    connectionID: connectionID,
                    operation: operation,
                    repository: repository,
                    changeRequestNumber: number
                ) { result in
                    continuation.resume(returning: result)
                }
            }
        }
    }

    private var providerLocalID: String {
        provider.rawValue.split(separator: ":", maxSplits: 2).last.map(String.init)
            ?? provider.rawValue
    }

    private func matches(
        _ summary: ExtensionChangeRequestSummary,
        branch: String,
        headRevision: String
    ) -> Bool {
        switch summary.lifecycle.normalized {
        case .open, .draft:
            return summary.headBranch == branch
        case .merged, .closed:
            return summary.headBranch == branch && summary.headRevision == headRevision
        case .unknown:
            return false
        }
    }

    private func makeSummary(_ source: ExtensionChangeRequestSummary) -> ChangeRequestSummary {
        let coverage: ChangeRequestChecks.Coverage = source.checks.isIncomplete
            ? .partial : .complete
        var outcomes: [ChangeRequestCheckOutcome: Int] = [:]
        outcomes[.passed] = source.checks.successful
        outcomes[.neutral] = source.checks.nonBlocking
        outcomes[.pending] = source.checks.active
        outcomes[.failed] = source.checks.needsAttention
        outcomes[.unknownActive("provider")] = source.checks.unknown
        let lifecycle: ChangeRequestSummaryLifecycle = switch source.lifecycle.normalized {
        case .open: .open
        case .draft: .draft
        case .merged: .merged
        case .closed: .closed
        case .unknown: .open
        }
        return ChangeRequestSummary(
            number: source.number,
            title: source.title,
            body: "",
            url: URL(string: source.webURL)!,
            isDraft: source.lifecycle.normalized == .draft,
            isMerged: source.lifecycle.normalized == .merged,
            baseBranch: source.baseBranch,
            headBranch: source.headBranch,
            headRevision: source.headRevision,
            checks: ChangeRequestChecks(outcomes: outcomes, coverage: coverage),
            reviews: ChangeRequestReviews(
                approvals: source.reviews.approvals,
                changesRequested: source.reviews.changesRequested,
                requested: source.reviews.requested
            ),
            lifecycle: lifecycle
        )
    }

    @MainActor
    private func webURLIsInsideConnection(
        _ rawURL: String,
        connectionID: String,
        extensionIdentifier: String
    ) -> Bool {
        guard let connection = SourceControlProviderConnectionStore.shared.connection(
            id: connectionID,
            extensionIdentifier: extensionIdentifier
        ), let approved = connection.origin,
        let returned = URL(string: rawURL),
        let approvedParts = URLComponents(url: approved, resolvingAgainstBaseURL: false),
        let returnedParts = URLComponents(url: returned, resolvingAgainstBaseURL: false) else {
            return false
        }
        return returnedParts.scheme == approvedParts.scheme
            && returnedParts.host?.lowercased() == approvedParts.host?.lowercased()
            && returnedParts.port == approvedParts.port
            && returnedParts.user == nil
            && returnedParts.password == nil
    }
}
