import Foundation
#if canImport(Glibc)
import Glibc
#endif

/// Shared host subprocess boundary: exact environment, bounded streams and wall time, and a
/// private process group. Pipe draining never waits for EOF from an escaped descendant.
///
/// **A set `failure` is a failure, whatever `exitCode` says.** A descendant that left the process
/// group (`setsid`) survives the group kill while holding the output pipes; the command can then
/// report exit 0 together with `cleanup_incomplete`. Every caller (trigger probes, mail
/// transport) treats any failure as a failed run. On Linux the cleanup additionally finds the
/// processes still holding this command's output pipes through `/proc` and kills them, reported
/// as `escaped_descendant_killed`; elsewhere an escapee is reported and survives, because there
/// is no portable way to name it without a container or cgroup boundary.
public enum BoundedCommand {
    public struct Result: Sendable {
        public let output: Data
        public let errors: Data
        public let exitCode: Int32?
        public let failure: String?
    }
    private static let spawnLock = NSLock()
    private static let cleanupSeconds: TimeInterval = 1

    public static func run(executable: String, arguments: [String], environment: [String: String],
                           directory: String, input: Data, timeout: TimeInterval,
                           outputLimit: Int, errorLimit: Int = 16_384) async -> Result {
        await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                continuation.resume(returning: blocking(executable: executable, arguments: arguments,
                    environment: environment, directory: directory, input: input, timeout: timeout,
                    outputLimit: outputLimit, errorLimit: errorLimit))
            }
        }
    }

    private static func blocking(executable: String, arguments: [String], environment: [String: String],
                                 directory: String, input: Data, timeout: TimeInterval,
                                 outputLimit: Int, errorLimit: Int) -> Result {
        func failed(_ reason: String) -> Result { Result(output: Data(), errors: Data(), exitCode: nil, failure: reason) }
        guard timeout > 0, outputLimit > 0, errorLimit >= 0 else { return failed("invalid_bounds") }
        signal(SIGPIPE, SIG_IGN)
        var pipes: [[Int32]] = []
        spawnLock.lock()
        for _ in 0..<3 {
            var pair: [Int32] = [-1, -1]
            guard pipe(&pair) == 0 else {
                pipes.flatMap { $0 }.forEach { close($0) }; spawnLock.unlock(); return failed("pipe")
            }
            pair.forEach { _ = fcntl($0, F_SETFD, FD_CLOEXEC) }
            pipes.append(pair)
        }
        #if canImport(Darwin)
        var actions: posix_spawn_file_actions_t?
        var attributes: posix_spawnattr_t?
        #else
        var actions = posix_spawn_file_actions_t()
        var attributes = posix_spawnattr_t()
        #endif
        posix_spawn_file_actions_init(&actions)
        posix_spawnattr_init(&attributes)
        defer { posix_spawn_file_actions_destroy(&actions); posix_spawnattr_destroy(&attributes) }
        for (source, target) in [(pipes[0][0], Int32(0)), (pipes[1][1], 1), (pipes[2][1], 2)] {
            posix_spawn_file_actions_adddup2(&actions, source, target)
        }
        pipes.flatMap { $0 }.forEach { posix_spawn_file_actions_addclose(&actions, $0) }
        posix_spawn_file_actions_addchdir_np(&actions, directory)
        posix_spawnattr_setpgroup(&attributes, 0)
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETPGROUP))
        let argv = ([executable] + arguments).map { strdup($0) } + [nil]
        let envp = environment.sorted { $0.key < $1.key }.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer { argv.forEach { free($0) }; envp.forEach { free($0) } }
        var pid: pid_t = 0
        let spawned = posix_spawn(&pid, executable, &actions, &attributes, argv, envp)
        [pipes[0][0], pipes[1][1], pipes[2][1]].forEach { close($0) }
        spawnLock.unlock()
        let descriptors = [pipes[0][1], pipes[1][0], pipes[2][0]]
        var inputOpen = true
        defer { if inputOpen { close(descriptors[0]) }; descriptors.dropFirst().forEach { close($0) } }
        guard spawned == 0 else { return failed("spawn_\(spawned)") }
        descriptors.forEach { _ = fcntl($0, F_SETFL, fcntl($0, F_GETFL) | O_NONBLOCK) }
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        var cleanupDeadline: TimeInterval?
        var failure: String?
        var status: Int32 = 0
        var reaped = false
        var offset = 0
        var output = Data(), errors = Data()
        var ended = [false, false]
        var buffer = [UInt8](repeating: 0, count: 65_536)
        #if os(Linux)
        var swept = false
        #endif
        while true {
            let now = ProcessInfo.processInfo.systemUptime
            if !reaped {
                let result = waitpid(pid, &status, WNOHANG)
                if result == pid { reaped = true }
                else if result < 0 && errno != EINTR { failure = "wait_failed"; reaped = true }
            }
            if failure == nil && now >= deadline { failure = "timed_out" }
            if (reaped || failure != nil) && cleanupDeadline == nil {
                _ = kill(-pid, SIGKILL)
                cleanupDeadline = now + cleanupSeconds
            }
            if offset < input.count && cleanupDeadline == nil {
                let count = input.withUnsafeBytes { write(descriptors[0], $0.baseAddress!.advanced(by: offset), input.count - offset) }
                if count > 0 { offset += count }
                else if count < 0 && errno != EAGAIN && errno != EINTR { offset = input.count }
            }
            if offset == input.count {
                close(descriptors[0]); inputOpen = false
                offset += 1
            }
            for stream in 0..<2 where !ended[stream] {
                let count = read(descriptors[stream + 1], &buffer, buffer.count)
                if count == 0 { ended[stream] = true }
                else if count > 0 {
                    if stream == 0 {
                        let room = max(0, outputLimit - output.count)
                        output.append(contentsOf: buffer.prefix(min(count, room)))
                        if count > room { failure = "output_too_large" }
                    } else {
                        errors.append(contentsOf: buffer.prefix(min(count, max(0, errorLimit - errors.count))))
                    }
                } else if errno != EAGAIN && errno != EINTR { ended[stream] = true }
            }
            if reaped && ended.allSatisfy({ $0 }) { break }
            if let deadline = cleanupDeadline, now >= deadline {
                #if os(Linux)
                if !swept {
                    swept = true
                    if PipeHolders.kill(holding: Array(descriptors.dropFirst())) > 0 {
                        failure = failure ?? "escaped_descendant_killed"
                        cleanupDeadline = now + cleanupSeconds
                        continue
                    }
                }
                #endif
                failure = failure ?? "cleanup_incomplete"; break
            }
            _ = poll(nil, 0, 10)
        }
        if !reaped { _ = kill(-pid, SIGKILL); _ = waitpid(pid, &status, WNOHANG) }
        let code = reaped && (status & 0x7f) == 0 ? (status >> 8) & 0xff : nil
        return Result(output: output, errors: errors, exitCode: code, failure: failure)
    }
}

