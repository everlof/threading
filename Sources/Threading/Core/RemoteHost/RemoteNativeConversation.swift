import Foundation
import ThreadingPTYHostKit

/// One native surface's prepared remote route. Preparation is cancellable; SSH, credential
/// reads, JSON encoding and transcript transfers run on bounded workers rather than the UI actor.
@MainActor
final class RemoteNativeConversation {
    private static let worker = DispatchQueue(label: "codes.threading.remote-conversation", qos: .userInitiated)
    private(set) var launchPlan: AgentLaunchPlan?
    private(set) var childPlan: PTYHostChildPlan?
    private var context: RemoteHostLaunchContext?
    private var account: RemoteConversationAccount?
    private var recordedTranscript: String?
    private let hosts: RemoteExecutionHosts

    init(hosts: RemoteExecutionHosts = .shared) {
        self.hosts = hosts
    }

    func prepare(session: AgentSession, project: Project) async throws {
        try Task.checkCancellation()
        let host: ProjectExecutionHost
        switch RemoteExecutionHostRoute.resolve(project.executionHost) {
        case .remote(let selected): host = selected
        case .refused(let refusal): throw refusal
        case .local: throw RemoteConversationFailure.notPrepared
        }
        guard session.kind.supports(.remoteNativeConversation) else { throw RemoteAgentLaunchError.unsupportedAgent(session.kind) }
        guard session.managedWorkspace == nil else { throw RemoteAgentLaunchError.managedWorkspace }
        guard session.resumeState.transcriptID?.isSafePathComponent != false else { throw RemoteConversationFailure.notPrepared }
        guard AgentLauncher.forkParent(for: session, in: project) == nil else { throw RemoteAgentLaunchError.sideChatFork }
        let context = try await Self.readyContext(host: host, hosts: hosts)
        guard context.facts.hasPOSIXLoginShell else {
            throw RemoteAgentLaunchError.unsupportedLoginShell(context.facts.loginShell)
        }
        guard context.toolRoute?.bridgePath != nil, context.facts.curlPath != nil else {
            throw RemoteConversationFailure.toolsUnavailable
        }
        let remoteAccount = try await RemoteConversationAccount.prepared(for: session, on: host, context: context)
        try Task.checkCancellation()
        let unencoded = try Self.makeLaunch(session: session, host: host, context: context, account: remoteAccount)
        let encoded = await Self.encodedLaunch(unencoded)
        try Task.checkCancellation()
        self.context = context
        self.account = remoteAccount
        launchPlan = encoded
        childPlan = PTYHostChildPlan(
            identity: PTYHostSessionIdentity(TerminalInstanceIdentity.agentSession(session.id)),
            factory: PTYHostPolicy.attachingTransportFactory(socketPath: context.localSocketPath, retiresOlderDaemon: false),
            workingDirectory: host.remoteDirectory,
            isRemote: true
        )
        if let id = session.resumeState.transcriptID {
            let location = Self.transcriptLocation(session: session, id: id, host: host, context: context, account: remoteAccount)
            await Self.refreshMirror(location)
        }
        try Task.checkCancellation()
    }

    private static func readyContext(host: ProjectExecutionHost, hosts: RemoteExecutionHosts) async throws -> RemoteHostLaunchContext {
        guard let appSocket = MCPServer.shared.socketPath else { throw RemoteConversationFailure.toolsUnavailable }
        var phase = hosts.readiness(for: host.sshDestination, components: RemoteHostComponentSource.current(),
                                    appSocketPath: appSocket)
        let deadline = Date().addingTimeInterval(15 * 60)
        while true {
            try Task.checkCancellation()
            switch phase {
            case .ready(let context): return context
            case .failed(let failure): throw failure
            case .idle, .preparing: break
            }
            guard Date() < deadline else { throw RemoteConversationFailure.preparationTimedOut }
            try await Task.sleep(for: .milliseconds(200))
            phase = hosts.phase(for: host.sshDestination)
        }
    }

