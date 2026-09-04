import Foundation

struct SessionCheckoutDidMove: AppEvent {
    static let name = Notification.Name("sessionCheckoutDidMove")
    let sessionID: SessionID
    let projectID: ProjectID
    /// Why ownership moved, because the answer decides whether the runtime has to be replaced.
    ///
    /// A move the user or the agent *asked* for leaves the process running in the checkout it was
    /// launched in, so it has to be replaced to reach the new one. An `observedExecution` move is
    /// the opposite by construction: ownership is following a process that is **already** there,
    /// and replacing it would kill a working agent to put it back where it already is.
    let authorityBasis: SessionCheckoutAuthorityBasis
}

/// Bounds on how often ownership may follow an observation.
enum SessionCheckoutDefaults {

    /// How long after arriving somewhere a session refuses to be observed back out of it.
    ///
    /// Ownership following execution is a feedback loop: committing a move changes what the next
    /// observation is measured against, and `SessionExecutionLocusTracker.forget` deliberately
    /// clears the memo that would otherwise suppress a repeat. When an agent's own root and its
    /// tool descendants genuinely sit in different checkouts the two signals disagree forever, and
    /// without hysteresis ownership oscillates between them — measured at 88 committed moves in
    /// 4m34s on a real machine. There is no "correct" checkout to pick in that situation; there is
    /// only picking one and staying, which is what a dwell expresses.
    static let reversalDwell: TimeInterval = 60

    /// The window the ceiling below is counted over.
    ///
    /// Half an hour rather than a few minutes, and the two constants have to be read together:
    /// the dwell already caps a straight reversal at one move a minute, so a window short enough
    /// to expire between damped moves would make the ceiling unreachable for the very pattern it
    /// exists to catch. At these numbers a damped oscillation still trips it inside ten minutes,
    /// while an agent legitimately walking a few worktrees does not.
    static let observedMoveWindow: TimeInterval = 1800

    /// How many observed moves one session may commit inside `observedMoveWindow` before
    /// Threading stops following its execution for the rest of the run.
    ///
    /// The dwell above stops the oscillation we found; this stops the one we did not — it is
    /// reason-neutral, so a pattern nobody predicted (three checkouts in a cycle, two signals
    /// disagreeing in a shape the dwell does not name) still terminates. A session that keeps
    /// moving despite the dwell is reporting something Threading does not model, and guessing at
    /// it repeatedly is worse than stopping once and saying so.
    static let observedMoveCeiling = 6
}

enum SessionCheckoutValidationFailure: Error, Equatable, LocalizedError {
    case sessionUnavailable
    case sourceNotCheckout
    case pathMustBeAbsolute
    case targetMissing
    case targetNotDirectory
    case targetNotCheckoutRoot
    case targetNotCheckout
    case detachedHead
    case differentRepository
    case managedWorkspace
    case checkoutChanged

    var errorDescription: String? {
        switch self {
        case .sessionUnavailable: return "This chat is no longer available."
        case .sourceNotCheckout: return "The chat does not currently belong to a Git checkout."
        case .pathMustBeAbsolute: return "The checkout path must be absolute."
        case .targetMissing: return "The target checkout no longer exists."
        case .targetNotDirectory: return "The target checkout path is not a directory."
        case .targetNotCheckoutRoot: return "Choose the root of an existing Git checkout."
        case .targetNotCheckout: return "The target is not a Git checkout."
        case .detachedHead: return "A detached checkout cannot own a chat."
        case .differentRepository: return "A chat can move only between checkouts of one repository."
        case .managedWorkspace: return "Threading-managed temporary workspaces cannot own moved chats."
        case .checkoutChanged: return "The target checkout changed after the move was requested."
        }
    }
}

struct ValidatedSessionCheckout: Equatable, Sendable {
    let path: String
    let repositoryIdentity: String
    let worktreeIdentity: String
    let branch: String
}

enum SessionCheckoutMoveRequestResult: Equatable {
    case queued(PendingCheckoutMove)
    case approvalRequired(PendingCheckoutMove)
    case denied
    case failed(String)
}

/// One authority for validating, fencing and committing checkout ownership changes.
@MainActor
final class SessionCheckoutCoordinator {
    static let shared = SessionCheckoutCoordinator()

