import Foundation
import Darwin

/// A node in the process tree representing a single process and its children.
final class ProcessNode {

    // MARK: - Properties

    let pid: pid_t
    let parentPid: pid_t
    let command: String
    let workingDirectory: String?
    let cpuTimeNs: UInt64
    let memoryBytes: UInt64
    let startTime: Date?
    var children: [ProcessNode]

    // MARK: - Computed Properties

    /// Formats memory as a human-readable string.
    var formattedMemory: String {
        let kb = Double(memoryBytes) / 1024
        if kb < 1024 {
            return String(format: "%.0f KB", kb)
        }
        let mb = kb / 1024
        if mb < 1024 {
            return String(format: "%.1f MB", mb)
        }
        let gb = mb / 1024
        return String(format: "%.2f GB", gb)
    }

    /// Formats CPU time as a human-readable string.
    var formattedCpuTime: String {
        let seconds = Double(cpuTimeNs) / 1_000_000_000
        if seconds < 60 {
            return String(format: "%.1fs", seconds)
        }
        let minutes = Int(seconds) / 60
        let remainingSeconds = Int(seconds) % 60
        if minutes < 60 {
            return String(format: "%dm %ds", minutes, remainingSeconds)
        }
        let hours = minutes / 60
        let remainingMinutes = minutes % 60
        return String(format: "%dh %dm", hours, remainingMinutes)
    }

    /// Formats process age (time since start) as a human-readable string.
    var formattedAge: String {
        guard let startTime = startTime else { return "-" }

        let elapsed = Date().timeIntervalSince(startTime)
        if elapsed < 60 {
            return String(format: "%.0fs", elapsed)
        }
        let minutes = Int(elapsed) / 60
        let seconds = Int(elapsed) % 60
        if minutes < 60 {
            return String(format: "%dm %ds", minutes, seconds)
        }
        let hours = minutes / 60
        let remainingMinutes = minutes % 60
        if hours < 24 {
            return String(format: "%dh %dm", hours, remainingMinutes)
        }
        let days = hours / 24
        let remainingHours = hours % 24
        return String(format: "%dd %dh", days, remainingHours)
    }

    // MARK: - Initialization

    init(
        pid: pid_t,
        parentPid: pid_t,
        command: String,
        workingDirectory: String?,
        cpuTimeNs: UInt64,
        memoryBytes: UInt64,
        startTime: Date?,
        children: [ProcessNode] = []
    ) {
        self.pid = pid
        self.parentPid = parentPid
        self.command = command
        self.workingDirectory = workingDirectory
        self.cpuTimeNs = cpuTimeNs
        self.memoryBytes = memoryBytes
        self.startTime = startTime
        self.children = children
    }
}

/// Builds a process tree starting from a given root process.
enum ProcessTreeBuilder {

    /// Builds a complete process tree rooted at the given PID.
    /// Returns nil if the root process doesn't exist.
    static func buildTree(rootPid: pid_t) -> ProcessNode? {
        guard let info = ProcessUtility.getProcessInfo(forPid: rootPid) else {
            return nil
        }

        let usage = ProcessUtility.getResourceUsage(forPid: rootPid)

        let node = ProcessNode(
            pid: info.pid,
            parentPid: info.parentPid,
            command: info.command,
            workingDirectory: info.workingDirectory,
            cpuTimeNs: usage?.cpuTime ?? 0,
            memoryBytes: usage?.memoryBytes ?? 0,
            startTime: info.startTime
        )

        // Recursively build children
        node.children = buildChildren(forPid: rootPid)

        return node
    }

    /// Recursively builds child nodes for a given parent PID.
    private static func buildChildren(forPid parentPid: pid_t) -> [ProcessNode] {
        let childPids = ProcessUtility.getProcessChildren(forPid: parentPid)

        return childPids.compactMap { childPid -> ProcessNode? in
            guard let info = ProcessUtility.getProcessInfo(forPid: childPid) else {
                return nil
            }

            let usage = ProcessUtility.getResourceUsage(forPid: childPid)

            let node = ProcessNode(
                pid: info.pid,
                parentPid: info.parentPid,
                command: info.command,
                workingDirectory: info.workingDirectory,
                cpuTimeNs: usage?.cpuTime ?? 0,
                memoryBytes: usage?.memoryBytes ?? 0,
                startTime: info.startTime
            )

            // Recursively build grandchildren
            node.children = buildChildren(forPid: childPid)

            return node
        }.sorted { $0.pid < $1.pid }
    }

    /// Counts total processes in a tree.
    static func countNodes(_ node: ProcessNode?) -> Int {
        guard let node = node else { return 0 }
        return 1 + node.children.reduce(0) { $0 + countNodes($1) }
    }

    /// Calculates total memory usage in a tree.
    static func totalMemory(_ node: ProcessNode?) -> UInt64 {
        guard let node = node else { return 0 }
        return node.memoryBytes + node.children.reduce(0) { $0 + totalMemory($1) }
    }
}
