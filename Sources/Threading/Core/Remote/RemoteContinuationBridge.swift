import Foundation
import ThreadingRemoteKit

/// The wire form of "where could this conversation continue", and the reverse lookup that turns
/// a phone's answer back into an account the Mac discovered.
///
/// Eligibility is never recomputed on the phone. `ConversationContinuation` already answers it
/// from facts only the Mac holds — the source transcript on disk, the logins under the user's
/// home, whether the scoped history tool is enabled — and a second implementation across the
/// wire would be a copy that drifts. The phone receives a list and sends back one row's ids.
///
/// This is deliberately not on the session-summary projection. `canContinue` resolves a
/// transcript on disk, and a `me` response carries every visible session, so paying it per row
/// per snapshot would put a filesystem probe on the mirror's hot path. It is asked once, when
/// somebody opens the screen that offers the choice — the same moment the Mac's own menu pays it.
@MainActor
enum RemoteContinuationBridge {

    // MARK: - Public Methods

    static func options(
        for session: AgentSession,
        in project: Project
    ) -> RemoteSessionContinuationOptionsDTO {
        guard ConversationContinuation.canContinue(session, in: project) else {
            return RemoteSessionContinuationOptionsDTO(destinations: [])
        }
        return RemoteSessionContinuationOptionsDTO(
            destinations: ConversationContinuation.destinations(for: session).map(destination(for:))
        )
    }

    /// The wire form of one destination account.
    ///
    /// A runtime that routes no logins sends no account identity at all, rather than the
    /// synthetic standard handle `ConversationContinuation` builds it from: the phone would
    /// otherwise draw a login name for a CLI that has none.
    static func destination(for account: AgentAccount) -> RemoteContinuationDestinationDTO {
        guard account.provider.supportsAccounts else {
            return RemoteContinuationDestinationDTO(
                agentID: account.provider.rawValue,
                agentName: account.provider.displayName
            )
        }
        return RemoteContinuationDestinationDTO(
            agentID: account.provider.rawValue,
            agentName: account.provider.displayName,
            accountID: account.handle.name,
            accountName: AccountName.display(for: account),
            emoji: account.emoji
        )
    }

    /// Resolves what the phone chose against the destinations that were actually offered.
    ///
    /// Going back through `destinations(for:)` rather than trusting the request is the point: a
    /// client cannot name a login the Mac never listed, and it cannot name the source's own
    /// provider, because neither is in that list.
    static func account(
        for target: RemoteContinuationTarget,
        continuing session: AgentSession
    ) -> AgentAccount? {
        ConversationContinuation.destinations(for: session).first { account in
            guard account.provider == target.kind else { return false }
            guard account.provider.supportsAccounts else { return target.accountHandle == nil }
            // A runtime that routes logins accepts an unnamed one as its standard login, which
            // is what a client sends for a runtime it believes has none.
            return account.handle == (target.accountHandle ?? .standard)
        }
    }
}
