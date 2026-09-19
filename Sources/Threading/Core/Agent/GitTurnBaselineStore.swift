import Foundation

// MARK: - Private Ref Namespace

/// The only refs Threading is allowed to create or remove.
///
/// IDs are UUIDs rather than user/provider strings, so ref construction cannot escape the
/// namespace. Every deletion revalidates the full shape instead of trusting persisted text.
enum GitTurnCheckpointRefs {
    static let prefix = "refs/threading/turn-checkpoints/v1/"

    static func pair(
        sessionID: SessionID,
        checkpointID: GitTurnCheckpointID
    ) -> (before: String, after: String) {
        let base = prefix
            + sessionID.uuidString.lowercased() + "/"
            + checkpointID.uuidString.lowercased() + "/"
        return (base + "before", base + "after")
    }

    static func isOwned(_ ref: String) -> Bool {
        guard ref.hasPrefix(prefix) else { return false }
        let tail = ref.dropFirst(prefix.count).split(separator: "/", omittingEmptySubsequences: false)
        guard tail.count == 3,
              UUID(uuidString: String(tail[0])) != nil,
              UUID(uuidString: String(tail[1])) != nil else { return false }
        return tail[2] == "before" || tail[2] == "after"
    }
}

// MARK: - Capture Context

/// The stable checkout facts resolved before admission. Internal so tests can supply isolated
/// repositories without replacing the app-wide `ProjectStore` singleton.
struct GitTurnCaptureContext: Sendable {
    let projectID: ProjectID
    let logicalProjectPath: String
    let root: URL
    let repositoryIdentity: String
    let worktreeIdentity: String
}

// MARK: - Store

/// Owns durable before/end checkpoints for stable session turns.
///
/// Admission still waits for the before tree. Completion now waits for the matching end tree,
/// and both trees are kept alive by refs in `GitTurnCheckpointRefs`. Metadata is a bounded,
/// versioned user-authored store so an unreadable predecessor is quarantined rather than
/// overwritten. All state transitions are main-actor confined; git work runs in
/// `GitReviewReader`'s background queues.
@MainActor
final class GitTurnBaselineStore {

    /// Hosted XCTest bundles run inside the shipping app process. Give that process a durable
    /// store of its own so production-style deletion paths and lifecycle endpoints can be tested
    /// without opening or rewriting the developer's real turn history.
    static let shared: GitTurnBaselineStore = {
        guard NSClassFromString("XCTestCase") == nil else {
            let scratch = FileManager.default.temporaryDirectory.appendingPathComponent(
                "ThreadingTestGitTurnCheckpoints/\(ProcessInfo.processInfo.processIdentifier)",
                isDirectory: true
            )
            return GitTurnBaselineStore(directory: scratch)
        }
        return GitTurnBaselineStore()
    }()

    // MARK: - Properties

    private let persistence: RecoverableFileStore<GitTurnCheckpointArchive>
    private let contextProvider: @MainActor (SessionID) -> GitTurnCaptureContext?
    private let maximumPerSession: Int
    private let maximumTotal: Int
    private var archive: GitTurnCheckpointArchive

    private var lastRuntime: [SessionID: SessionRuntimeSnapshot] = [:]
    private var generations: [SessionID: Int] = [:]
    private var activeCheckpointIDs: [SessionID: GitTurnCheckpointID] = [:]
    private var preparingCheckpointIDs: [SessionID: GitTurnCheckpointID] = [:]
    private var preparationWaiters: [
        GitTurnCheckpointID: [@MainActor (GitTurnCheckpointID?) -> Void]
    ] = [:]
    private var garbageCollectionsInFlight: Set<GitTurnCheckpointID> = []

    /// A prepared native submission or blocking terminal hook is followed by the ordinary
    /// entering-working activity edge. Consume that edge instead of taking a second snapshot.
    private var preparedActivityEdges: Set<SessionID> = []

    /// A terminal can repaint while its blocking turn-start hook is still waiting. If that
    /// output is inferred as the entering-working edge, consume it here; starting a second
    /// capture at that point could move the before tree past the agent's first write.
    private var preparingActivityEdges: Set<SessionID> = []

    // MARK: - Initialization

    init(
        directory: URL? = nil,
        fileManager: FileManager = .default,
        maximumPerSession: Int = GitTurnCheckpointDefaults.maximumPerSession,
        maximumTotal: Int = GitTurnCheckpointDefaults.maximumTotal,
        contextProvider: (@MainActor (SessionID) -> GitTurnCaptureContext?)? = nil
    ) {
        let root = directory ?? fileManager
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(ProjectIconDefaults.applicationDirectoryName)
        persistence = RecoverableFileStore(
            url: root.appendingPathComponent(GitTurnCheckpointDefaults.fileName),
            fileManager: fileManager,
            criticality: .userAuthored,
            // Not `.compactMetadata`: retention keeps up to `maximumTotal` records, and a record
            // carries two checkout paths plus an arbitrary failure description — measured at
            // ~900 bytes each, so a full archive lands within a rounding error of that policy's
            // 1 MB ceiling and the store would start refusing to save the user's turn history.
            sizePolicy: .userDocument,
            dateEncodingStrategy: .iso8601,
            dateDecodingStrategy: .iso8601
        )
        self.maximumPerSession = max(1, maximumPerSession)
        self.maximumTotal = max(1, maximumTotal)
        self.contextProvider = contextProvider ?? { sessionID in
            guard let project = ProjectStore.shared.project(forSessionID: sessionID),
                  let execution = ProjectStore.shared.executionProject(forSessionID: sessionID),
                  let location = GitInfo.worktreeLocation(for: execution.folderPath) else {
                return nil
            }
            return GitTurnCaptureContext(
                projectID: project.id,
                logicalProjectPath: project.folderPath,
                root: location.root,
                repositoryIdentity: location.repositoryIdentity,
                worktreeIdentity: location.worktreeIdentity
            )
        }

        let outcome = persistence.load(defaultValue: GitTurnCheckpointArchive()) { stored in
            try Self.validate(stored)
        }
        archive = outcome.value
        normalizeInterruptedCaptures()
        pruneIfNeeded()
    }

    // MARK: - Admission and Completion

