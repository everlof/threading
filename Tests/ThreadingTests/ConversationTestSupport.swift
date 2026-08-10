import XCTest
@testable import Threading

/// Test fixtures may ask only for a runtime that owns the native-conversation boundary. Keep the
/// unwrap in one loud helper so individual render/layout tests do not weaken the production
/// failable initializer with force unwraps.
@MainActor
func requireConversationViewController(
    agentSession: AgentSession,
    project: Project,
    subagentState: SubagentSessionState? = nil,
    customizationLookup: @escaping ComponentCustomizationHost.Lookup = {
        ComponentCustomizationProviderSlot.shared.customization(for: $0)
    },
    file: StaticString = #filePath,
    line: UInt = #line
) -> ConversationViewController {
    guard let controller = ConversationViewController(
        agentSession: agentSession,
        project: project,
        subagentState: subagentState,
        customizationLookup: customizationLookup
    ) else {
        XCTFail(
            "\(agentSession.kind.rawValue) does not own a native conversation surface",
            file: file,
            line: line
        )
        fatalError("Invalid native-conversation test fixture")
    }
    return controller
}
