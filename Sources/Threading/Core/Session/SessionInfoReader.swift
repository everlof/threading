import Foundation

// MARK: - Model

/// Where something in the info panel came from within one session.
///
/// A session can run processes from two places at once: the agent Threading launched, and the
/// shell the user opened in the drawer beneath it. They are different answers to "what is this
/// port" — one is the agent's dev server, the other is something you started yourself.
enum SessionInfoOrigin: String, Equatable {
    case agent = "Agent"
    case shell = "Shell"
}

/// One process in a session's tree, as the panel draws it.
struct SessionProcess: Equatable {

    let pid: pid_t
    let command: String
    let memoryBytes: UInt64

    /// Share of one core, measured between two polls. **Nil on the first reading**, where there
    /// is no earlier sample to measure against — a rate needs two points in time, and printing
    /// `0%` for "not yet known" would claim a measurement that was never taken.
    let cpuPercent: Double?

    var formattedMemory: String {
        Self.memoryFormatter.string(fromByteCount: Int64(memoryBytes))
    }

    var formattedCPU: String {
        guard let cpuPercent else { return "—" }
        return String(format: "%.0f%%", cpuPercent)
    }

    /// Read only while drawing, so the formatter stays on the main thread.
    private static let memoryFormatter: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .memory
        formatter.allowedUnits = [.useKB, .useMB, .useGB]
        return formatter
    }()
}

/// The processes contributed by one origin.
struct SessionProcessGroup: Equatable {
    let origin: SessionInfoOrigin
    let processes: [SessionProcess]
}

/// The listening ports contributed by one origin.
struct SessionPortGroup: Equatable {
    let origin: SessionInfoOrigin
    let ports: [ListeningPort]
}

/// One reading of what a session is running.
struct SessionInfoSnapshot: Equatable {

    let processGroups: [SessionProcessGroup]
    let portGroups: [SessionPortGroup]

    static let empty = SessionInfoSnapshot(processGroups: [], portGroups: [])

    /// Whether the panel names each group's origin.
    ///
    /// Only one origin contributed means there is nothing to tell apart, and a lone "Agent"
    /// heading over the only list on screen is a label answering a question nobody asked. Two
    /// origins means the distinction is the point.
    var namesProcessOrigins: Bool { processGroups.count > 1 }
    var namesPortOrigins: Bool { portGroups.count > 1 }

    var processes: [SessionProcess] { processGroups.flatMap(\.processes) }
    var ports: [ListeningPort] { portGroups.flatMap(\.ports) }

    var isEmpty: Bool { processGroups.isEmpty && portGroups.isEmpty }
}

// MARK: - Grouping

/// The rule deciding how findings are presented, kept apart from the reading so it can be
/// tested without a live process.
enum SessionInfoGrouping {

    /// Emits a group per origin that actually contributed something.
    ///
    /// Dropping empty origins is what makes `namesProcessOrigins` / `namesPortOrigins` true only
    /// when there is a real distinction to draw: a session with no shell open, or a shell that
    /// is listening on nothing, produces one group and therefore no headings.
    static func groups<Element>(agent: [Element], shell: [Element]) -> [(SessionInfoOrigin, [Element])] {
        var groups: [(SessionInfoOrigin, [Element])] = []
        if !agent.isEmpty { groups.append((.agent, agent)) }
        if !shell.isEmpty { groups.append((.shell, shell)) }
        return groups
    }

