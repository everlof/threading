import AppKit
import Foundation

enum ManagedWorkspaceRemoteCleanupOutcome: Equatable, Sendable {
    case waiting
    case disposed(ManagedWorkspaceRemoteBranchState)
    case ownershipLost(String)
    case failed(String)
}

/// The post-review half of a managed publication. It has no local-worktree dependency: the
/// repository root supplies Git's remote configuration, while the durable publication receipt
/// supplies every identity that must agree before the generated ref can be touched.
struct ManagedWorkspaceRemoteCleaner: Sendable {
    private let github: GitHubPullRequestClient

    init(github: GitHubPullRequestClient) {
        self.github = github
    }

    @MainActor
    static func live() -> Self {
        Self(github: .live())
    }

    func reconcile(
        sessionID: SessionID,
        workspace: ManagedWorkspace
    ) async -> ManagedWorkspaceRemoteCleanupOutcome {
        guard let receipt = workspace.changeRequest,
              let branch = workspace.remoteBranch,
              let finalCommit = workspace.finalCommit,
              receipt.remote == "origin",
              receipt.branch == branch,
              branch == ManagedGitWorkspace.publicationBranch(for: sessionID) else {
            return .ownershipLost(L10n.string(
                "The stored review no longer matches Threading’s generated branch, so the remote branch was left in place."
            ))
        }

        guard let remote = GitInfo.remoteOriginURL(for: workspace.repositoryRoot),
              let repository = ChangeRequestRepository.supported(remote: remote),
              repository.provider == receipt.provider,
              repository.slug.caseInsensitiveCompare(receipt.repository) == .orderedSame else {
            return .failed(L10n.string(
                "Threading could not match the published review to this repository’s origin remote."
            ))
        }

        let review: ChangeRequestLifecycle
        switch await github.lifecycle(repository: repository, number: receipt.number) {
        case .loaded(let lifecycle):
            review = lifecycle
        case .failed(let message):
            return .failed(message)
        }

        guard review.number == receipt.number, review.headBranch == branch else {
            return .ownershipLost(L10n.string(
                "The stored review no longer matches Threading’s generated branch, so the remote branch was left in place."
            ))
        }
        guard case .closed = review.state else { return .waiting }

        let remoteRevision: String?
        do {
            remoteRevision = try await ChangeRequestGit.remoteRevision(
                of: branch,
                remote: receipt.remote,
                in: URL(fileURLWithPath: workspace.repositoryRoot, isDirectory: true)
            )
        } catch {
            return .failed(error.localizedDescription)
        }
        guard let remoteRevision else { return .disposed(.alreadyAbsent) }

        guard review.headRevision == finalCommit, remoteRevision == finalCommit else {
            return .ownershipLost(L10n.string(
                "The generated review branch changed remotely, so Threading left it in place."
            ))
        }

        do {
            let root = URL(fileURLWithPath: workspace.repositoryRoot, isDirectory: true)
            try await ChangeRequestGit.deleteRemoteBranch(
                branch,
                ifRevisionIs: finalCommit,
                remote: receipt.remote,
                in: root
            )
            let remaining = try await ChangeRequestGit.remoteRevision(
                of: branch,
                remote: receipt.remote,
                in: root
            )
            guard remaining == nil else {
                return .failed(L10n.string(
                    "The generated review branch still exists after Git accepted its removal."
                ))
            }
            return .disposed(.deleted)
        } catch {
            return .failed(error.localizedDescription)
        }
    }
}

/// Reconciles reviews after the session that created them is already archived.
///
/// Launch and activation catch work completed while Threading was away; the tolerant heartbeat
/// catches a merge performed elsewhere while Threading remains in front. A second request during
/// a pass is coalesced into one follow-up, and every result is revalidated against the live store
/// before it is persisted.
@MainActor
final class ManagedWorkspaceRemoteCleanupCoordinator {
    static let shared = ManagedWorkspaceRemoteCleanupCoordinator()

    private struct Candidate: Sendable {
        let sessionID: SessionID
        let workspace: ManagedWorkspace
    }

    private struct Result: Sendable {
        let candidate: Candidate
        let outcome: ManagedWorkspaceRemoteCleanupOutcome
    }

