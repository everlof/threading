import Foundation

/// The validated launch choices the remote server hands to the application layer.
///
/// This value deliberately stops at application concepts. The remote transport owns wire
/// decoding and validation; the application decides how a session is created and surfaced.
struct RemoteSessionLaunch {
    let projectID: ProjectID
    let kind: AgentKind
    let accountHandle: AccountHandle
    let model: String?
    let reasoningEffort: String?
    let fastMode: Bool?
    let permissionMode: AgentPermissionMode?
    let usesNativeUI: Bool
    /// An isolated worktree to run in, already validated against the project and the runtime.
    /// Nil is the project's own checkout, which is where every remotely started session ran
    /// before a phone could ask for anything else.
    let managedWorkspacePlan: ManagedWorkspacePlan?
    /// A manager is the same session with its project's control grant conferred once it exists
    /// — what the Mac's own New Manager template does. Validated by the server, conferred by the
    /// coordinator, so the authority never leaves the Mac.
    let role: SessionRole
    /// Server-owned temporary files that must enter session attachment custody before launch.
    /// The application either takes every path and names its own copies in the prompt, or starts
    /// no session at all.
    let openingAttachmentPaths: [String]
    let prompt: String
}

enum RemoteSessionAccountMoveFailure: Error {
    case appUnavailable
    case sessionNotFound
    case accountNotFound
    case unsupportedRuntime
    case moveRefused(SessionMigration.MoveError.Code)
}

/// Why a cross-provider continuation could not be created.
///
/// `continuationRefused` carries the transaction's own bounded code, not its sentence: the
/// refusal's prose is written for a Mac alert, and a phone words the same cause for itself. A
/// nil code is a capture failure, which has no cause to name beyond the read error.
enum RemoteSessionContinuationFailure: Error {
    case appUnavailable
    case sessionNotFound
    case destinationNotFound
    case continuationRefused(ConversationContinuation.ContinuationError.Code?)
}

/// A validated continuation destination: a runtime, and the login to run it under when that
/// runtime routes logins at all.
struct RemoteContinuationTarget {
    let kind: AgentKind
    /// Nil means the runtime's single login, which is what a runtime without account routing has.
    let accountHandle: AccountHandle?
}

/// The application operations the remote transport is allowed to request.
///
/// `RemoteAccessServer` is Core transport code: it must not know which window or controller
/// currently presents a session. The composition root supplies this capability, and tests can
/// route the real HTTP server without constructing AppDelegate or AppKit windows.
@MainActor
protocol RemoteSessionCommands: AnyObject {
    /// Returns false when the application cannot currently surface the existing session.
    func resumeRemoteSession(_ sessionID: SessionID) -> Bool

    /// Clears a stored launch failure and reopens the session, which is exactly what the Mac's
    /// launch-failure surface does when somebody presses **Try Again**.
    ///
    /// Separate from `resumeRemoteSession` because the difference is the whole point: an
    /// ordinary resume must not clear a record nobody has read, and a retry must not be refused
    /// by the gate that record installs. Returns false when the application cannot surface it.
    func retryRemoteSessionLaunch(_ sessionID: SessionID) -> Bool

    /// Returns false when the application cannot surface this standalone shell.
    func resumeRemoteTerminal(_ terminalID: TerminalID) -> Bool

    /// Stops, migrates and reopens a conversation under another login. The phone owns the
    /// confirmation; this application command owns the transcript transaction and live pane.
    func moveRemoteSession(
        _ sessionID: SessionID,
        to accountHandle: AccountHandle
    ) -> Result<Void, RemoteSessionAccountMoveFailure>

    /// Freezes this conversation and creates a new one on another provider, leaving the source
    /// session and its transcript intact. Asynchronous because capturing the snapshot reads the
    /// source transcript; the phone owns the confirmation, this owns the transaction.
    func continueRemoteSession(
        _ sessionID: SessionID,
        with destination: RemoteContinuationTarget,
        completion: @escaping @MainActor @Sendable (
            Result<SessionID, RemoteSessionContinuationFailure>
        ) -> Void
    )

    /// Returns the durable identity only after the application has accepted the launch.
    func startRemoteSession(_ launch: RemoteSessionLaunch) -> SessionID?

    /// Reconciles navigation after session metadata or archived state changes.
    func refreshAfterRemoteSessionMutation(sessionID: SessionID, archived: Bool)

    /// Replaces a standing terminal/conversation surface after its durable choice changes.
    func refreshAfterRemoteSurfaceMutation(sessionID: SessionID)
}
