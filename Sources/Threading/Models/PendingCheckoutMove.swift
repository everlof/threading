import Foundation

/// Why the calling chat is asking Threading to change its checkout ownership.
///
/// The value is durable and deliberately closed: policy and audit must not infer authority from
/// free-form prose after the request has crossed a turn boundary.
enum SessionCheckoutAuthorityBasis: String, Codable, Sendable, CaseIterable {
    case explicitUserRequest = "explicit_user_request"
    case agentInitiated = "agent_initiated"
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
