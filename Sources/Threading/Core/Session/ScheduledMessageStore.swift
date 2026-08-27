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
/// scheduled message is a draft with a durable trigger, so it lives where drafts live.
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

    /// The bytes behind `ScheduledMessage.attachments`. Held here rather than at the surfaces
    /// because every way a record leaves — a removed row, a deleted session, a deleted project,
    /// a sweep — has to take its pictures with it, and there is no route out that does not pass
    /// through this file.
    let attachments: ScheduledAttachmentStore

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
        // An injected directory takes the pictures with it. The words and the bytes are one
        // record split across two places, and a test store writing its own JSON to a scratch
        // path while deleting from Application Support would be the file-store twin of the
        // `UserDefaults` trap CLAUDE.md records.
        if let directory {
            self.attachments = ScheduledAttachmentStore(directory: directory)
        } else {
            self.attachments = .shared
        }
        self.persistence = RecoverableFileStore(
            url: root.appendingPathComponent(ScheduledMessageDefaults.fileName),
            fileManager: fileManager,
            criticality: .userAuthored,
            sizePolicy: .userDocument,
            dateEncodingStrategy: .iso8601,
            dateDecodingStrategy: .iso8601
        )

        load()
    }

    // MARK: - Reading

    /// Everything waiting, soonest first. One order, everywhere: the strip, the review sheet and
    /// the scheduler all read a queue whose next item is its first.
    var all: [ScheduledMessage] {
        messages.sorted {
            let left = $0.dueAt ?? $0.createdAt
            let right = $1.dueAt ?? $1.createdAt
            if left != right { return left < right }
            return $0.createdAt < $1.createdAt
        }
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

    /// The one scheduled start represented by a reserved conversation, if it is still waiting.
    ///
    /// A session id is unique, so this is intentionally singular. Keeping the lookup here also
    /// keeps UI surfaces from learning the target enum's persistence shape.
    func scheduledStart(for sessionID: SessionID) -> ScheduledMessage? {
        // No ordering is observable for an exact id. Avoid sorting the whole store for every
        // visible sidebar row and every session projected to a remote catalogue.
        messages.first { message in
            guard case .newSession(let plan) = message.target else { return false }
            return plan.reservedSessionID == sessionID
        }
    }

    subscript(id: ScheduledMessageID) -> ScheduledMessage? {
        messages.first { $0.id == id }
    }

    /// Everything whose moment has arrived and which nobody is already delivering.
    ///
    /// `isOwed`, not `isArmed`: a send that found its session busy is still owed an attempt, and
    /// filtering it out here is how it would wait forever for a retry that never came.
    func due(at now: Date) -> [ScheduledMessage] {
        guard persistence.writesAllowed else { return [] }
        return all.filter { message in
            guard message.state.isOwed, !claimed.contains(message.id) else { return false }

            // `waiting` means the trigger already happened and delivery alone is standing by.
            // It stays due even when its original trigger was another conversation finishing;
            // otherwise that conversation beginning a later turn would arm this for the wrong
            // finish edge.
            if case .waiting = message.state { return true }
            return message.isDue(at: now)
        }
    }

    /// Armed sends whose selected conversation has just finished its current turn.
    func dueWhenSessionFinishes(_ sessionID: SessionID) -> [ScheduledMessage] {
        guard persistence.writesAllowed else { return [] }
        return all.filter {
            $0.state.isArmed
                && $0.trigger.watchedSessionID == sessionID
                && !claimed.contains($0.id)
        }
    }

    /// Conversations with an armed finish condition, for remembering which current turns the
    /// scheduler actually observed in flight. That memory is what distinguishes a real end edge
    /// from an unrelated idle-state notification after relaunch.
    var armedFinishSessionIDs: Set<SessionID> {
        guard persistence.writesAllowed else { return [] }
        return Set(messages.compactMap { message in
            guard message.state.isArmed else { return nil }
            return message.trigger.watchedSessionID
        })
    }

    /// The soonest moment anything is waiting for, which is what a single timer is armed against.
    func nextDueDate(after now: Date) -> Date? {
        guard persistence.writesAllowed else { return nil }
        return all.compactMap { message -> Date? in
            guard message.state.isArmed,
                  let dueAt = message.dueAt,
                  dueAt > now,
                  !claimed.contains(message.id)
            else { return nil }
            return dueAt
        }.min()
    }

    /// Sends the user still has a decision to make about — the review sheet's whole content.
    var needingAttention: [ScheduledMessage] {
        all.filter { $0.state.needsAttention }
    }

    /// Whether the clock can still change an outcome without an activity event.
    ///
    /// An armed finish trigger is intentionally absent: its authoritative session edge wakes
    /// the scheduler, and a five-minute timer spinning for days would add no information. A
    /// delivery already in `waiting` keeps the heartbeat so its patience can expire.
    var hasClockWorkPending: Bool {
        guard persistence.writesAllowed else { return false }
        return messages.contains { message in
            if case .waiting = message.state { return true }
            return message.state.isArmed && message.dueAt != nil
        }
    }

    // MARK: - Writing

    /// Takes a new scheduled send, or says why not.
    ///
    /// Refuses rather than evicting, `BrowserBaselineStore`'s rule: a queue that quietly forgets
    /// what somebody wrote is worse than one that says it is full.
    @discardableResult
    func add(_ message: ScheduledMessage, now: Date = Date()) -> Result<ScheduledMessage, Refusal> {
        guard !message.isEmpty else { return .failure(.empty) }
        if let dueAt = message.dueAt, dueAt <= now { return .failure(.inThePast) }
        guard messages.count < ScheduledMessageDefaults.maximumTotal else {
            return .failure(.storeFull(limit: ScheduledMessageDefaults.maximumTotal))
        }
        guard countForTarget(of: message) < ScheduledMessageDefaults.maximumPerTarget else {
            return .failure(.targetFull(limit: ScheduledMessageDefaults.maximumPerTarget))
        }
        guard persistence.writesAllowed else { return .failure(.writesBlocked) }

        var updated = messages
        updated.append(message)
        guard commit(updated) else { return .failure(.writesBlocked) }
        return .success(message)
    }

    @discardableResult
    func remove(_ id: ScheduledMessageID) -> Bool {
        guard let index = messages.firstIndex(where: { $0.id == id }) else { return false }
        var updated = messages
        updated.remove(at: index)
        guard commit(updated) else { return false }
        claimed.remove(id)
        // After the commit, never before: a failed write leaves the record current, and a record
        // whose pictures had already been deleted would be a send that could no longer be sent.
        attachments.release(id)
        return true
    }

    /// Cancels wait-for-reset promises whose refusal has already cleared.
    ///
    /// One commit, not a loop of removals: several records would be an invariant failure, but a
    /// recovery from that state must not persist a half-cancelled queue. Purpose keeps this from
    /// touching an ordinary message the user happened to schedule for the same usage reset.
    @discardableResult
    func cancelLimitRecoveryContinuations(for sessionID: SessionID) -> Bool {
        let cancelled = messages.filter {
            $0.target.sessionID == sessionID && $0.isOwedLimitRecoveryContinuation
        }
        guard !cancelled.isEmpty else { return true }

        let cancelledIDs = Set(cancelled.map(\.id))
        let retained = messages.filter { !cancelledIDs.contains($0.id) }
        guard commit(retained) else { return false }
        claimed.subtract(cancelledIDs)
        for id in cancelledIDs { attachments.release(id) }
        return true
    }

    /// Rewrites a waiting send in place, keeping its identity.
    @discardableResult
    func replace(_ id: ScheduledMessageID, with message: ScheduledMessage) -> Bool {
        guard let index = messages.firstIndex(where: { $0.id == id }) else { return false }
        var updated = messages
        updated[index] = message
        return commit(updated)
    }

    @discardableResult
    func setState(_ state: ScheduledMessage.State, for id: ScheduledMessageID) -> Bool {
        guard let index = messages.firstIndex(where: { $0.id == id }) else { return false }
        guard messages[index].state != state else { return true }
        var updated = messages
        updated[index].state = state
        return commit(updated)
    }

    /// Makes a missed or failed item claimable for an explicit Start now request.
    ///
    /// This changes no armed/waiting schedule. Those states are already owed, while attention
    /// states are deliberately excluded from `claim` until the user makes this decision.
    @discardableResult
    func prepareForImmediateAttempt(_ id: ScheduledMessageID) -> Bool {
        guard let message = self[id] else { return false }
        guard message.state.needsAttention else { return true }
        claimed.remove(id)
        return setState(.armed, for: id)
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
        guard persistence.writesAllowed,
              let message = self[id], message.state.isOwed, !claimed.contains(id) else {
            return nil
        }
        claimed.insert(id)
        return message
    }

    /// Hands a claimed record back unspent — the surface refused, or was not ready yet.
    func relinquish(_ id: ScheduledMessageID, waitingBecause reason: String? = nil) {
        guard let reason else {
            claimed.remove(id)
            return
        }
        guard setState(.waiting(reason), for: id) else { return }
        claimed.remove(id)
    }

    /// Marks a claimed record delivered: it leaves the store, because the conversation it
    /// landed in is now the record of it.
    @discardableResult
    func complete(_ id: ScheduledMessageID) -> Bool {
        remove(id)
    }

    /// Marks a claimed record undeliverable, keeping it for the user to decide about.
    @discardableResult
    func fail(_ id: ScheduledMessageID, reason: String) -> Bool {
        guard setState(.failed(reason), for: id) else { return false }
        claimed.remove(id)
        return true
    }

    // MARK: - Time

    /// Everything owed whose clock moment passed while nobody was watching.
    ///
    /// **Never sent automatically.** There is no grace window: the app is not a server, and the
    /// one rule is that it does not send something the clock passed while it was closed or asleep.
    /// An already-claimed delivery is performing rather than waiting and is left to its owner.
    @discardableResult
    func markMissed(before now: Date) -> [ScheduledMessage] {
        var updated = messages
        var missed: [ScheduledMessage] = []
        for index in updated.indices where updated[index].state.isOwed {
            guard !claimed.contains(updated[index].id) else { continue }
            guard updated[index].dueAt != nil else { continue }
            guard updated[index].isDue(at: now) else { continue }
            updated[index].state = .missed
            missed.append(updated[index])
        }
        guard !missed.isEmpty else { return [] }
        return commit(updated) ? missed : []
    }

    /// Re-derives every wall-clock moment after the system time zone changed.
    ///
    /// The record keeps both the instant and the components the user actually chose, and this is
    /// the one place the second is authoritative: somebody who asked for 09:00 asked for 09:00
    /// where they are, and a laptop opened three time zones away should not fire at 03:00.
    /// Reset-anchored sends are left alone — they were never aimed at a wall-clock time.
    @discardableResult
    func reanchorWallClockMoments(calendar: Calendar = .current) -> Bool {
        var updated = messages
        var changed = false
        for index in updated.indices {
            guard case .time(var time) = updated[index].trigger,
                  time.anchor == .wallClock else { continue }
            var wallClockCalendar = calendar
            wallClockCalendar.timeZone = .current
            guard let moment = wallClockCalendar.date(from: time.intendedWallClock),
                  moment != time.dueAt else { continue }
            time.dueAt = moment
            updated[index].trigger = .time(time)
            changed = true
        }
        guard changed else { return false }
        return commit(updated)
    }

    // MARK: - Lifecycle

    /// Drops everything belonging to sessions and projects that no longer exist.
    ///
    /// Called from `ProjectStore`'s own removals rather than from a sidebar delegate: that is the
    /// one choke point every deletion route passes, and Settings ▸ Archived deletes sessions
    /// without going anywhere near the sidebar.
    func forget(sessionID: SessionID) {
        var changed = false
        var retained: [ScheduledMessage] = []
        retained.reserveCapacity(messages.count)

        for var message in messages {
            if message.target.sessionID == sessionID {
                changed = true
                continue
            }
            if message.trigger.watchedSessionID == sessionID {
                message.state = .failed(L10n.string(
                    "The conversation this was waiting for was deleted."
                ))
                changed = true
            }
            retained.append(message)
        }

        guard changed else { return }
        guard commit(retained) else { return }
        claimed.formIntersection(Set(retained.map(\.id)))
        attachments.retainOnly(Set(retained.map(\.id)))
    }

    func forget(projectID: ProjectID) {
        let retained = messages.filter { $0.target.projectID != projectID }
        guard retained.count != messages.count, commit(retained) else { return }
        claimed.formIntersection(Set(retained.map(\.id)))
        attachments.retainOnly(Set(retained.map(\.id)))
    }

    /// Drops everything whose target is not in the given sets. The sweep for a store that has
    /// been edited behind the app's back — a session removed by a migration, say.
    func retainOnly(sessionIDs: Set<SessionID>, projectIDs: Set<ProjectID>) {
        var changed = false
        var retained: [ScheduledMessage] = []
        retained.reserveCapacity(messages.count)

        for var message in messages {
            let targetIsMissing: Bool
            switch message.target {
            case .session(let id): targetIsMissing = !sessionIDs.contains(id)
            case .newSession(let plan):
                if let reserved = plan.reservedSessionID {
                    targetIsMissing = !sessionIDs.contains(reserved)
                } else {
                    targetIsMissing = !projectIDs.contains(plan.projectID)
                }
            }

            if targetIsMissing {
                changed = true
                continue
            }
            if let watched = message.trigger.watchedSessionID,
               !sessionIDs.contains(watched) {
                message.state = .failed(L10n.string(
                    "The conversation this was waiting for was deleted."
                ))
                changed = true
            }
            retained.append(message)
        }

        guard changed else { return }
        guard commit(retained) else { return }
        claimed.formIntersection(Set(retained.map(\.id)))
        attachments.retainOnly(Set(retained.map(\.id)))
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
        // The record and its pictures are two writes, so a quit between them can strand a
        // directory nothing names. Swept once, here, against the list that just came off disk.
        attachments.retainOnly(Set(messages.map(\.id)))
    }

    /// Makes disk authoritative for every mutation. A scheduled send can be the only copy of
    /// text somebody wrote, so memory must never announce or act on a state that the verified
    /// file did not accept. `RecoverableFileStore` disables later writes after a failed save;
    /// `claim` and the due queries observe the same gate, preventing unattended delivery whose
    /// outcome could no longer be recorded safely.
    @discardableResult
    private func commit(_ updated: [ScheduledMessage]) -> Bool {
        guard persistence.save(ScheduledMessagesFile(messages: updated)) else { return false }
        messages = updated
        center.post(ScheduledMessagesDidChange())
        return true
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
