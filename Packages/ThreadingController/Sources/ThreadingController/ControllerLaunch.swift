import Foundation

/// Trusted owner configuration, never inferred from a work item or agent response.
public struct ControllerLaunchSpec: Codable, Equatable, Sendable {
    public let socketPath: String
    public let executable: String
    public let arguments: [String]
    /// Plain values, stored in every policy and launch row (and so in backups). Never put a
    /// credential here: name it in `secrets` instead.
    public let environment: [String: String]
    /// Environment name -> secret name (written by `secret-set`), resolved by the runtime at
    /// dispatch. Only the name is stored; the value never enters the database.
    public let secrets: [String: String]
    public let directory: String
    public let recipients: [String]
    public let destination: String
    /// Where the runtime's transcript is, so a receipt can be written when the process stops.
    public let usage: ControllerUsageSource?

    public init(socketPath: String, executable: String, arguments: [String], environment: [String: String],
                directory: String, recipients: [String], destination: String, usage: ControllerUsageSource? = nil,
                secrets: [String: String] = [:]) {
        self.socketPath = socketPath; self.executable = executable; self.arguments = arguments
        self.environment = environment; self.secrets = secrets; self.directory = directory
        self.recipients = recipients; self.destination = destination; self.usage = usage
    }
    public init(from decoder: any Decoder) throws {
        enum Keys: String, CodingKey { case socketPath, executable, arguments, environment, secrets, directory, recipients, destination, usage }
        let c = try decoder.container(keyedBy: Keys.self)
        socketPath = try c.decode(String.self, forKey: .socketPath)
        executable = try c.decode(String.self, forKey: .executable)
        arguments = try c.decode([String].self, forKey: .arguments)
        environment = try c.decode([String: String].self, forKey: .environment)
        secrets = try c.decodeIfPresent([String: String].self, forKey: .secrets) ?? [:]
        directory = try c.decode(String.self, forKey: .directory)
        recipients = try c.decode([String].self, forKey: .recipients)
        destination = try c.decode(String.self, forKey: .destination)
        usage = try c.decodeIfPresent(ControllerUsageSource.self, forKey: .usage)
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
        for key in Array(environment.keys) + Array(secrets.keys) {
            guard !key.isEmpty, !key.contains("="), !key.contains("\0"), !key.hasPrefix("THREADING_") else {
                throw ControllerError.invalidInput("environment_key")
            }
        }
        guard secrets.count <= Self.maximumSecrets, Set(secrets.keys).isDisjoint(with: environment.keys),
              secrets.values.allSatisfy(SecretName.isValid) else { throw ControllerError.invalidInput("launch_secrets") }
        guard (1...32).contains(recipients.count), Set(recipients).count == recipients.count else {
            throw ControllerError.invalidInput("recipients")
        }
        for recipient in recipients { try Limits.recipient(recipient) }
        try Limits.text(destination, field: "destination", maximum: 256)
        try usage?.validate()
    }
    static let maximumSecrets = 16
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
    public internal(set) var startedAt: String?
    public internal(set) var stoppedAt: String?
    /// The first bound transcript; kept for older readers. See `transcriptBindings`.
    public internal(set) var providerTranscript: ProviderTranscript?
    /// One binding per declared account home an attempt ran under, in report order.
    public internal(set) var providerTranscripts: [ProviderTranscriptBinding]?
    public internal(set) var providerTranscriptChanged: Bool?
    /// Why the launch stopped, when it was not a clean finish: bounded tokens, never prose.
    public internal(set) var failure: ControllerLaunchFailure?
    /// The child's last output when it exited non-zero, signalled or before its work finished.
    /// Control sequences are removed and the recipe's argument/environment values and the
    /// execution credential are redacted; bounded by `ControllerOutputTail.maximumBytes`.
    public internal(set) var outputTail: String?
}

/// A bounded diagnosis of a launch that did not end in a clean finish. `stage` says where it
/// ended (`spawn`, `exit`, `host`, `owner`, `preparation`), `reason` is a token, `errorNumber`
/// the operating system's errno for a machine failure, and `incident` the ptyd recovery event
/// that reported a loss.
public struct ControllerLaunchFailure: Codable, Equatable, Sendable {
    public let stage: String
    public let reason: String
    public let errorNumber: Int32?
    public let incident: String?
    public init(stage: String, reason: String, errorNumber: Int32? = nil, incident: String? = nil) {
        self.stage = stage; self.reason = reason; self.errorNumber = errorNumber; self.incident = incident
    }
}

