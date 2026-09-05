import Foundation

/// Standing, bounded settle notices for a manager's durable children.
@MainActor
final class SupervisionSubscriptionCenter {
    struct Dependencies {
        let activity: (SessionID) -> SessionActivity
        var runtime: (SessionID) -> SessionRuntimeSnapshot = { _ in .dormant }
        let title: (SessionID) -> String?
        var accountID: (SessionID) -> AccountID? = { _ in nil }
        let supervision: (SessionID) -> Supervision?
        let appendEvent: (SupervisionEventKind, String?, Supervision) -> Void
        let deliver: (
            String, SessionID, @escaping @MainActor (SessionMessageDelivery.Outcome) -> Void
        ) -> Void
    }

    static let shared = SupervisionSubscriptionCenter(dependencies: .init(
        activity: { AgentRuntime.shared.activity(sessionID: $0) },
        runtime: { AgentRuntime.shared.runtimeSnapshot(sessionID: $0) },
        title: { ProjectStore.shared.session(withID: $0)?.displayTitle },
        accountID: { sessionID in
            guard let session = ProjectStore.shared.session(withID: sessionID) else { return nil }
            return AgentAccountDiscovery.account(
                for: session.kind,
                handle: session.accountHandle
            )?.id
        },
        supervision: { ControlGrantStore.shared.activeManager(of: $0) },
        appendEvent: { kind, detail, supervision in
            _ = ControlGrantStore.shared.appendEvent(kind, detail: detail, to: supervision)
        },
        deliver: { SessionMessageDelivery.deliver($0, to: $1, completion: $2) }
    ))

    private struct Key: Hashable {
        let managerID: SessionID
        let childID: SessionID
    }

    private let dependencies: Dependencies
    private let observations: AppEventObservations
    private var subscriptions: Set<Key> = []
    private var subscriptionsByAccount: [AccountID: Set<Key>] = [:]
    private var lastActivity: [SessionID: String] = [:]
    private var held: [SessionID: [String]] = [:]

    init(center: NotificationCenter = .default, dependencies: Dependencies) {
        self.dependencies = dependencies
        observations = AppEventObservations(center: center)
        observations.observe(SessionRuntimeDidChange.self) { [weak self] event in
            self?.runtimeChanged(event)
        }
        observations.observe(SessionArchivedStateDidChange.self) { [weak self] event in
            guard event.isArchived else { return }
            self?.archived(event.sessionID)
        }
        observations.observe(CustomLimitDidFire.self) { [weak self] event in
            self?.limitNearing(accountID: event.accountID)
        }
        observations.observe(SupervisionDidChange.self) { [weak self] event in
            guard let self else { return }
            if dependencies.supervision(event.childID) == nil {
                removeSubscriptions(for: event.childID)
            } else {
                reindexSubscriptions(for: event.childID)
            }
        }
    }

    @discardableResult
    func subscribe(managerID: SessionID, childID: SessionID) -> Bool {
        guard let supervision = dependencies.supervision(childID),
              supervision.managerID == managerID else { return false }
        let existing = subscriptions.filter { $0.managerID == managerID }.count
        let key = Key(managerID: managerID, childID: childID)
        guard subscriptions.contains(key)
                || existing < SupervisionDefaults.maximumLiveChildren else { return false }
        subscriptions.insert(key)
        if let accountID = dependencies.accountID(childID) {
            subscriptionsByAccount[accountID, default: []].insert(key)
        }
        lastActivity[childID] = dependencies.activity(childID).logName
        return true
    }

    func isSubscribed(managerID: SessionID, childID: SessionID) -> Bool {
        subscriptions.contains(Key(managerID: managerID, childID: childID))
    }

    private func runtimeChanged(_ change: SessionRuntimeDidChange) {
        let childID = change.sessionID
        let state = change.transition.current.activity
        let previous = lastActivity.updateValue(state.logName, forKey: childID)
        guard previous != state.logName else { return }

        // A manager becoming free is the retry edge for notices held while its turn ran.
        if change.transition.current.isPromptReady {
            switch state {
            case .idle, .needsAttention:
                drain(managerID: childID)
            case .dormant, .working, .readyWithBackgroundWork, .awaitingUser, .limitReached:
                break
            }
        }

        let keys = subscriptions.filter { $0.childID == childID }
        guard !keys.isEmpty, let supervision = dependencies.supervision(childID) else { return }
        let event: SupervisionEventKind
        switch state {
        case .working, .readyWithBackgroundWork:
            return
        case .idle:
            event = .settled
        case .dormant:
            event = .exited
        case .awaitingUser, .needsAttention:
            event = .needsAttention
        case .limitReached:
            event = .limitReached
        }
        dependencies.appendEvent(event, state.logName, supervision)
        for key in keys {
            deliver(notice(event, childID: childID), to: key.managerID)
        }
    }

