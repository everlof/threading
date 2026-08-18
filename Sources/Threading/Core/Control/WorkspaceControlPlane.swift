import Foundation

// MARK: - Workspace Control Plane

/// Resolves control-contract requests against the session model: who may see which sessions,
/// and who may send what to whom.
///
/// This is deliberately the one place scope is enforced. The MCP tools that call it own wording
/// only; a future CLI, extension binding or remote client calls the same methods and inherits
/// the same refusals, so a rule loosened for one caller cannot silently loosen for the rest.
///
/// Dependencies are injected closures in `SessionArchiveScheduler`'s style: tests drive the
/// plane with fakes and no live agent, window or store. `.live` is assembled once at the
/// application boundary (`AgentToolDependencies`).
@MainActor
final class WorkspaceControlPlane {

    // MARK: - Dependencies

    struct Dependencies {
        /// The session record, wherever it lives — including archived records.
        let session: (SessionID) -> AgentSession?
        /// The project a session belongs to, with its member sessions.
        let projectForSession: (SessionID) -> Project?
        let activity: (SessionID) -> SessionActivity
        /// Which input surface is live for a session right now.
        let surface: (SessionID) -> ControlSessionOverview.Surface
        /// Hands text to a session's live surface. The plane has already decided the send is
        /// permitted; this owns only the mechanics and reports what the surface did — through
        /// a completion, because a terminal delivery's honest answer waits on the target's
        /// own turn-started receipt.
        let deliver: (String, SessionID, @escaping @MainActor (SessionMessageDelivery.Outcome) -> Void) -> Void
        /// Adds text to a session's running turn. Synchronous: a steer is a stream write the
        /// transport accepts or refuses on the spot, and no receipt exists to wait for.
        let steer: (String, SessionID) -> SessionMessageDelivery.SteerOutcome
        /// Arms one watcher's one-shot watch on one target. The plane has already decided the
        /// watch is permitted; the centre owns the edge, the budget and the notice.
        let armWatch: (SessionID, SessionID, TimeInterval?) -> SessionWatchCenter.WatchArmOutcome

        /// Reads and settles only the active native-chat permission card. Evidence has already
        /// passed through the bounded provider-neutral projection before it reaches this plane.
        var pendingPermission: (SessionID) -> ControlPendingPermission? = { _ in nil }
        var resolvePermission: (
            SessionID, String, ControlPermissionDecision, SessionID
        ) -> Bool = { _, _, _, _ in false }

        /// Whether one of the *user's own* limits is holding the target's account, and the
        /// sentence that says so. Nil is the ordinary answer.
        ///
        /// A closure rather than a store read, like every other fact this plane needs: the
        /// admission rules stay a pure function of what it was handed, which is what lets the
        /// refusal matrix be a table test rather than a fixture with a preferences suite in it.
        var heldByOwnLimit: (SessionID) -> String? = { _ in nil }

        /// Stored grants only. The plane adds the implicit regular-session grants itself so an
        /// absent or unreadable store reproduces slice one's behavior exactly and never grants
        /// more authority by failing open.
        var grants: (ControlActor) -> [ControlGrant] = { _ in [] }
        var allProjects: () -> [Project] = { [] }
        var supervisionOverview: (SessionID) -> ControlSupervisionOverview = { _ in
            ControlSupervisionOverview(managedBy: nil, children: [], brief: nil, lastEvent: nil)
        }
        var adopt: (SessionID, SessionID, String) -> ControlSupervisionMutationOutcome = {
            _, _, _ in .refused(.deliveryFailed)
        }
        var release: (SessionID, SessionID, String?) -> ControlSupervisionMutationOutcome = {
            _, _, _ in .refused(.deliveryFailed)
        }
        var requestArchive: (SessionID, String?) -> SessionArchiveRequestOutcome = {
            _, _ in .refused("Archiving is unavailable.")
        }
        var requestManagerArchive: (SessionID, String?, SessionID) -> SessionArchiveRequestOutcome = {
            _, _, _ in .refused("Archiving is unavailable.")
        }
        var cancelArchive: (SessionID) -> SessionArchiveCancellation = { _ in .nothingPending }
        var rename: (SessionID, String) -> AgentTitleMutationResult = { _, _ in .persistenceRefused }
        /// Returns the user's own sentence when a grant ceiling currently bars new spend.
        var ceilingRefusal: (SpendCeiling, AgentSession) -> String? = { _, _ in nil }
        var accountMoveCount: (SessionID, SessionID, Date) -> Int = { _, _, _ in 0 }
    }

