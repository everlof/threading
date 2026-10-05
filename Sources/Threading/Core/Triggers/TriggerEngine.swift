import Foundation

struct TriggerDispatch: Sendable, Equatable {
    let run: TriggerRun
    let revision: TriggerRevision
    let event: TriggerEvent
}

struct TriggerIngestionResult: Sendable, Equatable {
    let accepted: Bool
    let createdRuns: [TriggerRun]
    let dispatches: [TriggerDispatch]
}

struct TriggerDispatchDidBecomeReady: AppEvent {
    static let name = Notification.Name("triggerDispatchDidBecomeReady")
    let dispatch: TriggerDispatch
}

struct TriggerFixStageDidBecomeReady: AppEvent {
    static let name = Notification.Name("triggerFixStageDidBecomeReady")
    let dispatch: TriggerDispatch
}

/// Process-wide bridge between source delivery and the window-owned session lifecycle.
actor TriggerRuntime {
    static let shared = TriggerRuntime()

    private let store: TriggerStore
    private let engine: TriggerEngine
    private var didStart = false
    private var discoveryOffset = 0
    private var queueTimer: Task<Void, Never>?

    init(store: TriggerStore = .shared, engine: TriggerEngine? = nil) {
        self.store = store
        self.engine = engine ?? TriggerEngine(store: store)
    }

    func start() async {
        guard !didStart else { return }
        didStart = true
        // Secrets an earlier build stored name only the app on their access list; rewrite them so
        // the listener can read them (TriggerSecretStore). Detached: the pass waits on the shared
        // keychain gate, which a prompt elsewhere may hold, and nothing below depends on it.
        let automatedRun = await MainActor.run { AutomatedRun.isUnderway }
        Task.detached(priority: .utility) {
            guard let migration = TriggerSecretStore.shared.migrateEarlierItemsAtLaunch(automatedRun: automatedRun),
                  migration != .init() else { return }
            ThreadingLogger.app.notice(
                "Trigger secrets rewritten for the listener: \(migration.rewritten, privacy: .public) rewritten, \(migration.unreadable, privacy: .public) unreadable"
            )
        }
        await discoverProjects()
        // The daemon's file is a projection; failing to write it must not also stop recovery and
        // the schedule sweep below. The listener's registration is left as it was.
        do {
            let shouldRun = try await store.publishDaemonConfiguration()
            await MainActor.run {
                TriggerDaemonRegistrationCoordinator.shared.reconcile(shouldRun: shouldRun)
            }
        } catch {
            ThreadingLogger.app.error(
                "Trigger daemon configuration was not published: \(error.localizedDescription, privacy: .private)"
            )
        }
        do {
            try await settleInterruptedRuns()
            try await store.settleStaleQueuedRuns()
            try await publish(try await store.receivedDispatches())
            try await publishFixStages(try await store.fixStageDispatches())
            try await publish(try await store.scheduledDispatches())
            await drainDaemonInbox()
            try await releaseQueue()
            queueTimer = Task {
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(15))
                    guard !Task.isCancelled else { return }
                    await self.discoverProjects()
                    try? await self.publish(try await self.store.scheduledDispatches())
                    try? await self.releaseQueue()
                }
            }
        } catch {
            ThreadingLogger.app.error(
                "Trigger recovery failed: \(error.localizedDescription, privacy: .private)"
            )
        }
    }

    /// Eight project folders per tick. No hidden project's views are built during discovery.
    private func discoverProjects() async {
        let offset = discoveryOffset
        let page = await MainActor.run {
            let projects = ProjectStore.shared.projects
            return (Array(projects.dropFirst(offset).prefix(8).filter { $0.executionHost == nil }.map { ($0.id, $0.folderPath) }), projects.count)
        }
        discoveryOffset = offset + 8 < page.1 ? offset + 8 : 0
        for (id, path) in page.0 { _ = try? await store.discoverProjectAutomations(projectID: id, checkout: path) }
    }

    func drainDaemonInbox() async {
        await drainDaemonInbox(directory: TriggerDaemonLocations.inbox, journal: .shared)
    }

    /// Ingests, acknowledges and dispatches every inbox file, a bounded page at a time. A file
    /// that does not decode, or that the store refuses on its bounds, is quarantined and the
    /// drain continues; only a failure that could succeed later (the store itself) stops it.
    func drainDaemonInbox(directory: URL, journal: EventLog) async {
        do {
            while true {
                let page = try await Task.detached(priority: .utility) {
                    try TriggerDaemonInbox.load(directory: directory, journal: journal)
                }.value
                for item in page.items {
                    let result: TriggerIngestionResult
                    do {
                        result = try await engine.ingest(item.event)
                    } catch TriggerStore.StoreError.invalidRecord {
                        try await Task.detached(priority: .utility) {
                            try TriggerDaemonInbox.quarantine(item.file, reason: .invalid, journal: journal)
                        }.value
                        continue
                    }
                    try await Task.detached(priority: .utility) {
                        try TriggerDaemonInbox.acknowledge(item)
                    }.value
                    try await publish(result.dispatches)
                }
                // Every examined file was acknowledged or set aside, so a full page means more.
                guard page.examined == TriggerDaemonInbox.pageLimit else { return }
            }
        } catch {
            ThreadingLogger.app.error(
                "Trigger daemon inbox drain failed: \(error.localizedDescription, privacy: .private)"
            )
        }
    }

    @discardableResult
    func ingest(_ event: TriggerEvent) async throws -> TriggerIngestionResult {
        let result = try await engine.ingest(event)
        try await publish(result.dispatches)
        return result
    }

    func releaseQueue() async throws {
        try await publish(try await engine.releaseEligibleQueuedRuns())
    }

    func publish(_ dispatches: [TriggerDispatch]) async throws {
        guard !dispatches.isEmpty else { return }
        await MainActor.run {
            for dispatch in dispatches {
                NotificationCenter.default.post(TriggerDispatchDidBecomeReady(dispatch: dispatch))
            }
        }
    }

    private func publishFixStages(_ dispatches: [TriggerDispatch]) async throws {
        guard !dispatches.isEmpty else { return }
        await MainActor.run {
            for dispatch in dispatches {
                // A fix stage recovered after a relaunch: the assessment's registration did not
                // survive the process, and the fix stage must not fall back to cards either.
                if let sessionID = dispatch.run.sessionID {
                    UnattendedRunPermissions.register(dispatch.revision, for: sessionID)
                }
                NotificationCenter.default.post(TriggerFixStageDidBecomeReady(dispatch: dispatch))
            }
        }
    }

    private func settleInterruptedRuns() async throws {
        while true {
            let interrupted = try await store.interruptedRuns()
            guard !interrupted.isEmpty else { return }
            for original in interrupted {
                var run = original
                run.state = .needsAttention
                run.settledAt = Date()
                run.boundedDiagnostic = original.state == .fixing
                    ? L10n.string("The fix agent ended without reporting a final result.")
                    : L10n.string("The assessment agent ended without reporting an assessment.")
                try await store.updateRun(run)
            }
            guard interrupted.count == 100 else { return }
        }
    }
}

