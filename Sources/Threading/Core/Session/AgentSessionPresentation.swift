import Foundation

extension AgentSession {
  /// The name shown in the sidebar.
  ///
  /// An explicit rename wins, then the agent's own title when that behaviour is enabled,
  /// then the first-prompt name — and a generic label when nothing has named the session
  /// yet. Never the agent or account, which the row's icon slot already identifies.
  @MainActor
  var displayTitle: String {
    AgentSessionRowPresentation(
      session: self,
      usesAgentTitle: AppSettings.usesAgentTitleInSidebar,
      untitledTitle: AgentDefaults.untitledSessionName
    ).title
  }

  /// `displayTitle` as a person sees it on screen: a session nothing has named yet wears the
  /// theme's own stand-in (`ThemeWords.untitledSession`) instead of "New Session".
  ///
  /// Presentation only. Anything that treats the name as a fact — a migrated session's stored
  /// title, notifications, search, control-plane output — keeps reading `displayTitle`, so a
  /// theme's word is never written down as a title nor survives a theme switch.
  @MainActor
  var presentedTitle: String {
    AgentSessionRowPresentation(
      session: self,
      usesAgentTitle: AppSettings.usesAgentTitleInSidebar,
      untitledTitle: AgentSession.presentedUntitledTitle
    ).title
  }

  /// True while nothing — the person, the agent or a first prompt — has named the session, so
  /// `presentedTitle` is the untitled stand-in.
  @MainActor
  var isUnnamed: Bool {
    AgentSessionRowPresentation(
      session: self,
      usesAgentTitle: AppSettings.usesAgentTitleInSidebar,
      untitledTitle: ""
    ).title.isEmpty
  }

  /// The stand-in an unnamed session wears on screen under the theme in force.
  @MainActor
  static var presentedUntitledTitle: String {
    ThemeWording.untitledSessionName ?? AgentDefaults.untitledSessionName
  }
}