#if os(Linux)
/// Finds processes that hold a given pipe open, by the pipe's inode in `/proc/*/fd`. Bounded in
/// processes and descriptors examined; used only on the rare escaped-descendant path.
enum PipeHolders {
    static let maximumProcesses = 32_768
    static let maximumDescriptors = 4_096

    static func kill(holding descriptors: [Int32]) -> Int {
        var inodes = Set<String>()
        for descriptor in descriptors {
            var info = stat()
            if fstat(descriptor, &info) == 0 { inodes.insert("pipe:[\(info.st_ino)]") }
        }
        guard !inodes.isEmpty,
              let entries = try? FileManager.default.contentsOfDirectory(atPath: "/proc") else { return 0 }
        let me = getpid()
        var killed = 0
        for name in entries.prefix(maximumProcesses) {
            guard let pid = Int32(name), pid != me,
                  let fds = try? FileManager.default.contentsOfDirectory(atPath: "/proc/\(name)/fd") else { continue }
            for fd in fds.prefix(maximumDescriptors) {
                guard let target = try? FileManager.default.destinationOfSymbolicLink(atPath: "/proc/\(name)/fd/\(fd)"),
                      inodes.contains(target) else { continue }
                if Glibc.kill(pid, SIGKILL) == 0 { killed += 1 }
                break
            }
        }
        return killed
    }
}
#endif
