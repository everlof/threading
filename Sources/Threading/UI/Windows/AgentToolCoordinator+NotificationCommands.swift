import AppKit
import ThreadingRemoteKit

@MainActor
extension AgentToolCoordinator {
  // MARK: Requested Notifications

  /// Sends a requested notification and records the attempt for the chat's Push Test
  /// tab. Recording is the whole of its effect on the window: the tab is not opened, selected or
  /// revealed, so an agent announcing finished work never moves the panel away from what the
  /// person is looking at. A tab that is already open refreshes in place.
  func notifyUser(
    _ arguments: NotifyUserArguments,
    for sessionID: SessionID
  ) -> MCPToolResult {
    let outcome = requestedNotifications.send(arguments, for: sessionID)
    notificationTests.record(arguments, outcome: outcome, origin: .agent, for: sessionID)
    switch outcome {
    case .queued(let message): return .success(message)
    case .refused(let message): return .failure(message)
    }
  }

  private var requestedNotifications: RequestedNotificationCommandService {
    RequestedNotificationCommandService(
      notifications: dependencies.notifications,
      targets: dependencies.notificationTargets,
      isRemoteAccessEnabled: { [settings = dependencies.settings] in
        settings.remoteAccessEnabled
      },
      postOnMac: { request in
        AttentionAlertCenter.shared.postRequestedUpdate(
          eventID: request.eventID,
          sessionID: request.sessionID,
          title: request.title,
          body: request.body,
          destination: request.destination
        )
      }
    )
  }
}

// MARK: - NotificationTestHosting

extension AgentToolCoordinator: NotificationTestHosting {
  func sendTestNotification(
    _ arguments: NotifyUserArguments,
    for sessionID: SessionID
  ) -> RequestedNotificationOutcome {
    let outcome = requestedNotifications.send(arguments, for: sessionID)
    notificationTests.record(arguments, outcome: outcome, origin: .person, for: sessionID)
    return outcome
  }

  func notificationRecipientNames(for sessionID: SessionID) -> [String] {
    requestedNotifications.memberRecipientNames(for: sessionID)
  }

  func notificationTargetKind(
    _ reference: String,
    for sessionID: SessionID
  ) -> RemoteNotificationDestinationDTO.Kind? {
    requestedNotifications.targetKind(reference, for: sessionID)
  }
}