    private let dependencies: Dependencies
    private var recentSends: [SessionID: [Date]] = [:]

    init(dependencies: Dependencies) {
        self.dependencies = dependencies
    }

    static let live = WorkspaceControlPlane(
        dependencies: Dependencies(
            session: { ProjectStore.shared.session(withID: $0) },
            projectForSession: { ProjectStore.shared.project(forSessionID: $0) },
            activity: { AgentRuntime.shared.activity(sessionID: $0) },
            surface: { SessionMessageDelivery.surface(for: $0) },
            deliver: { SessionMessageDelivery.deliver($0, to: $1, completion: $2) },
            steer: { SessionMessageDelivery.steer($0, to: $1) },
            armWatch: {
                SessionWatchCenter.shared.arm(watcher: $0, target: $1, timeout: $2)
            },
            pendingPermission: {
                AgentRuntime.shared.pendingControlPermission(sessionID: $0)
            },
            resolvePermission: { targetID, requestID, decision, managerID in
                AgentRuntime.shared.resolveManagerPermission(
                    sessionID: targetID,
                    id: requestID,
                    decision: decision,
                    managerID: managerID
                )
            },
            heldByOwnLimit: { sessionID in
                guard let session = ProjectStore.shared.session(withID: sessionID),
                      let account = AgentAccountDiscovery.account(
                          for: session.kind,
                          handle: session.accountHandle
                      ) else { return nil }
                let hold = CustomLimitBounds.hold(
                    on: AccountUsageService.shared.usage(for: account),
                    in: CustomLimitSettings.shared.rules(for: account.id)
                )
                guard hold.isHolding else { return nil }
                return CustomLimitReceipt.holdReason(hold)
            },
            grants: {
                // The Tools switch is a true global master: grants remain durable and visible,
                // but the plane ignores them on every admission while Supervision is off.
                guard MCPToolCatalog.isEnabled(MCPToolCatalog.supervision) else { return [] }
                return ControlGrantStore.shared.storedGrants(for: $0)
            },
            allProjects: { ProjectStore.shared.projects },
            supervisionOverview: { ControlGrantStore.shared.overview(for: $0) },
            adopt: { childID, managerID, brief in
                ControlGrantStore.shared.adopt(childID: childID, by: managerID, brief: brief)
            },
            release: { childID, managerID, outcome in
                ControlGrantStore.shared.release(
                    childID: childID,
                    by: managerID,
                    outcome: outcome
                )
            },
            requestArchive: { SessionArchiveScheduler.shared.request(sessionID: $0, reason: $1) },
            requestManagerArchive: {
                SessionArchiveScheduler.shared.request(
                    sessionID: $0,
                    reason: $1,
                    requestedByManagerID: $2
                )
            },
            cancelArchive: { SessionArchiveScheduler.shared.cancel(sessionID: $0) },
            rename: { ProjectStore.shared.updateAgentTitle($1, for: $0, source: .chosen) },
            ceilingRefusal: { ceiling, session in
                ControlSpendCeiling.currentRefusal(ceiling: ceiling, session: session)
            },
            accountMoveCount: { managerID, childID, since in
                guard let supervision = ControlGrantStore.shared.activeManager(of: childID),
                      supervision.managerID == managerID else { return 0 }
                return ControlGrantStore.shared.moveCount(for: supervision, since: since)
            }
        )
    )

    // MARK: - Scope

