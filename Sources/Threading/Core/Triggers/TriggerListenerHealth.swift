import Foundation

/// launchd's view of the listener's job: the few top-level fields of one
/// `launchctl print gui/<uid>/codes.threading.triggerd` that say why it is not running.
///
/// ServiceManagement cannot say this. It reported `.enabled` for 2026-09-12 to 2026-10-05 while
/// launchd killed every spawn with OS_REASON_CODESIGNING, and the Sources page said "Enabled in
/// Login Items" beside sources that were "Checking" forever.
struct TriggerListenerLaunchJob: Equatable, Sendable {
    var state: String?
    var jobState: String?
    var runs: Int?
    var lastExitReason: String?
    var lastExitCode: String?
    var processIdentifier: Int32?

    /// A spawn launchd or the kernel refused, as opposed to a listener that ran and exited:
    /// launchd writes `last exit reason` only for a termination it or the kernel imposed.
    var spawnFailed: Bool {
        processIdentifier == nil && (jobState == "spawn failed" || lastExitReason != nil)
    }

    /// Only the job's own lines, at depth one: nested dictionaries (its coalitions, its
    /// environment) carry `state =` lines of their own. Nil when the text describes no job,
    /// including launchctl's "Could not find service" answer.
    static func parse(_ text: String) -> TriggerListenerLaunchJob? {
        var job = TriggerListenerLaunchJob()
        var depth = 0
        var sawJob = false
        for rawLine in text.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasSuffix("{") {
                if depth == 0 { sawJob = true }
                depth += 1
                continue
            }
            if line == "}" {
                depth = max(0, depth - 1)
                continue
            }
            guard depth == 1, let separator = line.range(of: " = ") else { continue }
            let value = String(line[separator.upperBound...])
            switch line[..<separator.lowerBound] {
            case "state": job.state = value
            case "job state": job.jobState = value
            case "runs": job.runs = Int(value)
            case "last exit reason": job.lastExitReason = value
            case "last exit code": job.lastExitCode = value
            case "pid": job.processIdentifier = Int32(value)
            default: break
            }
        }
        return sawJob ? job : nil
    }
}

/// One bounded, read-only `launchctl print` for the listener's label. Off the main actor only.
enum TriggerListenerLaunchProbe {
    static let timeout: TimeInterval = 2
    static let maximumOutputBytes = 64 * 1_024

    static func read() -> TriggerListenerLaunchJob? {
        guard let result = try? BoundedChildProcess.run(
            executable: "/bin/launchctl",
            arguments: ["print", "gui/\(getuid())/\(TriggerDaemonRegistrationDefaults.label)"],
            timeout: timeout,
            maximumOutputBytes: maximumOutputBytes,
            output: .standardOutput
        ), result.termination == .exited(0), !result.outputWasTruncated else { return nil }
        return TriggerListenerLaunchJob.parse(String(decoding: result.output, as: UTF8.self))
    }
}

/// Everything the app knows about the listener at one moment, gathered on a bounded worker.
struct TriggerListenerReading: Equatable, Sendable {
    var registration: TriggerDaemonRegistrationStatus
    var heartbeat: TriggerListenerHeartbeat?
    var launchJob: TriggerListenerLaunchJob?
    /// Whether the published configuration gives the listener anything to do. Unknown (no
    /// readable file) counts as needed, so a failure is never explained away as idle.
    var needed = true

    static var heartbeatFile: URL {
        TriggerDaemonLocations.directory.appendingPathComponent(TriggerListenerHeartbeat.fileName, isDirectory: false)
    }

    /// ServiceManagement is an XPC call and launchctl a child process: call this from a worker,
    /// never a UI path. launchd is asked only when the heartbeat cannot answer.
    static func read(now: Date = Date()) -> TriggerListenerReading {
        let registration = TriggerDaemonRegistrationCoordinator.currentStatus()
        let heartbeat = (try? Data(contentsOf: heartbeatFile)).flatMap { try? TriggerListenerHeartbeat.decode($0) }
        let fresh = heartbeat.map { TriggerListenerState.isFresh($0, now: now) } ?? false
        let job = registration == .enabled && !fresh ? TriggerListenerLaunchProbe.read() : nil
        let configuration = (try? Data(contentsOf: TriggerDaemonLocations.configuration))
            .flatMap { try? JSONDecoder().decode(TriggerDaemonConfiguration.self, from: $0) }
        return TriggerListenerReading(registration: registration, heartbeat: heartbeat, launchJob: job,
                                      needed: configuration?.needsListener ?? true)
    }
}

/// Whether the listener is polling, and if not, why — in the words the Sources page, the
/// automation pages and `list_trigger_sources` share.
enum TriggerListenerState: Equatable, Sendable {
    case running
    /// Registered moments ago; launchd has not started it yet.
    case starting
    /// macOS will not start it. `reason` is launchd's own exit reason, such as
    /// OS_REASON_CODESIGNING; `attempts` how often launchd has tried.
    case refused(reason: String?, attempts: Int?)
    /// Registered, yet not running or no longer reporting.
    case stopped(lastReport: Date?, exitCode: String?)
    case requiresApproval
    case notRegistered
    /// Not registered because nothing needs it: no connected source, enabled probe or
    /// schedule. The app registers it as soon as one exists.
    case idle
    case missingHelper

