import Foundation

/// Catalogue admission stays with the host. Transports only encode an admitted binding.
@MainActor
enum ConversationMCPAdmission {
#if os(Linux)
    static var hasTools: (SessionID) -> Bool = { _ in false }
#else
    static func hasTools(for session: SessionID) -> Bool { !MCPToolCatalog.toolNames(for: session).isEmpty }
#endif
    static func allows(_ session: SessionID) -> Bool {
#if os(Linux)
        hasTools(session)
#else
        hasTools(for: session)
#endif
    }
}
