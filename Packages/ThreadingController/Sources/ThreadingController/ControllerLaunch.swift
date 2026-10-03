import Foundation

/// Trusted owner configuration, never inferred from a work item or agent response.
public struct ControllerLaunchSpec: Codable, Equatable, Sendable {
    public let socketPath: String
    public let executable: String
    public let arguments: [String]
    public let environment: [String: String]
    public let directory: String
    public let recipients: [String]
    public let destination: String
    /// Where the runtime's transcript is, so a receipt can be written when the process stops.
    public let usage: ControllerUsageSource?

    public init(socketPath: String, executable: String, arguments: [String], environment: [String: String],
                directory: String, recipients: [String], destination: String, usage: ControllerUsageSource? = nil) {
        self.socketPath = socketPath; self.executable = executable; self.arguments = arguments
        self.environment = environment; self.directory = directory
        self.recipients = recipients; self.destination = destination; self.usage = usage
    }

    func validate() throws {
        for path in [socketPath, executable, directory] {
            try Limits.text(path, field: "launch_path", maximum: 4096)
            guard path.hasPrefix("/") else { throw ControllerError.invalidInput("absolute_launch_path") }
        }
        guard arguments.count <= 64, environment.count <= 128,
              try JSONEncoder().encode(self).count <= 32_768 else { throw ControllerError.invalidInput("launch_size") }
        for value in arguments + Array(environment.values) {
            guard !value.contains("\0") else { throw ControllerError.invalidInput("launch_value") }
        }
        for key in environment.keys {
            guard !key.isEmpty, !key.contains("="), !key.contains("\0"), !key.hasPrefix("THREADING_") else {
                throw ControllerError.invalidInput("environment_key")
            }
        }
        guard (1...32).contains(recipients.count), Set(recipients).count == recipients.count else {
            throw ControllerError.invalidInput("recipients")
        }
        for recipient in recipients { try Limits.recipient(recipient) }
        try Limits.text(destination, field: "destination", maximum: 256)
        try usage?.validate()
    }
}

public enum LaunchState: String, Codable, Sendable { case prepared, dispatching, running, stopped }
public struct ControllerLaunch: Codable, Equatable, Sendable {
    public let executionID: ExecutionID
    public let workID: WorkID
    public let spec: ControllerLaunchSpec
    public let supervisorRevision: Int?
    public internal(set) var state: LaunchState
    public internal(set) var pid: Int32?
    public internal(set) var startSeconds: UInt64?
    public internal(set) var startMicroseconds: UInt64?
    public internal(set) var exitStatus: Int32?
}

/// Status deliberately omits argv, environment and credentials. Recipes may contain secrets
/// or prompts; inspecting a process must not print them into an operator's logs.
public struct ControllerLaunchStatus: Codable, Equatable, Sendable {
    public let executionID: ExecutionID
    public let workID: WorkID
    public let socketPath: String
    public let state: LaunchState
    public let pid: Int32?
    public let startSeconds: UInt64?
    public let startMicroseconds: UInt64?
    public let exitStatus: Int32?
    public init(_ launch: ControllerLaunch) {
        executionID = launch.executionID; workID = launch.workID; socketPath = launch.spec.socketPath
        state = launch.state; pid = launch.pid; startSeconds = launch.startSeconds
        startMicroseconds = launch.startMicroseconds; exitStatus = launch.exitStatus
    }
}

