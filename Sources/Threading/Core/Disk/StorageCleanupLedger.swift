import Foundation

// MARK: - Storage Cleanup Ledger

/// Asks the user about a proposed cleanup **once**, however many agents propose it.
///
/// The disk is one disk. When it fills, every session hits ENOSPC within the same minute, each
/// one calls `list_reclaimable_storage`, and each one reads the same 20 GB of stale build output
/// — so the app is handed three proposals naming largely the same directories. Nothing stopped
/// that: each `propose_storage_cleanup` opened its own sheet, AppKit queued them behind one
/// another, and the user answered the same question three times. Worse, the second sheet had
/// already resolved its artifacts, so it named directories the first sheet had just deleted and
/// then quietly removed nothing; a proposal arriving *after* the delete was refused with "none of
/// these paths are in the current listing", which reads as a stale listing rather than as an
/// answer, and sends the agent round the loop again. On 2026-08-16 two approved removals ran
/// concurrently here and deleted one DerivedData tree twice, from two threads, in the same
/// millisecond.
///
/// So decisions are remembered and proposals fold into them:
///
/// - **One sheet at a time.** A path already on screen in a sheet is not put in a second one; the
///   proposal that named it attaches to the outcome of the sheet that has it.
/// - **An approval answers later proposals.** A path this user approved and the app removed is
///   reported back as already removed, with what it freed, instead of being refused as unknown.
/// - **A decline is remembered for the run.** The user said no; asking again ten minutes later
///   because a different session read the same listing is the spam this exists to stop. The
///   refusal says so, so the agent can tell them rather than guess.
/// - **A rebuilt directory is a new question.** A `.build` that was removed and has come back is
///   in the findings again, so its old outcome is cleared rather than answered with — the
///   decision was about the bytes that are gone, not about the name.
///
/// What it deliberately does not do is stop asking. `approveAgentStorageCleanup` is
/// `alwaysAsks(.irreversible)` and stays that way: this removes the *repeated* question, not the
/// question. Nothing here is persisted either — a decision covers this run of the app, because a
/// remembered "no" that outlives a restart is a silent policy nobody can find.
///
/// The presenting half is a closure so the whole state machine is testable without a window: the
/// tool coordinator supplies the real sheet, a test supplies an answer.
@MainActor
final class StorageCleanupLedger {

    // MARK: - Singleton

    static let shared = StorageCleanupLedger()

    // MARK: - Types

    /// What became of one path.
    enum Outcome: Equatable {

        /// Approved, and the directory actually went.
        case removed(Int64)

        /// Approved, and the gate refused at the moment of deletion — it had stopped looking
        /// safe. Not a decision by the user, so it never folds a later proposal.
        case refused

        /// The user said no. Folds every later proposal naming it, for this run.
        case declined
    }

    /// One directory that went, and what it freed.
    struct Removal: Equatable {
        let path: String
        let byteCount: Int64
    }

    /// A batch of findings put to the user as one sheet.
    struct Batch {
        let artifacts: [ReclaimableArtifact]
        let reason: String?

        /// Which session proposed it, when it is known — the sheet says so, because "an agent"
        /// is not an answer to "which one of them is asking".
        let asker: String?
    }

    /// What the sheet did with a batch.
    enum SheetResult {

        /// The user approved, and these are the directories that actually went.
        case approved([Removal])

        /// The user said no.
        case declined

        /// Nothing was put to them, or nothing could be acted on — no window, or the one
        /// removal lane already busy. **No decision is recorded**: the user has not answered,
        /// so a later proposal naming these paths asks rather than folding. The reason is
        /// handed to the agent, which is the only party that can do anything about it.
        case unavailable(String)
    }

    /// The answer one proposal gets, once every path it named has an outcome. Formatting is the
    /// caller's: this says what happened, not how to word it.
    struct Answer: Equatable {

        /// Whether this proposal put anything to the user at all. False means every path it
        /// named had already been decided — the case this whole type exists to produce.
        let askedTheUser: Bool

        /// Decided while this proposal waited.
        let removed: [Removal]
        let refused: [String]
        let declined: [String]

        /// Decided before it arrived.
        let alreadyRemoved: [Removal]
        let declinedEarlier: [String]

        /// Named, and in no listing — a stale quote rather than a decision.
        let unknown: [String]

