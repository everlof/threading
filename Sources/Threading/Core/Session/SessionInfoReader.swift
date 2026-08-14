import Foundation

// MARK: - Model

/// Where something in the info panel came from within one session.
///
/// A session can run processes from two places at once: the agent Threading launched, and the
/// shell the user opened in the drawer beneath it. They are different answers to "what is this
/// port" — one is the agent's dev server, the other is something you started yourself.
enum SessionInfoOrigin: String, Equatable, Sendable {
    case agent = "Agent"
    case shell = "Shell"
}

/// One process in a session's tree, as the panel draws it.
struct SessionProcess: Equatable, Sendable {

    let pid: pid_t
    let command: String
    let memoryBytes: UInt64

    /// Share of one core, measured between two polls. **Nil on the first reading**, where there
    /// is no earlier sample to measure against — a rate needs two points in time, and printing
    /// `0%` for "not yet known" would claim a measurement that was never taken.
    let cpuPercent: Double?

    /// Distance from the origin's root in the process tree; the root itself is 0. The panel
    /// indents by it, which is how parentage is drawn.
    let depth: Int

    /// The kernel's run state at this reading — the fact the status dot must not overstate.
    let state: ProcessRunState

    /// The kernel's start identity, the other half of what a pid means. Nil when it could not
    /// be read, which any action on this process must treat as "do nothing".
    let startTime: ProcessStartTime?

    /// The executable's path and full argument vector, when the argument area was readable.
    let executablePath: String?
    let arguments: [String]

    /// Where the process is *now* — read fresh each poll, since a process moves.
    let workingDirectory: String?

    init(
        pid: pid_t,
        command: String,
        memoryBytes: UInt64,
        cpuPercent: Double?,
        depth: Int = 0,
        state: ProcessRunState = .running,
        startTime: ProcessStartTime? = nil,
        executablePath: String? = nil,
        arguments: [String] = [],
        workingDirectory: String? = nil
    ) {
        self.pid = pid
        self.command = command
        self.memoryBytes = memoryBytes
        self.cpuPercent = cpuPercent
        self.depth = depth
        self.state = state
        self.startTime = startTime
        self.executablePath = executablePath
        self.arguments = arguments
        self.workingDirectory = workingDirectory
    }

    /// The session's own root — the row session teardown owns, which the panel therefore
    /// never offers to stop.
    var isRoot: Bool { depth == 0 }

    var startDate: Date? {
        startTime.map { Date(timeIntervalSince1970: TimeInterval($0.seconds)) }
    }

    @MainActor
    var formattedMemory: String {
        Self.memoryFormatter.string(fromByteCount: Int64(memoryBytes))
    }

    var formattedCPU: String {
        guard let cpuPercent else { return "—" }
        return String(format: "%.0f%%", cpuPercent)
    }

    /// Read only while drawing, so the formatter stays on the main thread.
    @MainActor
    private static let memoryFormatter: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .memory
        formatter.allowedUnits = [.useKB, .useMB, .useGB]
        return formatter
    }()
}

/// The processes contributed by one origin.
struct SessionProcessGroup: Equatable, Sendable {
    let origin: SessionInfoOrigin
    let processes: [SessionProcess]
}

/// The listening ports contributed by one origin.
struct SessionPortGroup: Equatable, Sendable {
    let origin: SessionInfoOrigin
    let ports: [ListeningPort]
}

/// One reading of what a session is running.
struct SessionInfoSnapshot: Equatable, Sendable {

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

