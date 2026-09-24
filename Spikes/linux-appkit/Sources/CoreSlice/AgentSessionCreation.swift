import Foundation

/// Creates a fresh record after the host has admitted the project, identity and resolved model.
/// No account discovery, git lookup, persistence or presentation belongs in this operation.
/// Import and fork operations retain their distinct provenance and resume contracts.
enum AgentSessionCreation {
    static func makeRecord(
        kind: AgentKind,
        accountHandle: AccountHandle = .standard,
        model: String? = nil,
        reasoningEffort: String? = nil,
        fastMode: Bool? = nil,
        usesNativeUI: Bool = false,
        permissionMode: AgentPermissionMode? = nil,
        title: String? = nil,
        handoff: ConversationHandoff? = nil,
        managedWorkspace: ManagedWorkspace? = nil,
        id: SessionID = SessionID()
    ) -> AgentSession? {
        guard let configuration = AgentSessionConfiguration(
            kind: kind,
            reasoningEffort: reasoningEffort,
            accountHandle: accountHandle,
            permissionMode: permissionMode
        ), handoff == nil || handoff?.isValid(destinationID: id, destinationKind: kind) == true
        else { return nil }

        // Unnamed stays unnamed. Provider/account identity belongs to presentation, and the
        // first prompt can later supply a title without overwriting a fabricated provider name.
        var session = AgentSession(
            configuration: configuration,
            title: title ?? "",
            accountHandle: accountHandle,
            model: model,
            usesNativeUI: usesNativeUI,
            handoff: handoff,
            id: id
        )
        session.managedWorkspace = managedWorkspace
        session.fastMode = fastMode
        session.branch = managedWorkspace?.targetBranch
        session.permissionMode = permissionMode
        return session
    }
}