    /// One row per port, newest binding wins, ordered as a person reads them.
    ///
    /// A port can legitimately be reported more than once: a pre-forking server (gunicorn,
    /// unicorn) hands the *same* listening descriptor to every worker, so a dozen pids each
    /// report port 8000, and a dual-stack listener reports one port on two addresses. Showing
    /// them all would fill the panel with one server repeated. The survivor is the most widely
    /// bound — `0.0.0.0` over `127.0.0.1`, because that is the exposure that matters — and then
    /// the lowest pid, which for a pre-forking server is the master rather than an arbitrary
    /// worker.
    static func deduplicated(_ ports: [ListeningPort]) -> [ListeningPort] {
        var best: [UInt16: ListeningPort] = [:]

        for port in ports {
            guard let existing = best[port.port] else {
                best[port.port] = port
                continue
            }

            let candidate = port.interface.breadth
            let incumbent = existing.interface.breadth
            let wider = candidate > incumbent
            let earlier = candidate == incumbent && port.pid < existing.pid

            if wider || earlier {
                best[port.port] = port
            }
        }

        return best.values.sorted { $0.port < $1.port }
    }
}

// MARK: - Reader

/// Reads what a session is running: its process tree and the ports those processes listen on.
///
/// Everything blocking happens on a private queue and completes on main, the shape
/// `GitReviewReader` established — walking the machine's process table and reading every
/// descriptor of every process is not work for the thread that draws.
///
/// This is an instance rather than a namespace of static functions because **CPU percentage is
/// a rate**: it needs the previous reading to subtract from, so the reader carries state between
/// polls. That state is touched only on `queue`, which is serial.
final class SessionInfoReader {

    // MARK: - Types

    private struct CPUSample {
        let cpuTimeNanoseconds: UInt64
        let taken: Date
    }

    // MARK: - Properties

    private let queue = DispatchQueue(label: "codes.threading.session-info", qos: .userInitiated)

    /// Previous CPU readings keyed by pid. Only ever touched on `queue`.
    private var previousCPU: [pid_t: CPUSample] = [:]

    /// Resolved process names keyed by pid. A process cannot rename itself here, so each pid is
    /// asked once — reading `argv[0]` copies the argument area out of the kernel, which is far
    /// more than a two-second poll should repeat. Only ever touched on `queue`.
    private var resolvedNames: [pid_t: String] = [:]

    // MARK: - Public Methods

    /// Reads both roots and returns one snapshot. Completion arrives on main.
    ///
    /// The roots are resolved by the caller on the main actor — they come from `AgentRuntime`
    /// and the shell drawer, neither of which is safe to touch from here.
    func read(
        agentRoot: pid_t?,
        shellRoot: pid_t?,
        completion: @escaping @MainActor (SessionInfoSnapshot) -> Void
    ) {
        queue.async {
            let snapshot = self.snapshot(agentRoot: agentRoot, shellRoot: shellRoot)
            DispatchQueue.main.async { MainActor.assumeIsolated { completion(snapshot) } }
        }
    }

    /// Drops the sampling history, so the next reading starts a fresh rate measurement.
    func reset() {
        queue.async { self.previousCPU.removeAll() }
    }

    // MARK: - Private Methods

    private func snapshot(agentRoot: pid_t?, shellRoot: pid_t?) -> SessionInfoSnapshot {
        let table = ProcessUtility.processTable()
        let children = childrenByParent(in: table)
        let taken = Date()

        // The shell drawer is started by the app, so both roots are our own descendants and
        // cannot overlap — but a root that failed to start reads as pid 0, which must not be
        // mistaken for a real process.
        let agentPids = descendants(of: agentRoot, children: children, table: table)
        let shellPids = descendants(of: shellRoot, children: children, table: table)
            .filter { !agentPids.contains($0) }

        var sampled: [pid_t: CPUSample] = [:]

        let agentProcesses = agentPids.map { measure($0, in: table, at: taken, into: &sampled) }
        let shellProcesses = shellPids.map { measure($0, in: table, at: taken, into: &sampled) }

        // Keep only what is still alive, or the maps grow with every process the session ever ran.
        previousCPU = sampled
        let living = Set(agentPids).union(shellPids)
        resolvedNames = resolvedNames.filter { living.contains($0.key) }

        let agentPorts = SessionInfoGrouping.deduplicated(ports(for: agentPids, in: table))
        let shellPorts = SessionInfoGrouping.deduplicated(ports(for: shellPids, in: table))

        return SessionInfoSnapshot(
            processGroups: SessionInfoGrouping.groups(agent: agentProcesses, shell: shellProcesses)
                .map { SessionProcessGroup(origin: $0.0, processes: $0.1) },
            portGroups: SessionInfoGrouping.groups(agent: agentPorts, shell: shellPorts)
                .map { SessionPortGroup(origin: $0.0, ports: $0.1) }
        )
    }

