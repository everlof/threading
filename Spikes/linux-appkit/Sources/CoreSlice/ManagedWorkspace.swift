import Foundation

// MARK: - Managed Workspace

/// What Threading should do with an isolated worktree when its agent says the task is done.
///
/// A remote review is deliberately not one of these cases. Publishing a branch and opening a
/// PR/MR is a separate optional decision on `ManagedWorkspacePlan`; keeping it out of the
/// default is what makes enabling isolation mean only local, reversible repository work.
enum ManagedWorkspaceDelivery: String, Codable, Sendable, Equatable, Hashable, CaseIterable {
  case mergeAndCleanUp
  case keepForReview
}

/// The remote review Threading may publish after the agent's completion handshake.
///
/// This is intentionally narrower than the repository-wide Git Review policy: a managed
/// session cannot open an editor after an unattended final turn, and "push only" would leave
/// remote state without the review object the opt-in promised.
enum ManagedWorkspacePublication: String, Codable, Sendable, Equatable, CaseIterable {
  case draft
  case ready
}

/// The small, frozen choice made in the composer. Nil on a draft/session means the feature is
/// off, so records written before managed workspaces decode with precisely their old behaviour.
struct ManagedWorkspacePlan: Codable, Sendable, Equatable {
  var delivery: ManagedWorkspaceDelivery
  var publication: ManagedWorkspacePublication?

  init(
    delivery: ManagedWorkspaceDelivery = .mergeAndCleanUp,
    publication: ManagedWorkspacePublication? = nil
  ) {
    self.delivery = delivery
    self.publication = publication
  }
}

enum ManagedWorkspaceState: String, Codable, Sendable, Equatable {
  case active
  case kept
  case integrated
  case published
  case needsAttention
}

/// Durable evidence that the generated remote branch has a review object of its own.
///
/// The provider stays data rather than a type so another forge can use the same session record.
/// The branch is app-generated and opaque; it is persisted because a retry must find the same
/// change request instead of creating another one.
struct ManagedWorkspaceChangeRequest: Codable, Sendable, Equatable {
  let provider: String
  let repository: String
  let remote: String
  let branch: String
  let number: Int
  let url: URL
  let isDraft: Bool
}

/// What happened to the generated remote-only branch after its review finished.
///
/// Nil is the migration spelling of `awaitingReviewCompletion`: records published before the
/// reconciler existed still need cleanup. `ownershipLost` is terminal and deliberately leaves
/// the ref alone, because somebody moved it away from the exact commit Threading published.
enum ManagedWorkspaceRemoteBranchState: String, Codable, Sendable, Equatable {
  case awaitingReviewCompletion
  case deleted
  case alreadyAbsent
  case ownershipLost

  var needsReconciliation: Bool { self == .awaitingReviewCompletion }
}

/// Threading's durable ownership record for one generated, detached worktree.
///
/// The session still belongs to its logical Project; only its execution directory changes.
/// Keeping both paths is what lets the sidebar remain stable while cleanup can target exactly
/// the one directory Threading created.
struct ManagedWorkspace: Codable, Sendable, Equatable {
  let repositoryRoot: String
  let sourceCheckoutPath: String
  let worktreeRoot: String
  let executionPath: String
  let targetBranch: String
  var baseCommit: String
  let delivery: ManagedWorkspaceDelivery
  let publication: ManagedWorkspacePublication?
  let remoteBranch: String?
  var finalCommit: String?
  var changeRequest: ManagedWorkspaceChangeRequest?
  var remoteBranchState: ManagedWorkspaceRemoteBranchState?
  var state: ManagedWorkspaceState
  var lastError: String?
}