    static func isFresh(_ heartbeat: TriggerListenerHeartbeat, now: Date) -> Bool {
        let age = now.timeIntervalSince(heartbeat.heartbeatAt)
        return age <= TriggerListenerHeartbeat.staleAfter && age >= -TriggerListenerHeartbeat.staleAfter
    }

    static func classify(_ reading: TriggerListenerReading, now: Date) -> TriggerListenerState {
        switch reading.registration {
        case .missingHelper: return .missingHelper
        case .requiresApproval: return .requiresApproval
        case .notRegistered, .notFound, .unknown: return reading.needed ? .notRegistered : .idle
        case .enabled: break
        }
        if let heartbeat = reading.heartbeat, isFresh(heartbeat, now: now) { return .running }
        guard let job = reading.launchJob else {
            return .stopped(lastReport: reading.heartbeat?.heartbeatAt, exitCode: nil)
        }
        if job.spawnFailed { return .refused(reason: job.lastExitReason, attempts: job.runs) }
        if job.processIdentifier != nil {
            // A process that once reported and stopped is stuck; one that never reported is a
            // listener from before heartbeats, or one that started a moment ago.
            if let heartbeat = reading.heartbeat {
                return .stopped(lastReport: heartbeat.heartbeatAt, exitCode: nil)
            }
            return .running
        }
        if reading.heartbeat == nil, job.lastExitCode == nil, job.state == "spawn scheduled" || job.state == "waiting" {
            return .starting
        }
        return .stopped(lastReport: reading.heartbeat?.heartbeatAt, exitCode: job.lastExitCode)
    }

    /// Whether sources are being polled. Starting counts: the first beat is seconds away.
    var isListening: Bool {
        switch self {
        case .running, .starting: return true
        default: return false
        }
    }

    /// The stable spelling `list_trigger_sources` returns.
    var wireValue: String {
        switch self {
        case .running: return "running"
        case .starting: return "starting"
        case .refused: return "refused"
        case .stopped: return "stopped"
        case .requiresApproval: return "requires_approval"
        case .notRegistered: return "not_registered"
        case .idle: return "idle"
        case .missingHelper: return "missing_helper"
        }
    }

    /// For an agent: plain English with launchd's own words kept verbatim, so the cause can be
    /// searched for.
    var diagnostic: String {
        switch self {
        case .running:
            return "The background listener is running."
        case .starting:
            return "The background listener was registered and is starting."
        case .refused(let reason, let attempts):
            var text = reason?.contains("CODESIGNING") == true
                ? "macOS refuses to start the background listener: its code signature was rejected (\(reason ?? ""))."
                : "macOS refuses to start the background listener (\(reason ?? "spawn failed"))."
            if let attempts { text += " launchd has tried \(attempts) times." }
            return text + " No source is being checked."
        case .stopped(let lastReport, let exitCode):
            var text = "The background listener is registered but not running."
            if let lastReport { text += " It last reported at \(lastReport.formatted(.iso8601))." }
            if let exitCode { text += " Its last exit code was \(exitCode)." }
            return text + " No source is being checked."
        case .requiresApproval:
            return "The background listener is waiting for approval in System Settings > General > Login Items."
        case .notRegistered:
            return "The background listener is not registered, so no source is being checked."
        case .idle:
            return "The background listener is off because no source or schedule needs it; Threading starts it when one does."
        case .missingHelper:
            return "This build has no background listener, so no source is being checked."
        }
    }
}

/// The listener's per-source receipts and its own state, read together on a worker: the status
/// files, a ServiceManagement call, and launchctl only when the heartbeat cannot answer. The
/// Sources page, the automation pages and `list_trigger_sources` all read this one value.
struct TriggerSourceReceipts: Sendable {
    let statuses: [TriggerSourceInstallationID: TriggerDaemonSourceStatus]
    let listener: TriggerListenerState

    static func read() async -> TriggerSourceReceipts {
        await Task.detached(priority: .utility) {
            let now = Date()
            return TriggerSourceReceipts(
                statuses: (try? TriggerDaemonStatusStore.statuses()) ?? [:],
                listener: TriggerListenerState.classify(TriggerListenerReading.read(now: now), now: now)
            )
        }.value
    }

    /// The listener's receipt for this source, only when written after the source's last edit:
    /// an older one describes a configuration that no longer exists.
    func current(for source: TriggerSourceInstallation) -> TriggerDaemonSourceStatus? {
        statuses[source.id].flatMap { $0.lastCheckedAt >= source.updatedAt ? $0 : nil }
    }

    /// What `list_trigger_sources` reports for a source. A source the listener would poll (enabled,
    /// and approved if it is a probe) is `not_checked` while the listener is not running, with the
    /// listener's reason: its last receipt, or "checking", would describe polling that is not
    /// happening.
    func report(for source: TriggerSourceInstallation) -> (health: String, diagnostic: String?) {
        let polled = source.enabled && (source.probe.map(\.isApproved) ?? true)
        guard !polled || listener.isListening else { return ("not_checked", listener.diagnostic) }
        let status = current(for: source)
        return ((status?.health ?? source.health).rawValue, status?.boundedDiagnostic ?? source.boundedDiagnostic)
    }
}
