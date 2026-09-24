import Foundation

/// The latest requested notification in each chat, kept so the Push Test tab can show
/// what was sent, how it ended, and send it again.
///
/// Recording is all an agent's `notify_user` does to the interface. It never opens, selects or
/// reveals a tab: the request is a side effect of the agent's work, and the panel belongs to
/// whatever the person was looking at. A tab that is already open updates in place.
///
/// In memory only, so notification text and opaque target references gain no copy on disk. One
/// record per chat, replaced by each attempt, bounds it by the chats that have sent one since
/// launch.
@MainActor
final class NotificationTestLedger {

  struct Record: Equatable {
    enum Origin: Equatable {
      /// An agent's `notify_user` call.
      case agent
      /// A send from the Push Test tab.
      case person
    }

    let arguments: NotifyUserArguments
    let outcome: RequestedNotificationOutcome
    let origin: Origin
    let date: Date
  }

  // MARK: - Properties

  private var records: [SessionID: Record] = [:]
  private var observers: [SessionID: [WeakObserver]] = [:]
  private let now: () -> Date

  // MARK: - Initialization

  init(now: @escaping () -> Date = Date.init) {
    self.now = now
  }

  // MARK: - Public Methods

  func latest(for sessionID: SessionID) -> Record? {
    records[sessionID]
  }

  @discardableResult
  func record(
    _ arguments: NotifyUserArguments,
    outcome: RequestedNotificationOutcome,
    origin: Record.Origin,
    for sessionID: SessionID
  ) -> Record {
    let record = Record(arguments: arguments, outcome: outcome, origin: origin, date: now())
    records[sessionID] = record
    let live = (observers[sessionID] ?? []).compactMap(\.value)
    observers[sessionID] = live.isEmpty ? nil : live.map(WeakObserver.init)
    for observer in live {
      observer.notificationTestLedger(self, didRecord: record, for: sessionID)
    }
    return record
  }

  /// Drops a chat's record, for a chat that no longer exists.
  func forget(_ sessionID: SessionID) {
    records[sessionID] = nil
    observers[sessionID] = nil
  }

  /// Held weakly; an observer that goes away needs no matching call.
  func addObserver(_ observer: NotificationTestLedgerObserving, for sessionID: SessionID) {
    var live = (observers[sessionID] ?? []).filter { $0.value != nil }
    guard !live.contains(where: { $0.value === observer }) else { return }
    live.append(WeakObserver(observer))
    observers[sessionID] = live
  }

  // MARK: - Private Types

  private struct WeakObserver {
    weak var value: NotificationTestLedgerObserving?

    init(_ value: NotificationTestLedgerObserving) {
      self.value = value
    }
  }
}

@MainActor
protocol NotificationTestLedgerObserving: AnyObject {
  func notificationTestLedger(
    _ ledger: NotificationTestLedger,
    didRecord record: NotificationTestLedger.Record,
    for sessionID: SessionID
  )
}
