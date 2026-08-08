import Foundation

// MARK: - Scheduled Message Store

/// Every send waiting for its moment, on disk.
///
/// **Written on the mutation, never coalesced** — `DraftStore`'s rule, for `DraftStore`'s reason.
/// Once the composer is cleared, a scheduled message is the only copy of something somebody
/// wrote: no transcript has it, no terminal scrollback has it, and the agent it is addressed to
/// has never seen it. A coalescing window is the one interval this cannot afford.
///
/// **A file rather than a row in `threading.db`.** Columns exist to be ordered by, filtered on or
/// joined, and nothing here is: it is a handful of records read whole at launch. What it does
/// need is the contract `DraftStore` and `SessionContinuityStore` already have — synchronous
/// user-authored writes, and quarantine rather than deletion when the bytes will not decode. A
/// scheduled message is a draft with a due time, so it lives where drafts live.
///
/// The store keeps no clock of its own and knows nothing about delivery. It answers what is
/// waiting and records what became of it; `ScheduledMessageScheduler` owns when, and
/// `SessionCoordinator` owns how.
@MainActor
final class ScheduledMessageStore {

    // MARK: - Singleton

    static let shared = ScheduledMessageStore()

    // MARK: - Outcomes

    /// Why a schedule was refused. Values rather than prose, so the strip, the sheet and any
    /// later adapter word it their own way.
    enum Refusal: Error, Equatable, Sendable {
        case empty
        case targetFull(limit: Int)
        case storeFull(limit: Int)
        case inThePast
        case writesBlocked
    }

    // MARK: - Properties

    private var messages: [ScheduledMessage] = []
    private let persistence: RecoverableFileStore<ScheduledMessagesFile>
    private let center: NotificationCenter

    /// Ids taken by a performer and not yet resolved. Held in memory only: a claim is a promise
    /// about *this* run of the app, and a claim that survived a quit would strand the record.
    private var claimed: Set<ScheduledMessageID> = []

    // MARK: - Initialization

    /// The directory is injectable for the same reason `DraftStore`'s is: the test bundle is
    /// hosted in the app, so a store that always resolved Application Support would have every
    /// test writing the developer's own scheduled sends.
    init(directory: URL? = nil, fileManager: FileManager = .default, center: NotificationCenter = .default) {
        let root = directory ?? fileManager
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(ProjectIconDefaults.applicationDirectoryName)

        self.center = center
        self.persistence = RecoverableFileStore(
            url: root.appendingPathComponent(ScheduledMessageDefaults.fileName),
            fileManager: fileManager,
            criticality: .userAuthored,
            dateEncodingStrategy: .iso8601,
            dateDecodingStrategy: .iso8601
        )

        load()
    }

    // MARK: - Reading

    /// Everything waiting, soonest first. One order, everywhere: the strip, the review sheet and
    /// the scheduler all read a queue whose next item is its first.
    var all: [ScheduledMessage] {
        messages.sorted { $0.dueAt < $1.dueAt }
    }

    /// What is waiting for one session's conversation.
    func messages(for sessionID: SessionID) -> [ScheduledMessage] {
        all.filter { $0.target.sessionID == sessionID }
    }

    /// The session starts waiting for one project. Deliberately not "everything to do with this
    /// project": a reply to a session that happens to live here is that session's, and is shown
    /// under it.
    func sessionStarts(in projectID: ProjectID) -> [ScheduledMessage] {
        all.filter { $0.target.projectID == projectID }
    }

    subscript(id: ScheduledMessageID) -> ScheduledMessage? {
        messages.first { $0.id == id }
    }

    /// Everything whose moment has arrived and which nobody is already delivering.
    ///
    /// `isOwed`, not `isArmed`: a send that found its session busy is still owed an attempt, and
    /// filtering it out here is how it would wait forever for a retry that never came.
    func due(at now: Date) -> [ScheduledMessage] {
        all.filter { $0.state.isOwed && $0.isDue(at: now) && !claimed.contains($0.id) }
    }