    /// The scope an actor holds. Slice one: a session sees exactly its own project.
    func scope(for actor: ControlActor) -> ControlScope? {
        switch actor {
        case .agentSession(let sessionID):
            guard let project = dependencies.projectForSession(sessionID) else { return nil }
            return .project(project.id)
        }
    }

    /// The one authorization boundary for every control-plane operation.
    ///
    /// Membership is resolved before operation authority. A target outside every scope is
    /// therefore always `.targetUnknown`, even when the actor lacks the requested operation —
    /// the caller cannot use a denied operation to probe another project.
    func authorize(
        _ actor: ControlActor,
        operation: ControlOperation,
        target targetID: SessionID? = nil
    ) -> ControlRefusal? {
        guard case .agentSession(let callerID) = actor,
              let caller = dependencies.session(callerID),
              !caller.isArchived,
              let callerProject = dependencies.projectForSession(callerID) else {
            return .callerUnknown
        }

        let authority = effectiveAuthority(
            for: actor,
            callerID: callerID,
            callerProjectID: callerProject.id
        )
        if let targetID {
            guard let target = dependencies.session(targetID),
                  authority.contains(where: {
                      scope($0.scope, contains: target, sessionID: targetID)
                  }) else {
                return .targetUnknown
            }
            guard authority.contains(where: {
                $0.operations.contains(operation)
                    && scope($0.scope, contains: target, sessionID: targetID)
            }) else {
                return .notPermitted(operation)
            }
        } else if !authority.contains(where: { $0.operations.contains(operation) }) {
            return .notPermitted(operation)
        }
        return nil
    }

    // MARK: - Listing

    /// The sessions an actor may know about: every unarchived session in its scope, the
    /// caller's own marked as such.
    func sessions(for actor: ControlActor) -> Result<[ControlSessionOverview], ControlRefusal> {
        guard case .agentSession(let callerID) = actor,
              let caller = dependencies.session(callerID),
              !caller.isArchived,
              let project = dependencies.projectForSession(callerID) else {
            return .failure(.callerUnknown)
        }

        if let refusal = authorize(actor, operation: .listSessions) {
            return .failure(refusal)
        }

        let authority = effectiveAuthority(
            for: actor,
            callerID: callerID,
            callerProjectID: project.id
        ).filter { $0.operations.contains(.listSessions) }
        let projects = dependencies.allProjects()
        let rows = (projects.isEmpty ? [project] : projects).flatMap(\.sessions)
            .filter { session in
                !session.isArchived && authority.contains {
                    scope($0.scope, contains: session, sessionID: session.id)
                }
            }
            .map { overview(of: $0, caller: callerID) }
        return .success(rows)
    }

    // MARK: - Sending

    /// Delivers a message to another session in the actor's scope, provenance attached.
    ///
    /// Checks run caller → message → target → surface, so the answer names the first thing
    /// actually wrong rather than whichever guard happened to be written first. The outcome
    /// arrives through a completion because a terminal delivery's honest answer waits on the
    /// target's own turn-started receipt; refusals and chat sends complete immediately.
    func send(
        _ message: String,
        to targetID: SessionID,
        disposition: ControlSendDisposition = .queue,
        from actor: ControlActor,
        completion: @escaping @MainActor (ControlSendOutcome) -> Void
    ) {
        guard case .agentSession(let callerID) = actor,
              let caller = dependencies.session(callerID),
              !caller.isArchived,
              dependencies.projectForSession(callerID) != nil else {
            return completion(.refused(.callerUnknown))
        }

        let operation: ControlOperation = disposition == .steer ? .steer : .sendMessage
        if let refusal = authorize(actor, operation: operation, target: targetID) {
            return completion(.refused(refusal))
        }

        let trimmed = Self.sanitized(message).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return completion(.refused(.messageEmpty)) }

        guard !trimmed.hasPrefix("[Cross-session message ") else {
            return completion(.refused(.messageIsRelay))
        }

        guard targetID != callerID else { return completion(.refused(.targetIsCaller)) }

        guard let target = dependencies.session(targetID) else {
            return completion(.refused(.targetUnknown))
        }
        guard !target.isArchived else { return completion(.refused(.targetArchived)) }