    /// Feed every activity change through here; the store finds fallback edges itself.
    func noteRuntime(_ snapshot: SessionRuntimeSnapshot, sessionID: SessionID) {
        let previous = lastRuntime[sessionID]
        lastRuntime[sessionID] = snapshot
        let transition = SessionRuntimeTransition(
            previous: previous ?? .dormant,
            current: snapshot
        )

        if transition.beganTurn {
            // Answering a question resumes the same turn. Re-baselining there would lose the
            // work performed before the question.
            if preparingActivityEdges.remove(sessionID) != nil { return }
            if preparedActivityEdges.remove(sessionID) != nil { return }

            // Honest fallback for a terminal whose lifecycle hooks are unavailable. It cannot
            // precede the first write, but it is a new record and can never reuse an older turn.
            prepareTurn(sessionID: sessionID, expectsActivityEdge: false) { _ in }
            return
        }

        // A reporting terminal finishes through its blocking hook before the tracker moves. If
        // that hook never arrives, a process exit is evidence of an interrupted boundary, not
        // permission to bless whatever bytes happen to remain as an authoritative turn end.
        if transition.endedTurn {
            if snapshot.reportsOwnTurns {
                markActiveTurnIncomplete(
                    sessionID: sessionID,
                    message: L10n.string(
                        "The provider process exited before the turn end checkpoint was captured."
                    )
                )
                // Transcript recovery and process-exit paths can close a provider-owned turn
                // without traversing the blocking Stop hook. The incomplete checkpoint is the
                // final decision for that turn; checkout settlement must still cross after it.
                SessionCheckoutCoordinator.shared.finishPendingMove(
                    sessionID: sessionID,
                    completion: { _ in }
                )
            } else {
                // A runtime without hooks has no stronger completion signal. Preserve its
                // existing best-effort edge, but never apply it to a reporting session.
                finishTurn(sessionID: sessionID, completion: { _ in })
            }
        }
    }

    /// Establishes a new turn's before checkpoint and releases admission only after publication
    /// succeeded or definitively failed. Failure still releases the provider, but remains a new,
    /// explicit record; an older checkpoint is never allowed to stand in for this turn.
    func prepareTurn(
        sessionID: SessionID,
        userTurnID: String? = nil,
        providerTurnID: String? = nil,
        expectsActivityEdge: Bool = true,
        completion: @escaping @MainActor (GitTurnCheckpointID?) -> Void
    ) {
        // A remote session's turn happens in a checkout on its host. The only checkout here is the
        // Mac folder its project was created from, and snapshotting that would record whatever
        // changed *on this Mac* during the turn — a person's own edits included — as the agent's
        // work, with refs written into a repository the agent never touched. No checkpoint is
        // the truth; Last Turn then says it has none.
        if ProjectStore.shared.sessionRunsOnRemoteHost(sessionID) {
            completion(nil)
            return
        }
        if lastRuntime[sessionID]?.activity == .awaitingUser {
            completion(activeCheckpointIDs[sessionID] ?? preparingCheckpointIDs[sessionID])
            return
        }

        if let preparingID = preparingCheckpointIDs[sessionID],
           let preparing = checkpoint(id: preparingID) {
            let sameProviderTurn = providerTurnID?.isEmpty == false
                && preparing.providerTurnID == providerTurnID
            let sameNativeTurn = providerTurnID == nil
                && userTurnID != nil
                && preparing.userTurnID == userTurnID
            // A blocking hook may retry while its first HTTP request is still waiting. Join the
            // original barrier instead of starting a later snapshot and moving its before edge.
            if sameProviderTurn || sameNativeTurn || (providerTurnID == nil && userTurnID == nil) {
                preparationWaiters[preparingID, default: []].append(completion)
                return
            }
        }

        if let activeID = activeCheckpointIDs[sessionID],
           let active = checkpoint(id: activeID) {
            // A retried provider hook for the same stable turn is idempotent. A genuinely new
            // admission without an end is different evidence: retire the abandoned window
            // explicitly so neither its ref nor identity can be inherited by the newer turn.
            if let providerTurnID,
               !providerTurnID.isEmpty,
               active.providerTurnID == providerTurnID {
                completion(activeID)
                return
            }
            activeCheckpointIDs[sessionID] = nil
            update(activeID) {
                $0.status = .incomplete
                $0.failureDescription = L10n.string(
                    "A newer turn began before this turn’s checkpoint was complete."
                )
                $0.completedAt = Date()
            }
            _ = saveAndNotify(sessionID)
        }

        let generation = (generations[sessionID] ?? 0) + 1
        generations[sessionID] = generation
        let checkpointID = GitTurnCheckpointID()
        let ordinal = nextOrdinal(for: sessionID)
        let context = contextProvider(sessionID)
        let refs = GitTurnCheckpointRefs.pair(
            sessionID: sessionID,
            checkpointID: checkpointID
        )
        let now = Date()
        let project = context == nil
            ? ProjectStore.shared.project(forSessionID: sessionID)
            : nil
        // Contention is observed, never prevented: nothing below waits on another chat and no
        // git work is added. Both sides are stamped at this one moment because a second chat can
        // start *and* finish entirely inside this turn — by the time this turn ends, its record
        // is already out of the in-flight sets and unobservable.
        let contenders = contendingTurns(
            excluding: sessionID,
            worktreeIdentity: context?.worktreeIdentity
        )
        let record = GitTurnCheckpoint(
            id: checkpointID,
            projectID: context?.projectID ?? project?.id,
            sessionID: sessionID,
            ordinal: ordinal,
            userTurnID: userTurnID ?? checkpointID.uuidString,
            assistantTurnID: checkpointID.uuidString,
            providerTurnID: providerTurnID,
            logicalProjectPath: context?.logicalProjectPath ?? project?.folderPath,
            executionCheckoutPath: context?.root.path,
            repositoryIdentity: context?.repositoryIdentity,
            worktreeIdentity: context?.worktreeIdentity,
            beforeRef: context == nil ? nil : refs.before,
            afterRef: context == nil ? nil : refs.after,
            beforeTreeHash: nil,
            afterTreeHash: nil,
            status: .capturingBefore,
            requestedAt: now,
            beforeCapturedAt: nil,
            finalRequestedAt: nil,
            completedAt: nil,
            failureDescription: nil,
            overlappingSessionIDs: Self.mergedOverlap(nil, adding: contenders.map(\.sessionID))
        )
        archive.checkpoints.append(record)
        for contender in contenders {
            update(contender.checkpointID) {
                $0.overlappingSessionIDs = Self.mergedOverlap(
                    $0.overlappingSessionIDs,
                    adding: [sessionID]
                )
            }
        }
        preparingCheckpointIDs[sessionID] = checkpointID
        preparationWaiters[checkpointID] = [completion]
        if expectsActivityEdge {
            preparingActivityEdges.insert(sessionID)
            preparedActivityEdges.remove(sessionID)
        }
        // One write covers both sides of the stamp; each contender's review surface still hears
        // about its own record changing.
        let initialMetadataStored = saveAndNotify(
            Set(contenders.map(\.sessionID)).union([sessionID])
        )

        guard let context else {
            failBeforeCapture(
                checkpointID,
                generation: generation,
                message: L10n.string("The session’s execution checkout is not a git repository."),
                expectsActivityEdge: expectsActivityEdge
            )
            finishPreparation(checkpointID, sessionID: sessionID)
            return
        }
        guard initialMetadataStored else {
            failBeforeCapture(
                checkpointID,
                generation: generation,
                message: L10n.string("Couldn’t persist this turn’s checkpoint metadata."),
                expectsActivityEdge: expectsActivityEdge
            )
            finishPreparation(checkpointID, sessionID: sessionID)
            return
        }

        GitReviewReader.createCheckpointSnapshot(
            ref: refs.before,
            expectedRepositoryIdentity: context.repositoryIdentity,
            in: context.root
        ) { [weak self] result in
            guard let self else {
                completion(checkpointID)
                return
            }
            guard self.generations[sessionID] == generation else {
                self.discard(checkpointIDs: [checkpointID])
                self.finishPreparation(checkpointID, sessionID: sessionID)
                return
            }
            self.finishPreparedActivityEdge(sessionID, expectsActivityEdge: expectsActivityEdge)

            switch result {
            case .success(let baseline):
                self.update(checkpointID) {
                    $0.beforeTreeHash = baseline.treeHash
                    $0.beforeCapturedAt = baseline.capturedAt
                    $0.status = .inProgress
                    $0.failureDescription = nil
                }
                guard self.saveAndNotify(sessionID) else {
                    self.update(checkpointID) {
                        $0.status = .beforeCaptureFailed
                        $0.completedAt = Date()
                        $0.failureDescription = L10n.string(
                            "The turn start was captured, but its metadata could not be persisted."
                        )
                    }
                    NotificationCenter.default.post(
                        GitTurnCheckpointsDidChange(sessionID: sessionID)
                    )
                    self.discardRefOnly(
                        refs.before,
                        repositoryIdentity: context.repositoryIdentity,
                        root: context.root
                    )
                    self.finishPreparation(checkpointID, sessionID: sessionID)
                    return
                }
                self.activeCheckpointIDs[sessionID] = checkpointID

            case .failure(let failure):
                self.update(checkpointID) {
                    $0.status = .beforeCaptureFailed
                    $0.failureDescription = failure.localizedDescription
                    $0.completedAt = Date()
                }
                _ = self.saveAndNotify(sessionID)
                ThreadingLogger.git.error(
                    "Turn checkpoint start failed for \(sessionID, privacy: .public): \(failure.localizedDescription, privacy: .private(mask: .hash))"
                )
            }
            self.pruneIfNeeded()
            self.finishPreparation(checkpointID, sessionID: sessionID)
        }
    }