    /// The soonest moment anything is waiting for, which is what a single timer is armed against.
    func nextDueDate(after now: Date) -> Date? {
        all.first { $0.state.isArmed && $0.dueAt > now && !claimed.contains($0.id) }?.dueAt
    }

    /// Sends the user still has a decision to make about — the review sheet's whole content.
    var needingAttention: [ScheduledMessage] {
        all.filter { $0.state.needsAttention }
    }

    /// Whether anything at all is still expected to move on its own — what decides if the
    /// scheduler keeps a heartbeat running.
    var hasAnythingPending: Bool {
        messages.contains { !$0.state.needsAttention }
    }

    // MARK: - Writing

    /// Takes a new scheduled send, or says why not.
    ///
    /// Refuses rather than evicting, `BrowserBaselineStore`'s rule: a queue that quietly forgets
    /// what somebody wrote is worse than one that says it is full.
    @discardableResult
    func add(_ message: ScheduledMessage, now: Date = Date()) -> Result<ScheduledMessage, Refusal> {
        guard !message.isEmpty else { return .failure(.empty) }
        guard message.dueAt > now else { return .failure(.inThePast) }
        guard messages.count < ScheduledMessageDefaults.maximumTotal else {
            return .failure(.storeFull(limit: ScheduledMessageDefaults.maximumTotal))
        }
        guard countForTarget(of: message) < ScheduledMessageDefaults.maximumPerTarget else {
            return .failure(.targetFull(limit: ScheduledMessageDefaults.maximumPerTarget))
        }
        guard persistence.writesAllowed else { return .failure(.writesBlocked) }

        messages.append(message)
        save()
        return .success(message)
    }

    @discardableResult
    func remove(_ id: ScheduledMessageID) -> Bool {
        guard let index = messages.firstIndex(where: { $0.id == id }) else { return false }
        messages.remove(at: index)
        claimed.remove(id)
        save()
        return true
    }

    /// Rewrites a waiting send in place, keeping its identity.
    @discardableResult
    func replace(_ id: ScheduledMessageID, with message: ScheduledMessage) -> Bool {
        guard let index = messages.firstIndex(where: { $0.id == id }) else { return false }
        messages[index] = message
        save()
        return true
    }

    func setState(_ state: ScheduledMessage.State, for id: ScheduledMessageID) {
        guard let index = messages.firstIndex(where: { $0.id == id }) else { return }
        guard messages[index].state != state else { return }
        messages[index].state = state
        save()
    }

    // MARK: - Claiming

    /// Takes a due send for delivery, atomically.
    ///
    /// **The claim is what makes a posted "this is due" safe to observe more than once.** In the
    /// app there is one `SessionCoordinator`, but the hosted test bundle builds
    /// `MainWindowController` in a good many test methods, so several can be observing the
    /// default centre at once. Re-archiving a session is idempotent and survives that;
    /// re-*sending* a message is not. So a performer takes the record before it acts, and puts it
    /// back if it could not.
    func claim(_ id: ScheduledMessageID) -> ScheduledMessage? {
        guard let message = self[id], message.state.isOwed, !claimed.contains(id) else {
            return nil
        }
        claimed.insert(id)
        return message
    }

    /// Hands a claimed record back unspent — the surface refused, or was not ready yet.
    func relinquish(_ id: ScheduledMessageID, waitingBecause reason: String? = nil) {
        claimed.remove(id)
        guard let reason else { return }
        setState(.waiting(reason), for: id)
    }

    /// Marks a claimed record delivered: it leaves the store, because the conversation it
    /// landed in is now the record of it.
    func complete(_ id: ScheduledMessageID) {
        claimed.remove(id)
        remove(id)
    }

    /// Marks a claimed record undeliverable, keeping it for the user to decide about.
    func fail(_ id: ScheduledMessageID, reason: String) {
        claimed.remove(id)
        setState(.failed(reason), for: id)
    }