    private let projects: ProjectStore
    private let fileManager: FileManager
    private let hasTurnInFlight: @MainActor (SessionID) -> Bool
    private let now: @MainActor () -> Date
    private var inputFences: Set<SessionID> = []

    /// The worktree each session most recently *left*, and when — the dwell's whole memory.
    ///
    /// Kept here rather than on `SessionExecutionLocusTracker` on purpose: the tracker's memory is
    /// wiped by `forget` at every commit, which is correct for *classification* (the reading is
    /// measured against ownership that just changed) and exactly wrong for *damping*, which needs
    /// to remember the very commit that the wipe is reacting to.
    private var departures: [SessionID: (worktreeIdentity: String, at: Date)] = [:]

    /// Commit times of observed moves, newest last, trimmed to `observedMoveWindow` on each read.
    private var observedMoveHistory: [SessionID: [Date]] = [:]

    /// Sessions whose execution Threading has stopped following for the rest of this run.
    private var abandonedFollowing: Set<SessionID> = []

    /// The worktree a settling move is leaving, captured before the store transaction replaces it.
    private var departingIdentities: [SessionID: String] = [:]

    init(
        projects: ProjectStore = .shared,
        runtime: AgentRuntime = .shared,
        fileManager: FileManager = .default,
        hasTurnInFlight: (@MainActor (SessionID) -> Bool)? = nil,
        now: @escaping @MainActor () -> Date = Date.init
    ) {
        self.projects = projects
        self.fileManager = fileManager
        self.now = now
        self.hasTurnInFlight = hasTurnInFlight ?? { sessionID in
            runtime.activity(sessionID: sessionID).hasTurnInFlight
        }
    }

