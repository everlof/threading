import Foundation

extension ConversationTimeline {
    /// The app resolves chart calls through its admitted MCP registry. Portable hosts supply
    /// their own projection without importing the application command/permission machinery.
    init(sessionID: SessionID) {
        self.init(sessionID: sessionID, chartDecoder: ChartSpec.decoded(fromToolNamed:input:))
    }
}
