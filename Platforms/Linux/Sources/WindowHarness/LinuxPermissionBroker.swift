#if os(Linux)
import Foundation
@testable import CoreSlice

/// The Linux host's permission boundary, under the name the production card calls.
///
/// The shared `PermissionPolicy` answers first, with the same rules the Mac applies. Anything it
/// leaves open goes to the retained native session that raised it, whose pane shows the
/// production `PermissionRequestView` inline. A request with no live session is refused rather
/// than left holding the provider's turn. Linux serves no Threading MCP tools, so none is a
/// built-in allowlisted tool here.
@MainActor
enum PermissionBroker {
    typealias Completion = @MainActor @Sendable (PermissionDecision) -> Void

    private final class WeakSession {
        weak var session: NativeWorkspaceSession?
        init(_ session: NativeWorkspaceSession) { self.session = session }
    }

    private static var sessions: [SessionID: WeakSession] = [:]
    private static var alwaysAllowed: [SessionID: Set<ToolIdentity>] = [:]

    /// Routes every native transport's request through this boundary for the process lifetime.
    static func install() {
        ConversationPermissionDecision.decide = { request, completion in
            decide(request, completion: completion)
        }
    }

    static func register(_ session: NativeWorkspaceSession) {
        sessions[session.id] = WeakSession(session)
    }

    /// Forgets the session and its standing approvals, so a later incarnation asks again.
    static func unregister(_ sessionID: SessionID) {
        sessions[sessionID] = nil
        alwaysAllowed[sessionID] = nil
    }

    static func decide(_ request: PermissionRequest, completion: @escaping Completion) {
        guard let session = sessions[request.sessionID]?.session else {
            completion(.deny(reason: "Threading has no window available to ask for permission."))
            return
        }
        if let decision = automaticDecision(for: request, mode: session.permissionMode) {
            completion(decision)
            return
        }
        session.requestPermission(request, completion: completion)
    }

    /// Re-checked when a queued request reaches the front, because Allow for Session on an
    /// earlier request may already answer it.
    static func automaticDecision(for request: PermissionRequest,
                                  mode: AgentPermissionMode?) -> PermissionDecision? {
        PermissionPolicy.automaticDecision(for: request,
            allowedForSession: alwaysAllowed[request.sessionID] ?? [], mode: mode,
            builtInMCPTool: { _ in false })
    }

    static func allowAlways(toolName: String, for sessionID: SessionID) {
        alwaysAllowed[sessionID, default: []].insert(ToolIdentity(toolName))
    }
}
#endif