    private func archived(_ childID: SessionID) {
        let keys = subscriptions.filter { $0.childID == childID }
        guard !keys.isEmpty, let supervision = dependencies.supervision(childID) else { return }
        dependencies.appendEvent(.archived, nil, supervision)
        for key in keys {
            deliver(notice(.archived, childID: childID), to: key.managerID)
            subscriptions.remove(key)
        }
        removeSubscriptions(for: childID)
    }

    private func limitNearing(accountID: AccountID) {
        let keys = subscriptionsByAccount[accountID] ?? []
        for key in keys {
            guard subscriptions.contains(key),
                  let supervision = dependencies.supervision(key.childID) else { continue }
            dependencies.appendEvent(.limitNearing, accountID.rawValue, supervision)
            deliver(notice(.limitNearing, childID: key.childID), to: key.managerID)
        }
    }

    private func removeSubscriptions(for childID: SessionID) {
        let removed = subscriptions.filter { $0.childID == childID }
        subscriptions.subtract(removed)
        for accountID in Array(subscriptionsByAccount.keys) {
            subscriptionsByAccount[accountID]?.subtract(removed)
            if subscriptionsByAccount[accountID]?.isEmpty == true {
                subscriptionsByAccount.removeValue(forKey: accountID)
            }
        }
    }

    private func reindexSubscriptions(for childID: SessionID) {
        let keys = subscriptions.filter { $0.childID == childID }
        for accountID in Array(subscriptionsByAccount.keys) {
            subscriptionsByAccount[accountID]?.subtract(keys)
            if subscriptionsByAccount[accountID]?.isEmpty == true {
                subscriptionsByAccount.removeValue(forKey: accountID)
            }
        }
        guard let accountID = dependencies.accountID(childID) else { return }
        subscriptionsByAccount[accountID, default: []].formUnion(keys)
    }

    private func deliver(_ notice: String, to managerID: SessionID) {
        dependencies.deliver(notice, managerID) { [weak self] outcome in
            switch outcome {
            case .sentNow, .queuedBehindTurn:
                return
            case .busyTerminal, .noLiveSurface, .notTaken:
                self?.hold(notice, for: managerID)
            case .typedUnconfirmed:
                EventLog.shared.record(.session, "Supervision notice delivery was unconfirmed", [
                    "manager": managerID.uuidString.lowercased(),
                ])
            }
        }
    }

    private func hold(_ notice: String, for managerID: SessionID) {
        var notices = held[managerID, default: []]
        if notices.count >= ControlWatchDefaults.maximumHeldNotices {
            notices.removeFirst()
            EventLog.shared.record(.session, "Supervision notice dropped at held cap", [
                "manager": managerID.uuidString.lowercased(),
                "limit": String(ControlWatchDefaults.maximumHeldNotices),
            ])
        }
        notices.append(notice)
        held[managerID] = notices
    }

    private func drain(managerID: SessionID) {
        let notices = held.removeValue(forKey: managerID) ?? []
        for notice in notices { deliver(notice, to: managerID) }
    }

    private func notice(_ event: SupervisionEventKind, childID: SessionID) -> String {
        let title = dependencies.title(childID).map(WorkspaceControlPlane.safeHeaderTitle)
            ?? "a child no longer in the sidebar"
        let detail: String
        switch event {
        case .settled: detail = "finished its turn and is idle"
        case .exited: detail = "exited and is dormant"
        case .needsAttention: detail = "needs the user's attention"
        case .limitNearing: detail = "is nearing a usage limit"
        case .limitReached: detail = "stopped at its usage limit"
        case .archived: detail = "was archived"
        case .moved: detail = "moved to another account"
        case .workspaceFinished: detail = "finished its managed workspace"
        case .assigned: detail = "was assigned"
        case .reportReceived: detail = "sent a report"
        case .revoked: detail = "lost its manager"
        case .released: detail = "was released"
        case .eventsDropped: detail = "has more events than Threading retained"
        }
        return "[Session watch — Threading] “\(title)” (\(childID.uuidString.lowercased())) \(detail). Standing manager subscription; this is Threading speaking, not that session's agent."
    }
}