/// Turns bounded, untrusted source events into durable run reservations.
///
/// Matching and persistence happen without touching AppKit or starting a process. The app and
/// background bridge consume `dispatches` and own the higher-authority act of creating an agent
/// session. Keeping this actor small also makes the event path deterministic under redelivery.
actor TriggerEngine {
    private let store: TriggerStore
    private let now: @Sendable () -> Date

    init(
        store: TriggerStore = .shared,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.store = store
        self.now = now
    }

    func ingest(_ event: TriggerEvent) async throws -> TriggerIngestionResult {
        // A daemon may have committed an inbox item just before the person paused its source.
        // Preserve the event receipt, but re-check the host-owned source grant before reserving
        // any work from that item.
        let sourceEnabled = try await store.source(id: event.sourceInstallationID)?.enabled == true
        let candidates = sourceEnabled
            ? try await store.activeTriggers().filter { candidate in
                candidate.definition.enabled
                    && candidate.revision.sourceInstallationID == event.sourceInstallationID
                    && candidate.revision.eventKind == event.kind
                    && TriggerMatcher.matches(event, conditions: candidate.revision.conditions)
            }
            : []

        var runs: [TriggerRun] = []
        var dispatches: [TriggerDispatch] = []
        let acceptedAt = now()

        for candidate in candidates {
            let activeCount = try await store.activeRunCount(triggerID: candidate.definition.id)
            let heldForQuietHours = candidate.revision.quietHours?.contains(acceptedAt) == true
            let heldForConcurrency = activeCount >= candidate.revision.limits.maximumConcurrentRuns
            let launchNow = !heldForQuietHours && !heldForConcurrency
            let holdReason: TriggerRunHoldReason?
            if heldForQuietHours {
                holdReason = .quietHours
            } else if heldForConcurrency {
                holdReason = .concurrencyLimit
            } else {
                holdReason = nil
            }

            let run = TriggerRun(
                id: TriggerRunID(),
                triggerID: candidate.definition.id,
                triggerRevisionID: candidate.revision.id,
                eventKey: event.storageKey,
                state: launchNow ? .received : .queued,
                queuedAt: acceptedAt,
                startedAt: nil,
                settledAt: nil,
                sessionID: nil,
                managedWorkspaceID: nil,
                holdReason: holdReason,
                result: nil,
                boundedDiagnostic: nil
            )
            runs.append(run)
            if launchNow {
                dispatches.append(TriggerDispatch(
                    run: run,
                    revision: candidate.revision,
                    event: event
                ))
            }
        }

        let accepted = try await store.accept(event, creating: runs)
        guard accepted else {
            return TriggerIngestionResult(accepted: false, createdRuns: [], dispatches: [])
        }
        return TriggerIngestionResult(
            accepted: true,
            createdRuns: runs,
            dispatches: dispatches
        )
    }

    /// Re-evaluates only pre-launch holds. Revision identity remains frozen, while activation,
    /// source pause, quiet hours and concurrency are checked again at the moment of release.
    ///
    /// Selection is per trigger: SQL returns only triggers that are active at their held runs'
    /// revision, whose source is enabled and which have a free slot, and each contributes at most
    /// its free slots. A burst held behind one trigger's limit therefore never stands in front
    /// of another trigger's run, and the work is bounded by the catalogue, not the queue depth.
    func releaseEligibleQueuedRuns(limit: Int = 100) async throws -> [TriggerDispatch] {
        let candidates = try await store.queueReleaseCandidates()
        let acceptedAt = now()
        var dispatches: [TriggerDispatch] = []

        for candidate in candidates where dispatches.count < limit {
            guard candidate.revision.quietHours?.contains(acceptedAt) != true else { continue }
            let freeSlots = candidate.revision.limits.maximumConcurrentRuns - candidate.activeRunCount
            guard freeSlots > 0 else { continue }
            let held = try await store.queuedDispatches(
                triggerID: candidate.triggerID,
                revision: candidate.revision,
                limit: min(freeSlots, limit - dispatches.count)
            )
            for dispatch in held {
                var run = dispatch.run
                run.state = .received
                run.holdReason = nil
                run.boundedDiagnostic = nil
                try await store.updateRun(run)
                dispatches.append(TriggerDispatch(
                    run: run,
                    revision: dispatch.revision,
                    event: dispatch.event
                ))
            }
        }
        return dispatches
    }
}