extension ControllerStore {
    /// Claim and launch intent commit together; a crash cannot leave a claim without its intent.
    public func prepareLaunch(workerID: WorkerID, spec: ControllerLaunchSpec) throws -> ControllerLaunch? {
        try prepareLaunch(workerID: workerID, spec: spec, supervisorRevision: nil)
    }
    func prepareLaunch(workerID: WorkerID, spec: ControllerLaunchSpec, supervisorRevision: Int?) throws -> ControllerLaunch? {
        try spec.validate()
        return try db.transaction {
            guard let claim = try claim(workerID: workerID) else { return nil }
            let launch = ControllerLaunch(executionID: claim.execution.id, workID: claim.work.id, spec: spec, supervisorRevision: supervisorRevision,
                                          state: .prepared, pid: nil, startSeconds: nil, startMicroseconds: nil, exitStatus: nil)
            try insert("launch", launch.executionID.description, parent: claim.work.id.description,
                       state: launch.state.rawValue, scope: workerID.description, value: launch)
            // Private bearer routing credential, never included in launch/status/event output.
            let credential = UUID().uuidString + UUID().uuidString
            try insert("executionCredential", launch.executionID.description, value: credential)
            try event("launch.prepared", launch.executionID.description)
            return launch
        }
    }

    public func launch(_ id: ExecutionID) throws -> ControllerLaunch { try required("launch", id.description) }
    public func launches(workID: WorkID, after: Int64 = 0, limit: Int = 50) throws -> ControllerPage<ControllerLaunch> {
        try page("launch", parent: workID.description, after: after, limit: limit)
    }
    public func launchStatuses(workID: WorkID, after: Int64 = 0, limit: Int = 50) throws -> ControllerPage<ControllerLaunchStatus> {
        let page = try launches(workID: workID, after: after, limit: limit)
        return ControllerPage(items: page.items.map(ControllerLaunchStatus.init), next: page.next)
    }

    /// This is the only right to send spawn. Never send again after an uncertain response.
    public func beginLaunch(_ id: ExecutionID) throws -> ControllerLaunch {
        try db.transaction {
            var value = try launch(id)
            guard value.state == .prepared else { throw ControllerError.conflict }
            if let revision = value.supervisorRevision {
                let work = try work(value.workID)
                let policy = try requiredPolicy(work.workerID)
                guard policy.enabled, policy.revision == revision else { throw ControllerError.conflict }
            }
            _ = try running(id)
            value.state = .dispatching
            try saveLaunch(value)
            return value
        }
    }
    public func launchCredential(_ id: ExecutionID) throws -> String {
        let value = try launch(id)
        guard value.state == .dispatching else { throw ControllerError.conflict }
        return try required("executionCredential", id.description)
    }
    public func recordSpawn(_ id: ExecutionID, pid: Int32, seconds: UInt64, microseconds: UInt64) throws -> ControllerLaunch {
        try db.transaction {
            var value = try launch(id)
            guard pid > 0, microseconds < 1_000_000 else { throw ControllerError.invalidInput("process_identity") }
            if value.state == .running {
                guard value.pid == pid, value.startSeconds == seconds, value.startMicroseconds == microseconds else {
                    throw ControllerError.conflict
                }
                return value
            }
            guard value.state == .dispatching else { throw ControllerError.conflict }
            value.state = .running; value.pid = pid
            value.startSeconds = seconds; value.startMicroseconds = microseconds
            try saveLaunch(value)
            return value
        }
    }

    /// Trusted runtime receipt or explicit operator confirmation, not an agent tool. Absence
    /// from an inventory and a timeout are NOT confirmation. Exit alone never finishes work.
    public func confirmLaunchStopped(_ id: ExecutionID, exitStatus: Int32?) throws -> ControllerLaunch {
        try db.transaction {
            var value = try launch(id)
            if value.state == .stopped { return value }
            value.state = .stopped; value.exitStatus = exitStatus
            if value.spec.usage != nil {
                try db.run("INSERT OR IGNORE INTO usage_pending(execution) VALUES(?)", [.text(id.description)])
            }
            let execution: ControllerExecution = try required("execution", id.description)
            if execution.state == .running { _ = try interrupt(executionID: id) }
            try saveLaunch(value)
            return value
        }
    }
    func saveLaunch(_ launch: ControllerLaunch) throws {
        try update("launch", launch.executionID.description, state: launch.state.rawValue, value: launch)
        try event("launch.\(launch.state.rawValue)", launch.executionID.description)
    }
}
