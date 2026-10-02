import Foundation
import ThreadingRemoteKit

/// The send-time half of a project's default logins, for a chat a paired phone starts.
///
/// The phone predicted its login from the catalogue and the live capacity feed; this Mac holds
/// the newer reading and the owner's own lines, so it has the final word. It moves a send only
/// onto proven evidence, only within the runtime the phone chose, and says so in the response.
@MainActor
enum RemoteProjectDefaultLaunch {

    // MARK: - Types

    /// The launch a substituted send makes instead, and the receipt the phone words itself.
    struct Result: Equatable {
        let accountHandle: AccountHandle
        let model: String?
        let reasoningEffort: String?
        let fastMode: Bool?
        let dto: RemoteAccountSubstitutionDTO
    }

    // MARK: - Public Methods

    /// The launch to make instead of the one requested, or nil to make the one requested.
    ///
    /// `offered` is the runtime's enabled logins, the same list the request was validated
    /// against, so a substitute is always a login the phone could have picked itself.
    static func substitute(
        projectID: ProjectID,
        kind: AgentKind,
        requested: AccountHandle,
        model: String?,
        reasoningEffort: String?,
        fastMode: Bool?,
        offered: [AgentAccount],
        at now: Date = Date()
    ) -> Result? {
        let requestedAccount = offered.first { $0.handle == requested }
        guard let found = ProjectDefaultAccounts.substitution(
            projectID: projectID,
            current: AccountID(provider: kind, handle: requested),
            model: model ?? ProjectDefaultAccounts.defaultModel(for: requestedAccount),
            at: now
        ), let replacement = offered.first(where: { $0.id == found.to }) else { return nil }

        let carried = ProjectDefaultAccounts.carriedRunChoice(
            model: model,
            reasoningEffort: reasoningEffort,
            fastMode: fastMode,
            to: replacement
        )
        return Result(
            accountHandle: replacement.handle,
            model: carried.model,
            reasoningEffort: carried.reasoningEffort,
            fastMode: carried.fastMode,
            dto: RemoteAccountSubstitutionDTO(
                requestedAccountID: requested.name,
                accountID: replacement.handle.name,
                reason: found.wasOwnLimit ? .ownLimit : .spent,
                resetsAt: found.fromResetsAt?.timeIntervalSince1970
            )
        )
    }
}