    /// Captures the active turn's authoritative end. The active identity is consumed before the
    /// async work begins, so duplicate completion signals cannot publish a second end onto the
    /// same or a newer turn.
    func finishTurn(
        sessionID: SessionID,
        assistantTurnID: String? = nil,
        providerTurnID: String? = nil,
        settlePendingCheckoutMove: Bool = true,
        completion: @escaping @MainActor (GitTurnCheckpoint?) -> Void
    ) {
        let release: @MainActor (GitTurnCheckpoint?) -> Void = { checkpoint in
            if settlePendingCheckoutMove {
                SessionCheckoutCoordinator.shared.finishPendingMove(sessionID: sessionID) { _ in
                    completion(checkpoint)
                }
            } else {
                completion(checkpoint)
            }
        }
        guard let checkpointID = activeCheckpointIDs.removeValue(forKey: sessionID),
              var checkpoint = checkpoint(id: checkpointID) else {
            release(nil)
            return
        }

        checkpoint.status = .capturingAfter
        checkpoint.finalRequestedAt = Date()
        if let assistantTurnID { checkpoint.assistantTurnID = assistantTurnID }
        if let providerTurnID { checkpoint.providerTurnID = providerTurnID }
        // A chat that began working after this turn was admitted is contention too, and no
        // stamping happened on this record when it did.
        checkpoint.overlappingSessionIDs = Self.mergedOverlap(
            checkpoint.overlappingSessionIDs,
            adding: contendingTurns(
                excluding: sessionID,
                worktreeIdentity: checkpoint.worktreeIdentity
            ).map(\.sessionID)
        )
        replace(checkpoint)
        guard saveAndNotify(sessionID) else {
            failFinalCapture(
                checkpointID,
                message: L10n.string("Couldn’t persist this turn’s checkpoint metadata."),
                completion: release
            )
            return
        }

        guard let root = repositoryRoot(for: checkpoint),
              let repositoryIdentity = checkpoint.repositoryIdentity,
              let afterRef = checkpoint.afterRef else {
            failFinalCapture(
                checkpointID,
                message: L10n.string("The checkpoint repository is no longer available."),
                completion: release
            )
            return
        }

        GitReviewReader.createCheckpointSnapshot(
            ref: afterRef,
            expectedRepositoryIdentity: repositoryIdentity,
            in: root
        ) { [weak self] result in
            guard let self else {
                release(nil)
                return
            }
            switch result {
            case .success(let final):
                self.update(checkpointID) {
                    $0.afterTreeHash = final.treeHash
                    $0.completedAt = final.capturedAt
                    $0.status = .complete
                    $0.failureDescription = nil
                }
                if !self.saveAndNotify(sessionID) {
                    self.update(checkpointID) {
                        $0.status = .finalCaptureFailed
                        $0.failureDescription = L10n.string(
                            "The turn end was captured, but its metadata could not be persisted."
                        )
                    }
                    NotificationCenter.default.post(
                        GitTurnCheckpointsDidChange(sessionID: sessionID)
                    )
                    self.discardRefOnly(
                        afterRef,
                        repositoryIdentity: repositoryIdentity,
                        root: root
                    )
                }

            case .failure(let failure):
                self.update(checkpointID) {
                    $0.status = .finalCaptureFailed
                    $0.failureDescription = failure.localizedDescription
                    $0.completedAt = Date()
                }
                _ = self.saveAndNotify(sessionID)
                ThreadingLogger.git.error(
                    "Turn checkpoint end failed for \(sessionID, privacy: .public): \(failure.localizedDescription, privacy: .private(mask: .hash))"
                )
            }

            let completed = self.checkpoint(id: checkpointID)
            self.pruneIfNeeded()
            release(completed)
        }
    }

