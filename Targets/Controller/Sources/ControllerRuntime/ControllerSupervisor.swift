import Foundation
import ThreadingController
import ThreadingPTYHostKit

public struct SupervisorIssue: Codable, Sendable {
    public let executionID: ExecutionID
    public let code: String
}
/// A worker-level failure that did not stop supervision of anything else.
public struct SupervisorWorkerIssue: Codable, Sendable {
    public let workerID: WorkerID
    public let code: String
}
/// Queued work that automatic admission is holding back, and why.
public struct AdmissionHold: Codable, Sendable, Equatable {
    public let workerID: WorkerID
    public let reason: String
}
public struct SupervisorCycle: Codable, Sendable {
    public var scheduled = 0
    public var observed = 0
    public var started: [ExecutionID] = []
    public var stopped: [ExecutionID] = []
    public var issues: [SupervisorIssue] = []
    /// Spawns that started no process for a transient host reason; their work is queued again.
    public var requeued: [ExecutionID] = []
    public var workerIssues: [SupervisorWorkerIssue] = []
    /// Every current admission hold, reported when the set changes (always for one pass).
    public var held: [AdmissionHold]?
    /// Failures of a whole phase (a busy store, an unreadable page). Retried next pass.
    public var tickIssues: [String] = []
    /// Schedule admission that could not run this pass. Launch supervision continues regardless.
    public var automationIssues: [String] = []
    /// Tasks admitted because mail arrived for an idle worker whose grant lets it wake.
    public var woken: [WorkID] = []
    /// Outbound mail that waited past its lifetime for a peer and bounced this pass.
    public var expiredMail: [UUID] = []
    /// The most recent completed exchange with mail peers, reported once.
    public var mail: ControllerMailSync.Report?
    /// Source polls finished since the last report: events recorded and issues by source.
    public var sourceEvents = 0
    public var sourceIssues: [String] = []
    /// Usage receipts written since the last report, and collections that failed.
    public var receipts: [ExecutionID] = []
    public var usageIssues: [String] = []

    public init() {}

    public static func failedPass(_ error: Error) -> SupervisorCycle {
        var cycle = SupervisorCycle()
        cycle.tickIssues.append(ControllerSupervisor.describe(error))
        return cycle
    }

    /// Whether a resident loop has anything to say; idle passes print nothing.
    public var isQuiet: Bool {
        scheduled == 0 && started.isEmpty && stopped.isEmpty && issues.isEmpty && requeued.isEmpty
            && workerIssues.isEmpty && held == nil && tickIssues.isEmpty && automationIssues.isEmpty
            && woken.isEmpty && mail == nil && sourceEvents == 0 && sourceIssues.isEmpty
            && receipts.isEmpty && usageIssues.isEmpty && expiredMail.isEmpty
    }
}

