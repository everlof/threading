import Foundation

// MARK: - Scope

/// Which record answered for a session's limit recovery.
///
/// Named rather than inferred from "is the session's field nil", because both the menu's
/// checkmark and the row's mark need to tell *chose it* from *followed somebody who chose it* —
/// the same distinction `ThemeScope` draws, for the same surfaces.
enum LimitRecoveryScope: Equatable, Sendable {
    case session
    case project
    case app
}

// MARK: - Limit Recovery Resolution

/// Which policy governs one conversation, and who said so.
///
/// Three scopes, narrowest first: the chat, its checkout, the Settings choice. Absent means
/// **inherit, not copy** — the rule every scoped setting here follows (`ThemeResolution`,
/// `AttentionAlertScope`, `SoundResolution`) — so arming a checkout still reaches the chats
/// inside it that never answered, and changing Settings still reaches the checkouts that never
/// did either.
///
/// The chain is pure, and separately from the store on purpose: this is the rule that decides
/// whether the app types into somebody's session unattended, and it should be assertable with no
/// home directory, no database and no live agent. The `@MainActor` conveniences below are the
/// only part that knows where the records live.
enum LimitRecoveryResolution {

    /// A resolved policy and the scope that supplied it.
    struct Answer: Equatable, Sendable {
        let scope: LimitRecoveryScope
        let policy: LimitRecoveryPolicy
    }

    // MARK: - The Chain

    /// Resolves narrowest-first. The app scope always answers, so this cannot fail.
    static func resolve(
        session: LimitRecoveryPolicy?,
        project: LimitRecoveryPolicy?,
        app: LimitRecoveryPolicy
    ) -> Answer {
        if let session { return Answer(scope: .session, policy: session) }
        if let project { return Answer(scope: .project, policy: project) }
        return Answer(scope: .app, policy: app)
    }

    /// What a record *would* follow if it said nothing — the answer a menu names beside its
    /// Inherit state, and the value a writer compares against before storing anything.
    ///
    /// Expressed as resolution with that one level removed rather than as a second rule, so the
    /// label and the writer cannot drift apart; `SoundResolution.inherited(_:at:beyond:)` is the
    /// same construction for the same reason.
    static func inherited(
        beyond scope: LimitRecoveryScope,
        project: LimitRecoveryPolicy?,
        app: LimitRecoveryPolicy
    ) -> LimitRecoveryPolicy {
        switch scope {
        case .session:
            return resolve(session: nil, project: project, app: app).policy
        case .project, .app:
            return app
        }
    }

    // MARK: - Reading The Records

    // The store is a parameter rather than `ProjectStore.shared` reached for inside.
    //
    // A sidebar is built against whichever store it was handed — its tests build one of their
    // own — so a lookup that reaches past it answers about the wrong records, and merely
    // *touching* the singleton in a test loads the real database and posts its change
    // notifications into the controller under test. That is not a hypothetical: rows call this
    // on the mounting path, and it broke `SidebarTreeBuilderTests` wholesale.

    /// The policy governing one conversation.
    @MainActor
    static func policy(
        forSessionID sessionID: SessionID,
        in store: ProjectStore = .shared
    ) -> LimitRecoveryPolicy {
        answer(forSessionID: sessionID, in: store).policy
    }

    /// The same, with the scope that decided it.
    @MainActor
    static func answer(
        forSessionID sessionID: SessionID,
        in store: ProjectStore = .shared
    ) -> Answer {
        resolve(
            session: store.session(withID: sessionID)?.limitRecoveryPolicy,
            project: store.project(forSessionID: sessionID)?.limitRecoveryPolicy,
            app: LimitRecoverySettings.policy
        )
    }

    /// What this conversation would follow if it had no answer of its own.
    @MainActor
    static func inherited(
        beyondSessionID sessionID: SessionID,
        in store: ProjectStore = .shared
    ) -> LimitRecoveryPolicy {
        inherited(
            beyond: .session,
            project: store.project(forSessionID: sessionID)?.limitRecoveryPolicy,
            app: LimitRecoverySettings.policy
        )
    }

    /// The policy governing a checkout's chats that never answered for themselves.
    @MainActor
    static func answer(
        forProjectID projectID: ProjectID,
        in store: ProjectStore = .shared
    ) -> Answer {
        resolve(
            session: nil,
            project: store.project(withID: projectID)?.limitRecoveryPolicy,
            app: LimitRecoverySettings.policy
        )
    }

    /// What this checkout would follow if it had no answer of its own.
    @MainActor
    static func inherited(beyondProjectID projectID: ProjectID) -> LimitRecoveryPolicy {
        inherited(beyond: .project, project: nil, app: LimitRecoverySettings.policy)
    }
}
