import Foundation

/// Durable control authority and supervision state.
///
/// Reads are cached by actor/manager/child so a sidebar viewport and MCP admission never turn
/// into one SQLite query per row or tool. Every mutation writes first, invalidates the affected
/// values, then announces the exact identities whose presentation/tool list changed.
@MainActor
final class ControlGrantStore {
    struct Dependencies {
        let state: StateManager
        let projects: ProjectStore
        let events: NotificationCenter
        let now: () -> Date
        /// Told when an archive is about to close a child's tenure, while the manager's
        /// subscription to that child still exists to carry the notice.
        var childArchived: @MainActor (Supervision) -> Void = { _ in }
    }

    static let shared: ControlGrantStore = ControlGrantStore(
        dependencies: Dependencies(
            state: .shared,
            projects: .shared,
            events: .default,
            now: Date.init,
            childArchived: tellSubscribedManager
        )
    )

    /// A function rather than an inline closure: `SupervisionSubscriptionCenter.shared` reads
    /// this store in its own initializer, and two inferred static initializers naming each
    /// other are a circular reference to the type checker.
    private static func tellSubscribedManager(_ supervision: Supervision) {
        SupervisionSubscriptionCenter.shared.childArchived(supervision)
    }

    private let dependencies: Dependencies
    private let observations: AppEventObservations
    private var grantsBySession: [SessionID: [ControlGrant]] = [:]
    private var supervisionsByManager: [SessionID: [Supervision]] = [:]
    private var supervisionsByChild: [SessionID: [Supervision]] = [:]
    private var eventsBySupervision: [SupervisionID: [SupervisionEvent]] = [:]
    private var expectedManagerArchives: [SessionID: SessionID] = [:]

    init(dependencies: Dependencies) {
        self.dependencies = dependencies
        observations = AppEventObservations(center: dependencies.events)
        observations.observe(SessionArchivedStateDidChange.self) { [weak self] event in
            guard event.isArchived else { return }
            self?.sessionWasArchived(event.sessionID)
        }
    }

    // MARK: - Grants

    func storedGrants(for actor: ControlActor) -> [ControlGrant] {
        guard case .agentSession(let sessionID) = actor else { return [] }
        if let cached = grantsBySession[sessionID] { return cached }
        var loaded = dependencies.state.controlGrants(for: sessionID) ?? []

        // Manager is a user-appointed role, but older rows persist the exact operation set the
        // role had when they were written. Upgrade only the exact former full-role set. A partial
        // or custom grant remains exact, and a failed write fails closed by keeping the old set.
        for index in loaded.indices {
            var upgraded = loaded[index]
            guard upgraded.upgradeManagerRoleIfNeeded() else { continue }
            guard dependencies.state.saveControlGrant(upgraded) else { continue }
            loaded[index] = upgraded
            EventLog.shared.record(.session, "Manager grant upgraded", [
                "session": sessionID.uuidString,
                "grant": upgraded.id.uuidString,
                "capability": ControlOperation.respondToPermission.rawValue,
            ])
        }
        grantsBySession[sessionID] = loaded
        return loaded
    }

    func activeGrants(for actor: ControlActor) -> [ControlGrant] {
        storedGrants(for: actor).filter(\.isActive)
    }

    func managerGrant(for sessionID: SessionID) -> ControlGrant? {
        activeGrants(for: .agentSession(sessionID)).first {
            !$0.operations.isDisjoint(with: ControlOperation.managerOperations
                .subtracting(ControlOperation.regularProjectOperations)
                .subtracting(ControlOperation.regularSelfOperations))
        }
    }

    func isManager(_ sessionID: SessionID) -> Bool {
        managerGrant(for: sessionID) != nil
    }