    /// Every pid in the tree rooted at `root`, the root itself included, breadth first.
    private func descendants(
        of root: pid_t?,
        children: [pid_t: [pid_t]],
        table: [pid_t: ProcessSummary]
    ) -> [pid_t] {
        guard let root, root > 0, table[root] != nil else { return [] }

        var ordered: [pid_t] = []
        var seen: Set<pid_t> = []
        var queue: [pid_t] = [root]

        while let pid = queue.first {
            queue.removeFirst()

            // A process table read live can in principle contain a cycle after pid reuse; the
            // seen set means a malformed table costs a wrong row rather than a hang.
            guard seen.insert(pid).inserted else { continue }
            ordered.append(pid)
            queue.append(contentsOf: children[pid] ?? [])
        }

        return ordered
    }

    private func childrenByParent(in table: [pid_t: ProcessSummary]) -> [pid_t: [pid_t]] {
        var children: [pid_t: [pid_t]] = [:]
        for summary in table.values {
            children[summary.parentPid, default: []].append(summary.pid)
        }
        for parent in children.keys {
            children[parent]?.sort()
        }
        return children
    }

    private func measure(
        _ pid: pid_t,
        in table: [pid_t: ProcessSummary],
        at taken: Date,
        into sampled: inout [pid_t: CPUSample]
    ) -> SessionProcess {
        let usage = ProcessUtility.getResourceUsage(forPid: pid)
        let cpuTime = usage?.cpuTime ?? 0
        sampled[pid] = CPUSample(cpuTimeNanoseconds: cpuTime, taken: taken)

        return SessionProcess(
            pid: pid,
            command: name(for: pid, in: table),
            memoryBytes: usage?.memoryBytes ?? 0,
            cpuPercent: percentage(forPid: pid, cpuTime: cpuTime, at: taken)
        )
    }

    /// What to call a process, asked once per pid.
    ///
    /// `argv[0]` is preferred over the executable's filename because a versioned install names
    /// its binary after the version — the agent would otherwise read as "2.1.218" rather than
    /// "claude". The process table's own name is the fallback, for a process whose arguments
    /// cannot be read.
    private func name(for pid: pid_t, in table: [pid_t: ProcessSummary]) -> String {
        if let cached = resolvedNames[pid] { return cached }

        let resolved = ProcessUtility.processName(forPid: pid) ?? table[pid]?.command ?? "—"
        resolvedNames[pid] = resolved
        return resolved
    }

    /// CPU as a share of one core between this reading and the last, the way `top` reports it —
    /// so a process saturating four cores reads above 100 rather than being clamped into a
    /// number that hides how busy it is.
    private func percentage(forPid pid: pid_t, cpuTime: UInt64, at taken: Date) -> Double? {
        guard let previous = previousCPU[pid] else { return nil }

        let elapsed = taken.timeIntervalSince(previous.taken)
        guard elapsed > 0, cpuTime >= previous.cpuTimeNanoseconds else { return nil }

        let burned = Double(cpuTime - previous.cpuTimeNanoseconds) / Double(NSEC_PER_SEC)
        return max(0, burned / elapsed * 100)
    }

    private func ports(for pids: [pid_t], in table: [pid_t: ProcessSummary]) -> [ListeningPort] {
        pids.flatMap { pid in
            ProcessUtility.listeningPorts(forPid: pid, command: name(for: pid, in: table))
        }
    }
}
