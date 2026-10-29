import Foundation

/// The one aggregate the composer's activity beam draws: how many sessions are
/// working right now, and whether any of them runs at the top of its
/// provider's reasoning ladder.
///
/// "Working" is `SessionActivity.working` alone. A session waiting on the user
/// (`awaitingUser`, `needsAttention`) is not work in progress — counting it
/// would hold the beam lit for exactly the sessions where the user is the
/// reason nothing is happening.
struct AgentWorkload: Equatable, Sendable {
    var workingCount: Int
    var anyAtTopEffort: Bool

    static let none = AgentWorkload(workingCount: 0, anyAtTopEffort: false)
}