    private let store: ProjectStore
    private let center: NotificationCenter
    private let cleaner: ManagedWorkspaceRemoteCleaner
    private var observations: AppEventObservations?
    private var timer: Timer?
    private var isReconciling = false
    private var owesAnotherPass = false
    private var hasStarted = false
    private var reportedFailures: [SessionID: String] = [:]

    init(
        store: ProjectStore = .shared,
        center: NotificationCenter = .default,
        cleaner: ManagedWorkspaceRemoteCleaner? = nil
    ) {
        self.store = store
        self.center = center
        self.cleaner = cleaner ?? .live()
    }

    func start() {
        guard !hasStarted, !RecoveryMode.isActive else { return }
        hasStarted = true

        let observations = AppEventObservations(center: center)
        observations.observe(NSApplication.didBecomeActiveNotification) { [weak self] in
            self?.reconcile()
        }
        self.observations = observations
        reconcile()
    }

    func reconcile() {
        guard hasStarted else { return }
        rearm()
        guard !isReconciling else {
            owesAnotherPass = true
            return
        }

        let candidates = store.projects.flatMap { project in
            project.sessions.compactMap { session -> Candidate? in
                guard let workspace = session.managedWorkspace,
                      workspace.changeRequest != nil,
                      workspace.finalCommit != nil,
                      workspace.state == .published || workspace.state == .kept,
                      workspace.remoteBranchState?.needsReconciliation ?? true else { return nil }
                return Candidate(sessionID: session.id, workspace: workspace)
            }
        }
        guard !candidates.isEmpty else { return }

        isReconciling = true
        let cleaner = self.cleaner
        Task { [weak self] in
            var results: [Result] = []
            results.reserveCapacity(candidates.count)
            for candidate in candidates {
                results.append(Result(
                    candidate: candidate,
                    outcome: await cleaner.reconcile(
                        sessionID: candidate.sessionID,
                        workspace: candidate.workspace
                    )
                ))
            }
            self?.apply(results)
        }
    }

    private func apply(_ results: [Result]) {
        for result in results {
            guard let current = store.session(withID: result.candidate.sessionID)?.managedWorkspace,
                  current.remoteBranch == result.candidate.workspace.remoteBranch,
                  current.finalCommit == result.candidate.workspace.finalCommit,
                  current.changeRequest == result.candidate.workspace.changeRequest,
                  current.remoteBranchState?.needsReconciliation ?? true else { continue }

            switch result.outcome {
            case .waiting:
                reportedFailures.removeValue(forKey: result.candidate.sessionID)

            case .disposed(let state):
                store.update(sessionID: result.candidate.sessionID) {
                    $0.managedWorkspace?.remoteBranchState = state
                    $0.managedWorkspace?.lastError = nil
                }
                reportedFailures.removeValue(forKey: result.candidate.sessionID)
                EventLog.shared.record(.session, "Managed review branch disposed", [
                    "session": result.candidate.sessionID.uuidString,
                    "result": state.rawValue
                ])

            case .ownershipLost(let message):
                store.update(sessionID: result.candidate.sessionID) {
                    $0.managedWorkspace?.remoteBranchState = .ownershipLost
                    $0.managedWorkspace?.lastError = message
                }
                reportedFailures.removeValue(forKey: result.candidate.sessionID)
                EventLog.shared.record(.session, "Managed review branch preserved", [
                    "session": result.candidate.sessionID.uuidString,
                    "reason": message
                ])

            case .failed(let message):
                reportFailureOnce(message, sessionID: result.candidate.sessionID)
            }
        }

        isReconciling = false
        if owesAnotherPass {
            owesAnotherPass = false
            reconcile()
        }
    }

    private func reportFailureOnce(_ message: String, sessionID: SessionID) {
        guard reportedFailures[sessionID] != message else { return }
        reportedFailures[sessionID] = message
        EventLog.shared.record(.session, "Managed review branch cleanup deferred", [
            "session": sessionID.uuidString,
            "reason": message
        ])
    }

    private func rearm() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(
            withTimeInterval: ManagedWorkspaceRemoteCleanupDefaults.heartbeat,
            repeats: false
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.reconcile() }
        }
        timer?.tolerance = ManagedWorkspaceRemoteCleanupDefaults.heartbeat
            * ManagedWorkspaceRemoteCleanupDefaults.toleranceFraction
    }
}

enum ManagedWorkspaceRemoteCleanupDefaults {
    static let heartbeat: TimeInterval = 10 * 60
    static let toleranceFraction = 0.1
}
