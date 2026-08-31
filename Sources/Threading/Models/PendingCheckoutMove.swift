import Foundation

/// Why the calling chat is asking Threading to change its checkout ownership.
///
/// The value is durable and deliberately closed: policy and audit must not infer authority from
/// free-form prose after the request has crossed a turn boundary.
enum SessionCheckoutAuthorityBasis: String, Codable, Sendable, CaseIterable {
    case explicitUserRequest = "explicit_user_request"
    case agentInitiated = "agent_initiated"

    /// Nobody asked: Threading observed the agent working in another checkout of the same
    /// repository and is reconciling ownership with where the work is actually happening.
    ///
    /// A third case rather than a reuse of `agentInitiated`, because the provenance genuinely
    /// differs and the audit trail must not blur them. An agent-initiated move is a decision
    /// some model made and can be asked to justify; this one is an inference *Threading* made
    /// from a lifecycle report, and it is the only basis that can be granted without a human or
    /// a model having requested anything at all.
    case observedExecution = "observed_execution"
}

/// A validated checkout move held until the current turn has fully settled.
///
/// Both identities are stored with the canonical root. Revalidating them at commit detects a
/// removed or replaced worktree without falling back to its branch name.
struct PendingCheckoutMove: Codable, Equatable, Sendable {
    let checkoutPath: String
    let repositoryIdentity: String
    let worktreeIdentity: String
    let authorityBasis: SessionCheckoutAuthorityBasis
    let reason: String
    let requestedAt: Date
}

/// How much checkout-moving authority a chat receives without another host confirmation.
enum SessionCheckoutAuthorityPolicy: String, Codable, Sendable, CaseIterable {
    case alwaysAsk
    case allowExplicitRequests
    case allowSameRepository
}
