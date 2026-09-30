import Foundation

/// A session's semantic row content. Hosts supply preferences and fallback wording; renderers
/// retain provider/account decoration, truncation, styling and accessibility geometry.
struct AgentSessionRowPresentation: Equatable, Sendable {
    let id: SessionID
    let kind: AgentKind
    let accountHandle: AccountHandle
    let title: String

    init(session: AgentSession, usesAgentTitle: Bool, untitledTitle: String) {
        id = session.id
        kind = session.kind
        accountHandle = session.accountHandle
        if let customTitle = session.customTitle, !customTitle.isEmpty {
            title = customTitle
        } else if usesAgentTitle, let agentTitle = session.agentTitle, !agentTitle.isEmpty {
            title = agentTitle
        } else {
            title = session.title.isEmpty ? untitledTitle : session.title
        }
    }

    /// A newly admitted, unnamed session before a host has refreshed its stored row. This is
    /// presentation only: constructing it does not create a record or choose a launch timestamp.
    static func unnamed(id: SessionID, kind: AgentKind, accountHandle: AccountHandle,
                        untitledTitle: String) -> Self {
        Self(id: id, kind: kind, accountHandle: accountHandle, title: untitledTitle)
    }

    private init(id: SessionID, kind: AgentKind, accountHandle: AccountHandle, title: String) {
        self.id = id
        self.kind = kind
        self.accountHandle = accountHandle
        self.title = title
    }
}
