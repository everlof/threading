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
    /// from observed runtime or descendant-process cwd, and it is the only basis that can be
    /// granted without a human or a model having requested anything at all.
    case observedExecution = "observed_execution"
}

/// A validated checkout move held until the current turn has fully settled.
///
/// Both identities are stored with the canonical root. Revalidating them at commit detects a
/// removed or replaced worktree without falling back to its branch name.
struct PendingCheckoutMove: Codable, Equatable, Sendable {
    enum Phase: String, Codable, Sendable {
        case pendingBoundary = "pending_boundary"
        case settling
        case failed
    }

    let requestID: UUID
    let checkoutPath: String
    let repositoryIdentity: String
    let worktreeIdentity: String
    let authorityBasis: SessionCheckoutAuthorityBasis
    let reason: String
    let requestedAt: Date
    let phase: Phase
    let failureDescription: String?

    init(
        requestID: UUID = UUID(),
        checkoutPath: String,
        repositoryIdentity: String,
        worktreeIdentity: String,
        authorityBasis: SessionCheckoutAuthorityBasis,
        reason: String,
        requestedAt: Date,
        phase: Phase = .pendingBoundary,
        failureDescription: String? = nil
    ) {
        self.requestID = requestID
        self.checkoutPath = checkoutPath
        self.repositoryIdentity = repositoryIdentity
        self.worktreeIdentity = worktreeIdentity
        self.authorityBasis = authorityBasis
        self.reason = reason
        self.requestedAt = requestedAt
        self.phase = phase
        self.failureDescription = failureDescription
    }

    private enum CodingKeys: String, CodingKey {
        case requestID
        case checkoutPath
        case repositoryIdentity
        case worktreeIdentity
        case authorityBasis
        case reason
        case requestedAt
        case phase
        case failureDescription
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        requestID = try values.decodeIfPresent(UUID.self, forKey: .requestID) ?? UUID()
        checkoutPath = try values.decode(String.self, forKey: .checkoutPath)
        repositoryIdentity = try values.decode(String.self, forKey: .repositoryIdentity)
        worktreeIdentity = try values.decode(String.self, forKey: .worktreeIdentity)
        authorityBasis = try values.decode(SessionCheckoutAuthorityBasis.self, forKey: .authorityBasis)
        reason = try values.decode(String.self, forKey: .reason)
        requestedAt = try values.decode(Date.self, forKey: .requestedAt)
        phase = try values.decodeIfPresent(Phase.self, forKey: .phase) ?? .pendingBoundary
        failureDescription = try values.decodeIfPresent(String.self, forKey: .failureDescription)
    }

    func updating(phase: Phase, failureDescription: String? = nil) -> Self {
        Self(
            requestID: requestID,
            checkoutPath: checkoutPath,
            repositoryIdentity: repositoryIdentity,
            worktreeIdentity: worktreeIdentity,
            authorityBasis: authorityBasis,
            reason: reason,
            requestedAt: requestedAt,
            phase: phase,
            failureDescription: failureDescription
        )
    }
}

/// How much checkout-moving authority a chat receives without another host confirmation.
enum SessionCheckoutAuthorityPolicy: String, Codable, Sendable, CaseIterable {
    case alwaysAsk
    case allowExplicitRequests
    case allowSameRepository
}