    /// Makes the turn immediately before a checkout ownership change explicitly unavailable.
    /// The tree pair remains retained for bounded cleanup, but no surface may attribute it to a
    /// single checkout after external commands could have crossed the ownership boundary.
    func markLatestTurnCheckoutChanged(sessionID: SessionID) {
        guard let latest = checkpoints(forSessionID: sessionID).last else { return }
        update(latest.id) {
            $0.status = .checkoutChanged
            $0.failureDescription = L10n.string(
                "Last Turn is unavailable because this chat moved to another checkout."
            )
        }
        _ = saveAndNotify(sessionID)
    }

    /// A prepared native transport refused the send. It never became a turn, so it is excluded
    /// from history and its before ref is collected.
    func cancelPreparedTurn(_ checkpointID: GitTurnCheckpointID, sessionID: SessionID) {
        guard let record = checkpoint(id: checkpointID), record.sessionID == sessionID else {
            return
        }
        activeCheckpointIDs[sessionID] = nil
        update(checkpointID) {
            $0.status = .notAdmitted
            $0.failureDescription = L10n.string("The provider did not admit this turn.")
            $0.completedAt = Date()
        }
        if archive.nextOrdinalBySession[sessionID.uuidString] == record.ordinal + 1 {
            archive.nextOrdinalBySession[sessionID.uuidString] = record.ordinal
        }
        _ = saveAndNotify(sessionID)
        discard(checkpointIDs: [checkpointID])
    }

    // MARK: - Claimed Edits

    /// Records the files this session's structured edit tools named inside its open turn.
    ///
    /// Calling with no paths is meaningful: it marks the turn as *tracked*, which is what
    /// separates "this chat's edit tools claimed nothing" from "nobody was watching". A session
    /// whose runtime has no live per-tool feed never calls this and keeps nil.
    ///
    /// Deliberately not persisted per call. A fifty-edit turn would otherwise rewrite the whole
    /// archive fifty times to store advisory metadata; the accumulated claims ride out on the
    /// ordinary completion and failure saves instead. Losing them to a crash costs nothing that
    /// matters, because the same crash leaves the turn incomplete, and an incomplete turn presents
    /// no diff to annotate. Replay and transcript seeding reach this method with no turn in
    /// flight, so the checkpoint binding below is also what keeps historical events out.
    func recordClaimedEdits(sessionID: SessionID, paths: [String]) {
        guard let checkpointID = preparingCheckpointIDs[sessionID]
                ?? activeCheckpointIDs[sessionID],
              let checkoutPath = checkpoint(id: checkpointID)?.executionCheckoutPath else {
            return
        }
        update(checkpointID) { record in
            var claimed = record.claimedEditPaths ?? []
            var overflowed = record.claimedEditsOverflowed ?? false
            for path in paths {
                guard let relative = Self.checkoutRelativePath(path, in: checkoutPath),
                      !claimed.contains(relative) else { continue }
                guard claimed.count < GitTurnCheckpointDefaults.maximumClaimedEditPaths else {
                    overflowed = true
                    break
                }
                claimed.append(relative)
            }
            record.claimedEditPaths = claimed
            record.claimedEditsOverflowed = overflowed
        }
    }

    /// A claim names the file the provider wrote; a diff row names a path relative to the
    /// checkout. Anything that cannot be inside the checkout is dropped rather than stamped: a
    /// claim that no diff row can ever match could only mislead the surface reading it.
    private static func checkoutRelativePath(_ path: String, in checkoutPath: String) -> String? {
        guard !path.isEmpty else { return nil }
        let root = canonicalPath(URL(fileURLWithPath: checkoutPath))
        let candidate = path.hasPrefix("/")
            ? canonicalPath(URL(fileURLWithPath: path))
            : canonicalPath(URL(fileURLWithPath: checkoutPath).appendingPathComponent(path))
        let prefix = root.hasSuffix("/") ? root : root + "/"
        guard candidate.hasPrefix(prefix) else { return nil }
        let relative = String(candidate.dropFirst(prefix.count))
        return relative.isEmpty ? nil : relative
    }

    /// `/var` and `/private/var` name one directory on every Mac, but Foundation strips the
    /// `/private` spelling only when the result already exists — so a file the agent is creating
    /// for the first time would fail to match the checkout it is being created in. Fold both
    /// sides the same way regardless of what is on disk yet.
    private static func canonicalPath(_ url: URL) -> String {
        let resolved = url.standardizedFileURL.resolvingSymlinksInPath().path
        guard resolved.hasPrefix("/private/") else { return resolved }
        return String(resolved.dropFirst("/private".count))
    }

    /// What the chats that contended for this checkout claimed while this turn was open.
    ///
    /// Only turns whose own window overlaps this one count, and only where their claims can be
    /// trusted: an untracked or overflowed contender contributes nothing rather than a partial
    /// list, because absence from a partial list is exactly the inference this must not enable.
    /// Paths are already checkout-relative, so they compare directly — the worktree identity is
    /// checked anyway, since two checkouts of one repository share path spellings but not files.
    ///
    /// One pass over the archive (≤ `maximumTotal` records), no git and no filesystem work, and
    /// resolved once per review load rather than per row.
    func otherChatsClaimedPaths(overlapping checkpoint: GitTurnCheckpoint) -> Set<String> {
        guard let overlapping = checkpoint.overlappingSessionIDs, !overlapping.isEmpty,
              let worktreeIdentity = checkpoint.worktreeIdentity else { return [] }
        let contenders = Set(overlapping)
        var paths: Set<String> = []
        for other in archive.checkpoints
        where contenders.contains(other.sessionID)
            && other.worktreeIdentity == worktreeIdentity
            && other.hasUsableEditClaims
            && Self.windowsOverlap(checkpoint, other) {
            paths.formUnion(other.claimedEditPaths ?? [])
        }
        return paths
    }