    /// Operations used to derive this session's MCP tool catalogue. Implicit operations are
    /// always present; stored operations add manager tools while their grant remains active.
    func effectiveOperations(for sessionID: SessionID) -> Set<ControlOperation> {
        ControlOperation.regularProjectOperations
            .union(ControlOperation.regularSelfOperations)
            .union(ControlOperation.implicitOnlyOperations)
            .union(activeGrants(for: .agentSession(sessionID)).flatMap(\.operations))
    }

    @discardableResult
    func conferManager(
        sessionID: SessionID,
        origin: GrantOrigin,
        maximumPermissionMode: AgentPermissionMode? = nil
    ) -> ControlGrant? {
        guard let session = dependencies.projects.session(withID: sessionID),
              !session.isArchived,
              let project = dependencies.projects.project(forSessionID: sessionID)
        else { return nil }

        if let existing = managerGrant(for: sessionID) { return existing }

        let grant = ControlGrant.manager(
            sessionID: sessionID,
            projectID: project.id,
            maximumPermissionMode: maximumPermissionMode ?? session.permissionMode ?? .manual,
            origin: origin,
            at: dependencies.now()
        )
        guard dependencies.state.saveControlGrant(grant) else { return nil }
        invalidateGrant(sessionID)
        dependencies.events.post(ControlGrantsDidChange(sessionID: sessionID))
        EventLog.shared.record(.session, "Manager role conferred", [
            "session": sessionID.uuidString,
            "grant": grant.id.uuidString,
            "project": project.id.uuidString,
        ])
        return grant
    }

    /// Revocation is immediate and reversible by conferring a new grant. The old row remains as
    /// the audit of who once held authority.
    @discardableResult
    func revokeManager(sessionID: SessionID) -> Bool {
        let now = dependencies.now()
        let active = activeGrants(for: .agentSession(sessionID)).filter {
            !$0.operations.isDisjoint(with: ControlOperation.managerOperations
                .subtracting(ControlOperation.regularProjectOperations)
                .subtracting(ControlOperation.regularSelfOperations))
        }
        guard !active.isEmpty else { return true }

        var saved: [ControlGrant] = []
        for var grant in active {
            grant.revokedAt = now
            guard dependencies.state.saveControlGrant(grant) else { return false }
            saved.append(grant)
        }

        invalidateGrant(sessionID)
        releaseAllChildren(of: sessionID, outcome: "Manager role revoked")
        dependencies.events.post(ControlGrantsDidChange(sessionID: sessionID))
        EventLog.shared.record(.session, "Manager role revoked", [
            "session": sessionID.uuidString,
            "grants": saved.map { $0.id.uuidString }.joined(separator: ","),
        ])
        return true
    }

    /// Removes every active manager grant in one user-authored operation.
    ///
    /// The database owns the authoritative identity set so this also reaches archived and
    /// otherwise non-materialized sessions. Revocation still travels through the ordinary
    /// per-session path, which releases children, invalidates caches and refreshes MCP tools.
    @discardableResult
    func revokeAllManagers() -> Bool {
        guard let sessionIDs = dependencies.state.activeManagerSessionIDs() else { return false }
        for sessionID in sessionIDs where !revokeManager(sessionID: sessionID) {
            return false
        }
        return true
    }

    func invalidateGrant(_ sessionID: SessionID) {
        grantsBySession.removeValue(forKey: sessionID)
    }

    // MARK: - Supervision

    func supervisions(managedBy managerID: SessionID) -> [Supervision] {
        if let cached = supervisionsByManager[managerID] { return cached }
        let loaded = dependencies.state.supervisions(managerID: managerID) ?? []
        supervisionsByManager[managerID] = loaded
        for supervision in loaded {
            supervisionsByChild[supervision.childID, default: []].appendIfMissing(supervision)
        }
        return loaded
    }

    func supervisions(forChild childID: SessionID) -> [Supervision] {
        if let cached = supervisionsByChild[childID] { return cached }
        let loaded = dependencies.state.supervisions(childID: childID) ?? []
        supervisionsByChild[childID] = loaded
        for supervision in loaded {
            supervisionsByManager[supervision.managerID, default: []].appendIfMissing(supervision)
        }
        return loaded
    }