        /// Paths that could not be put to the user at all, and why. Nothing was decided about
        /// them, so proposing them again is legitimate rather than repetition.
        let couldNotAsk: [String]
        let couldNotAskReason: String?

        var removedBytes: Int64 { removed.reduce(0) { $0 + $1.byteCount } }
        var alreadyRemovedBytes: Int64 { alreadyRemoved.reduce(0) { $0 + $1.byteCount } }
    }

    /// Puts one batch to the user and reports what happened. Injected so the state machine can
    /// be driven without a window.
    typealias Presenting = @MainActor (Batch, @escaping @MainActor (SheetResult) -> Void) -> Void

    // MARK: - Properties

    /// Every path this run has an answer for. Holds `.refused` too, so a waiter can tell a
    /// finished batch from an unfinished one, while only `.removed` and `.declined` fold a later
    /// proposal.
    private var outcomes: [String: Outcome] = [:]

    /// Paths spoken for by the sheet on screen or by one waiting behind it. A second proposal
    /// naming them waits for that answer rather than opening a sheet of its own.
    private var claimed: Set<String> = []

    private var queue: [PendingBatch] = []
    private var waiters: [Waiter] = []
    private var isPresenting = false

    /// Paths a batch could not put to the user, and why.
    ///
    /// Deliberately not an outcome: nothing was decided about these, so they fold nothing. The
    /// entry is cleared the moment the path is proposed again — which is what keeps it from
    /// answering a *later* proposal with an old failure — and kept until then, so a proposal
    /// still waiting on another batch is not left waiting forever for a path nobody will decide.
    private var unavailable: [String: String] = [:]

    /// Whether a sheet is up or one is queued behind it — read by tests, and by nothing else.
    var isAsking: Bool { isPresenting || !queue.isEmpty }

    // MARK: - Submitting

    /// Takes one proposal, folds it into what is already decided or already being asked, and
    /// answers when every path it named has an outcome.
    ///
    /// The resolution comes from `StorageCleanupGate`, which stays the security boundary: this
    /// never widens what may be proposed, it only decides how often the user is asked about it.
    func submit(
        _ resolution: StorageCleanupGate.Resolution,
        reason: String?,
        asker: String?,
        present: @escaping Presenting,
        completion: @escaping @MainActor (Answer) -> Void
    ) {
        var candidates: [ReclaimableArtifact] = []
        var declinedEarlier: [String] = []
        var alreadyRemoved: [Removal] = []
        var unknown: [String] = []

        for artifact in resolution.matched {
            let path = artifact.url.path
            if outcomes[path] == .declined {
                declinedEarlier.append(path)
                continue
            }
            // Still in the findings, so it is on disk now. Any earlier outcome was about a
            // directory that has since been rebuilt, and answering with it would decide a
            // question nobody asked. A path that could not be asked about last time is asked
            // about now, so that report is cleared too.
            outcomes[path] = nil
            unavailable[path] = nil
            candidates.append(artifact)
        }

        for path in resolution.unknown {
            // Not in the findings — because it never was, or because it is gone. If this app
            // removed it on the user's word, say so; that is an answer, where "not in the
            // listing" is a riddle.
            if case .removed(let bytes) = outcomes[path] {
                alreadyRemoved.append(Removal(path: path, byteCount: bytes))
            } else {
                unknown.append(path)
            }
        }

        let fresh = candidates.filter { !claimed.contains($0.url.path) }

        guard !candidates.isEmpty else {
            ThreadingLogger.storage.info(
                """
                Agent cleanup folded without asking \
                already_removed=\(alreadyRemoved.count, privacy: .public) \
                declined_earlier=\(declinedEarlier.count, privacy: .public)
                """
            )
            completion(Answer(
                askedTheUser: false,
                removed: [],
                refused: [],
                declined: [],
                alreadyRemoved: alreadyRemoved,
                declinedEarlier: declinedEarlier,
                unknown: unknown,
                couldNotAsk: [],
                couldNotAskReason: nil
            ))
            return
        }

        waiters.append(Waiter(
            candidates: candidates.map(\.url.path),
            alreadyRemoved: alreadyRemoved,
            declinedEarlier: declinedEarlier,
            unknown: unknown,
            completion: completion
        ))

        if fresh.isEmpty {
            ThreadingLogger.storage.info(
                """
                Agent cleanup attached to the sheet already asking \
                paths=\(candidates.count, privacy: .public)
                """
            )
        } else {
            claimed.formUnion(fresh.map(\.url.path))
            queue.append(PendingBatch(
                batch: Batch(artifacts: fresh, reason: reason, asker: asker),
                present: present
            ))
        }

        presentNextIfIdle()
    }