    /// A turn with no recorded end has not been observed ending, so it is treated as still open.
    /// Erring towards overlap can only add another chat's claims, and a claim is a positive fact
    /// that stands on its own; erring the other way would silently drop true attribution.
    private static func windowsOverlap(
        _ first: GitTurnCheckpoint,
        _ second: GitTurnCheckpoint
    ) -> Bool {
        first.requestedAt <= (second.completedAt ?? .distantFuture)
            && second.requestedAt <= (first.completedAt ?? .distantFuture)
    }

    // MARK: - Reads

    func checkpoints(forSessionID sessionID: SessionID) -> [GitTurnCheckpoint] {
        archive.checkpoints
            .filter { $0.sessionID == sessionID && $0.status != .notAdmitted }
            .sorted { $0.ordinal < $1.ordinal }
    }

    /// Whether this session has any turn checkpoint at all.
    ///
    /// Separate from `checkpoints(forSessionID:)` because the Activity card asks it on every
    /// refresh — once per tool call during a live turn — and that one sorts a copy of every
    /// retained record to answer a question this settles on the first match.
    func hasCheckpoints(forSessionID sessionID: SessionID) -> Bool {
        archive.checkpoints.contains { $0.sessionID == sessionID && $0.status != .notAdmitted }
    }

    func checkpoint(id: GitTurnCheckpointID) -> GitTurnCheckpoint? {
        archive.checkpoints.first { $0.id == id }
    }

    func latestCheckpoint(forSessionID sessionID: SessionID) -> GitTurnCheckpoint? {
        checkpoints(forSessionID: sessionID).last
    }

    func activeCheckpoint(forSessionID sessionID: SessionID) -> GitTurnCheckpoint? {
        activeCheckpointIDs[sessionID].flatMap(checkpoint(id:))
    }

    func captureFailure(forSessionID sessionID: SessionID) -> GitFailure? {
        guard let failure = latestCheckpoint(forSessionID: sessionID)?.failureDescription else {
            return nil
        }
        return .gitFailed(failure)
    }

    /// Finds any currently accessible checkout of the recorded repository. A managed execution
    /// worktree may have moved or been recreated; immutable tree-to-tree diffs can safely use the
    /// logical project's checkout as long as repository identity still matches.
    func repositoryRoot(
        for checkpoint: GitTurnCheckpoint,
        preferredPath: String? = nil
    ) -> URL? {
        guard let expected = checkpoint.repositoryIdentity else { return nil }
        var candidates = [preferredPath]
        if let execution = ProjectStore.shared.executionProject(forSessionID: checkpoint.sessionID) {
            candidates.append(execution.folderPath)
        }
        candidates.append(checkpoint.executionCheckoutPath)
        candidates.append(checkpoint.logicalProjectPath)

        for candidate in candidates.compactMap({ $0 }) {
            guard let root = GitInfo.repositoryRoot(for: candidate),
                  FileManager.default.fileExists(atPath: root.path),
                  GitInfo.worktreeLocation(for: root.path)?.repositoryIdentity == expected else {
                continue
            }
            return root
        }
        return nil
    }

    // MARK: - Ownership Cleanup

    /// Permanent session/project deletion calls this; Archive/Restore does not. Metadata is kept
    /// until its refs are successfully removed, making a failed cleanup retryable rather than
    /// stranding untracked app-owned refs with no record of their repository.
    func remove(sessionID: SessionID) {
        remove(sessionIDs: [sessionID])
    }

    /// Removes a project's sessions as one metadata mutation. Project deletion used to scan and
    /// rewrite the complete checkpoint archive once per session before its batched ref cleanup
    /// even began, making confirmation time grow as sessions × retained checkpoints.
    func remove(sessionIDs: Set<SessionID>) {
        guard !sessionIDs.isEmpty else { return }
        let span = PerformanceRecorder.shared.begin(
            "sidebar.sessions-remove.git-checkpoints",
            category: "sidebar",
            metadata: ["removed_sessions": String(sessionIDs.count)]
        )
        defer { span.end() }

        for sessionID in sessionIDs {
            archive.nextOrdinalBySession.removeValue(forKey: sessionID.uuidString)
            activeCheckpointIDs.removeValue(forKey: sessionID)
            generations[sessionID] = (generations[sessionID] ?? 0) + 1
            cancelPreparation(for: sessionID)
        }
        let ids = archive.checkpoints
            .filter { sessionIDs.contains($0.sessionID) }
            .map(\.id)
        _ = saveAndNotify(sessionIDs)
        discard(checkpointIDs: ids)
    }

    /// Drops transient state and garbage-collects durable records for sessions that no longer
    /// exist. Archived sessions remain in the supplied set and therefore retain their history.
    func retainOnly(sessionIDs: Set<SessionID>) {
        lastRuntime = lastRuntime.filter { sessionIDs.contains($0.key) }
        generations = generations.filter { sessionIDs.contains($0.key) }
        activeCheckpointIDs = activeCheckpointIDs.filter { sessionIDs.contains($0.key) }
        for sessionID in Array(preparingCheckpointIDs.keys) where !sessionIDs.contains(sessionID) {
            cancelPreparation(for: sessionID)
        }
        preparedActivityEdges.formIntersection(sessionIDs)
        preparingActivityEdges.formIntersection(sessionIDs)

        let removed = archive.checkpoints.filter { !sessionIDs.contains($0.sessionID) }
        for sessionID in Set(removed.map(\.sessionID)) {
            archive.nextOrdinalBySession.removeValue(forKey: sessionID.uuidString)
        }
        if !removed.isEmpty { _ = persistence.save(archive) }
        discard(checkpointIDs: removed.map(\.id))
    }

