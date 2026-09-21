import Foundation

extension AgentSession {
  /// The name shown in the sidebar.
  ///
  /// An explicit rename wins, then the agent's own title when that behaviour is enabled,
  /// then the first-prompt name — and a generic label when nothing has named the session
  /// yet. Never the agent or account, which the row's icon slot already identifies.
  @MainActor
  var displayTitle: String {
    if let customTitle, !customTitle.isEmpty {
      return customTitle
    }

    if AppSettings.usesAgentTitleInSidebar,
      let agentTitle, !agentTitle.isEmpty
    {
      return agentTitle
    }

    return title.isEmpty ? AgentDefaults.untitledSessionName : title
  }
}