    func validate(
        checkoutPath: String,
        forSessionID sessionID: SessionID
    ) -> Result<ValidatedSessionCheckout, SessionCheckoutValidationFailure> {
        guard checkoutPath.hasPrefix("/") else { return .failure(.pathMustBeAbsolute) }
        guard let sourceProject = projects.project(forSessionID: sessionID),
              let session = projects.session(withID: sessionID) else {
            return .failure(.sessionUnavailable)
        }
        guard session.managedWorkspace == nil else { return .failure(.managedWorkspace) }
        let canonicalSourcePath = URL(fileURLWithPath: sourceProject.folderPath, isDirectory: true)
            .standardizedFileURL.resolvingSymlinksInPath().path
        guard let source = GitInfo.worktreeLocation(for: canonicalSourcePath) else {
            return .failure(.sourceNotCheckout)
        }

        let requested = URL(fileURLWithPath: checkoutPath, isDirectory: true)
            .standardizedFileURL.resolvingSymlinksInPath()
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: requested.path, isDirectory: &isDirectory) else {
            return .failure(.targetMissing)
        }
        guard isDirectory.boolValue else { return .failure(.targetNotDirectory) }
        guard let target = GitInfo.worktreeLocation(for: requested.path) else {
            return .failure(.targetNotCheckout)
        }
        guard target.root.standardizedFileURL.resolvingSymlinksInPath().path == requested.path else {
            return .failure(.targetNotCheckoutRoot)
        }
        guard target.repositoryIdentity == source.repositoryIdentity else {
            return .failure(.differentRepository)
        }
        guard !isManagedWorkspace(target.root) else { return .failure(.managedWorkspace) }
        guard let branch = GitInfo.currentBranch(for: target.root.path) else {
            return .failure(.detachedHead)
        }
        return .success(ValidatedSessionCheckout(
            path: target.root.standardizedFileURL.resolvingSymlinksInPath().path,
            repositoryIdentity: target.repositoryIdentity,
            worktreeIdentity: target.worktreeIdentity,
            branch: branch
        ))
    }

    func requestMove(
        sessionID: SessionID,
        checkoutPath: String,
        authorityBasis: SessionCheckoutAuthorityBasis,
        reason: String,
        policy: SessionCheckoutAuthorityPolicy = AppSettings.shared.sessionCheckoutAuthorityPolicy,
        approval: Bool? = nil,
        waitForCurrentTurnBoundary: Bool = false
    ) -> SessionCheckoutMoveRequestResult {
        switch validate(checkoutPath: checkoutPath, forSessionID: sessionID) {
        case .failure(let failure):
            return .failed(failure.localizedDescription)
        case .success(let checkout):
            let pending = PendingCheckoutMove(
                checkoutPath: checkout.path,
                repositoryIdentity: checkout.repositoryIdentity,
                worktreeIdentity: checkout.worktreeIdentity,
                authorityBasis: authorityBasis,
                reason: String(reason.prefix(2_000)),
                requestedAt: Date()
            )
            if Self.requiresApproval(
                policy: policy,
                authorityBasis: authorityBasis
            ) {
                guard let approval else { return .approvalRequired(pending) }
                guard approval else {
                    recordAudit("Checkout move denied", sessionID: sessionID, pending: pending)
                    return .denied
                }
            }
            guard projects.setPendingCheckoutMove(pending, forSessionID: sessionID) else {
                return .failed("The checkout move could not be saved.")
            }
            inputFences.insert(sessionID)
            recordAudit("Checkout move queued", sessionID: sessionID, pending: pending)
            if !waitForCurrentTurnBoundary, !hasTurnInFlight(sessionID) {
                finishPendingMove(sessionID: sessionID) { _ in }
            }
            return .queued(pending)
        }
    }

    /// Reconciles one observed drift into checkout ownership.
    ///
    /// The whole of the decision is delegated to `requestMove`, which is the point: an observed
    /// move is validated, fenced, transcript-copied, committed and audited by exactly the same
    /// path as one an agent asks for, and differs only in the basis it records and in what the
    /// policy will grant that basis. A separate route would be a second way to change durable
    /// ownership, which is the thing this type exists to prevent.
    ///
    /// The turn boundary is left to `requestMove`'s own reading rather than forced. An
    /// observation raised by a mid-turn hook finds a turn in flight and is fenced until Stop; one
    /// raised by the Stop hook itself finds none and settles at once, which matters because that
    /// event's own checkout fence has already run by the time the report is relayed.
    @discardableResult
    func reconcileObservedExecution(
        sessionID: SessionID,
        checkout: ObservedCheckout,
        policy: SessionCheckoutAuthorityPolicy = AppSettings.shared.sessionCheckoutAuthorityPolicy
    ) -> SessionCheckoutMoveRequestResult {
        // A queued move is already the answer to this question, and re-asking it every time
        // another tool call reports the same directory would rewrite the pending record and
        // restart its fence for no change.
        if let pending = projects.session(withID: sessionID)?.pendingCheckoutMove {
            return .queued(pending)
        }

        // Both guards below are deliberately *only* on this entry point. A move the user or the
        // agent asked for is an instruction and is never rate-limited; these damp a signal
        // Threading is inferring on its own.
        if abandonedFollowing.contains(sessionID) { return .denied }

        // Going straight back where we just came from is the oscillation's whole shape, and it is
        // never information: the reading that produced it was taken against ownership that has
        // since changed. A move onwards to a *third* checkout is left alone, because that is an
        // agent genuinely walking the tree rather than two signals disagreeing.
        if let departure = departures[sessionID],
           departure.worktreeIdentity == checkout.worktreeIdentity,
           now().timeIntervalSince(departure.at) < SessionCheckoutDefaults.reversalDwell {
            return .denied
        }

        return requestMove(
            sessionID: sessionID,
            checkoutPath: checkout.root,
            authorityBasis: .observedExecution,
            reason: "Observed running in \(checkout.displayName)",
            policy: policy
        )
    }

    @discardableResult
    func cancelPendingMove(sessionID: SessionID) -> Bool {
        guard let pending = projects.session(withID: sessionID)?.pendingCheckoutMove else {
            return true
        }
        guard projects.setPendingCheckoutMove(nil, forSessionID: sessionID) else { return false }
        inputFences.remove(sessionID)
        recordAudit("Checkout move cancelled", sessionID: sessionID, pending: pending)
        return true
    }

    /// Replays durable fences before ordinary launch restoration can resume their old runtime.
    /// The list is captured once and settled serially: each move may rewrite the project graph,
    /// and an unbounded fan-out of transcript copies is the wrong launch-time scaling shape.
    func resumePendingMovesAtLaunch(
        completion: @escaping @MainActor @Sendable () -> Void = {}
    ) {
        let pendingIDs = Array(projects.projects.lazy.flatMap(\.sessions).compactMap { session in
            session.pendingCheckoutMove == nil ? nil : session.id
        })
        func settle(_ remaining: ArraySlice<SessionID>) {
            guard let sessionID = remaining.first else {
                completion()
                return
            }
            finishPendingMove(sessionID: sessionID) { _ in
                settle(remaining.dropFirst())
            }
        }
        settle(pendingIDs[...])
    }

    /// Runs at the authoritative after-checkpoint fence. Completion is the outbox release.
    func finishPendingMove(
        sessionID: SessionID,
        completion: @escaping @MainActor @Sendable (Bool) -> Void
    ) {
        guard let session = projects.session(withID: sessionID),
              let pending = session.pendingCheckoutMove else {
            completion(true)
            return
        }
        inputFences.insert(sessionID)
        let validated: ValidatedSessionCheckout
        switch validate(checkoutPath: pending.checkoutPath, forSessionID: sessionID) {
        case .failure(let failure):
            _ = projects.setPendingCheckoutMove(nil, forSessionID: sessionID)
            inputFences.remove(sessionID)
            recordAudit("Checkout move failed", sessionID: sessionID, pending: pending, detail: failure.localizedDescription)
            completion(false)
            return
        case .success(let checkout):
            guard checkout.repositoryIdentity == pending.repositoryIdentity,
                  checkout.worktreeIdentity == pending.worktreeIdentity else {
                _ = projects.setPendingCheckoutMove(nil, forSessionID: sessionID)
                inputFences.remove(sessionID)
                recordAudit("Checkout move failed", sessionID: sessionID, pending: pending, detail: SessionCheckoutValidationFailure.checkoutChanged.localizedDescription)
                completion(false)
                return
            }
            validated = checkout
        }

        // Read before the store moves the session: afterwards the project this session points at
        // *is* the destination, and the checkout it left is unrecoverable from the graph.
        departingIdentities[sessionID] = currentWorktreeIdentity(forSessionID: sessionID)

        let movingIDs = dependencyClosure(for: sessionID)
        if allSessions(movingIDs, belongTo: validated) {
            completeStoreMove(
                sessionIDs: movingIDs,
                checkout: validated,
                pending: pending,
                completion: completion
            )
            return
        }
        let transcriptPairs = claudeTranscriptPairs(
            sessionIDs: movingIDs,
            destinationPath: validated.path
        )
        guard !transcriptPairs.isEmpty else {
            completeStoreMove(
                sessionIDs: movingIDs,
                checkout: validated,
                pending: pending,
                completion: completion
            )
            return
        }

        DispatchQueue.global(qos: .utility).async { [weak self] in
            do {
                let prepared = try CheckoutTranscriptCopyTransaction.prepare(
                    transcriptPairs,
                    fileManager: FileManager.default
                )
                DispatchQueue.main.async { [weak self] in
                    guard let self else { completion(false); return }
                    do {
                        let commitCheckout = try self.revalidatedCheckout(
                            pending,
                            sessionID: sessionID
                        )
                        var storeResult: SessionCheckoutStoreMoveResult?
                        _ = try prepared.install {
                            let result = self.moveInStore(
                                sessionIDs: movingIDs,
                                checkout: commitCheckout
                            )
                            storeResult = result
                            return result.didPersist
                        }
                        guard let storeResult else {
                            throw CheckoutTranscriptCopyError.commitRefused
                        }
                        self.complete(
                            storeResult,
                            sessionIDs: movingIDs,
                            checkout: commitCheckout,
                            pending: pending,
                            completion: completion
                        )
                    } catch {
                        self.recordAudit(
                            "Checkout move failed",
                            sessionID: sessionID,
                            pending: pending,
                            detail: error.localizedDescription
                        )
                        self.inputFences.remove(sessionID)
                        completion(false)
                    }
                }
            } catch {
                DispatchQueue.main.async { [weak self] in
                    self?.recordAudit(
                        "Checkout move failed",
                        sessionID: sessionID,
                        pending: pending,
                        detail: error.localizedDescription
                    )
                    self?.inputFences.remove(sessionID)
                    completion(false)
                }
            }
        }
    }

    /// Whether one request needs a human answer before it may change durable ownership.
    ///
    /// Observed execution is a fact the host measured rather than a model's request. Under the
    /// default policy it therefore follows the same-repository work automatically; treating it
    /// like `agentInitiated` made an accurately detected worktree merely produce another prompt
    /// while the sidebar and Review stayed wrong. Validation still confines the move to an
    /// existing attached worktree of the same repository, and the turn fence still waits until
    /// the work that supplied the evidence has finished.
    ///
    /// `alwaysAsk` still asks. It is the answer of someone who has said they want to be asked
    /// about every one of these, and a repair is still a change of ownership.
    static func requiresApproval(
        policy: SessionCheckoutAuthorityPolicy,
        authorityBasis: SessionCheckoutAuthorityBasis
    ) -> Bool {
        switch policy {
        case .alwaysAsk: return true
        case .allowExplicitRequests:
            switch authorityBasis {
            case .explicitUserRequest: return false
            case .agentInitiated: return true
            case .observedExecution: return false
            }
        case .allowSameRepository: return false
        }
    }

    private func completeStoreMove(
        sessionIDs: [SessionID],
        checkout: ValidatedSessionCheckout,
        pending: PendingCheckoutMove,
        completion: @escaping @MainActor @Sendable (Bool) -> Void
    ) {
        complete(
            moveInStore(sessionIDs: sessionIDs, checkout: checkout),
            sessionIDs: sessionIDs,
            checkout: checkout,
            pending: pending,
            completion: completion
        )
    }

    /// Transcript preparation can take long enough for Git's worktree registration or HEAD to
    /// change. Re-read both identities and the display branch at the actual commit boundary.
    private func revalidatedCheckout(
        _ pending: PendingCheckoutMove,
        sessionID: SessionID
    ) throws -> ValidatedSessionCheckout {
        let checkout = try validate(
            checkoutPath: pending.checkoutPath,
            forSessionID: sessionID
        ).get()
        guard checkout.repositoryIdentity == pending.repositoryIdentity,
              checkout.worktreeIdentity == pending.worktreeIdentity else {
            throw SessionCheckoutValidationFailure.checkoutChanged
        }
        return checkout
    }

    private func moveInStore(
        sessionIDs: [SessionID],
        checkout: ValidatedSessionCheckout
    ) -> SessionCheckoutStoreMoveResult {
        projects.moveSessionsToCheckout(
            sessionIDs,
            checkoutPath: checkout.path,
            repositoryIdentity: checkout.repositoryIdentity,
            worktreeIdentity: checkout.worktreeIdentity,
            branch: checkout.branch
        )
    }

    private func complete(
        _ result: SessionCheckoutStoreMoveResult,
        sessionIDs: [SessionID],
        checkout: ValidatedSessionCheckout,
        pending: PendingCheckoutMove,
        completion: @escaping @MainActor @Sendable (Bool) -> Void
    ) {
        switch result {
        case .moved:
            publishMove(sessionIDs: sessionIDs, checkout: checkout, pending: pending)
            completion(true)
        case .unchanged:
            recordAudit("Checkout move already current", sessionID: sessionIDs[0], pending: pending)
            inputFences.remove(sessionIDs[0])
            completion(true)
        case .sessionNotFound, .persistenceRefused:
            recordAudit(
                "Checkout move failed",
                sessionID: sessionIDs[0],
                pending: pending,
                detail: "The checkout ownership transaction was refused."
            )
            inputFences.remove(sessionIDs[0])
            completion(false)
        }
    }

    private func publishMove(
        sessionIDs: [SessionID],
        checkout: ValidatedSessionCheckout,
        pending: PendingCheckoutMove
    ) {
        GitTurnBaselineStore.shared.markLatestTurnCheckoutChanged(sessionID: sessionIDs[0])
        GitInfo.invalidateCache(for: checkout.path)
        for id in sessionIDs {
            projects.refreshBranch(forSessionID: id)
            // Every stored observation is stale the instant ownership moves: the directory the
            // agent reported has not changed, but what it is measured against has. Left alone,
            // a chat that just arrived where it was already working would go on being marked as
            // working somewhere else until its next turn produced a fresh report.
            SessionExecutionLocusTracker.shared.forget(sessionID: id)
        }
        recordDeparture(sessionIDs[0], pending: pending)

        // The source may now be a row Threading adopted for an earlier move and that nothing is
        // left in. Taking it back here rather than inside the store transaction is deliberate:
        // this is ordinary project removal and wants `removeProject`'s auxiliary cleanup — the
        // icon file, drafts, scheduled work, the audit — rather than a second, thinner copy of it
        // inlined into a session-graph transaction.
        projects.reclaimAdoptedEmptyProjects()

        if let projectID = projects.project(forSessionID: sessionIDs[0])?.id {
            let event = SessionCheckoutDidMove(
                sessionID: sessionIDs[0],
                projectID: projectID,
                authorityBasis: pending.authorityBasis
            )
            DispatchQueue.main.async { NotificationCenter.default.post(event) }
        }
        recordAudit("Checkout move committed", sessionID: sessionIDs[0], pending: pending)
    }

    private func allSessions(
        _ sessionIDs: [SessionID],
        belongTo checkout: ValidatedSessionCheckout
    ) -> Bool {
        sessionIDs.allSatisfy { id in
            guard let project = projects.project(forSessionID: id) else {
                return false
            }
            let canonicalPath = URL(fileURLWithPath: project.folderPath, isDirectory: true)
                .standardizedFileURL.resolvingSymlinksInPath().path
            guard let location = GitInfo.worktreeLocation(for: canonicalPath) else { return false }
            return location.repositoryIdentity == checkout.repositoryIdentity
                && location.worktreeIdentity == checkout.worktreeIdentity
        }
    }

    /// The canonical worktree identity the session stands in right now, or nil when it is not in
    /// a checkout Threading can resolve. Same canonicalisation as `allSessions(_:belongTo:)`.
    private func currentWorktreeIdentity(forSessionID sessionID: SessionID) -> String? {
        guard let project = projects.project(forSessionID: sessionID) else { return nil }
        let canonicalPath = URL(fileURLWithPath: project.folderPath, isDirectory: true)
            .standardizedFileURL.resolvingSymlinksInPath().path
        return GitInfo.worktreeLocation(for: canonicalPath)?.worktreeIdentity
    }

    /// Remembers a committed move so the dwell and the ceiling can see it.
    ///
    /// Only observed moves are counted. An explicit or agent-initiated move is an instruction and
    /// must never spend a budget that would later refuse one — but it *does* record its departure,
    /// because a chat the user moved by hand should not be dragged straight back by a reading
    /// taken before they moved it.
    private func recordDeparture(_ sessionID: SessionID, pending: PendingCheckoutMove) {
        let moment = now()
        if let departed = departingIdentities.removeValue(forKey: sessionID) {
            departures[sessionID] = (worktreeIdentity: departed, at: moment)
        }

        guard pending.authorityBasis == .observedExecution else { return }

        let recent = (observedMoveHistory[sessionID] ?? []).filter {
            moment.timeIntervalSince($0) < SessionCheckoutDefaults.observedMoveWindow
        } + [moment]
        observedMoveHistory[sessionID] = recent

        guard recent.count >= SessionCheckoutDefaults.observedMoveCeiling else { return }
        abandonedFollowing.insert(sessionID)
        observedMoveHistory[sessionID] = nil
        EventLog.shared.record(.session, "Checkout move following abandoned", [
            "session": sessionID.uuidString,
            "moves": String(recent.count),
            "window": String(Int(SessionCheckoutDefaults.observedMoveWindow))
        ])
    }

    /// Whether Threading has stopped following this session's execution after too many moves.
    func hasAbandonedFollowing(sessionID: SessionID) -> Bool {
        abandonedFollowing.contains(sessionID)
    }

    /// Forgets a session's damping state. For tests and for a session leaving the store.
    func forgetMoveHistory(sessionID: SessionID) {
        departures[sessionID] = nil
        observedMoveHistory[sessionID] = nil
        departingIdentities[sessionID] = nil
        abandonedFollowing.remove(sessionID)
    }

    func isHoldingInput(sessionID: SessionID) -> Bool {
        inputFences.contains(sessionID)
            || projects.session(withID: sessionID)?.pendingCheckoutMove != nil
    }

    func runtimeRelaunchDidStart(sessionID: SessionID) {
        inputFences.remove(sessionID)
    }

    private func dependencyClosure(for rootID: SessionID) -> [SessionID] {
        guard let root = projects.session(withID: rootID),
              root.kind.supports(.checkoutScopedConversationStorage),
              !root.hasLaunched else { return [rootID] }
        var result: [SessionID] = []
        var seen: Set<SessionID> = []
        var queue = [rootID]
        while let id = queue.first {
            queue.removeFirst()
            guard seen.insert(id).inserted,
                  let session = projects.session(withID: id),
                  session.kind.supports(.checkoutScopedConversationStorage),
                  !session.hasLaunched else { continue }
            result.append(id)
            if let parent = session.forkedFrom { queue.append(parent) }
            for project in projects.projects {
                queue.append(contentsOf: project.sessions.compactMap { candidate in
                    candidate.forkedFrom == id && !candidate.hasLaunched ? candidate.id : nil
                })
            }
        }
        return result.isEmpty ? [rootID] : result
    }

    private func claudeTranscriptPairs(
        sessionIDs: [SessionID],
        destinationPath: String
    ) -> [CheckoutTranscriptCopyPair] {
        var destinationProject = Project(
            name: GitInfo.suggestedProjectName(for: URL(fileURLWithPath: destinationPath)),
            folderURL: URL(fileURLWithPath: destinationPath, isDirectory: true)
        )
        destinationProject.folderPath = destinationPath
        return sessionIDs.compactMap { id in
            guard let session = projects.session(withID: id),
                  session.kind.supports(.checkoutScopedConversationStorage),
                  let transcriptID = session.resumeState.transcriptID,
                  let sourceProject = projects.executionProject(forSessionID: id),
                  let account = AgentAccountDiscovery.account(
                    for: session.kind,
                    handle: session.accountHandle
                  ),
                  let source = ClaudeTranscript.url(
                    sessionID: transcriptID,
                    account: account,
                    in: sourceProject
                  ),
                  fileManager.fileExists(atPath: source.path),
                  let destination = ClaudeTranscript.url(
                    sessionID: transcriptID,
                    account: account,
                    in: destinationProject
                  ) else { return nil }
            return CheckoutTranscriptCopyPair(
                sourceTranscript: source,
                destinationTranscript: destination,
                sourceSubagents: ClaudeTranscript.subagentsDirectory(
                    sessionID: transcriptID,
                    account: account,
                    in: sourceProject
                ),
                destinationSubagents: ClaudeTranscript.subagentsDirectory(
                    sessionID: transcriptID,
                    account: account,
                    in: destinationProject
                )
            )
        }
    }

    private func isManagedWorkspace(_ root: URL) -> Bool {
        let managed = AppDataLocations.supportDirectory
            .appendingPathComponent("ManagedWorkspaces", isDirectory: true)
            .standardizedFileURL.resolvingSymlinksInPath().path
        let path = root.standardizedFileURL.resolvingSymlinksInPath().path
        if path == managed || path.hasPrefix(managed + "/") { return true }
        return projects.projects.lazy.flatMap(\.sessions).contains { session in
            guard let workspace = session.managedWorkspace else { return false }
            return URL(fileURLWithPath: workspace.worktreeRoot)
                .standardizedFileURL.resolvingSymlinksInPath().path == path
        }
    }

    private func recordAudit(
        _ message: String,
        sessionID: SessionID,
        pending: PendingCheckoutMove,
        detail: String = ""
    ) {
        EventLog.shared.record(.session, message, [
            "session": sessionID.uuidString,
            "checkout": pending.checkoutPath,
            "authority_basis": pending.authorityBasis.rawValue,
            "reason": pending.reason,
            "detail": detail
        ])
    }
}

private extension SessionCheckoutStoreMoveResult {
    var didPersist: Bool {
        switch self {
        case .moved, .unchanged: return true
        case .sessionNotFound, .persistenceRefused: return false
        }
    }
}