    /// Reconciles app-owned refs in repositories the project catalog can still reach.
    ///
    /// This closes the retention loop after a metadata file was quarantined or an exit happened
    /// between ref deletion and metadata removal. The namespace listing is filtered to exact
    /// UUID-shaped Threading refs, and the retained set is recomputed after the asynchronous read
    /// so a turn admitted during startup cannot be mistaken for an orphan.
    func garbageCollectOrphanedRefs(in checkouts: [URL]) {
        var repositories: [String: URL] = [:]
        for checkout in checkouts {
            guard let root = GitInfo.repositoryRoot(for: checkout.path),
                  let location = GitInfo.worktreeLocation(for: root.path) else { continue }
            repositories[location.repositoryIdentity] = root
        }

        for (repositoryIdentity, root) in repositories {
            GitReviewReader.checkpointRefs(
                expectedRepositoryIdentity: repositoryIdentity,
                in: root
            ) { [weak self] result in
                guard let self else { return }
                switch result {
                case .success(let refs):
                    let retained = Set(self.archive.checkpoints.flatMap {
                        [$0.beforeRef, $0.afterRef].compactMap { $0 }
                    })
                    let orphaned = refs.filter { !retained.contains($0) }
                    guard !orphaned.isEmpty else { return }
                    GitReviewReader.deleteCheckpointRefs(
                        orphaned,
                        expectedRepositoryIdentity: repositoryIdentity,
                        in: root
                    ) { deletion in
                        if case .failure(let failure) = deletion {
                            ThreadingLogger.git.error(
                                "Orphaned checkpoint ref collection failed: \(failure.localizedDescription, privacy: .private(mask: .hash))"
                            )
                        }
                    }

                case .failure(let failure):
                    ThreadingLogger.git.error(
                        "Checkpoint ref reconciliation failed: \(failure.localizedDescription, privacy: .private(mask: .hash))"
                    )
                }
            }
        }
    }

    // MARK: - Private State

    private func nextOrdinal(for sessionID: SessionID) -> Int {
        let key = sessionID.uuidString
        let ordinal = archive.nextOrdinalBySession[key]
            ?? ((archive.checkpoints.filter { $0.sessionID == sessionID }.map(\.ordinal).max() ?? 0) + 1)
        archive.nextOrdinalBySession[key] = ordinal + 1
        return ordinal
    }

    private func update(
        _ checkpointID: GitTurnCheckpointID,
        _ mutation: (inout GitTurnCheckpoint) -> Void
    ) {
        guard let index = archive.checkpoints.firstIndex(where: { $0.id == checkpointID }) else {
            return
        }
        mutation(&archive.checkpoints[index])
    }

    private func replace(_ checkpoint: GitTurnCheckpoint) {
        guard let index = archive.checkpoints.firstIndex(where: { $0.id == checkpoint.id }) else {
            return
        }
        archive.checkpoints[index] = checkpoint
    }

    @discardableResult
    private func saveAndNotify(_ sessionID: SessionID) -> Bool {
        saveAndNotify([sessionID])
    }

    @discardableResult
    private func saveAndNotify(_ sessionIDs: Set<SessionID>) -> Bool {
        let saved = persistence.save(archive)
        for sessionID in sessionIDs {
            NotificationCenter.default.post(GitTurnCheckpointsDidChange(sessionID: sessionID))
        }
        return saved
    }

    private func finishPreparedActivityEdge(_ sessionID: SessionID, expectsActivityEdge: Bool) {
        guard expectsActivityEdge,
              preparingActivityEdges.remove(sessionID) != nil else { return }
        preparedActivityEdges.insert(sessionID)
    }

    private func finishPreparation(
        _ checkpointID: GitTurnCheckpointID,
        sessionID: SessionID
    ) {
        if preparingCheckpointIDs[sessionID] == checkpointID {
            preparingCheckpointIDs[sessionID] = nil
        }
        let waiters = preparationWaiters.removeValue(forKey: checkpointID) ?? []
        for waiter in waiters { waiter(checkpointID) }
    }

    private func cancelPreparation(for sessionID: SessionID) {
        guard let checkpointID = preparingCheckpointIDs.removeValue(forKey: sessionID) else {
            return
        }
        let waiters = preparationWaiters.removeValue(forKey: checkpointID) ?? []
        for waiter in waiters { waiter(nil) }
    }

    private func failBeforeCapture(
        _ checkpointID: GitTurnCheckpointID,
        generation: Int,
        message: String,
        expectsActivityEdge: Bool
    ) {
        guard let record = checkpoint(id: checkpointID),
              generations[record.sessionID] == generation else { return }
        finishPreparedActivityEdge(record.sessionID, expectsActivityEdge: expectsActivityEdge)
        update(checkpointID) {
            $0.status = .beforeCaptureFailed
            $0.failureDescription = message
            $0.completedAt = Date()
        }
        _ = saveAndNotify(record.sessionID)
        ThreadingLogger.git.error(
            "Turn checkpoint start failed for \(record.sessionID, privacy: .public): \(message, privacy: .private(mask: .hash))"
        )
        pruneIfNeeded()
    }

    private func failFinalCapture(
        _ checkpointID: GitTurnCheckpointID,
        message: String,
        completion: @escaping @MainActor (GitTurnCheckpoint?) -> Void
    ) {
        guard let record = checkpoint(id: checkpointID) else {
            completion(nil)
            return
        }
        update(checkpointID) {
            $0.status = .finalCaptureFailed
            $0.failureDescription = message
            $0.completedAt = Date()
        }
        _ = saveAndNotify(record.sessionID)
        pruneIfNeeded()
        completion(checkpoint(id: checkpointID))
    }

    private func markActiveTurnIncomplete(sessionID: SessionID, message: String) {
        guard let checkpointID = activeCheckpointIDs.removeValue(forKey: sessionID) else {
            return
        }
        update(checkpointID) {
            $0.status = .incomplete
            $0.failureDescription = message
            $0.completedAt = Date()
        }
        _ = saveAndNotify(sessionID)
        pruneIfNeeded()
    }

    private func normalizeInterruptedCaptures() {
        var changedSessions: Set<SessionID> = []
        for index in archive.checkpoints.indices
        where archive.checkpoints[index].status.isTransitional {
            archive.checkpoints[index].status = .incomplete
            archive.checkpoints[index].failureDescription = L10n.string(
                "Threading exited before this turn’s checkpoint was complete."
            )
            archive.checkpoints[index].completedAt = Date()
            changedSessions.insert(archive.checkpoints[index].sessionID)
        }
        guard !changedSessions.isEmpty else { return }
        _ = persistence.save(archive)
        for sessionID in changedSessions {
            NotificationCenter.default.post(GitTurnCheckpointsDidChange(sessionID: sessionID))
        }
    }

