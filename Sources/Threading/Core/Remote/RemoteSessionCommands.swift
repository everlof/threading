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
    let prompt: String
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

    /// Returns the durable identity only after the application has accepted the launch.
    func startRemoteSession(_ launch: RemoteSessionLaunch) -> SessionID?

    /// Reconciles navigation after session metadata or archived state changes.
    func refreshAfterRemoteSessionMutation(sessionID: SessionID, archived: Bool)

    /// Replaces a standing terminal/conversation surface after its durable choice changes.
    func refreshAfterRemoteSurfaceMutation(sessionID: SessionID)
}