    func activeChildren(of managerID: SessionID) -> [Supervision] {
        supervisions(managedBy: managerID).filter { $0.state == .active }
    }

    func activeManager(of childID: SessionID) -> Supervision? {
        supervisions(forChild: childID).last(where: { $0.state == .active })
    }

    func events(for supervisionID: SupervisionID) -> [SupervisionEvent] {
        if let cached = eventsBySupervision[supervisionID] { return cached }
        let loaded = dependencies.state.supervisionEvents(for: supervisionID) ?? []
        eventsBySupervision[supervisionID] = loaded
        return loaded
    }

    func overview(for sessionID: SessionID) -> ControlSupervisionOverview {
        let parent = activeManager(of: sessionID)
        let children = activeChildren(of: sessionID)
        let relevant = parent ?? children.last
        return ControlSupervisionOverview(
            managedBy: parent?.managerID,
            children: children.map(\.childID),
            brief: parent?.brief,
            lastEvent: relevant.flatMap { events(for: $0.id).last }
        )
    }

    func adopt(
        childID: SessionID,
        by managerID: SessionID,
        brief: String
    ) -> ControlSupervisionMutationOutcome {
        if let existing = activeManager(of: childID) {
            return existing.managerID == managerID
                ? .alreadyManaged(existing)
                : .refused(.notPermitted(.adoptSession))
        }
        let children = activeChildren(of: managerID)
        guard children.count < SupervisionDefaults.maximumLiveChildren else {
            return .refused(.childrenAtCapacity(limit: SupervisionDefaults.maximumLiveChildren))
        }

        let supervision = Supervision(
            managerID: managerID,
            childID: childID,
            brief: brief,
            assignedAt: dependencies.now()
        )
        guard dependencies.state.saveSupervision(supervision) else {
            return .refused(.deliveryFailed)
        }
        invalidateSupervision(managerID: managerID, childID: childID)
        _ = appendEvent(.assigned, detail: supervision.brief, to: supervision)
        dependencies.events.post(SupervisionDidChange(managerID: managerID, childID: childID))
        return .adopted(supervision)
    }

    func release(
        childID: SessionID,
        by managerID: SessionID,
        outcome: String? = nil
    ) -> ControlSupervisionMutationOutcome {
        close(
            childID: childID,
            by: managerID,
            state: .released,
            event: .released,
            outcome: outcome
        )
    }

    /// Marks an archive `managerID` asked for, so the archive edge closes the child's tenure as
    /// the manager's. It has to be recorded before archiving starts: the edge can arrive before
    /// the archive's own completion, so attribution written afterwards would be too late.
    func expectArchive(of childID: SessionID, by managerID: SessionID) {
        expectedManagerArchives[childID] = managerID
    }

    func cancelExpectedArchive(of childID: SessionID) {
        expectedManagerArchives.removeValue(forKey: childID)
    }

    /// Closes the relationship as the manager's archive, preserving the manager attribution for
    /// the Archived settings row and audit history.
    @discardableResult
    func archive(childID: SessionID, by managerID: SessionID) -> Bool {
        switch close(
            childID: childID,
            by: managerID,
            state: .archived,
            event: .archived,
            outcome: "Archived by manager"
        ) {
        case .released: return true
        case .alreadyManaged, .adopted, .refused: return false
        }
    }

    private func close(
        childID: SessionID,
        by managerID: SessionID,
        state: SupervisionState,
        event: SupervisionEventKind,
        outcome: String?
    ) -> ControlSupervisionMutationOutcome {
        guard var supervision = activeManager(of: childID),
              supervision.managerID == managerID else {
            return .refused(.supervisionUnknown)
        }
        supervision.state = state
        supervision.closedAt = dependencies.now()
        supervision.outcome = outcome
        guard dependencies.state.saveSupervision(supervision) else {
            return .refused(.deliveryFailed)
        }
        invalidateSupervision(managerID: managerID, childID: childID)
        _ = appendEvent(event, detail: outcome, to: supervision)
        dependencies.events.post(SupervisionDidChange(managerID: managerID, childID: childID))
        return .released(supervision)
    }

