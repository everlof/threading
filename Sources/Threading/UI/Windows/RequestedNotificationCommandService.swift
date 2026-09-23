import AppKit
import ThreadingRemoteKit

/// One validated delivery path for MCP requests and the user's Push Test tab.
@MainActor
struct RequestedNotificationCommandService {
  static func send(
    _ arguments: NotifyUserArguments,
    for sessionID: SessionID,
    dependencies: AgentToolDependencies
  ) -> MCPToolResult {
    guard
      let message = arguments.message?
        .trimmingCharacters(in: .whitespacesAndNewlines),
      !message.isEmpty
    else {
      return .failure("message is required.")
    }
    guard message.utf8.count <= RemoteAccessDefaults.maximumNotificationBodyBytes else {
      return .failure("message is too long for a notification.")
    }
    if let title = arguments.title,
      title.utf8.count > RemoteAccessDefaults.maximumNotificationTitleBytes
    {
      return .failure("title is too long for a notification.")
    }
    let delivery = RequestedNotificationDelivery(arguments.delivery)
    guard let delivery else {
      return .failure("delivery must be auto, mac, ios, or both.")
    }

    let destination: RemoteNotificationDestinationDTO
    if let rawReference = arguments.targetRef?
      .trimmingCharacters(in: .whitespacesAndNewlines), !rawReference.isEmpty {
      guard let resolved = dependencies.notificationTargets.resolve(
        rawReference,
        for: sessionID
      ) else {
        return .failure(
          "target_ref is unknown, expired, or belongs to another session. "
            + "Use the reference returned by the display or browser tool in this chat."
        )
      }
      destination = resolved
    } else {
      destination = .session
    }

    let eventID = UUID().uuidString.lowercased()
    var receipts: [String] = []
    var failures: [String] = []

    if delivery.includesMac {
      if dependencies.notifications.requestedRecipientIncludesOwner(
        sessionID: sessionID,
        recipient: arguments.recipient
      ) {
        let queued = AttentionAlertCenter.shared.postRequestedUpdate(
          eventID: eventID,
          sessionID: sessionID,
          title: arguments.title,
          body: message,
          destination: destination
        )
        if queued {
          receipts.append("the Mac")
        } else {
          failures.append("Mac notifications are disabled or this chat is muted")
        }
      } else {
        failures.append("the selected recipient is not the Mac owner")
      }
    }

    if delivery.includesIOS {
      guard dependencies.settings.remoteAccessEnabled else {
        failures.append("Remote Access is off")
        if receipts.isEmpty { return .failure(failures.joined(separator: "; ") + ".") }
        return .success(
          "Notification queued for \(receipts.joined(separator: " and ")); "
            + failures.joined(separator: "; ") + "."
        )
      }
      switch dependencies.notifications.notifyRequested(
        sessionID: sessionID,
        title: arguments.title,
        body: message,
        recipient: arguments.recipient,
        destination: destination
      ) {
      case .delivered(let recipient):
        receipts.append(recipient)
      case .unavailable(let reason):
        failures.append(reason)
      }
    }

    guard !receipts.isEmpty else {
      return .failure(failures.joined(separator: "; "))
    }
    let partial = failures.isEmpty ? "" : "; " + failures.joined(separator: "; ")
    return .success("Notification queued for \(receipts.joined(separator: " and "))\(partial).")
  }
}

private enum RequestedNotificationDelivery: Equatable {
  case mac
  case ios
  case both

  init?(_ rawValue: String?) {
    switch rawValue?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
    case nil, "", "auto", "both": self = .both
    case "mac": self = .mac
    case "ios", "iphone", "phone": self = .ios
    default: return nil
    }
  }

  var includesMac: Bool { self == .mac || self == .both }
  var includesIOS: Bool { self == .ios || self == .both }
}