    /// Forgets every decision. For tests, and for nothing else: a decision is meant to last the
    /// run.
    func reset() {
        outcomes = [:]
        claimed = []
        queue = []
        waiters = []
        unavailable = [:]
        isPresenting = false
    }

    // MARK: - Presenting

    private func presentNextIfIdle() {
        guard !isPresenting else { return }

        while !queue.isEmpty {
            let pending = queue.removeFirst()

            // Anything decided since it was queued leaves the batch rather than being put to the
            // user again — the sheet in front of this one may have removed it.
            let artifacts = pending.batch.artifacts.filter { outcomes[$0.url.path] == nil }
            guard !artifacts.isEmpty else {
                claimed.subtract(pending.batch.artifacts.map(\.url.path))
                flushWaiters()
                continue
            }

            let batch = Batch(
                artifacts: artifacts,
                reason: pending.batch.reason,
                asker: pending.batch.asker
            )
            isPresenting = true
            pending.present(batch) { [weak self] result in
                self?.record(result, for: batch)
            }
            return
        }
    }

    private func record(_ result: SheetResult, for batch: Batch) {
        switch result {
        case .approved(let removals):
            let removed = Dictionary(
                removals.map { ($0.path, $0.byteCount) },
                uniquingKeysWith: { first, _ in first }
            )
            for artifact in batch.artifacts {
                let path = artifact.url.path
                outcomes[path] = removed[path].map(Outcome.removed) ?? .refused
            }

        case .declined:
            for artifact in batch.artifacts {
                outcomes[artifact.url.path] = .declined
            }

        case .unavailable(let reason):
            for artifact in batch.artifacts {
                unavailable[artifact.url.path] = reason
            }
        }

        claimed.subtract(batch.artifacts.map(\.url.path))
        isPresenting = false

        flushWaiters()
        presentNextIfIdle()
    }

    /// Answers every proposal whose paths have all been settled — decided, or reported as
    /// unaskable by the batch that has just come back.
    private func flushWaiters() {
        let ready = waiters.filter { waiter in
            waiter.candidates.allSatisfy { outcomes[$0] != nil || unavailable[$0] != nil }
        }
        guard !ready.isEmpty else { return }

        let readyIdentities = Set(ready.map(ObjectIdentifier.init))
        waiters.removeAll { readyIdentities.contains(ObjectIdentifier($0)) }

        for waiter in ready {
            var removed: [Removal] = []
            var refused: [String] = []
            var declined: [String] = []
            var couldNotAsk: [String] = []
            var reason: String?

            for path in waiter.candidates {
                switch outcomes[path] {
                case .removed(let bytes): removed.append(Removal(path: path, byteCount: bytes))
                case .refused: refused.append(path)
                case .declined: declined.append(path)
                case nil:
                    couldNotAsk.append(path)
                    reason = reason ?? unavailable[path]
                }
            }

            waiter.completion(Answer(
                askedTheUser: couldNotAsk.count < waiter.candidates.count,
                removed: removed,
                refused: refused,
                declined: declined,
                alreadyRemoved: waiter.alreadyRemoved,
                declinedEarlier: waiter.declinedEarlier,
                unknown: waiter.unknown,
                couldNotAsk: couldNotAsk,
                couldNotAskReason: reason
            ))
        }
    }

    // MARK: - Private Types

    private struct PendingBatch {
        let batch: Batch
        let present: Presenting
    }

    /// One proposal waiting for the paths it named to be decided.
    ///
    /// A class so the flush can tell two waiters apart by identity: two sessions proposing the
    /// same directories produce two waiters that are equal in every field.
    private final class Waiter {
        let candidates: [String]
        let alreadyRemoved: [Removal]
        let declinedEarlier: [String]
        let unknown: [String]
        let completion: @MainActor (Answer) -> Void

        init(
            candidates: [String],
            alreadyRemoved: [Removal],
            declinedEarlier: [String],
            unknown: [String],
            completion: @escaping @MainActor (Answer) -> Void
        ) {
            self.candidates = candidates
            self.alreadyRemoved = alreadyRemoved
            self.declinedEarlier = declinedEarlier
            self.unknown = unknown
            self.completion = completion
        }
    }
}