    @discardableResult
    func appendEvent(
        _ kind: SupervisionEventKind,
        detail: String? = nil,
        to supervision: Supervision
    ) -> SupervisionEvent? {
        let retained = events(for: supervision.id)
        if retained.count >= SupervisionDefaults.maximumEvents,
           kind != .eventsDropped,
           !retained.contains(where: { $0.kind == .eventsDropped }) {
            let marker = SupervisionEvent(
                supervisionID: supervision.id,
                at: dependencies.now(),
                kind: .eventsDropped,
                detail: "Older supervision events were dropped at the retention cap."
            )
            guard dependencies.state.saveSupervisionEvent(marker) else { return nil }
            EventLog.shared.record(.session, "Supervision events dropped at cap", [
                "manager": supervision.managerID.uuidString,
                "child": supervision.childID.uuidString,
                "limit": String(SupervisionDefaults.maximumEvents),
            ])
        }
        let event = SupervisionEvent(
            supervisionID: supervision.id,
            at: dependencies.now(),
            kind: kind,
            detail: detail
        )
        guard dependencies.state.saveSupervisionEvent(event) else { return nil }
        eventsBySupervision.removeValue(forKey: supervision.id)
        dependencies.events.post(SupervisionDidChange(
            managerID: supervision.managerID,
            childID: supervision.childID
        ))
        return event
    }

    func moveCount(for supervision: Supervision, since date: Date) -> Int {
        events(for: supervision.id).filter { $0.kind == .moved && $0.at >= date }.count
    }

    func sendCount(for managerID: SessionID, since date: Date) -> Int {
        activeChildren(of: managerID).reduce(0) { count, supervision in
            count + events(for: supervision.id).filter {
                $0.kind == .reportReceived && $0.at >= date
            }.count
        }
    }

    // MARK: - Private

    /// Every archive closes the archived chat's tenures, whichever route filed it: the sidebar,
    /// the iPhone, the provider's own archive, the chat's agent or its manager.
    ///
    /// Only the manager's own request closes as `.archived`, because Settings ▸ Archived credits
    /// the manager with exactly that. Any other route releases, so the child stops counting
    /// against the manager's live children and leaves its Chats tab. Before this, only the
    /// manager's route closed anything, and a child the user archived stayed "managed" for good.
    ///
    /// An archived manager releases its children: it can no longer act for them, and the
    /// one-manager rule would otherwise keep any other manager from adopting them.
    private func sessionWasArchived(_ sessionID: SessionID) {
        let requestedBy = expectedManagerArchives.removeValue(forKey: sessionID)
        if let supervision = activeManager(of: sessionID) {
            dependencies.childArchived(supervision)
            if requestedBy == supervision.managerID {
                archive(childID: sessionID, by: supervision.managerID)
            } else {
                _ = close(
                    childID: sessionID,
                    by: supervision.managerID,
                    state: .released,
                    event: .archived,
                    outcome: "Archived, not by its manager"
                )
            }
        }
        releaseAllChildren(of: sessionID, outcome: "Manager archived")
    }

    private func invalidateSupervision(managerID: SessionID, childID: SessionID) {
        supervisionsByManager.removeValue(forKey: managerID)
        supervisionsByChild.removeValue(forKey: childID)
    }

    private func releaseAllChildren(of managerID: SessionID, outcome: String) {
        for supervision in activeChildren(of: managerID) {
            _ = release(childID: supervision.childID, by: managerID, outcome: outcome)
        }
    }
}

private extension Array where Element == Supervision {
    mutating func appendIfMissing(_ supervision: Supervision) {
        guard !contains(where: { $0.id == supervision.id }) else { return }
        append(supervision)
    }
}
