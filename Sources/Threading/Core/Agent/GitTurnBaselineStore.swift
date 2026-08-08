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

    private var lastActivity: [SessionID: SessionActivity] = [:]
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
    func noteActivity(
        _ activity: SessionActivity,
        sessionID: SessionID,
        hasAuthoritativeReporting: Bool = false
    ) {
        let previous = lastActivity[sessionID]
        lastActivity[sessionID] = activity

        if activity == .working, previous != .working {
            // Answering a question resumes the same turn. Re-baselining there would lose the
            // work performed before the question.
            guard previous != .awaitingUser else { return }
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
        if previous?.hasTurnInFlight == true, !activity.hasTurnInFlight {
            if hasAuthoritativeReporting {
                markActiveTurnIncomplete(
                    sessionID: sessionID,
                    message: L10n.string(
                        "The provider process exited before the turn end checkpoint was captured."
                    )
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
        if lastActivity[sessionID] == .awaitingUser {
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
            failureDescription: nil
        )
        archive.checkpoints.append(record)
        preparingCheckpointIDs[sessionID] = checkpointID
        preparationWaiters[checkpointID] = [completion]
        if expectsActivityEdge {
            preparingActivityEdges.insert(sessionID)
            preparedActivityEdges.remove(sessionID)
        }
        let initialMetadataStored = saveAndNotify(sessionID)

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
        completion: @escaping @MainActor (GitTurnCheckpoint?) -> Void
    ) {
        guard let checkpointID = activeCheckpointIDs.removeValue(forKey: sessionID),
              var checkpoint = checkpoint(id: checkpointID) else {
            completion(nil)
            return
        }

        checkpoint.status = .capturingAfter
        checkpoint.finalRequestedAt = Date()
        if let assistantTurnID { checkpoint.assistantTurnID = assistantTurnID }
        if let providerTurnID { checkpoint.providerTurnID = providerTurnID }
        replace(checkpoint)
        guard saveAndNotify(sessionID) else {
            failFinalCapture(
                checkpointID,
                message: L10n.string("Couldn’t persist this turn’s checkpoint metadata."),
                completion: completion
            )
            return
        }

        guard let root = repositoryRoot(for: checkpoint),
              let repositoryIdentity = checkpoint.repositoryIdentity,
              let afterRef = checkpoint.afterRef else {
            failFinalCapture(
                checkpointID,
                message: L10n.string("The checkpoint repository is no longer available."),
                completion: completion
            )
            return
        }

        GitReviewReader.createCheckpointSnapshot(
            ref: afterRef,
            expectedRepositoryIdentity: repositoryIdentity,
            in: root
        ) { [weak self] result in
            guard let self else {
                completion(nil)
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
            completion(completed)
        }
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

    // MARK: - Reads

    func checkpoints(forSessionID sessionID: SessionID) -> [GitTurnCheckpoint] {
        archive.checkpoints
            .filter { $0.sessionID == sessionID && $0.status != .notAdmitted }
            .sorted { $0.ordinal < $1.ordinal }
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
        archive.nextOrdinalBySession.removeValue(forKey: sessionID.uuidString)
        activeCheckpointIDs.removeValue(forKey: sessionID)
        generations[sessionID] = (generations[sessionID] ?? 0) + 1
        cancelPreparation(for: sessionID)
        let ids = archive.checkpoints.filter { $0.sessionID == sessionID }.map(\.id)
        _ = saveAndNotify(sessionID)
        discard(checkpointIDs: ids)
    }

    /// Drops transient state and garbage-collects durable records for sessions that no longer
    /// exist. Archived sessions remain in the supplied set and therefore retain their history.
    func retainOnly(sessionIDs: Set<SessionID>) {
        lastActivity = lastActivity.filter { sessionIDs.contains($0.key) }
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
        let saved = persistence.save(archive)
        NotificationCenter.default.post(GitTurnCheckpointsDidChange(sessionID: sessionID))
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
        for checkpointID in checkpointIDs where !garbageCollectionsInFlight.contains(checkpointID) {
            guard let record = checkpoint(id: checkpointID),
                  activeCheckpointIDs[record.sessionID] != checkpointID else { continue }
            let refs = [record.beforeRef, record.afterRef].compactMap { $0 }
            guard !refs.isEmpty else {
                removeMetadata(checkpointID, sessionID: record.sessionID)
                continue
            }
            guard let repositoryIdentity = record.repositoryIdentity,
                  let root = repositoryRoot(for: record) else {
                ThreadingLogger.git.error(
                    "Keeping checkpoint metadata because its repository is unavailable: \(checkpointID.uuidString, privacy: .public)"
                )
                continue
            }

            garbageCollectionsInFlight.insert(checkpointID)
            GitReviewReader.deleteCheckpointRefs(
                refs,
                expectedRepositoryIdentity: repositoryIdentity,
                in: root
            ) { [weak self] result in
                guard let self else { return }
                self.garbageCollectionsInFlight.remove(checkpointID)
                switch result {
                case .success:
                    self.removeMetadata(checkpointID, sessionID: record.sessionID)
                case .failure(let failure):
                    ThreadingLogger.git.error(
                        "Checkpoint garbage collection failed for \(checkpointID.uuidString, privacy: .public): \(failure.localizedDescription, privacy: .private(mask: .hash))"
                    )
                }
            }
        }
    }

    private func removeMetadata(_ checkpointID: GitTurnCheckpointID, sessionID: SessionID) {
        archive.checkpoints.removeAll { $0.id == checkpointID }
        _ = saveAndNotify(sessionID)
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
            if !admitted {
                store.cancelPreparedTurn(checkpointID, sessionID: sessionID)
            }
            completion(admitted, checkpointID)
        }
    }
}