    private static func validate(_ archive: GitTurnCheckpointArchive) throws {
        guard archive.schemaVersion == GitTurnCheckpointDefaults.schemaVersion else {
            throw GitTurnCheckpointStoreError.invalidRecord
        }
        var ids: Set<GitTurnCheckpointID> = []
        var ordinals: Set<String> = []
        for checkpoint in archive.checkpoints {
            let ordinalKey = checkpoint.sessionID.uuidString + ":" + String(checkpoint.ordinal)
            guard checkpoint.ordinal > 0,
                  ids.insert(checkpoint.id).inserted,
                  ordinals.insert(ordinalKey).inserted else {
                throw GitTurnCheckpointStoreError.invalidRecord
            }
            let expected = GitTurnCheckpointRefs.pair(
                sessionID: checkpoint.sessionID,
                checkpointID: checkpoint.id
            )
            if let beforeRef = checkpoint.beforeRef, beforeRef != expected.before {
                throw GitTurnCheckpointStoreError.invalidRef(beforeRef)
            }
            if let afterRef = checkpoint.afterRef, afterRef != expected.after {
                throw GitTurnCheckpointStoreError.invalidRef(afterRef)
            }
            if checkpoint.status == .complete {
                guard checkpoint.projectID != nil,
                      checkpoint.repositoryIdentity != nil,
                      checkpoint.worktreeIdentity != nil,
                      checkpoint.beforeRef == expected.before,
                      checkpoint.afterRef == expected.after,
                      checkpoint.beforeTreeHash != nil,
                      checkpoint.afterTreeHash != nil,
                      checkpoint.beforeCapturedAt != nil,
                      checkpoint.finalRequestedAt != nil,
                      checkpoint.completedAt != nil else {
                    throw GitTurnCheckpointStoreError.invalidRecord
                }
            }
        }
        for (key, nextOrdinal) in archive.nextOrdinalBySession {
            guard let sessionID = SessionID(uuidString: key), nextOrdinal > 0 else {
                throw GitTurnCheckpointStoreError.invalidRecord
            }
            // A refused transport briefly persists its record while rolling the ordinal back,
            // so `.notAdmitted` records do not constrain the next usable ordinal.
            let highestCommittedOrdinal = archive.checkpoints
                .filter { $0.sessionID == sessionID && $0.status != .notAdmitted }
                .map(\.ordinal)
                .max() ?? 0
            guard nextOrdinal > highestCommittedOrdinal else {
                throw GitTurnCheckpointStoreError.invalidRecord
            }
        }
    }

    // MARK: - Observed Contention

    /// The other sessions whose turn is plausibly open in the same worktree right now, each with
    /// the record it would be stamped on.
    ///
    /// Bounded by the sessions holding an active or preparing checkpoint — a handful even in a
    /// busy window — and deliberately free of git and filesystem work, because this runs inside
    /// the admission path. A record still mid-capture counts: its turn is in flight by
    /// definition, whatever activity the tracker has published so far.
    private func contendingTurns(
        excluding sessionID: SessionID,
        worktreeIdentity: String?
    ) -> [(sessionID: SessionID, checkpointID: GitTurnCheckpointID)] {
        guard let worktreeIdentity else { return [] }
        var seen: Set<SessionID> = [sessionID]
        var contenders: [(sessionID: SessionID, checkpointID: GitTurnCheckpointID)] = []
        for (otherSessionID, checkpointID) in Array(activeCheckpointIDs)
            + Array(preparingCheckpointIDs) {
            guard !seen.contains(otherSessionID),
                  let record = checkpoint(id: checkpointID),
                  let otherWorktree = record.worktreeIdentity,
                  otherWorktree == worktreeIdentity,
                  lastRuntime[otherSessionID]?.hasOpenTurn == true
                      || record.status.isTransitional else { continue }
            seen.insert(otherSessionID)
            contenders.append((otherSessionID, checkpointID))
        }
        // Dictionary iteration order is not stable across runs; a stamp a person reads and a
        // test asserts should be.
        return contenders.sorted { $0.sessionID.uuidString < $1.sessionID.uuidString }
    }

    /// Union in stable order. A stamp is only ever added to, so the same contender observed at
    /// admission and again at completion stays one entry, and nil keeps meaning "none observed".
    private static func mergedOverlap(
        _ existing: [SessionID]?,
        adding additions: [SessionID]
    ) -> [SessionID]? {
        guard !additions.isEmpty else { return existing }
        var merged = existing ?? []
        for sessionID in additions where !merged.contains(sessionID) {
            merged.append(sessionID)
        }
        return merged.isEmpty ? nil : merged
    }

    // MARK: - Retention and Garbage Collection

    private func pruneIfNeeded() {
        var selected: Set<GitTurnCheckpointID> = Set(
            archive.checkpoints.filter { $0.status == .notAdmitted }.map(\.id)
        )

        let grouped = Dictionary(grouping: archive.checkpoints, by: \.sessionID)
        for records in grouped.values {
            let candidates = records
                .filter { activeCheckpointIDs[$0.sessionID] != $0.id }
                .sorted { $0.requestedAt < $1.requestedAt }
            let overflow = max(records.count - maximumPerSession, 0)
            selected.formUnion(candidates.prefix(overflow).map(\.id))
        }

        let remainingCount = archive.checkpoints.count - selected.count
        if remainingCount > maximumTotal {
            let overflow = remainingCount - maximumTotal
            let candidates = archive.checkpoints
                .filter {
                    !selected.contains($0.id)
                        && activeCheckpointIDs[$0.sessionID] != $0.id
                }
                .sorted { $0.requestedAt < $1.requestedAt }
            selected.formUnion(candidates.prefix(overflow).map(\.id))
        }

        discard(checkpointIDs: Array(selected))
    }