/// What establishes that a launch's process is not running. Each case is definite evidence; an
/// absent inventory entry or a timeout is not, and has no case here.
public enum ControllerStopEvidence: Sendable, Equatable {
    /// A ptyd exit receipt. `tail` is the raw last output, redacted before it is stored.
    case exited(status: Int32, signalled: Bool, tail: Data?)
    /// A restarted ptyd reported the session lost and reclaimed its process group.
    case hostLost(incident: UUID?)
    /// ptyd refused the spawn with this token; no process was started.
    case spawnRefused(String)
    /// ptyd's fork failed; no process was started.
    case spawnFailed(errorNumber: Int32?)
    /// The owner asserted the stop from independent evidence.
    case ownerConfirmed
    /// A never-dispatched intent was cancelled because its policy revision changed.
    case preparationCancelled
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
    public let startedAt: String?
    public let stoppedAt: String?
    public let failure: ControllerLaunchFailure?
    /// Already redacted and bounded when stored; see `ControllerLaunch.outputTail`.
    public let outputTail: String?
    public init(_ launch: ControllerLaunch) {
        executionID = launch.executionID; workID = launch.workID; socketPath = launch.spec.socketPath
        state = launch.state; pid = launch.pid; startSeconds = launch.startSeconds
        startMicroseconds = launch.startMicroseconds; exitStatus = launch.exitStatus
        startedAt = launch.startedAt; stoppedAt = launch.stoppedAt
        failure = launch.failure; outputTail = launch.outputTail
    }
}

extension ControllerStore {
    /// Claim and launch intent commit together; a crash cannot leave a claim without its intent.
    ///
    /// An owner's manual launch passes the same budget admission as supervised work, judged on
    /// the recipe it will actually run. `overrideBudget` admits it anyway and records
    /// `launch.budget_overridden` with the refused reason. Capacity holds and the paused flag
    /// are supervisor policy and do not apply to a manual launch.
    public func prepareLaunch(workerID: WorkerID, spec: ControllerLaunchSpec, overrideBudget: Bool = false) throws -> ControllerLaunch? {
        try spec.validate()
        return try db.transaction {
            let budget = try budgetDecision(workerID, usage: spec.usage).reason
            guard budget == .ready || overrideBudget else { throw ControllerError.invalidInput("worker_capacity_\(budget.rawValue)") }
            guard let launch = try prepareLaunch(workerID: workerID, spec: spec, supervisorRevision: nil) else { return nil }
            if budget != .ready {
                try event("launch.budget_overridden", launch.executionID.description, text: budget.rawValue, source: "owner")
            }
            return launch
        }
    }
    func prepareLaunch(workerID: WorkerID, spec: ControllerLaunchSpec, supervisorRevision: Int?) throws -> ControllerLaunch? {
        try spec.validate()
        return try db.transaction {
            guard let claim = try claim(workerID: workerID) else { return nil }
            let launch = ControllerLaunch(executionID: claim.execution.id, workID: claim.work.id, spec: spec, supervisorRevision: supervisorRevision,
                                          state: .prepared, pid: nil, startSeconds: nil, startMicroseconds: nil, exitStatus: nil)
            try insert("launch", launch.executionID.description, parent: claim.work.id.description,
                       state: launch.state.rawValue, scope: workerID.description, value: launch)
            try db.run("INSERT INTO usage_unsettled(execution,worker) VALUES(?,?)", [.text(launch.executionID.description), .text(workerID.description)])
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
            value.state = .dispatching; value.startedAt = Self.now()
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
        try recordLaunchStopped(id, evidence: exitStatus.map { .exited(status: $0, signalled: false, tail: nil) } ?? .ownerConfirmed)
    }

    /// Records definite stop evidence. Unfinished work is interrupted, as before; `requeue`
    /// instead returns it to the queue, which is only correct when no process ever started
    /// (a transient spawn refusal or fork failure). `expectedState` fences an owner's assertion
    /// against a launch that moved since they inspected it; a launch already stopped is
    /// returned unchanged, with whatever evidence stopped it.
    public func recordLaunchStopped(_ id: ExecutionID, evidence: ControllerStopEvidence,
                                    expectedState: LaunchState? = nil, requeue: Bool = false) throws -> ControllerLaunch {
        try db.transaction {
            var value = try launch(id)
            if value.state == .stopped { return value }
            if let expectedState, value.state != expectedState { throw ControllerError.conflict }
            let stoppedAt = Self.now()
            let execution: ControllerExecution = try required("execution", id.description)
            let unfinished = execution.state == .running
            value.state = .stopped; value.stoppedAt = stoppedAt
            switch evidence {
            case .exited(let status, let signalled, let tail):
                value.exitStatus = status
                if signalled || status != 0 || unfinished {
                    let reason = signalled ? "signalled" : (status != 0 ? "nonzero_exit" : "exited_before_finish")
                    value.failure = ControllerLaunchFailure(stage: "exit", reason: reason)
                    if let tail {
                        let credential: String? = try optional("executionCredential", id.description)
                        value.outputTail = ControllerOutputTail.redact(tail, secrets: value.spec.arguments
                            + Array(value.spec.environment.values) + [credential, id.description].compactMap { $0 })
                    }
                }
            case .hostLost(let incident):
                value.failure = ControllerLaunchFailure(stage: "host", reason: "lost", incident: incident?.uuidString.lowercased())
            case .spawnRefused(let token):
                value.failure = ControllerLaunchFailure(stage: "spawn", reason: String(token.prefix(64)))
            case .spawnFailed(let errorNumber):
                value.failure = ControllerLaunchFailure(stage: "spawn", reason: "spawn_failed", errorNumber: errorNumber)
            case .ownerConfirmed:
                value.failure = ControllerLaunchFailure(stage: "owner", reason: "confirmed_stopped")
            case .preparationCancelled:
                value.failure = ControllerLaunchFailure(stage: "preparation", reason: "policy_changed")
            }
            try db.run("UPDATE usage_unsettled SET stopped_day=? WHERE execution=?",
                       [.text(String(stoppedAt.prefix(10))), .text(id.description)])
            if value.spec.usage != nil {
                try db.run("INSERT OR IGNORE INTO usage_pending(execution) VALUES(?)", [.text(id.description)])
            }
            if unfinished {
                let work = try interrupt(executionID: id)
                // A newer automation occurrence may hold the slot; then the work stays interrupted
                // for an owner, exactly as without requeueing.
                if requeue {
                    do { _ = try retry(workID: work.id) } catch ControllerError.conflict {}
                    try event("launch.requeued", id.description)
                }
            }
            try saveLaunch(value)
            return value
        }
    }

    /// The owner's `interrupt`: records that an execution is no longer running. Refused while
    /// any launch of that execution is still unresolved, because interrupting and then retrying
    /// work whose process may be alive is how one task runs twice. Confirm the launch stopped
    /// first; that interrupts it on its own.
    public func interruptStoppedExecution(_ executionID: ExecutionID) throws -> WorkItem {
        try db.transaction {
            let launch: ControllerLaunch? = try optional("launch", executionID.description)
            if let launch, launch.state != .stopped { throw ControllerError.conflict }
            return try interrupt(executionID: executionID)
        }
    }

    /// A launch only when this store has one for the id. Used to decide which host receipts
    /// are ours to acknowledge; a receipt for anything else is left alone.
    public func launchIfPresent(_ id: ExecutionID) throws -> ControllerLaunch? { try optional("launch", id.description) }
    func saveLaunch(_ launch: ControllerLaunch) throws {
        try update("launch", launch.executionID.description, state: launch.state.rawValue, value: launch)
        try event("launch.\(launch.state.rawValue)", launch.executionID.description)
    }
}

/// The bounded, redacted last output of a launch that did not finish cleanly.
///
/// Best effort, stated honestly: control sequences are dropped and every recipe argument,
/// environment value and the execution credential of at least `minimumRedactedLength`
/// characters is replaced. It is not a general secret scanner — a provider that prints a token
/// it fetched itself is not covered — which is why the tail stays an owner-only diagnostic.
public enum ControllerOutputTail {
    public static let maximumBytes = 2_048
    static let minimumRedactedLength = 8
    static let redaction = "[redacted]"
    private static let escape: Unicode.Scalar = "\u{1B}"
    private static let bell: Unicode.Scalar = "\u{07}"
    private static let controlSequenceIntroducer: Unicode.Scalar = "\u{9B}"
    private static let finalBytes: ClosedRange<UInt32> = 0x40...0x7E
    private static let stringIntroducers: Set<Unicode.Scalar> = ["]", "P", "X", "^", "_"]