    /// Every pid in the tree rooted at `root`, depth first with each node's distance from the
    /// root — the order a tree is *read*: children directly under their parent, siblings by pid
    /// (the caller hands children pre-sorted). A breadth-first walk put every grandchild after
    /// every child, which drew a list no indentation could explain.
    ///
    /// A process table read live can in principle contain a cycle after pid reuse; the seen set
    /// means a malformed table costs a wrong row rather than a hang.
    static func preorder(root: pid_t, children: [pid_t: [pid_t]]) -> [(pid: pid_t, depth: Int)] {
        var ordered: [(pid: pid_t, depth: Int)] = []
        var seen: Set<pid_t> = []
        var stack: [(pid: pid_t, depth: Int)] = [(root, 0)]

        while let (pid, depth) = stack.popLast() {
            guard seen.insert(pid).inserted else { continue }
            ordered.append((pid, depth))
            for child in (children[pid] ?? []).reversed() {
                stack.append((child, depth + 1))
            }
        }

        return ordered
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
final class SessionInfoReader: @unchecked Sendable {

    // MARK: - Types

    private struct CPUSample {
        let cpuTimeNanoseconds: UInt64
        let taken: Date
    }

    // MARK: - Properties

    private let queue = DispatchQueue(label: "codes.threading.session-info", qos: .userInitiated)

    /// Previous CPU readings keyed by pid. Only ever touched on `queue`.
    private var previousCPU: [pid_t: CPUSample] = [:]

    /// Resolved command lines keyed by pid, each guarded by the start identity it was read
    /// under. A process cannot rewrite its argument area, so each *process* is asked once —
    /// copying it out of the kernel is far more than a two-second poll should repeat — but a
    /// pid can be handed out again, and a recycled pid must not inherit a dead process's
    /// command line. Only ever touched on `queue`.
    private var resolvedCommandLines: [pid_t: (identity: ProcessStartTime?, commandLine: ProcessCommandLine?)] = [:]

    // MARK: - Public Methods

    /// Reads both roots and returns one snapshot. Completion arrives on main.
    ///
    /// The roots are resolved by the caller on the main actor — they come from `AgentRuntime`
    /// and the shell drawer, neither of which is safe to touch from here.
    func read(
        agentRoot: pid_t?,
        shellRoot: pid_t?,
        completion: @escaping @MainActor @Sendable (SessionInfoSnapshot) -> Void
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
        let agentEntries = descendants(of: agentRoot, children: children, table: table)
        let agentPids = Set(agentEntries.map(\.pid))
        let shellEntries = descendants(of: shellRoot, children: children, table: table)
            .filter { !agentPids.contains($0.pid) }

        var sampled: [pid_t: CPUSample] = [:]

        let agentProcesses = agentEntries.map {
            measure($0.pid, depth: $0.depth, in: table, at: taken, into: &sampled)
        }
        let shellProcesses = shellEntries.map {
            measure($0.pid, depth: $0.depth, in: table, at: taken, into: &sampled)
        }

        // Keep only what is still alive, or the maps grow with every process the session ever ran.
        previousCPU = sampled
        let living = agentPids.union(shellEntries.map(\.pid))
        resolvedCommandLines = resolvedCommandLines.filter { living.contains($0.key) }

        let agentPorts = SessionInfoGrouping.deduplicated(ports(for: agentProcesses))
        let shellPorts = SessionInfoGrouping.deduplicated(ports(for: shellProcesses))

        return SessionInfoSnapshot(
            processGroups: SessionInfoGrouping.groups(agent: agentProcesses, shell: shellProcesses)
                .map { SessionProcessGroup(origin: $0.0, processes: $0.1) },
            portGroups: SessionInfoGrouping.groups(agent: agentPorts, shell: shellPorts)
                .map { SessionPortGroup(origin: $0.0, ports: $0.1) }
        )
    }

    /// Every pid in the tree rooted at `root`, the root itself included, in reading order —
    /// `SessionInfoGrouping.preorder`, which is where the walk itself is testable without a
    /// live process.
    private func descendants(
        of root: pid_t?,
        children: [pid_t: [pid_t]],
        table: [pid_t: ProcessSummary]
    ) -> [(pid: pid_t, depth: Int)] {
        guard let root, root > 0, table[root] != nil else { return [] }
        return SessionInfoGrouping.preorder(root: root, children: children)
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
        depth: Int,
        in table: [pid_t: ProcessSummary],
        at taken: Date,
        into sampled: inout [pid_t: CPUSample]
    ) -> SessionProcess {
        let usage = ProcessUtility.getResourceUsage(forPid: pid)
        let cpuTime = usage?.cpuTime ?? 0
        sampled[pid] = CPUSample(cpuTimeNanoseconds: cpuTime, taken: taken)

        let summary = table[pid]
        let commandLine = self.commandLine(for: pid, identity: summary?.startTime)

        return SessionProcess(
            pid: pid,
            command: name(from: commandLine, in: table, pid: pid),
            memoryBytes: usage?.memoryBytes ?? 0,
            cpuPercent: percentage(forPid: pid, cpuTime: cpuTime, at: taken),
            depth: depth,
            state: summary?.state ?? .running,
            startTime: summary?.startTime,
            executablePath: commandLine?.executablePath,
            arguments: commandLine?.arguments ?? [],
            workingDirectory: ProcessUtility.workingDirectory(forPid: pid)?.path
        )
    }

    /// The cached command line for a live process, re-read only when the pid's start identity
    /// says it is no longer the process the cache knew.
    private func commandLine(for pid: pid_t, identity: ProcessStartTime?) -> ProcessCommandLine? {
        if let cached = resolvedCommandLines[pid], cached.identity == identity {
            return cached.commandLine
        }

        let resolved = ProcessUtility.commandLine(forPid: pid)
        resolvedCommandLines[pid] = (identity, resolved)
        return resolved
    }

    /// What to call a process.
    ///
    /// `argv[0]` is preferred over the executable's filename because a versioned install names
    /// its binary after the version — the agent would otherwise read as "2.1.218" rather than
    /// "claude". The process table's own name is the fallback, for a process whose arguments
    /// cannot be read.
    private func name(
        from commandLine: ProcessCommandLine?,
        in table: [pid_t: ProcessSummary],
        pid: pid_t
    ) -> String {
        if let argumentZero = commandLine?.arguments.first {
            let name = (argumentZero as NSString).lastPathComponent
            if !name.isEmpty { return name }
        }
        return table[pid]?.command ?? "—"
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

    private func ports(for processes: [SessionProcess]) -> [ListeningPort] {
        processes.flatMap { process in
            ProcessUtility.listeningPorts(forPid: process.pid, command: process.command)
        }
    }
}