    private func discard(checkpointIDs: [GitTurnCheckpointID]) {
        struct RefBatch {
            let root: URL
            var records: [GitTurnCheckpoint] = []
            var refs: [String] = []
        }

        var metadataOnly: [GitTurnCheckpoint] = []
        var batchesByRepository: [String: RefBatch] = [:]

        for checkpointID in checkpointIDs where !garbageCollectionsInFlight.contains(checkpointID) {
            guard let record = checkpoint(id: checkpointID),
                  activeCheckpointIDs[record.sessionID] != checkpointID else { continue }
            let refs = [record.beforeRef, record.afterRef].compactMap { $0 }
            guard !refs.isEmpty else {
                metadataOnly.append(record)
                continue
            }
            guard let repositoryIdentity = record.repositoryIdentity,
                  let root = repositoryRoot(for: record) else {
                ThreadingLogger.git.error(
                    "Keeping checkpoint metadata because its repository is unavailable: \(checkpointID.uuidString, privacy: .public)"
                )
                continue
            }

            var batch = batchesByRepository[repositoryIdentity] ?? RefBatch(root: root)
            batch.records.append(record)
            batch.refs.append(contentsOf: refs)
            batchesByRepository[repositoryIdentity] = batch
        }

        // Checkpoints that never admitted refs are a metadata edit, not one document rewrite per
        // checkpoint. This path is common when a session is removed while captures are pending.
        if !metadataOnly.isEmpty {
            let ids = Set(metadataOnly.map(\.id))
            archive.checkpoints.removeAll { ids.contains($0.id) }
            _ = saveAndNotify(Set(metadataOnly.map(\.sessionID)))
        }

        // `git update-ref --stdin` already accepts a batch. Grouping by repository turns a
        // 50-turn session deletion from 50 child processes and 50 archive rewrites into one of
        // each, while metadata still remains durable until every owned ref in the batch is gone.
        for (repositoryIdentity, batch) in batchesByRepository {
            let ids = Set(batch.records.map(\.id))
            let sessionIDs = Set(batch.records.map(\.sessionID))
            garbageCollectionsInFlight.formUnion(ids)
            GitReviewReader.deleteCheckpointRefs(
                batch.refs,
                expectedRepositoryIdentity: repositoryIdentity,
                in: batch.root
            ) { [weak self] result in
                guard let self else { return }
                self.garbageCollectionsInFlight.subtract(ids)
                switch result {
                case .success:
                    self.archive.checkpoints.removeAll { ids.contains($0.id) }
                    _ = self.saveAndNotify(sessionIDs)
                case .failure(let failure):
                    ThreadingLogger.git.error(
                        "Checkpoint garbage collection failed for \(ids.count, privacy: .public) records: \(failure.localizedDescription, privacy: .private(mask: .hash))"
                    )
                }
            }
        }
    }

    private func discardRefOnly(
        _ ref: String,
        repositoryIdentity: String,
        root: URL
    ) {
        GitReviewReader.deleteCheckpointRefs(
            [ref],
            expectedRepositoryIdentity: repositoryIdentity,
            in: root
        ) { result in
            if case .failure(let failure) = result {
                ThreadingLogger.git.error(
                    "Checkpoint rollback failed: \(failure.localizedDescription, privacy: .private(mask: .hash))"
                )
            }
        }
    }
}

// MARK: - Stored Shape

struct GitTurnCheckpointArchive: Codable, Equatable {
    var schemaVersion = GitTurnCheckpointDefaults.schemaVersion
    var checkpoints: [GitTurnCheckpoint] = []
    var nextOrdinalBySession: [String: Int] = [:]

    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case checkpoints
        case nextOrdinalBySession
    }

    init() {}

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        // The initial development build wrote this same v1 shape before the explicit version
        // field was added. Treat an absent field as v1; unknown future versions are still
        // rejected by `validate` and quarantined by `RecoverableFileStore`.
        schemaVersion = try container.decodeIfPresent(Int.self, forKey: .schemaVersion)
            ?? GitTurnCheckpointDefaults.schemaVersion
        checkpoints = try container.decodeIfPresent(
            [GitTurnCheckpoint].self,
            forKey: .checkpoints
        ) ?? []
        nextOrdinalBySession = try container.decodeIfPresent(
            [String: Int].self,
            forKey: .nextOrdinalBySession
        ) ?? [:]
    }
}

enum GitTurnCheckpointDefaults {
    static let schemaVersion = 1
    static let fileName = "git-turn-checkpoints.json"
    static let maximumPerSession = 50
    static let maximumTotal = 1_000

    /// A turn's claimed-path list is advisory metadata inside a record that is already capped at
    /// ~900 bytes of prose; a refactoring turn that rewrites more files than this is exactly the
    /// case where per-file attribution stops being worth stating, so it says so instead of
    /// growing.
    static let maximumClaimedEditPaths = 256
}

private enum GitTurnCheckpointStoreError: LocalizedError {
    case invalidRecord
    case invalidRef(String)

    var errorDescription: String? {
        switch self {
        case .invalidRecord:
            return "git turn checkpoint metadata contains an invalid record"
        case .invalidRef(let ref):
            return "git turn checkpoint metadata names a ref outside its recorded turn: \(ref)"
        }
    }
}

// MARK: - Native Admission Gate

/// The one door native transports use to cross the before-checkpoint barrier.
///
/// Keeping the transport call inside this gate makes the ordering executable and directly
/// testable: the provider cannot receive a prompt until `prepareTurn` has either published this
/// turn's exact before ref or persisted an explicit capture failure. A transport refusal then
/// retires that same record rather than leaving a snapshot that looks like an admitted turn.
@MainActor
enum NativeGitTurnAdmission {
    static func admit(
        store: GitTurnBaselineStore = .shared,
        sessionID: SessionID,
        userTurnID: String,
        transport: @escaping @MainActor (GitTurnCheckpointID?) -> Bool,
        completion: @escaping @MainActor (_ admitted: Bool, _ checkpointID: GitTurnCheckpointID?) -> Void
    ) {
        store.prepareTurn(sessionID: sessionID, userTurnID: userTurnID) { checkpointID in
            guard let checkpointID else {
                completion(false, nil)
                return
            }
            let admitted = transport(checkpointID)
            if admitted {
                // Direct sends, provider commands and queue drains share this accepted transport
                // edge. Renderers may echo it afterwards; replay and rejected sends never enter.
                ProjectStore.shared.noteTurnStarted(sessionID: sessionID)
            } else {
                store.cancelPreparedTurn(checkpointID, sessionID: sessionID)
            }
            completion(admitted, checkpointID)
        }
    }
}