/// One serial sweep owner. The database remains the admission authority across processes.
/// Eight unresolved launches/eight policies per tick; at most two spawn attempts. Cursors wrap
/// instead of walking retained history. Inventory reads share one request per socket in a page.
///
/// **One item never stops the loop.** Each launch observation, dispatch, cancellation and
/// policy admission is isolated: its failure becomes an issue and a bounded in-memory backoff
/// for that item, and the pass continues. Only `ControllerError.isFatalStorage` — a store this
/// process can no longer trust or write — propagates, because continuing then would only look
/// like supervision. A busy store is reported and retried on the next pass.
public actor ControllerSupervisor {
    private let store: ControllerStore
    private let database: String
    private let binary: String
    private var launchCursor: Int64 = 0
    private var policyCursor: Int64 = 0
    private var sweeping = false
    private var mailWakeCursor: Int64 = 0
    private var mailPeerCursor: Int64 = 0
    private var mailSyncRunning = false
    private var mailSyncStarted = Date.distantPast
    private var finishedMailSync: ControllerMailSync.Report?
    private var pollingSources: Set<SourceID> = []
    private var finishedSourceEvents = 0
    private var finishedSourceIssues: [String] = []
    private var collecting: Set<ExecutionID> = []
    private var finishedReceipts: [ExecutionID] = []
    private var finishedUsageIssues: [String] = []
    /// Sockets that failed to answer or to start a process, until when they are skipped.
    private var hostBackoff: [String: Backoff] = [:]
    /// Launches and workers whose last operation failed, until when they are skipped.
    private var quarantine: [String: Backoff] = [:]
    private var holds: [WorkerID: String] = [:]
    private var reportedHolds: [AdmissionHold]?
    private enum Budget {
        static let page = 8; static let starts = 2; static let mailSyncSeconds: TimeInterval = 15
        static let concurrentPolls = 2; static let reportedHolds = 32
    }
    private struct Backoff {
        var failures: Int
        var until: Date
        static let hostBase: TimeInterval = 5, hostCeiling: TimeInterval = 300
        static let itemBase: TimeInterval = 30, itemCeiling: TimeInterval = 900
        static let maximumExponent = 16
        static func next(after previous: Backoff?, base: TimeInterval, ceiling: TimeInterval) -> Backoff {
            let failures = (previous?.failures ?? 0) + 1
            let delay = min(ceiling, base * pow(2, Double(min(failures - 1, maximumExponent))))
            return Backoff(failures: failures, until: Date().addingTimeInterval(delay))
        }
    }

    public init(store: ControllerStore, database: String, controllerBinary: String) {
        self.store = store; self.database = database; self.binary = controllerBinary
    }

    /// `reportAllHolds` includes the current holds even when unchanged (a one-shot pass).
    public func tick(reportAllHolds: Bool = false) async throws -> SupervisorCycle {
        guard !sweeping else { throw ControllerError.conflict }
        sweeping = true
        defer { sweeping = false }
        var report = SupervisorCycle()
        // Admission failures never stop supervision of work that is already running: a busy
        // database or a broken rule is reported and retried on a later pass.
        do { report.scheduled = try await store.tickAutomations(limit: Budget.page).count }
        catch { try Self.rethrowIfFatal(error); report.automationIssues.append(String(describing: error)) }
        do {
            let wake = try await store.admitMailWakes(after: mailWakeCursor, limit: Budget.page)
            mailWakeCursor = wake.next
            report.woken = wake.admitted.map(\.id)
        } catch { try Self.rethrowIfFatal(error); report.automationIssues.append("mail_wake: \(error)") }
        do { report.expiredMail = try await store.expireOutboundMail(limit: Budget.page) }
        catch { try Self.rethrowIfFatal(error); report.automationIssues.append("mail_expiry: \(error)") }
        startMailSyncIfDue()
        if let finished = finishedMailSync { report.mail = finished; finishedMailSync = nil }
        do { try await startDueSourcePolls() } catch {
            try Self.rethrowIfFatal(error); report.sourceIssues.append("due_sources: \(error)")
        }
        report.sourceEvents = finishedSourceEvents; finishedSourceEvents = 0
        report.sourceIssues += finishedSourceIssues; finishedSourceIssues = []
        do { try await startUsageCollection() } catch {
            try Self.rethrowIfFatal(error); report.usageIssues.append("usage_pending: \(error)")
        }
        report.receipts = finishedReceipts; finishedReceipts = []
        report.usageIssues += finishedUsageIssues; finishedUsageIssues = []

        var attempts = 0
        do {
            let page = try await store.unresolvedLaunches(after: launchCursor, limit: Budget.page)
            launchCursor = page.items.isEmpty ? 0 : page.next
            try await observe(page.items.filter { $0.state != .prepared }, report: &report)
            for launch in page.items where launch.state == .prepared && launch.supervisorRevision != nil {
                let key = "launch:\(launch.executionID)"
                guard !isQuarantined(key) else { continue }
                do {
                    if try await store.cancelObsoletePreparation(launch.executionID) { continue }
                } catch {
                    try fail(key, error, report: &report) { .init(executionID: launch.executionID, code: "cancel_failed: \($0)") }
                    continue
                }
                // Reserve at least one attempt for another worker, even if old endpoints stay down.
                guard attempts < Budget.starts / 2, !isBackedOff(launch.spec.socketPath) else { continue }
                attempts += 1
                try await dispatch(launch.executionID, socketPath: launch.spec.socketPath, report: &report)
            }
        } catch {
            try Self.rethrowIfFatal(error)
            report.tickIssues.append("launches: \(Self.describe(error))")
        }
        try await admit(attempts: attempts, report: &report)
        let current = holds.sorted { $0.key.description < $1.key.description }
            .prefix(Budget.reportedHolds).map { AdmissionHold(workerID: $0.key, reason: $0.value) }
        if reportAllHolds || current != (reportedHolds ?? []) {
            report.held = current
            reportedHolds = current
        }
        return report
    }

    /// Reads each socket once, concurrently and bounded, then records whatever each host proves.
    private func observe(_ active: [ControllerLaunch], report: inout SupervisorCycle) async throws {
        let candidates = active.filter { !isQuarantined("launch:\($0.executionID)") }
        let bySocket = Dictionary(grouping: candidates, by: { $0.spec.socketPath })
        // At most eight independent bounded socket requests. Work on one unavailable endpoint
        // does not hold the others behind its timeout. Never attach or seize a user's terminal.
        let inventories = await withTaskGroup(of: InventoryResult.self, returning: [InventoryResult].self) { group in
            for (path, launches) in bySocket {
                group.addTask {
                    let ids = launches.map(\.executionID)
                    do { return InventoryResult(path: path, ids: ids, evidence: try ControllerPTYRuntime.evidence(socketPath: path)) }
                    catch { return InventoryResult(path: path, ids: ids, evidence: nil) }
                }
            }
            var results: [InventoryResult] = []
            for await result in group { results.append(result) }
            return results
        }
        for inventory in inventories {
            guard let evidence = inventory.evidence else {
                // A host that cannot answer is not asked to start more work until it does.
                hostBackoff[inventory.path] = Backoff.next(after: hostBackoff[inventory.path],
                                                           base: Backoff.hostBase, ceiling: Backoff.hostCeiling)
                for id in inventory.ids { report.issues.append(.init(executionID: id, code: "host_unavailable")) }
                continue
            }
            hostBackoff[inventory.path] = nil
            for id in inventory.ids {
                do {
                    let observation = try await ControllerPTYRuntime.observe(store: store, executionID: id, evidence: evidence)
                    report.observed += 1
                    switch observation.presence {
                    case .stopped: report.stopped.append(id)
                    case .absent: report.issues.append(.init(executionID: id, code: "process_unresolved"))
                    case .running: break
                    }
                } catch {
                    try fail("launch:\(id)", error, report: &report) { .init(executionID: id, code: "observe_failed: \($0)") }
                }
            }
            await ControllerPTYRuntime.acknowledgeRecorded(store: store, socketPath: inventory.path, evidence: evidence)
        }
    }

    /// Advance only through actually examined policies, not past a start budget boundary.
    private func admit(attempts initial: Int, report: inout SupervisorCycle) async throws {
        var attempts = initial
        for _ in 0..<Budget.page {
            guard attempts < Budget.starts else { break }
            let one: ControllerPage<WorkerPolicyStatus>
            do { one = try await store.workerPolicies(after: policyCursor, limit: 1) } catch {
                try Self.rethrowIfFatal(error)
                report.tickIssues.append("policies: \(Self.describe(error))")
                return
            }
            guard let policy = one.items.first else { policyCursor = 0; break }
            policyCursor = one.next
            let key = "worker:\(policy.workerID)"
            guard policy.enabled else { holds[policy.workerID] = nil; continue }
            guard !isQuarantined(key) else { holds[policy.workerID] = "quarantined"; continue }
            let admission: SupervisedAdmission
            do {
                admission = try await store.admitSupervisedLaunch(policy.workerID, unavailableHosts: backedOffHosts())
            } catch {
                try Self.rethrowIfFatal(error)
                if !((error as? ControllerError)?.isTransientStorage ?? false) {
                    quarantine[key] = Backoff.next(after: quarantine[key], base: Backoff.itemBase, ceiling: Backoff.itemCeiling)
                }
                report.workerIssues.append(.init(workerID: policy.workerID, code: "admission_failed: \(Self.describe(error))"))
                continue
            }
            quarantine[key] = nil
            switch admission {
            case .idle: holds[policy.workerID] = nil
            case .held(let reason): holds[policy.workerID] = reason
            case .prepared(let launch):
                holds[policy.workerID] = nil
                attempts += 1
                try await dispatch(launch.executionID, socketPath: launch.spec.socketPath, report: &report)
            }
        }
    }

    /// Peer exchanges run SSH with timeouts, so they run beside launch supervision rather than
    /// inside a tick, one pass at a time.
    private func startMailSyncIfDue() {
        guard !mailSyncRunning, Date().timeIntervalSince(mailSyncStarted) >= Budget.mailSyncSeconds else { return }
        mailSyncRunning = true
        mailSyncStarted = Date()
        let store = store, cursor = mailPeerCursor
        Task {
            let result: (ControllerMailSync.Report, Int64)
            do { result = try await ControllerMailSync.sync(store: store, after: cursor) }
            catch {
                var report = ControllerMailSync.Report()
                report.issues.append(ControllerMailSync.describe(error))
                result = (report, 0)
            }
            self.finishMailSync(result.0, next: result.1)
        }
    }
    /// Probes run with timeouts of up to five minutes, so at most two run at once, beside launch
    /// supervision and never inside a tick. A slow source cannot delay another one's deadline
    /// past the next tick: each is claimed (its next deadline written) before it runs.
    private func startDueSourcePolls() async throws {
        let available = Budget.concurrentPolls - pollingSources.count
        guard available > 0 else { return }
        for source in try await store.dueSources(limit: Budget.page) where !pollingSources.contains(source.id) {
            guard pollingSources.count < Budget.concurrentPolls else { break }
            pollingSources.insert(source.id)
            let store = store, database = database, id = source.id
            Task {
                do {
                    let events = try await ControllerSourcePoller.poll(store: store, id: id, database: database)
                    self.finishSourcePoll(id, events: events.count, issue: nil)
                } catch {
                    self.finishSourcePoll(id, events: 0, issue: "\(id): \(error)")
                }
            }
        }
    }
    /// Reading a transcript can take a while for a long run, so receipts are written beside
    /// supervision, two at a time, from the pending list confirmed stops leave behind. A failed
    /// collection is reported, not swallowed; the execution stays pending for the next pass.
    private func startUsageCollection() async throws {
        for id in try await store.pendingUsage(limit: Budget.page) where !collecting.contains(id) {
            guard collecting.count < Budget.concurrentPolls else { break }
            collecting.insert(id)
            let store = store
            Task {
                do {
                    _ = try await ControllerUsageCollector.collect(store: store, executionID: id)
                    self.finishCollection(id, issue: nil)
                } catch {
                    self.finishCollection(id, issue: "\(id): \(Self.describe(error))")
                }
            }
        }
    }
    private func finishCollection(_ id: ExecutionID, issue: String?) {
        collecting.remove(id)
        if let issue { finishedUsageIssues.append(issue) } else { finishedReceipts.append(id) }
    }

    private func finishSourcePoll(_ id: SourceID, events: Int, issue: String?) {
        pollingSources.remove(id)
        finishedSourceEvents += events
        if let issue { finishedSourceIssues.append(issue) }
    }

    private func finishMailSync(_ report: ControllerMailSync.Report, next: Int64) {
        mailSyncRunning = false
        mailPeerCursor = next
        if !report.isEmpty { finishedMailSync = report }
    }

    private func dispatch(_ id: ExecutionID, socketPath: String, report: inout SupervisorCycle) async throws {
        let key = "launch:\(id)"
        do {
            _ = try await ControllerPTYRuntime.dispatch(store: store, executionID: id, database: database, controllerBinary: binary)
            report.started.append(id)
            hostBackoff[socketPath] = nil
        } catch ControllerRuntimeError.spawnRefused(let reason) {
            if reason == .alreadyExists {
                report.issues.append(.init(executionID: id, code: "spawn_refused"))
            } else if reason.isTransient {
                // No process started; the work is queued again and the host is given time.
                backOff(socketPath)
                report.requeued.append(id)
                report.issues.append(.init(executionID: id, code: "spawn_deferred_\(reason.rawValue)"))
            } else {
                // A broken recipe must not drain the queue; a newer owner revision is kept.
                let paused: Bool
                do { paused = try await store.pauseWorkerAfterLaunchRefusal(id) } catch {
                    try fail(key, error, report: &report) { .init(executionID: id, code: "pause_failed: \($0)") }
                    return
                }
                report.issues.append(.init(executionID: id, code: paused ? "worker_paused_after_spawn_refusal" : "spawn_refused"))
            }
        } catch ControllerRuntimeError.spawnFailed {
            backOff(socketPath)
            report.requeued.append(id)
            report.issues.append(.init(executionID: id, code: "spawn_failed_requeued"))
        } catch let error as ControllerError where error == .conflict {
            // A concurrent owner can change/pause the recipe.
            report.issues.append(.init(executionID: id, code: "dispatch_conflict"))
        } catch ControllerRuntimeError.unavailable {
            backOff(socketPath)
            report.issues.append(.init(executionID: id, code: "dispatch_failed"))
        } catch {
            // Surface one bounded observation. The durable launch tells recovery whether the
            // failure happened before dispatch, after send, or as an explicit spawn refusal.
            try fail(key, error, report: &report) { _ in .init(executionID: id, code: "dispatch_failed") }
        }
    }

    private func backOff(_ socketPath: String) {
        hostBackoff[socketPath] = Backoff.next(after: hostBackoff[socketPath], base: Backoff.hostBase, ceiling: Backoff.hostCeiling)
    }
    private func isBackedOff(_ socketPath: String) -> Bool { (hostBackoff[socketPath]?.until ?? .distantPast) > Date() }
    private func backedOffHosts() -> Set<String> { Set(hostBackoff.filter { $0.value.until > Date() }.keys) }
    private func isQuarantined(_ key: String) -> Bool { (quarantine[key]?.until ?? .distantPast) > Date() }

    /// Records one item's failure. A busy store is retried next pass without quarantine; a fatal
    /// store error propagates; anything else skips the item for a growing interval.
    private func fail(_ key: String, _ error: Error, report: inout SupervisorCycle,
                      issue: (String) -> SupervisorIssue) throws {
        try Self.rethrowIfFatal(error)
        if !((error as? ControllerError)?.isTransientStorage ?? false) {
            quarantine[key] = Backoff.next(after: quarantine[key], base: Backoff.itemBase, ceiling: Backoff.itemCeiling)
        }
        report.issues.append(issue(Self.describe(error)))
    }

    static func rethrowIfFatal(_ error: Error) throws {
        if let error = error as? ControllerError, error.isFatalStorage { throw error }
    }

    public static func describe(_ error: Error) -> String {
        if let error = error as? ControllerError { return error.description }
        if let error = error as? ControllerRuntimeError {
            switch error {
            case .processIdentityMismatch: return "process_identity_mismatch"
            case .unavailable: return "host_unavailable"
            case .timedOut: return "timed_out"
            case .protocolFailure: return "protocol_failure"
            case .overflow: return "overflow"
            case .spawnRefused(let reason): return "spawn_refused_\(reason.rawValue)"
            case .spawnFailed: return "spawn_failed"
            }
        }
        return "error"
    }
}

private struct InventoryResult: Sendable {
    let path: String
    let ids: [ExecutionID]
    let evidence: HostEvidence?
}
