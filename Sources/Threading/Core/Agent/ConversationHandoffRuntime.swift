import Foundation

// Live model/account lookup belongs to the handoff operation, not the persisted record's
// compilation boundary. The Codable values and path validation remain in Models/AgentSession.
extension ConversationHandoff {
  /// Carries an existing path into a new destination, refreshing the source's own endpoint with
  /// its current title/model snapshot first. This is what turns direct lineage into a real path
  /// across repeated handoffs.
  @MainActor
  static func continuing(
    source: AgentSession,
    targetID: SessionID,
    targetKind: AgentKind,
    targetModel: String?,
    targetTitle: String
  ) -> ConversationHandoff? {
    guard source.kind != targetKind, source.id != targetID else { return nil }

    var endpoints = source.handoff?.endpoints ?? []
    let sourceEndpoint = ConversationHandoffEndpoint(
      sessionID: source.id,
      kind: source.kind,
      model: source.handoffModelSnapshot,
      title: source.displayTitle
    )
    if endpoints.isEmpty {
      endpoints.append(sourceEndpoint)
    } else {
      endpoints[endpoints.count - 1] = sourceEndpoint
    }
    endpoints.append(ConversationHandoffEndpoint(
      sessionID: targetID,
      kind: targetKind,
      model: targetModel,
      title: targetTitle,
      modelIsProvisional: true
    ))

    return ConversationHandoff(
      endpoints: endpoints,
      omittedEndpointCount: source.handoff?.omittedEndpointCount ?? 0
    )
  }
}

extension AgentSession {
  /// Best durable model label available before a handoff is made. A model the session pinned
  /// wins, then the account's configured default, then the runtime's last report for that
  /// account. Nil is preserved as an honest provider-name fallback for Grok/OpenCode and an
  /// account whose CLI states no default.
  @MainActor
  var handoffModelSnapshot: String? {
    if let model, !model.isEmpty { return model }
    let account = AgentAccountDiscovery.account(for: kind, handle: accountHandle)
    return AgentModels.defaultModel(for: kind, account: account)
      ?? account.flatMap { AccountPreferencesStore.shared.lastReportedModel(for: $0.id) }
  }
}
