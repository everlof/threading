import Foundation

public enum ControllerSupervisorLimits {
    public static let maximumActiveLaunches = 32
}

public struct ControllerWorkerPolicy: Codable, Equatable, Sendable {
    public let workerID: WorkerID
    public let revision: Int
    public let enabled: Bool
    public let maximumConcurrent: Int
    public let spec: ControllerLaunchSpec
}

/// Public inspection excludes command arguments, environment and other private recipe data.
public struct WorkerPolicyStatus: Codable, Sendable {
    public let workerID: WorkerID
    public let revision: Int
    public let enabled: Bool
    public let maximumConcurrent: Int
    public init(_ policy: ControllerWorkerPolicy) {
        workerID = policy.workerID; revision = policy.revision
        enabled = policy.enabled; maximumConcurrent = policy.maximumConcurrent
    }
}

extension ControllerStore {
    public func workerPolicy(_ workerID: WorkerID) throws -> WorkerPolicyStatus? {
        let policy: ControllerWorkerPolicy? = try optional("workerPolicy", workerID.description)
        return policy.map(WorkerPolicyStatus.init)
    }
    public func workerPolicies(after: Int64 = 0, limit: Int = 8) throws -> ControllerPage<WorkerPolicyStatus> {
        let policies: ControllerPage<ControllerWorkerPolicy> = try page("workerPolicy", after: after, limit: limit)
        return ControllerPage(items: policies.items.map(WorkerPolicyStatus.init), next: policies.next)
    }
    /// New recipes start paused; replacing an enabled recipe also pauses it for explicit enable.
    public func configureWorker(_ workerID: WorkerID, expectedRevision: Int, maximumConcurrent: Int,
                                spec: ControllerLaunchSpec) throws -> WorkerPolicyStatus {
        try spec.validate()
        guard (1...8).contains(maximumConcurrent), expectedRevision >= 0, expectedRevision < Int.max else {
            throw ControllerError.invalidInput("worker_policy")
        }
        return try db.transaction {
            let _: ControllerWorker = try required("worker", workerID.description)
            try requireActiveWorker(workerID)
            let old: ControllerWorkerPolicy? = try optional("workerPolicy", workerID.description)
            guard (old?.revision ?? 0) == expectedRevision else { throw ControllerError.conflict }
            let policy = ControllerWorkerPolicy(workerID: workerID, revision: expectedRevision + 1, enabled: false,
                                                maximumConcurrent: maximumConcurrent, spec: spec)
            if old == nil { try insert("workerPolicy", workerID.description, value: policy) }
            else { try update("workerPolicy", workerID.description, value: policy) }
            try event("worker.configured", workerID.description)
            return WorkerPolicyStatus(policy)
        }
    }
    /// Trusted owner reconciliation. A response loss can be retried without pausing a worker
    /// or repeatedly invalidating prepared launches. Never changes the owner's enable intent.
    public func reconcileWorker(_ workerID: WorkerID, expectedRevision: Int,
                                spec: ControllerLaunchSpec) throws -> WorkerPolicyStatus {
        try spec.validate()
        return try db.transaction {
            try requireActiveWorker(workerID)
            let old = try requiredPolicy(workerID)
            guard old.revision == expectedRevision, expectedRevision < Int.max else { throw ControllerError.conflict }
            if old.spec == spec { return WorkerPolicyStatus(old) }
            let policy = ControllerWorkerPolicy(workerID: workerID, revision: old.revision + 1,
                enabled: old.enabled, maximumConcurrent: old.maximumConcurrent, spec: spec)
            try update("workerPolicy", workerID.description, value: policy)
            try event("worker.reconciled", workerID.description)
            return WorkerPolicyStatus(policy)
        }
    }
    public func setWorkerEnabled(_ workerID: WorkerID, expectedRevision: Int, enabled: Bool) throws -> WorkerPolicyStatus {
        try db.transaction {
            try requireActiveWorker(workerID)
            let old = try requiredPolicy(workerID)
            guard old.revision == expectedRevision, expectedRevision < Int.max else { throw ControllerError.conflict }
            let policy = ControllerWorkerPolicy(workerID: workerID, revision: old.revision + 1, enabled: enabled,
                                                maximumConcurrent: old.maximumConcurrent, spec: old.spec)
            try update("workerPolicy", workerID.description, value: policy)
            try event(enabled ? "worker.enabled" : "worker.paused", workerID.description)
            return WorkerPolicyStatus(policy)
        }
    }
    /// Limits count all unresolved launches, including manual and uncertain ones. Admission and
    /// claim share the write lock, so even different supervisor processes cannot overbook a slot.
    public func prepareSupervisedLaunch(_ workerID: WorkerID) throws -> ControllerLaunch? {
        try db.transaction {
            let policy = try requiredPolicy(workerID)
            guard policy.enabled else { return nil }
            let total = try db.rows("""
                SELECT id FROM record INDEXED BY unresolved_launch WHERE kind='launch'
                AND state IN ('prepared','dispatching','running') LIMIT ?
                """, [.integer(Int64(ControllerSupervisorLimits.maximumActiveLaunches))])
            guard total.count < ControllerSupervisorLimits.maximumActiveLaunches else { return nil }
            let active = try db.rows("""
                SELECT id FROM record WHERE kind='launch' AND scope=?
                AND state IN ('prepared','dispatching','running') LIMIT ?
                """, [.text(workerID.description), .integer(Int64(policy.maximumConcurrent))])
            guard active.count < policy.maximumConcurrent else { return nil }
            return try prepareLaunch(workerID: workerID, spec: policy.spec, supervisorRevision: policy.revision)
        }
    }
    public func unresolvedLaunches(after: Int64 = 0, limit: Int = 8) throws -> ControllerPage<ControllerLaunch> {
        try Limits.page(after, limit)
        let rows = try db.rows("""
            SELECT sequence,payload FROM record INDEXED BY unresolved_launch WHERE kind='launch'
            AND state IN ('prepared','dispatching','running') AND sequence>? ORDER BY sequence LIMIT ?
            """, [.integer(after), .integer(Int64(limit))], pageByteLimit: 1_048_576)
        return ControllerPage(items: try rows.map { try decode($0.text(1)) }, next: rows.last?.integers[0] ?? after)
    }
    public func activeLaunchStatuses(after: Int64 = 0, limit: Int = 50) throws -> ControllerPage<ControllerLaunchStatus> {
        let page = try unresolvedLaunches(after: after, limit: limit)
        return ControllerPage(items: page.items.map(ControllerLaunchStatus.init), next: page.next)
    }
    /// Only a never-dispatched intent may be cancelled and requeued automatically. A concurrent
    /// dispatcher either wins first or observes the new policy; no network effect is undone.
    public func cancelObsoletePreparation(_ id: ExecutionID) throws -> Bool {
        try db.transaction {
            let launch = try launch(id)
            guard launch.state == .prepared, let revision = launch.supervisorRevision else { return false }
            let work = try work(launch.workID)
            let policy = try requiredPolicy(work.workerID)
            guard !policy.enabled || policy.revision != revision else { return false }
            _ = try confirmLaunchStopped(id, exitStatus: nil)
            // Owner intervention may already have changed the work state.
            if try self.work(work.id).state == .interrupted { _ = try retry(workID: work.id) }
            try event("launch.preparation_cancelled", id.description)
            return true
        }
    }
    /// A definite spawn refusal must not drain an entire queue through a broken recipe. The
    /// runtime calls this only for a refusal receipt; newer owner configuration always wins.
    public func pauseWorkerAfterLaunchRefusal(_ id: ExecutionID) throws -> Bool {
        try db.transaction {
            let launch = try launch(id)
            guard launch.state == .stopped, let revision = launch.supervisorRevision else { return false }
            let work = try work(launch.workID)
            let policy = try requiredPolicy(work.workerID)
            guard policy.enabled, policy.revision == revision else { return false }
            _ = try setWorkerEnabled(work.workerID, expectedRevision: revision, enabled: false)
            try event("worker.launch_refused", work.workerID.description)
            return true
        }
    }
    func requiredPolicy(_ id: WorkerID) throws -> ControllerWorkerPolicy {
        let policy: ControllerWorkerPolicy = try required("workerPolicy", id.description)
        guard policy.workerID == id, policy.revision > 0, (1...8).contains(policy.maximumConcurrent) else {
            throw ControllerError.invalidInput("stored_worker_policy")
        }
        try policy.spec.validate()
        return policy
    }
}
