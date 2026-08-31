import Foundation

struct SessionCheckoutDidMove: AppEvent {
    static let name = Notification.Name("sessionCheckoutDidMove")
    let sessionID: SessionID
    let projectID: ProjectID
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
    private var inputFences: Set<SessionID> = []

    init(
        projects: ProjectStore = .shared,
        runtime: AgentRuntime = .shared,
        fileManager: FileManager = .default,
        hasTurnInFlight: (@MainActor (SessionID) -> Bool)? = nil
    ) {
        self.projects = projects
        self.fileManager = fileManager
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
            // Asked only for the basis that can be lowered by it, and only after validation has
            // produced a canonical destination: the answer is about two exact transcript paths,
            // and the reported directory is routinely a subdirectory of the checkout root.
            let repairs = authorityBasis == .observedExecution
                && conversationHasLeftOwnedCheckout(
                    sessionID: sessionID,
                    forDestination: checkout.path
                )
            if Self.requiresApproval(
                policy: policy,
                authorityBasis: authorityBasis,
                repairsDetachedConversation: repairs
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
    /// `repairsDetachedConversation` is the one condition that can *lower* the bar, and only for
    /// `observedExecution`. It means the chat's provider conversation is already filed under the
    /// checkout the agent moved to and is no longer under the one that owns it — so resume is
    /// already broken, the move copies nothing, and refusing to act preserves a defect rather
    /// than preventing one. Everywhere else the bar is unchanged: asking about a move that will
    /// copy a transcript and replace a runtime is exactly what the policy is for.
    ///
    /// `alwaysAsk` still asks. It is the answer of someone who has said they want to be asked
    /// about every one of these, and a repair is still a change of ownership.
    static func requiresApproval(
        policy: SessionCheckoutAuthorityPolicy,
        authorityBasis: SessionCheckoutAuthorityBasis,
        repairsDetachedConversation: Bool = false
    ) -> Bool {
        switch policy {
        case .alwaysAsk: return true
        case .allowExplicitRequests:
            switch authorityBasis {
            case .explicitUserRequest: return false
            case .agentInitiated: return true
            case .observedExecution: return !repairsDetachedConversation
            }
        case .allowSameRepository: return false
        }
    }

    /// Whether the chat's provider conversation has already followed the agent out of the
    /// checkout that owns it, leaving the chat unresumable where Threading would launch it.
    ///
    /// This is a filesystem question and must not be inferred from the reported directory, which
    /// was measured to disagree with it. Two chats of one repository both reported working in a
    /// sibling worktree; one runtime had re-filed its conversation under that worktree's slug
    /// and the other had not, and only reading both paths tells them apart. Where the answer is
    /// true, `AgentLauncher` has already stopped finding the transcript and its `--resume`
    /// branch has already fallen through to minting an empty conversation under the same id.
    ///
    /// False for every runtime whose conversation storage is not checkout-scoped, which is every
    /// runtime but one — they resume by a provider-owned id no directory can invalidate.
    func conversationHasLeftOwnedCheckout(
        sessionID: SessionID,
        forDestination destinationPath: String
    ) -> Bool {
        guard let session = projects.session(withID: sessionID),
              session.kind.supports(.checkoutScopedConversationStorage),
              let transcriptID = session.resumeState.transcriptID,
              let ownedProject = projects.executionProject(forSessionID: sessionID),
              let account = AgentAccountDiscovery.account(
                for: session.kind,
                handle: session.accountHandle
              ),
              let owned = ClaudeTranscript.url(
                sessionID: transcriptID,
                account: account,
                in: ownedProject
              ) else { return false }

        var destinationProject = Project(
            name: GitInfo.suggestedProjectName(for: URL(fileURLWithPath: destinationPath)),
            folderURL: URL(fileURLWithPath: destinationPath, isDirectory: true)
        )
        destinationProject.folderPath = destinationPath
        guard let destination = ClaudeTranscript.url(
            sessionID: transcriptID,
            account: account,
            in: destinationProject
        ) else { return false }

        return Self.conversationHasLeft(
            owned: owned,
            destination: destination,
            fileManager: fileManager
        )
    }

    /// The rule itself, separated from finding the two paths.
    ///
    /// Both halves are load-bearing and neither alone is the condition. *Gone from the owned
    /// checkout* on its own is a chat with no conversation yet, or one whose files a user moved;
    /// *present at the destination* on its own is an unrelated conversation that happens to
    /// share an id, or a copy left by an earlier move. Only both together mean the thing this
    /// answers: the conversation is somewhere else and resume is already broken.
    static func conversationHasLeft(
        owned: URL,
        destination: URL,
        fileManager: FileManager
    ) -> Bool {
        !fileManager.fileExists(atPath: owned.path)
            && fileManager.fileExists(atPath: destination.path)
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
        if let projectID = projects.project(forSessionID: sessionIDs[0])?.id {
            let event = SessionCheckoutDidMove(sessionID: sessionIDs[0], projectID: projectID)
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
