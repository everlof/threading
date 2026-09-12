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
    private var queueTimer: Task<Void, Never>?

    init(store: TriggerStore = .shared, engine: TriggerEngine? = nil) {
        self.store = store
        self.engine = engine ?? TriggerEngine(store: store)
    }

    func start() async {
        guard !didStart else { return }
        didStart = true
        do {
            let shouldRun = try TriggerDaemonConfigurationStore.publish(try await store.sources())
            await MainActor.run {
                TriggerDaemonRegistrationCoordinator.shared.reconcile(shouldRun: shouldRun)
            }
            try await settleInterruptedRuns()
            try await publish(try await store.receivedDispatches())
            try await publishFixStages(try await store.fixStageDispatches())
            await drainDaemonInbox()
            try await releaseQueue()
            queueTimer = Task {
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(60))
                    guard !Task.isCancelled else { return }
                    try? await self.releaseQueue()
                }
            }
        } catch {
            ThreadingLogger.app.error(
                "Trigger recovery failed: \(error.localizedDescription, privacy: .private)"
            )
        }
    }

    func drainDaemonInbox() async {
        do {
            let items = try await Task.detached(priority: .utility) {
                try TriggerDaemonInbox.load()
            }.value
            for item in items {
                let result = try await engine.ingest(item.event)
                try await Task.detached(priority: .utility) {
                    try TriggerDaemonInbox.acknowledge(item)
                }.value
                try await publish(result.dispatches)
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

    private func publish(_ dispatches: [TriggerDispatch]) async throws {
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
    func releaseEligibleQueuedRuns(limit: Int = 100) async throws -> [TriggerDispatch] {
        let queued = try await store.queuedDispatches(limit: limit)
        let active = try await store.activeTriggers()
        let acceptedAt = now()
        var dispatches: [TriggerDispatch] = []

        for dispatch in queued {
            guard active.contains(where: {
                $0.definition.id == dispatch.run.triggerID
                    && $0.revision.id == dispatch.run.triggerRevisionID
            }),
            try await store.source(id: dispatch.event.sourceInstallationID)?.enabled == true else {
                continue
            }
            let activeCount = try await store.activeRunCount(triggerID: dispatch.run.triggerID)
            let heldForQuietHours = dispatch.revision.quietHours?.contains(acceptedAt) == true
            let heldForConcurrency = activeCount >= dispatch.revision.limits.maximumConcurrentRuns
            guard !heldForQuietHours, !heldForConcurrency else { continue }

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
        return dispatches
    }
}
