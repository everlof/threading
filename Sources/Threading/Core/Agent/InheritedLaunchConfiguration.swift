import Foundation

// MARK: - What A Chat Nobody Configured Comes Up As

/// The launch choices a chat inherits when it is created for somebody rather than by them: the
/// configuration of the chat most recently used in the same project.
///
/// Two routes open a conversation nobody is standing in front of a composer for — the
/// development build's report chat, and a report sent to the Mac from a paired phone — and both
/// face the same question: what should it come up as? The answer is deliberately **not** the app
/// defaults. The person filing the report is the person who was working in that project a moment
/// ago, and a chat that arrives on a different agent, login, model or permission mode than the
/// one they have used all day is a chat they have to reconfigure before it can do anything.
///
/// The rule was written once for the Mac's own report chat and then contradicted by the phone,
/// which picked Codex and the standard login out of two string literals. One rule, both routes:
/// that disagreement is exactly what this type exists to prevent.
///
/// Three details are load-bearing:
///
/// - **`lastUsedAt`, not `lastActiveAt`.** The first is when somebody last used the chat; the
///   second is when the runtime last touched it, which a background relaunch does to every
///   session at once. Inheriting from the wrong one copies whichever chat the app happened to
///   restore last.
/// - **Archived rows are skipped.** Those are the ones deliberately put away.
/// - **The two clamps are `AgentSessionConfiguration`'s own rules**, applied here rather than
///   discovered as a nil session two steps later: an account handle only means something for a
///   runtime with logins, and a permission mode only for one with modes.
///
/// Deliberately says nothing about a branch or a managed workspace. Where the chat runs is a
/// decision about the task, not about the last conversation, so each route makes it itself:
/// `DeveloperReportChat` refuses both, because a UI report is read against the tree the build
/// came from.
struct InheritedLaunchConfiguration: Equatable, Sendable {
    let kind: AgentKind
    let accountHandle: AccountHandle
    let model: String?
    let reasoningEffort: String?
    let fastMode: Bool?
    let usesNativeUI: Bool
    let permissionMode: AgentPermissionMode?

    /// Resolves the configuration from one project's sessions.
    ///
    /// A project with no chat yet inherits nothing, so it falls back to the user's default agent
    /// on that runtime's own surface — the same starting point a fresh composer would offer.
    static func resolve(
        sessions: [AgentSession],
        defaultKind: AgentKind
    ) -> InheritedLaunchConfiguration {
        let latest = sessions
            .filter { !$0.isArchived }
            .max { $0.lastUsedAt < $1.lastUsedAt }
        let kind = latest?.kind ?? defaultKind

        return InheritedLaunchConfiguration(
            kind: kind,
            accountHandle: kind.supportsAccounts ? (latest?.accountHandle ?? .standard) : .standard,
            model: latest?.model,
            reasoningEffort: latest?.reasoningEffort,
            fastMode: latest?.fastMode,
            usesNativeUI: latest?.usesNativeUI ?? kind.supportsNativeUI,
            permissionMode: kind.supportsPermissionModes ? latest?.permissionMode : nil
        )
    }
}
