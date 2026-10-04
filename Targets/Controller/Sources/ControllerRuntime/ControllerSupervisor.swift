import Foundation
import ThreadingController
import ThreadingPTYHostKit

public struct SupervisorIssue: Codable, Sendable {
    public let executionID: ExecutionID
    public let code: String
}
public struct SupervisorCycle: Codable, Sendable {
    public var scheduled = 0
    public var observed = 0
    public var started: [ExecutionID] = []
    public var stopped: [ExecutionID] = []
    public var issues: [SupervisorIssue] = []
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
    /// Usage receipts written since the last report.
    public var receipts: [ExecutionID] = []
}

/// One serial sweep owner. The database remains the admission authority across processes.
/// Eight unresolved launches/eight policies per tick; at most two spawn attempts. Cursors wrap
/// instead of walking retained history. Inventory reads share one request per socket in a page.
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
    private enum Budget { static let page = 8; static let starts = 2; static let mailSyncSeconds: TimeInterval = 15; static let concurrentPolls = 2 }

    public init(store: ControllerStore, database: String, controllerBinary: String) {
        self.store = store; self.database = database; self.binary = controllerBinary
    }

    public func tick() async throws -> SupervisorCycle {
        guard !sweeping else { throw ControllerError.conflict }
        sweeping = true
        defer { sweeping = false }
        var report = SupervisorCycle()
        // Admission failures never stop supervision of work that is already running: a busy
        // database or a broken rule is reported and retried on a later pass.
        do { report.scheduled = try await store.tickAutomations(limit: Budget.page).count }
        catch { report.automationIssues.append(String(describing: error)) }
        do {
            let wake = try await store.admitMailWakes(after: mailWakeCursor, limit: Budget.page)
            mailWakeCursor = wake.next
            report.woken = wake.admitted.map(\.id)
        } catch { report.automationIssues.append("mail_wake: \(error)") }
        do { report.expiredMail = try await store.expireOutboundMail(limit: Budget.page) }
        catch { report.automationIssues.append("mail_expiry: \(error)") }
        startMailSyncIfDue()
        if let finished = finishedMailSync { report.mail = finished; finishedMailSync = nil }
        do { try await startDueSourcePolls() } catch { report.sourceIssues.append("due_sources: \(error)") }
        report.sourceEvents = finishedSourceEvents; finishedSourceEvents = 0
        report.sourceIssues += finishedSourceIssues; finishedSourceIssues = []
        do { try await startUsageCollection() } catch { report.automationIssues.append("usage_pending: \(error)") }
        report.receipts = finishedReceipts; finishedReceipts = []
        let page = try await store.unresolvedLaunches(after: launchCursor, limit: Budget.page)
        launchCursor = page.items.isEmpty ? 0 : page.next
        let active = page.items.filter { $0.state != .prepared }
        let bySocket = Dictionary(grouping: active, by: { $0.spec.socketPath })
        // At most eight independent bounded socket requests. Work on one unavailable endpoint
        // does not hold the others behind its timeout. Never attach or seize a user's terminal.
        let inventories = await withTaskGroup(of: InventoryResult.self, returning: [InventoryResult].self) { group in
            for (path, launches) in bySocket {
                group.addTask {
                    do { return InventoryResult(ids: launches.map(\.executionID), sessions: try ControllerPTYRuntime.inventory(socketPath: path)) }
                    catch { return InventoryResult(ids: launches.map(\.executionID), sessions: nil) }
                }
            }
            var results: [InventoryResult] = []
            for await result in group { results.append(result) }
            return results
        }
        for inventory in inventories {
            for id in inventory.ids {
                guard let sessions = inventory.sessions else {
                    report.issues.append(.init(executionID: id, code: "host_unavailable")); continue
                }
                let observation = try await ControllerPTYRuntime.observe(store: store, executionID: id, sessions: sessions)
                report.observed += 1
                switch observation.presence {
                case .stopped: report.stopped.append(id)
                case .absent: report.issues.append(.init(executionID: id, code: "process_unresolved"))
                case .running: break
                }
            }
        }
        var attempts = 0
        for launch in page.items where launch.state == .prepared && launch.supervisorRevision != nil {
            if try await store.cancelObsoletePreparation(launch.executionID) { continue }
            // Reserve at least one attempt for another worker, even if old endpoints stay down.
            guard attempts < Budget.starts / 2 else { continue }
            attempts += 1
            try await dispatch(launch.executionID, report: &report)
        }
        // Advance only through actually examined policies, not past a start budget boundary.
        for _ in 0..<Budget.page {
            guard attempts < Budget.starts else { break }
            let one = try await store.workerPolicies(after: policyCursor, limit: 1)
            guard let policy = one.items.first else { policyCursor = 0; break }
            policyCursor = one.next
            guard policy.enabled, let launch = try await store.prepareSupervisedLaunch(policy.workerID) else { continue }
            attempts += 1
            try await dispatch(launch.executionID, report: &report)
        }
        return report
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
    /// supervision, two at a time, from the pending list confirmed stops leave behind.
    private func startUsageCollection() async throws {
        for id in try await store.pendingUsage(limit: Budget.page) where !collecting.contains(id) {
            guard collecting.count < Budget.concurrentPolls else { break }
            collecting.insert(id)
            let store = store
            Task {
                let written = (try? await ControllerUsageCollector.collect(store: store, executionID: id)) != nil
                self.finishCollection(id, written: written)
            }
        }
    }
    private func finishCollection(_ id: ExecutionID, written: Bool) {
        collecting.remove(id)
        if written { finishedReceipts.append(id) }
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

    private func dispatch(_ id: ExecutionID, report: inout SupervisorCycle) async throws {
        do {
            _ = try await ControllerPTYRuntime.dispatch(store: store, executionID: id, database: database, controllerBinary: binary)
            report.started.append(id)
        } catch ControllerRuntimeError.spawnRefused(let reason) {
            if reason != .alreadyExists, try await store.pauseWorkerAfterLaunchRefusal(id) {
                report.issues.append(.init(executionID: id, code: "worker_paused_after_spawn_refusal"))
            } else { report.issues.append(.init(executionID: id, code: "spawn_refused")) }
        } catch let error as ControllerError {
            // A concurrent owner can change/pause the recipe. Persistence failures are fatal;
            // continuing on corrupt or unwritable state would falsely look like supervision.
            guard error == .conflict else { throw error }
            report.issues.append(.init(executionID: id, code: "dispatch_conflict"))
        } catch {
            // Surface one bounded observation. The durable launch tells recovery whether the
            // failure happened before dispatch, after send, or as an explicit spawn refusal.
            report.issues.append(.init(executionID: id, code: "dispatch_failed"))
        }
    }
}

private struct InventoryResult: Sendable {
    let ids: [ExecutionID]
    let sessions: [PTYHostSessionSummary]?
}
