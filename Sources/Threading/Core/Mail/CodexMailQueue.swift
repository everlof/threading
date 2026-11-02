import Foundation

/// The short-lived queue client uses the selected executable and account, and an explicit
/// private socket. It cannot discover/start Codex's shared daemon or open a different TUI.
enum CodexMailQueue {
    private static let workers: OperationQueue = {
        let queue = OperationQueue()
        queue.name = "codes.threading.codex-mail"
        queue.maxConcurrentOperationCount = 4
        queue.qualityOfService = .utility
        return queue
    }()
    static let timeout: TimeInterval = 10
    static let maximumOutputBytes = 4096

    static func enqueue(_ target: CodexTerminalMail.Target, notice: String) async -> Bool {
        await withCheckedContinuation { continuation in
            workers.addOperation {
                continuation.resume(returning: enqueueBlocking(target, notice: notice))
            }
        }
    }

    static func enqueueBlocking(_ target: CodexTerminalMail.Target, notice: String) -> Bool {
        guard let socketPath = privateSocketPath(at: target.socketPath) else { return false }
        // The server owns model credentials. This client needs only local socket access;
        // account configuration is kept consistent without inheriting another chat's identity.
        let environment = ["HOME": FileManager.default.homeDirectoryForCurrentUser.path,
                           "CODEX_HOME": target.accountHome,
                           "PATH": AgentLocalLaunch.store?.effectivePATH ?? ManagedAgentCatalog.systemPATH]
        guard let result = try? BoundedChildProcess.run(
            executable: target.executable,
            arguments: ["queue", "--remote", "unix://\(socketPath)", "--thread", target.threadID,
                        "--message", notice, "-c", "check_for_update_on_startup=false"],
            environment: environment, timeout: timeout, maximumOutputBytes: maximumOutputBytes
        ) else { return false }
        return result.termination == .exited(0)
    }

    /// Codex publishes its requested endpoint as an alias to a socket in its private daemon
    /// directory. Validate both ends, then connect to that exact socket; never discover a daemon.
    /// These fixed-count filesystem checks run on the bounded queue worker, not the main actor.
    private static func privateSocketPath(at path: String) -> String? {
        guard isPrivateDirectory((path as NSString).deletingLastPathComponent) else { return nil }
        var attributes = stat()
        guard lstat(path, &attributes) == 0, attributes.st_uid == getuid() else { return nil }
        let type = attributes.st_mode & S_IFMT
        guard type == S_IFSOCK || type == S_IFLNK else { return nil }

        let socket = URL(fileURLWithPath: path).resolvingSymlinksInPath()
        guard isPrivateDirectory(socket.deletingLastPathComponent().path),
              lstat(socket.path, &attributes) == 0, attributes.st_uid == getuid(),
              attributes.st_mode & S_IFMT == S_IFSOCK else { return nil }
        return socket.path
    }

    private static func isPrivateDirectory(_ path: String) -> Bool {
        var attributes = stat()
        return lstat(path, &attributes) == 0 && attributes.st_uid == getuid()
            && attributes.st_mode & S_IFMT == S_IFDIR && attributes.st_mode & 0o777 == 0o700
    }
}