        guard admitSend(from: callerID) else {
            return completion(.refused(.sendRateReached(
                limit: SupervisionDefaults.maximumSendsPerMinute
            )))
        }

        // A message from one agent to another is Threading-initiated spend on the target's
        // account, which is exactly what a tier-3 rule stands down. Refused in the plane's own
        // voice rather than delivered and regretted — and *after* the scope checks, so a caller
        // cannot learn whether a session outside its scope has a limit on it.
        if let held = dependencies.heldByOwnLimit(targetID) {
            return completion(.refused(.targetHeldByOwnLimit(reason: held)))
        }

        // The budget bounds what is delivered, header included — a cap applied before the
        // prefix let every message exceed the limit it had just been held to.
        let delivered = Self.provenancePrefixed(trimmed, from: caller)
        guard delivered.count <= ControlDefaults.maximumMessageLength else {
            return completion(.refused(.messageTooLong(limit: ControlDefaults.maximumMessageLength)))
        }

        switch disposition {
        case .queue:
            dependencies.deliver(delivered, targetID) { [weak self] outcome in
                guard let self else { return completion(.refused(.deliveryFailed)) }
                switch outcome {
                case .sentNow:
                    completion(.sent(to: self.overview(of: target, caller: callerID)))
                case .queuedBehindTurn:
                    completion(.queued(behind: self.overview(of: target, caller: callerID)))
                case .typedUnconfirmed:
                    completion(.typedUnconfirmed(to: self.overview(of: target, caller: callerID)))
                case .noLiveSurface:
                    completion(.refused(.targetNotRunning))
                case .busyTerminal:
                    completion(.refused(.targetBusy))
                case .notTaken:
                    completion(.refused(.deliveryFailed))
                }
            }

        case .steer:
            switch dependencies.steer(delivered, targetID) {
            case .steered:
                completion(.steered(into: overview(of: target, caller: callerID)))
            case .targetNotLiveChat:
                completion(.refused(.steerNeedsLiveChat))
            case .refused(let refusal):
                completion(.refused(.steerUnavailable(refusal)))
            case .notTaken:
                completion(.refused(.deliveryFailed))
            }
        }
    }

    // MARK: - Watching

    /// Arms a one-shot notice for when another session in the actor's scope next settles.
    ///
    /// The same scope guards a send runs, minus the ones about a message — a watch carries no
    /// text — so who may be watched is exactly who may be messaged, decided here rather than
    /// twice. Synchronous: arming is a decision, not a delivery, and the notice it buys arrives
    /// later through the delivery seam.
    func watch(
        _ targetID: SessionID,
        timeout: TimeInterval? = nil,
        from actor: ControlActor
    ) -> ControlWatchOutcome {
        guard case .agentSession(let callerID) = actor,
              let caller = dependencies.session(callerID),
              !caller.isArchived,
              dependencies.projectForSession(callerID) != nil else {
            return .refused(.callerUnknown)
        }

        if let refusal = authorize(actor, operation: .watch, target: targetID) {
            return .refused(refusal)
        }

        guard targetID != callerID else { return .refused(.targetIsCaller) }

        guard let target = dependencies.session(targetID) else {
            return .refused(.targetUnknown)
        }
        guard !target.isArchived else { return .refused(.targetArchived) }

        let overview = overview(of: target, caller: callerID)
        switch dependencies.armWatch(callerID, targetID, timeout) {
        case .armed(let expiresAfter):
            return .armed(on: overview, expiresAfter: expiresAfter)
        case .alreadyWatching:
            return .alreadyWatching(on: overview)
        case .targetAlreadySettled:
            return .targetAlreadySettled(overview)
        case .watcherAtCapacity(let limit):
            return .refused(.watcherAtCapacity(limit: limit))
        case .invalidTimeout:
            return .refused(.invalidWatchTimeout)
        }
    }

    // MARK: - Permission Responses

    /// Returns the exact bounded evidence for the target's active permission card.
    func inspectPermission(
        in targetID: SessionID,
        from actor: ControlActor
    ) -> ControlPermissionInspectionOutcome {
        guard case .agentSession(let callerID) = actor else { return .refused(.callerUnknown) }
        if let refusal = authorize(actor, operation: .respondToPermission, target: targetID) {
            return .refused(refusal)
        }
        guard targetID != callerID else { return .refused(.targetIsCaller) }
        guard let target = dependencies.session(targetID), !target.isArchived else {
            return .refused(.targetArchived)
        }

        let row = overview(of: target, caller: callerID)
        guard let request = dependencies.pendingPermission(targetID) else {
            return .noPendingRequest(in: row)
        }
        return .pending(in: row, request: request)
    }

    /// Applies one allow/deny to the exact active request id. Authorization and current evidence
    /// are both re-read here, so grant revocation and card replacement take effect immediately.
    func resolvePermission(
        in targetID: SessionID,
        requestID: String,
        decision: ControlPermissionDecision,
        from actor: ControlActor
    ) -> ControlPermissionResolutionOutcome {
        guard case .agentSession(let callerID) = actor else { return .refused(.callerUnknown) }
        if let refusal = authorize(actor, operation: .respondToPermission, target: targetID) {
            return .refused(refusal)
        }
        guard targetID != callerID else { return .refused(.targetIsCaller) }
        guard let target = dependencies.session(targetID), !target.isArchived else {
            return .refused(.targetArchived)
        }

        let row = overview(of: target, caller: callerID)
        guard let current = dependencies.pendingPermission(targetID) else {
            return .noPendingRequest(in: row)
        }
        guard requestID.count <= ControlDefaults.maximumPermissionRequestIDLength,
              requestID == current.requestID else {
            return .requestChanged(in: row)
        }
        guard current.canDecide else {
            return .requiresLocalReview(
                in: row,
                reason: current.unavailableReason ?? "The complete evidence is available only locally."
            )
        }
        guard dependencies.resolvePermission(targetID, requestID, decision, callerID) else {
            // The card may have settled or advanced between the read and the exact one-shot write.
            return dependencies.pendingPermission(targetID) == nil
                ? .noPendingRequest(in: row)
                : .requestChanged(in: row)
        }
        return .resolved(in: row, requestID: requestID, decision: decision)
    }

    // MARK: - Targeted Lifecycle

    func archive(
        _ targetID: SessionID,
        reason: String?,
        from actor: ControlActor
    ) -> ControlArchiveOutcome {
        guard case .agentSession(let callerID) = actor else { return .refused(.callerUnknown) }
        if let refusal = authorize(actor, operation: .archiveSession, target: targetID) {
            return .refused(refusal)
        }
        guard let target = dependencies.session(targetID), !target.isArchived else {
            return .refused(targetID == callerID ? .callerUnknown : .targetArchived)
        }
        if targetID != callerID, dependencies.activity(targetID).hasTurnInFlight {
            return .refused(.targetBusy)
        }
        let row = overview(of: target, caller: callerID)
        let request = targetID == callerID
            ? dependencies.requestArchive(targetID, reason)
            : dependencies.requestManagerArchive(targetID, reason, callerID)
        switch request {
        case .scheduled: return .scheduled(row)
        case .alreadyPending: return .alreadyPending(row)
        case .refused: return .refused(.deliveryFailed)
        }
    }

    func cancelArchive(
        _ targetID: SessionID,
        from actor: ControlActor
    ) -> ControlArchiveOutcome {
        guard case .agentSession(let callerID) = actor else { return .refused(.callerUnknown) }
        if let refusal = authorize(actor, operation: .archiveSession, target: targetID) {
            return .refused(refusal)
        }
        guard let target = dependencies.session(targetID) else { return .refused(.targetUnknown) }
        let row = overview(of: target, caller: callerID)
        switch dependencies.cancelArchive(targetID) {
        case .cancelled: return .cancelled(row)
        case .nothingPending: return .nothingPending(row)
        }
    }

    func rename(
        _ targetID: SessionID,
        to name: String,
        from actor: ControlActor
    ) -> ControlRenameOutcome {
        guard case .agentSession(let callerID) = actor else { return .refused(.callerUnknown) }
        if let refusal = authorize(actor, operation: .renameSession, target: targetID) {
            return .refused(refusal)
        }
        guard dependencies.session(targetID) != nil else { return .refused(.targetUnknown) }
        switch dependencies.rename(targetID, name) {
        case .accepted:
            guard let updated = dependencies.session(targetID) else {
                return .refused(.targetUnknown)
            }
            let row = overview(of: updated, caller: callerID)
            if let userTitle = updated.customTitle, !userTitle.isEmpty {
                return .protectedByUserTitle(row, visibleTitle: userTitle)
            }
            return .renamed(row, visibleTitle: updated.displayTitle)
        case .protectedByStrongerSource:
            guard let updated = dependencies.session(targetID) else {
                return .refused(.targetUnknown)
            }
            return .protectedByUserTitle(
                overview(of: updated, caller: callerID),
                visibleTitle: updated.displayTitle
            )
        case .sessionNotFound: return .refused(.targetUnknown)
        case .persistenceRefused: return .refused(.deliveryFailed)
        case .refusedAsNoise, .cleared: return .refused(.messageEmpty)
        }
    }

    // MARK: - Supervision

    func admitResume(
        _ targetID: SessionID,
        from actor: ControlActor
    ) -> ControlRefusal? {
        if let refusal = authorize(actor, operation: .resumeSession, target: targetID) {
            return refusal
        }
        guard let target = dependencies.session(targetID), !target.isArchived else {
            return .targetUnknown
        }
        guard !dependencies.activity(targetID).hasTurnInFlight else { return .targetBusy }
        guard target.usesNativeUI else { return .terminalCannotBeWoken }
        if let held = dependencies.heldByOwnLimit(targetID) {
            return .targetHeldByOwnLimit(reason: held)
        }
        return ceilingRefusal(for: actor, operation: .resumeSession, target: target)
    }

    func admitSpawn(
        _ plan: ScheduledSessionPlan,
        from actor: ControlActor
    ) -> ControlRefusal? {
        if let refusal = authorize(actor, operation: .spawnSession) { return refusal }
        guard case .agentSession(let managerID) = actor,
              let manager = dependencies.session(managerID),
              let managerProject = dependencies.projectForSession(managerID),
              plan.projectID == managerProject.id else { return .callerUnknown }
        guard dependencies.supervisionOverview(managerID).children.count
                < SupervisionDefaults.maximumLiveChildren else {
            return .childrenAtCapacity(limit: SupervisionDefaults.maximumLiveChildren)
        }
        guard let grant = storedGrant(for: actor, operation: .spawnSession) else {
            return .notPermitted(.spawnSession)
        }
        if let requested = plan.permissionMode,
           permissionRank(requested) > permissionRank(grant.maximumPermissionMode) {
            return .planExceedsGrant(field: "permission_mode")
        }
        if let delivery = plan.managedWorkspacePlan?.delivery,
           !grant.allowedDeliveries.contains(delivery) {
            return .planExceedsGrant(field: "managed_workspace_plan.delivery")
        }
        if let held = dependencies.heldByOwnLimit(managerID) {
            return .targetHeldByOwnLimit(reason: held)
        }
        return grant.ceiling.flatMap { dependencies.ceilingRefusal($0, manager) }
            .map(ControlRefusal.ceilingReached(reason:))
    }

    func admitMove(
        _ targetID: SessionID,
        from actor: ControlActor,
        at now: Date = Date()
    ) -> ControlRefusal? {
        if let refusal = authorize(actor, operation: .moveSessionToAccount, target: targetID) {
            return refusal
        }
        guard case .agentSession(let managerID) = actor,
              dependencies.session(targetID) != nil else { return .callerUnknown }
        guard !dependencies.activity(targetID).hasTurnInFlight else { return .targetBusy }
        let since = Calendar(identifier: .gregorian).date(byAdding: .day, value: -1, to: now)
            ?? now.addingTimeInterval(-86_400)
        guard dependencies.accountMoveCount(managerID, targetID, since)
                < SupervisionDefaults.maximumAccountMovesPerDay else {
            return .accountMoveBudgetReached(limit: SupervisionDefaults.maximumAccountMovesPerDay)
        }
        return nil
    }

    func admitFinish(
        _ targetID: SessionID,
        from actor: ControlActor
    ) -> ControlRefusal? {
        if let refusal = authorize(actor, operation: .finishWorkspace, target: targetID) {
            return refusal
        }
        guard let target = dependencies.session(targetID),
              let workspace = target.managedWorkspace else { return .workspaceUnavailable }
        guard !dependencies.activity(targetID).hasTurnInFlight else { return .targetBusy }
        guard workspace.state != .needsAttention else { return .workspaceUnavailable }
        guard let grant = storedGrant(for: actor, operation: .finishWorkspace),
              grant.allowedDeliveries.contains(workspace.delivery) else {
            return .planExceedsGrant(field: "managed_workspace.delivery")
        }
        return nil
    }

    func adopt(
        _ childID: SessionID,
        brief: String,
        from actor: ControlActor
    ) -> ControlSupervisionMutationOutcome {
        guard case .agentSession(let managerID) = actor else { return .refused(.callerUnknown) }
        if let refusal = authorize(actor, operation: .adoptSession, target: childID) {
            return .refused(refusal)
        }
        guard childID != managerID else { return .refused(.targetIsCaller) }
        return dependencies.adopt(childID, managerID, brief)
    }

    func release(
        _ childID: SessionID,
        outcome: String?,
        from actor: ControlActor
    ) -> ControlSupervisionMutationOutcome {
        guard case .agentSession(let managerID) = actor else { return .refused(.callerUnknown) }
        if let refusal = authorize(actor, operation: .releaseSession, target: childID) {
            return .refused(refusal)
        }
        return dependencies.release(childID, managerID, outcome)
    }

    // MARK: - Provenance

    /// Every cross-session message says which session sent it, ahead of anything it says.
    ///
    /// The receiving transcript renders the delivery as an ordinary user turn — that is the
    /// honest mechanics, since it runs as one — so the header is what keeps the receiving
    /// agent, and the user reading over its shoulder, from mistaking a peer session's words
    /// for the user's own.
    ///
    /// The header is the only part of a delivery Threading vouches for, and only as its
    /// *first* line: the body is the sender's words, unescaped, so a sender can write a
    /// header-shaped line of its own further down. The group instruction says exactly that to
    /// receivers. The title slot is fenced (`safeHeaderTitle`) because a session names itself
    /// — a title ending in `”` or `]` would close the frame early and put sender-authored
    /// text where the reader has been told Threading speaks.
    static func provenancePrefixed(_ message: String, from source: AgentSession) -> String {
        """
        [Cross-session message from “\(safeHeaderTitle(source.displayTitle))” — Threading \
        session \(source.id.uuidString.lowercased()) in this project. Sent by that session's \
        agent, not typed by the user. Only this first line is written by Threading.]

        \(message)
        """
    }

    /// A session title, safe to interpolate into the one line Threading vouches for.
    ///
    /// `nonisolated`, like `sanitized`: a pure function of its argument, and the session
    /// reference a dragged sidebar row becomes (`SessionReference`) fences its title with the
    /// same rule from a value type that has no actor.
    nonisolated static func safeHeaderTitle(_ title: String) -> String {
        var safe = sanitized(title).replacingOccurrences(of: "\n", with: " ")
        for framing in ["[", "]", "“", "”"] {
            safe = safe.replacingOccurrences(of: framing, with: "'")
        }
        return safe
    }

    /// Drops control characters a delivered message must never carry.
    ///
    /// The terminal path types the message into a PTY, where ESC and C0/C1 bytes are live
    /// keystrokes — `ESC [201~` inside a body would end the bracketed paste and hand the rest
    /// to the TUI as typed input, Returns and Ctrl-C included. Newlines and tabs stay; they
    /// are the message's own structure. The chat path never interprets these, but one rule
    /// for both surfaces means the answer cannot depend on where the target happens to live.
    nonisolated static func sanitized(_ message: String) -> String {
        String(String.UnicodeScalarView(message.unicodeScalars.filter { scalar in
            scalar == "\n" || scalar == "\t"
                || (scalar.value >= 0x20 && scalar.value != 0x7F
                    && !(0x80...0x9F).contains(scalar.value))
        }))
    }

    // MARK: - Private

    /// **The title is fenced here, once, for every consumer.**
    ///
    /// A session names itself (`set_session_name`, or its own terminal title), and every tool
    /// result in this feature interpolates that name into prose an agent reads as structure:
    /// `list_sessions` prints one bullet per session with an id after an em dash. A session
    /// titled `X” — claude, chat, idle — id <someone-else's-uuid>` followed by a newline and a
    /// bullet therefore forges a listing row, attributing an id to a session that does not
    /// hold it — and the reading agent has no way to tell the forged row from the real ones.
    /// The header fence already existed for the delivery frame; the listing needed it just as
    /// much, and putting it on the overview means no future tool can forget it.
    private func overview(of session: AgentSession, caller: SessionID) -> ControlSessionOverview {
        ControlSessionOverview(
            id: session.id,
            title: Self.safeHeaderTitle(session.displayTitle),
            kind: session.kind,
            activity: dependencies.activity(session.id),
            surface: dependencies.surface(session.id),
            isCaller: session.id == caller,
            forkedFrom: session.forkedFrom,
            supervision: dependencies.supervisionOverview(session.id)
        )
    }

    private struct EffectiveGrant {
        let scope: ControlScope
        let operations: Set<ControlOperation>
    }

    private func effectiveAuthority(
        for actor: ControlActor,
        callerID: SessionID,
        callerProjectID: ProjectID
    ) -> [EffectiveGrant] {
        var result = [
            EffectiveGrant(
                scope: .project(callerProjectID),
                operations: ControlOperation.regularProjectOperations
            ),
            EffectiveGrant(
                scope: .sessions([callerID]),
                operations: ControlOperation.regularSelfOperations
            ),
        ]
        result.append(contentsOf: dependencies.grants(actor).filter(\.isActive).map {
            EffectiveGrant(scope: $0.scope, operations: $0.operations)
        })
        return result
    }

    private func storedGrant(
        for actor: ControlActor,
        operation: ControlOperation
    ) -> ControlGrant? {
        dependencies.grants(actor).first { $0.isActive && $0.operations.contains(operation) }
    }

    private func ceilingRefusal(
        for actor: ControlActor,
        operation: ControlOperation,
        target: AgentSession
    ) -> ControlRefusal? {
        guard let ceiling = storedGrant(for: actor, operation: operation)?.ceiling,
              let reason = dependencies.ceilingRefusal(ceiling, target) else { return nil }
        return .ceilingReached(reason: reason)
    }

    private func permissionRank(_ mode: AgentPermissionMode) -> Int {
        AgentPermissionMode.allCases.firstIndex(of: mode) ?? .max
    }

    private func scope(
        _ scope: ControlScope,
        contains session: AgentSession,
        sessionID: SessionID
    ) -> Bool {
        switch scope {
        case .sessions(let ids):
            return ids.contains(sessionID)
        case .project(let projectID):
            return dependencies.projectForSession(sessionID)?.id == projectID
        case .projects(let projectIDs):
            guard let projectID = dependencies.projectForSession(sessionID)?.id else { return false }
            return projectIDs.contains(projectID)
        }
    }

    private func admitSend(from callerID: SessionID) -> Bool {
        let cutoff = Date().addingTimeInterval(-60)
        let retained = (recentSends[callerID] ?? []).filter { $0 >= cutoff }
        guard retained.count < SupervisionDefaults.maximumSendsPerMinute else {
            recentSends[callerID] = retained
            return false
        }
        recentSends[callerID] = retained + [Date()]
        return true
    }
}