    public static func redact(_ data: Data, secrets: [String]) -> String {
        var text = strip(String(decoding: data, as: UTF8.self))
        let candidates = Set(secrets.filter { $0.count >= minimumRedactedLength }).sorted { $0.count > $1.count }
        for secret in candidates { text = text.replacingOccurrences(of: secret, with: redaction) }
        var bytes = 0
        var start = text.endIndex
        for index in text.indices.reversed() {
            let size = text[index].utf8.count
            guard bytes + size <= maximumBytes else { break }
            bytes += size
            start = index
        }
        return String(text[start...])
    }

    /// Removes CSI, OSC/DCS-style strings and other escapes, and C0 controls but newline/tab.
    static func strip(_ text: String) -> String {
        var output = String.UnicodeScalarView()
        var scalars = Array(text.replacingOccurrences(of: "\r\n", with: "\n").unicodeScalars)[...]
        while let scalar = scalars.popFirst() {
            if scalar == escape || scalar == controlSequenceIntroducer {
                let introducer = scalar == controlSequenceIntroducer ? "[" : scalars.popFirst()
                if introducer == "[" {
                    while let next = scalars.popFirst(), !finalBytes.contains(next.value) {}
                } else if let introducer, stringIntroducers.contains(introducer) {
                    while let next = scalars.popFirst() {
                        if next == bell { break }
                        if next == escape { _ = scalars.popFirst(); break }
                    }
                }
                continue
            }
            if scalar == "\r" { output.append("\n"); continue }
            if scalar == "\n" || scalar == "\t" || scalar.value >= 0x20 && scalar.value != 0x7F { output.append(scalar) }
        }
        return String(output)
    }
}
