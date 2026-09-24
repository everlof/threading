import Foundation
import ThreadingRemoteKit

/// Where a requested notification may go.
///
/// One vocabulary for the `notify_user` argument, the Push Test tab's picker and the
/// service that acts on both, so the tab cannot offer a destination the tool would read
/// differently. Declared in the order the picker lists them.
enum RequestedNotificationDelivery: String, CaseIterable, Equatable, Sendable {
  case ios
  case mac
  case both

  /// Reads the `delivery` argument. Omitted, empty and `auto` all mean both.
  init?(argument rawValue: String?) {
    switch rawValue?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
    case nil, "", "auto", "both": self = .both
    case "mac": self = .mac
    case "ios", "iphone", "phone": self = .ios
    default: return nil
    }
  }

  /// The spelling a request carries.
  var argument: String { rawValue }

  var includesMac: Bool { self != .ios }
  var includesIOS: Bool { self != .mac }
}

/// How one requested notification ended, in the words the requester is shown.
enum RequestedNotificationOutcome: Equatable, Sendable {
  /// At least one destination took it. The text names each, and any that refused.
  case queued(String)
  /// No destination took it, and why.
  case refused(String)

  var message: String {
    switch self {
    case .queued(let message), .refused(let message): message
    }
  }

  var isQueued: Bool {
    if case .queued = self { return true }
    return false
  }
}

/// What a requested notification posts on this Mac.
struct RequestedMacNotification: Sendable {
  let eventID: String
  let sessionID: SessionID
  let title: String?
  let body: String
  let destination: RemoteNotificationDestinationDTO
}

/// The one validated delivery path for `notify_user` and the Push Test tab.
///
/// A resend from the tab is a new request: it takes a fresh event identity, resolves its
/// `target_ref` again, and rechecks recipient consent, Remote Access and the live and push
/// routes as they are now. Nothing about an earlier attempt is trusted.
@MainActor
struct RequestedNotificationCommandService {
  let notifications: RemoteNotificationService
  let targets: NotificationTargetRegistry
  let isRemoteAccessEnabled: () -> Bool
  /// Answers whether the Mac queued it — false when notifications are off or the chat is muted.
  let postOnMac: (RequestedMacNotification) -> Bool

  func send(
    _ arguments: NotifyUserArguments,
    for sessionID: SessionID
  ) -> RequestedNotificationOutcome {
    guard
      let message = arguments.message?
        .trimmingCharacters(in: .whitespacesAndNewlines),
      !message.isEmpty
    else {
      return .refused("message is required.")
    }
    guard message.utf8.count <= RemoteAccessDefaults.maximumNotificationBodyBytes else {
      return .refused("message is too long for a notification.")
    }
    if let title = arguments.title,
      title.utf8.count > RemoteAccessDefaults.maximumNotificationTitleBytes
    {
      return .refused("title is too long for a notification.")
    }
    guard let delivery = RequestedNotificationDelivery(argument: arguments.delivery) else {
      return .refused("delivery must be auto, mac, ios, or both.")
    }

    let destination: RemoteNotificationDestinationDTO
    if let rawReference = arguments.targetRef?
      .trimmingCharacters(in: .whitespacesAndNewlines), !rawReference.isEmpty {
      guard let resolved = targets.resolve(rawReference, for: sessionID) else {
        return .refused(
          "target_ref is unknown, expired, or belongs to another session. "
            + "Use the reference returned by the display or browser tool in this chat."
        )
      }
      destination = resolved
    } else {
      destination = .session
    }

    var receipts: [String] = []
    var failures: [String] = []

    if delivery.includesMac {
      if notifications.requestedRecipientIncludesOwner(
        sessionID: sessionID,
        recipient: arguments.recipient
      ) {
        let queued = postOnMac(RequestedMacNotification(
          eventID: UUID().uuidString.lowercased(),
          sessionID: sessionID,
          title: arguments.title,
          body: message,
          destination: destination
        ))
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
      if !isRemoteAccessEnabled() {
        failures.append("Remote Access is off")
        if receipts.isEmpty { return .refused(failures.joined(separator: "; ") + ".") }
        return .queued(
          "Notification queued for \(receipts.joined(separator: " and ")); "
            + failures.joined(separator: "; ") + "."
        )
      }
      switch notifications.notifyRequested(
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
      return .refused(failures.joined(separator: "; "))
    }
    let partial = failures.isEmpty ? "" : "; " + failures.joined(separator: "; ")
    return .queued("Notification queued for \(receipts.joined(separator: " and "))\(partial).")
  }

  /// Chat members who could receive a requested notification now, by display name.
  func memberRecipientNames(for sessionID: SessionID) -> [String] {
    notifications.requestedRecipientMemberNames(for: sessionID)
  }

  /// What an agent's `target_ref` still opens; nil once it has expired or if it was never this
  /// chat's.
  func targetKind(
    _ reference: String,
    for sessionID: SessionID
  ) -> RemoteNotificationDestinationDTO.Kind? {
    targets.resolve(reference, for: sessionID)?.kind
  }
}
