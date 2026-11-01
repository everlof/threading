import Foundation
import ThreadingController

/// Idle terminal delivery through Codex's own queue. No terminal/composer capability is held.
/// Normal load is a few live terminals; 128 recipients and four child processes bound bursts.
/// Activity touches one identity, and only a transition into prompt-ready queries its mailbox.
@MainActor
final class CodexTerminalMail {
    struct Target: Equatable, Sendable {
        let executable: String
        let socketPath: String
        let threadID: String
        let accountHome: String
    }

    static let shared = CodexTerminalMail(mailbox: .shared, isReady: liveIsReady)
    static let maximumPending = 128
    private let mailbox: MacMailbox
    private let target: @MainActor (SessionID) -> Target?
    private let isReady: @MainActor (SessionID) -> Bool
    private let enqueue: @Sendable (Target, String) async -> Bool
    private var ready: Set<SessionID> = []
    private var pending: Set<SessionID> = []
    private var changedWhilePending: Set<SessionID> = []

    init(mailbox: MacMailbox,
         target: @escaping @MainActor (SessionID) -> Target? = liveTarget,
         isReady: (@MainActor (SessionID) -> Bool)? = nil,
         enqueue: @escaping @Sendable (Target, String) async -> Bool = { await CodexMailQueue.enqueue($0, notice: $1) }) {
        self.mailbox = mailbox
        self.target = target
        self.isReady = isReady ?? { target($0) != nil }
        self.enqueue = enqueue
    }

    static func liveIsReady(_ id: SessionID) -> Bool {
        guard MCPToolCatalog.isEnabled(MCPToolCatalog.workspace),
              let session = ProjectStore.shared.session(withID: id),
              session.kind.supports(.queuedTerminalMail), !session.isArchived, !session.usesNativeUI,
              ProjectStore.shared.project(forSessionID: id)?.executionHost == nil,
              !RemoteSessionMailboxes.shared.keepsMailOnHost(id),
              AgentRuntime.shared.runtimeSnapshot(sessionID: id).isPromptReady,
              let thread = session.resumeState.transcriptID, UUID(uuidString: thread.rawValue) != nil
        else { return false }
        return true
    }

    static func liveTarget(_ id: SessionID) -> Target? {
        guard liveIsReady(id), let session = ProjectStore.shared.session(withID: id),
              let thread = session.resumeState.transcriptID, UUID(uuidString: thread.rawValue) != nil,
              let executable = AgentLocalLaunch.store?.selection(for: session.kind).executable,
              let account = AgentAccountDiscovery.account(for: session.kind, handle: session.accountHandle)
        else { return nil }
        return Target(executable: executable, socketPath: CodexTerminalLaunch.socketPath(for: id),
                      threadID: thread.rawValue, accountHome: account.configPath)
    }

    func activityChanged(_ id: SessionID) {
        guard isReady(id) else { ready.remove(id); return }
        guard ready.insert(id).inserted else { return }
        arrived(for: id)
    }

    func arrived(for id: SessionID) {
        if pending.contains(id) { changedWhilePending.insert(id); return }
        guard pending.count < Self.maximumPending, let destination = target(id) else { return }
        pending.insert(id)
        Task { @MainActor in
            defer {
                pending.remove(id)
                if changedWhilePending.remove(id) != nil { arrived(for: id) }
            }
            guard let notice = await mailbox.pendingWake(for: id), target(id) == destination else { return }
            guard await enqueue(destination, notice.text) else {
                // No receipt consumes no notice. A later arrival/prompt-ready edge can retry;
                // an ambiguous timeout is not blindly replayed into a second model turn.
                EventLog.shared.record(.mcp, "Codex mail wake unconfirmed", ["session": id.uuidString])
                return
            }
            await mailbox.confirmWake(for: id, ids: notice.ids)
            EventLog.shared.record(.mcp, "Codex mail wake queued", ["session": id.uuidString,
                                                                  "messages": "\(notice.ids.count)"])
        }
    }
}

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
        let directory = (target.socketPath as NSString).deletingLastPathComponent
        var attributes = stat()
        guard lstat(directory, &attributes) == 0, attributes.st_uid == getuid(),
              attributes.st_mode & S_IFMT == S_IFDIR, attributes.st_mode & 0o777 == 0o700,
              lstat(target.socketPath, &attributes) == 0, attributes.st_uid == getuid(),
              attributes.st_mode & S_IFMT == S_IFSOCK else { return false }
        // The server owns model credentials. This client needs only local socket access;
        // account configuration is kept consistent without inheriting another chat's identity.
        let environment = ["HOME": FileManager.default.homeDirectoryForCurrentUser.path,
                           "CODEX_HOME": target.accountHome,
                           "PATH": AgentLocalLaunch.store?.effectivePATH ?? ManagedAgentCatalog.systemPATH]
        guard let result = try? BoundedChildProcess.run(
            executable: target.executable,
            arguments: ["queue", "--remote", "unix://\(target.socketPath)", "--thread", target.threadID,
                        "--message", notice, "-c", "check_for_update_on_startup=false"],
            environment: environment, timeout: timeout, maximumOutputBytes: maximumOutputBytes
        ) else { return false }
        return result.termination == .exited(0)
    }
}
