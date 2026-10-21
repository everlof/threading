import Foundation

/// Where a chat came from, when another chat started it to do part of that chat's work.
///
/// Birth, not responsibility. `Supervision` says who answers for a chat now, and that can end;
/// this never changes after creation, so the sidebar keeps a subagent under its parent whatever
/// has happened to the tenure since.
///
/// Provider-neutral and kept outside the runtime configuration, because a parent and its
/// subagent may run different runtimes. A fork (`AgentSession.forkedFrom`) is the other kind of
/// lineage and still lives in Claude's own configuration, because only Claude forks; the forks
/// draft moves it here as a second case.
enum SessionLineage: Codable, Equatable, Sendable {
  case subagent(of: SessionID)

  var parentID: SessionID {
    switch self {
    case .subagent(let parent): parent
    }
  }
}