    static func makeLaunch(session: AgentSession, host: ProjectExecutionHost, context: RemoteHostLaunchContext,
                           account: RemoteConversationAccount) throws -> RemoteAgentLaunch.Unencoded {
        let integration = RemoteAgentLaunch.Integration.make(
            for: session, context: context, reportsLifecycle: AppSettings.shared.reportsClaudeLifecycleEvents,
            allowedTools: MCPToolCatalog.remoteProviderLaunchToolNames, brokersPermissions: true
        )
        let commands = try AgentLauncher.remoteStreamCommands(for: session, integration: integration.flags, toolRoute: context.toolRoute)
        let q = { (value: String) in ShellCommand(word: value).source }
        var lines = integration.scriptLines + ["cd \(q(host.remoteDirectory)) || exit 72"]
        if let credentialScript = account.credentialEnvironmentScript(for: session.kind) {
            lines.append(credentialScript)
        }
        if session.kind.supports(.presetSessionID), let id = commands.state.transcriptID {
            let path = transcriptPath(kind: session.kind, id: id, directory: host.remoteDirectory, account: account)
            lines.append("if [ -f \(q(path)) ]; then exec \(commands.resume.source); fi")
        }
        lines.append("exec \(commands.fresh.source)")
        let plan = AgentLaunchPlan(executable: context.facts.loginShell, arguments: ["-l", "-c", lines.joined(separator: "\n")],
                                   resumeState: commands.state)
        return RemoteAgentLaunch.Unencoded(plan: plan,
            environment: RemoteAgentLaunch.environment(for: context.facts) + integration.environment
                + ["\(account.environmentKey)=\(account.directory)"], payloads: integration.payloads)
    }

    private static func encodedLaunch(_ launch: RemoteAgentLaunch.Unencoded) async -> AgentLaunchPlan {
        await withCheckedContinuation { continuation in
            worker.async {
                let encoded = launch.encode()
                var environment: [String: String] = [:]
                for entry in encoded.environment {
                    guard let split = entry.firstIndex(of: "=") else { continue }
                    environment[String(entry[..<split])] = String(entry[entry.index(after: split)...])
                }
                continuation.resume(returning: AgentLaunchPlan(executable: encoded.plan.executable, arguments: encoded.plan.arguments,
                    resumeState: encoded.plan.resumeState, baseEnvironment: environment))
            }
        }
    }

    private static func refreshMirror(_ location: RemoteTranscriptLocation) async {
        await withCheckedContinuation { continuation in
            RemoteTranscriptMirror.shared.refresh(location) { _ in
                continuation.resume()
            }
        }
    }

    nonisolated static func transcriptPath(kind: AgentKind, id: TranscriptID, directory: String, account: RemoteConversationAccount) -> String {
        switch kind {
        case .claude:
            return "\(account.directory)/projects/\(ClaudeTranscript.projectSlug(forPath: directory))/\(id.rawValue).jsonl"
        case .codex:
            return "\(account.directory)/threading-transcripts/\(id.rawValue).jsonl"
        case .grok, .openCode, .cursor: return ""
        }
    }

    static func transcriptLocation(session: AgentSession, id: TranscriptID, host: ProjectExecutionHost,
                                   context: RemoteHostLaunchContext, account: RemoteConversationAccount) -> RemoteTranscriptLocation {
        RemoteTranscriptLocation(destination: context.destination,
            remotePath: transcriptPath(kind: session.kind, id: id, directory: host.remoteDirectory, account: account),
            localURL: RemoteTranscriptMirror.shared.localURL(destination: context.destination, transcriptID: id))
    }

    /// App-server supplies the exact rollout path. Remember it as a stable remote alias, avoiding
    /// a walk of the remote account's entire history on each reopen.
    func recordTranscript(id: TranscriptID, path: String) {
        guard let context, let account, recordedTranscript != path,
              let script = Self.transcriptAliasScript(id: id, path: path, account: account)
        else { return }
        recordedTranscript = path
        Self.worker.async { [weak self] in
            let result = try? SystemSSHCommandRunner().run(on: context.destination, command: "sh -s",
                input: .data(Data(script.utf8)), extraOptions: [], timeout: 30)
            if result?.succeeded != true {
                Task { @MainActor [weak self] in
                    if self?.recordedTranscript == path { self?.recordedTranscript = nil }
                }
            }
        }
    }

    nonisolated static func transcriptAliasScript(id: TranscriptID, path: String, account: RemoteConversationAccount) -> String? {
        guard UUID(uuidString: id.rawValue) != nil, path.hasPrefix(account.directory + "/sessions/"),
              !path.contains("/../"), !path.contains("\0"), path.utf8.count <= 4096 else { return nil }
        let q = { (value: String) in ShellCommand(word: value).source }
        let directory = "\(account.directory)/threading-transcripts"
        let alias = "\(directory)/\(id.rawValue).jsonl"
        return """
        set -eu
        umask 077
        test ! -L \(q(directory))
        mkdir -p \(q(directory))
        chmod 700 \(q(directory))
        ln -sfnT \(q(path)) \(q(alias))
        """
    }

}
