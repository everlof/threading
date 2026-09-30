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
    private enum Budget { static let page = 8; static let starts = 2 }

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