    // MARK: - Time

    /// Everything armed whose moment passed while nobody was watching.
    ///
    /// **Never sent automatically.** There is no grace window: the app is not a server, and the
    /// one rule is that it does not send something the clock passed while it was not running.
    /// The next launch asks, item by item.
    @discardableResult
    func markMissed(before now: Date) -> [ScheduledMessage] {
        var missed: [ScheduledMessage] = []
        for index in messages.indices where messages[index].state.isArmed {
            guard messages[index].isDue(at: now) else { continue }
            messages[index].state = .missed
            missed.append(messages[index])
        }
        guard !missed.isEmpty else { return [] }
        save()
        return missed
    }

    /// Re-derives every wall-clock moment after the system time zone changed.
    ///
    /// The record keeps both the instant and the components the user actually chose, and this is
    /// the one place the second is authoritative: somebody who asked for 09:00 asked for 09:00
    /// where they are, and a laptop opened three time zones away should not fire at 03:00.
    /// Reset-anchored sends are left alone — they were never aimed at a wall-clock time.
    @discardableResult
    func reanchorWallClockMoments(calendar: Calendar = .current) -> Bool {
        var changed = false
        for index in messages.indices where messages[index].anchor == .wallClock {
            var wallClockCalendar = calendar
            wallClockCalendar.timeZone = .current
            guard let moment = wallClockCalendar.date(from: messages[index].intendedWallClock),
                  moment != messages[index].dueAt else { continue }
            messages[index].dueAt = moment
            changed = true
        }
        guard changed else { return false }
        save()
        return true
    }

    // MARK: - Lifecycle

    /// Drops everything belonging to sessions and projects that no longer exist.
    ///
    /// Called from `ProjectStore`'s own removals rather than from a sidebar delegate: that is the
    /// one choke point every deletion route passes, and Settings ▸ Archived deletes sessions
    /// without going anywhere near the sidebar.
    func forget(sessionID: SessionID) {
        let before = messages.count
        messages.removeAll { $0.target.sessionID == sessionID }
        guard messages.count != before else { return }
        save()
    }

    func forget(projectID: ProjectID) {
        let before = messages.count
        messages.removeAll { $0.target.projectID == projectID }
        guard messages.count != before else { return }
        save()
    }

    /// Drops everything whose target is not in the given sets. The sweep for a store that has
    /// been edited behind the app's back — a session removed by a migration, say.
    func retainOnly(sessionIDs: Set<SessionID>, projectIDs: Set<ProjectID>) {
        let before = messages.count
        messages.removeAll { message in
            switch message.target {
            case .session(let id): return !sessionIDs.contains(id)
            case .newSession(let plan): return !projectIDs.contains(plan.projectID)
            }
        }
        guard messages.count != before else { return }
        save()
    }

    // MARK: - Private Methods

    private func countForTarget(of message: ScheduledMessage) -> Int {
        switch message.target {
        case .session(let id):
            return messages.filter { $0.target.sessionID == id }.count
        case .newSession(let plan):
            return messages.filter { $0.target.projectID == plan.projectID }.count
        }
    }

    private func load() {
        let outcome = persistence.load(defaultValue: ScheduledMessagesFile(messages: [])) { stored in
            if let broken = stored.messages.first(where: { $0.isEmpty }) {
                throw ScheduledMessageStoreError.emptyMessage(broken.id.uuidString)
            }
        }
        messages = outcome.value.messages
    }

    private func save() {
        persistence.save(ScheduledMessagesFile(messages: messages))
        center.post(ScheduledMessagesDidChange())
    }
}

// MARK: - Stored Shape

private enum ScheduledMessageStoreError: LocalizedError {
    case emptyMessage(String)

    var errorDescription: String? {
        switch self {
        case .emptyMessage(let id):
            return "scheduled message '\(id)' carries neither prose nor context"
        }
    }
}

private struct ScheduledMessagesFile: Codable {
    var messages: [ScheduledMessage]
}
