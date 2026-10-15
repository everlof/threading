import CryptoKit
import Darwin
import Foundation

/// The selected login's remote home. Credential bytes only exist on the preparation worker and
/// SSH stdin; neither launch arguments nor diagnostics carry them. The remote CLI owns refreshes.
struct RemoteConversationAccount: Sendable {
    private static let worker = DispatchQueue(label: "codes.threading.remote-account", qos: .userInitiated)
    let directory: String
    let environmentKey: String
    let credentialFile: String
    let usesCopiedLogin: Bool

    @MainActor
    static func reusesCredentials(on host: ProjectExecutionHost, store: RemoteHostStore = .shared) -> Bool {
        let record = host.hostID.flatMap { store.host(withID: $0) }
            ?? store.host(naming: host.destination, sshConfigFile: host.sshConfigFile)
        return record?.reusesLocalCredentials == true
    }

    /// A pre-existing transcript stays with its original account across presentation changes.
    static func usesCopiedAccount(for session: AgentSession, reuseCredentials: Bool) -> Bool {
        session.remoteUsesCopiedAccount ?? (session.resumeState.transcriptID == nil && reuseCredentials)
    }

    /// Shared by terminal and native launches. Discovery, credential reads and SSH stay off-main.
    @MainActor
    static func prepared(for session: AgentSession, on host: ProjectExecutionHost,
                         context: RemoteHostLaunchContext) async throws -> Self {
        let reuse = reusesCredentials(on: host)
        let copied = usesCopiedAccount(for: session, reuseCredentials: reuse)
        guard let local = await AgentAccountDiscovery.discoverAccount(for: session.kind, handle: session.accountHandle),
              local.handle == session.accountHandle else { throw RemoteConversationFailure.accountUnavailable }
        try Task.checkCancellation()
        let remote = try make(account: local, home: context.facts.home, reuse: copied)
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            worker.async {
                continuation.resume(with: Result {
                    try remote.prepare(account: local, reuse: reuse && copied, context: context)
                })
            }
        }
        try Task.checkCancellation()
        return remote
    }

    static func make(account: AgentAccount, home: String, reuse: Bool) throws -> Self {
        let key: String
        let defaultDirectory: String
        let file: String
        switch account.provider {
        case .claude:
            key = "CLAUDE_CONFIG_DIR"
            defaultDirectory = ".claude"
            file = ".credentials.json"
        case .codex:
            key = "CODEX_HOME"
            defaultDirectory = ".codex"
            file = "auth.json"
        case .grok, .openCode, .cursor:
            throw RemoteAgentLaunchError.unsupportedAgent(account.provider)
        }
        guard reuse else {
            return Self(directory: "\(home)/\(defaultDirectory)", environmentKey: key, credentialFile: file, usesCopiedLogin: false)
        }
        let digest = SHA256.hash(data: Data((key + "\0" + account.configPath).utf8))
            .map { String(format: "%02x", $0) }.joined()
        let directory = "\(home)/.local/share/threading/accounts/\(digest)"
        return Self(directory: directory, environmentKey: key, credentialFile: file, usesCopiedLogin: true)
    }

    /// Reassert the selected account after the host's login profile runs. Host-owned logins
    /// retain the profile's authentication environment; copied logins use their own credentials.
    func credentialEnvironmentScript(for provider: AgentKind) -> String? {
        guard usesCopiedLogin else { return nil }
        var lines = ["export \(environmentKey)=\(ShellCommand(word: directory).source)"]
        switch provider {
        case .claude: lines.append("unset ANTHROPIC_API_KEY ANTHROPIC_AUTH_TOKEN")
        case .codex: lines.append("unset OPENAI_API_KEY CODEX_API_KEY")
        case .grok, .openCode, .cursor: return nil
        }
        guard let spec = provider.longLivedToken else { return lines.joined(separator: "\n") }
        let tokenFile = ShellCommand(word: directory + "/threading-login-token").source
        lines.append("if [ -f \(tokenFile) ]; then export \(spec.environmentKey)=\"$(cat \(tokenFile))\"; else unset \(spec.environmentKey); fi")
        return lines.joined(separator: "\n")
    }

    /// Runs on a bounded, serial worker. An already populated remote account is left alone:
    /// copying the Mac's older refresh token over a remotely refreshed token would break login.
    func prepare(
        account: AgentAccount,
        reuse: Bool,
        context: RemoteHostLaunchContext,
        runner: any RemoteHostCommandRunning = SystemSSHCommandRunner()
    ) throws {
        let q = { (value: String) in ShellCommand(word: value).source }
        let probe = "command -v \(q(account.provider.executableName)) >/dev/null 2>&1"
        let command = "\(q(context.facts.loginShell)) -l -c \(q(probe))"
        let installed = try runner.run(on: context.destination, command: command, input: .none,
                                       extraOptions: [], timeout: 30)
        guard installed.succeeded else { throw RemoteAgentLaunchError.agentNotInstalled(account.provider) }
        guard reuse else { return }
        let token = account.provider.longLivedToken == nil ? nil : AgentAccountTokenVault.shared.token(for: account.id)
        let file = token == nil ? credentialFile : "threading-login-token"
        let path = "\(directory)/\(file)"
        let check = Self.privateDirectoryScript(directory) + """

        target=\(q(path))
        test ! -L "$target" || exit 2
        test -e "$target" || exit 1
        test -f "$target" && test -s "$target" || exit 2
        test "$(stat -c %u "$target")" = "$(id -u)" || exit 2
        chmod 600 "$target"
        """
        let existing = try runner.run(
            on: context.destination, command: "sh -s",
            input: .data(Data(check.utf8)),
            extraOptions: [], timeout: 30
        )
        if !existing.succeeded {
            guard existing.termination == .exited(1) else { throw RemoteConversationFailure.credentialTransfer }
            let credentials = try token.map { Data($0.value.utf8) } ?? Self.credentials(for: account)
            let script = Self.installScript(directory: directory, file: file, credentials: credentials)
            let result = try runner.run(on: context.destination, command: "sh -s", input: .data(Data(script.utf8)),
                                        extraOptions: [], timeout: 30)
            guard result.succeeded else { throw RemoteConversationFailure.credentialTransfer }
        }
        switch account.provider {
        case .claude:
            // A new copied login has already completed sign-in on the Mac. Claude's interactive
            // onboarding otherwise asks for a second sign-in even with a usable credential.
            // Seed only our private account's missing state file; existing CLI state is preserved.
            let script = Self.installScript(directory: directory, file: ".claude.json",
                credentials: Data(#"{"hasCompletedOnboarding":true}"#.utf8))
            let result = try runner.run(on: context.destination, command: "sh -s", input: .data(Data(script.utf8)),
                                        extraOptions: [], timeout: 30)
            guard result.succeeded else { throw RemoteConversationFailure.credentialTransfer }
        case .codex, .grok, .openCode, .cursor:
            break
        }
    }

    static func installScript(directory: String, file: String, credentials: Data) -> String {
        let q = { (value: String) in ShellCommand(word: value).source }
        return privateDirectoryScript(directory) + """

        target="$directory"/\(q(file))
        test ! -L "$target"
        if [ -e "$target" ]; then
          test -f "$target"
          test "$(stat -c %u "$target")" = "$(id -u)"
          chmod 600 "$target"
          exit 0
        fi
        temporary=$(mktemp "$directory/.credential.XXXXXXXX")
        trap 'rm -f "$temporary"' EXIT HUP INT TERM
        printf '%s' '\(credentials.base64EncodedString())' | base64 -d > "$temporary"
        chmod 600 "$temporary"
        # Atomic create, without replacing credentials another launch has just refreshed.
        ln "$temporary" "$target" 2>/dev/null || test -f "$target"
        """
    }

    private static func privateDirectoryScript(_ directory: String) -> String {
        """
        set -eu
        umask 077
        directory=\(ShellCommand(word: directory).source)
        # Reject symlinks in every existing ancestor before making private directories.
        parent="$directory"
        while [ "$parent" != / ]; do
          test ! -L "$parent" || exit 2
          parent=${parent%/*}
          test -n "$parent" || parent=/
        done
        mkdir -p "$directory"
        test "$(stat -c %u "$directory")" = "$(id -u)" || exit 2
        chmod 700 "$directory"
        """
    }

    static func credentials(
        for account: AgentAccount,
        keychainExport: (String) throws -> Data? = { try ClaudeKeychainCredentials.exportForRemoteLogin(configPath: $0) }
    ) throws -> Data {
        let bytes: Data
        switch account.provider {
        case .codex:
            bytes = try readCredentialFile("\(account.configPath)/auth.json", provider: account.provider)
        case .claude:
            do {
                bytes = try keychainExport(account.configPath)
                    ?? readCredentialFile("\(account.configPath)/.credentials.json", provider: account.provider)
            } catch ClaudeKeychainCredentials.RemoteLoginExportError.accessRequired {
                // A file-backed login can still work when the Keychain item is inaccessible.
                guard let file = try? readCredentialFile("\(account.configPath)/.credentials.json", provider: account.provider) else {
                    throw RemoteConversationFailure.claudeKeychainAccessRequired
                }
                bytes = file
            }
        case .grok, .openCode, .cursor:
            throw RemoteAgentLaunchError.unsupportedAgent(account.provider)
        }
        return try validatedCredentials(bytes, provider: account.provider)
    }

    /// Copy only authentication fields, never CLI preferences, hooks, MCP servers or history.
    static func validatedCredentials(_ bytes: Data, provider: AgentKind) throws -> Data {
        guard bytes.count <= 64 * 1024,
              let object = try? JSONSerialization.jsonObject(with: bytes) as? [String: Any]
        else { throw RemoteConversationFailure.credentialsUnavailable(provider) }
        let result: [String: Any]
        switch provider {
        case .claude:
            guard let oauth = object["claudeAiOauth"] as? [String: Any],
                  let token = oauth["accessToken"] as? String, !token.isEmpty
            else { throw RemoteConversationFailure.credentialsUnavailable(provider) }
            result = ["claudeAiOauth": oauth]
        case .codex:
            let tokens = object["tokens"] as? [String: Any]
            let hasOAuth = (tokens?["access_token"] as? String)?.isEmpty == false
            let hasKey = (object["OPENAI_API_KEY"] as? String)?.isEmpty == false
            guard hasOAuth || hasKey else { throw RemoteConversationFailure.credentialsUnavailable(provider) }
            result = object.filter { ["auth_mode", "OPENAI_API_KEY", "tokens", "last_refresh"].contains($0.key) }
        case .grok, .openCode, .cursor:
            throw RemoteAgentLaunchError.unsupportedAgent(provider)
        }
        return try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys])
    }

    private static func readCredentialFile(_ path: String, provider: AgentKind) throws -> Data {
        let descriptor = open(path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        guard descriptor >= 0 else { throw RemoteConversationFailure.credentialsUnavailable(provider) }
        defer { close(descriptor) }
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
              info.st_uid == getuid(), info.st_size > 0, info.st_size <= 64 * 1024
        else { throw RemoteConversationFailure.credentialsUnavailable(provider) }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: false)
        guard let data = try handle.read(upToCount: 64 * 1024 + 1), data.count <= 64 * 1024
        else { throw RemoteConversationFailure.credentialsUnavailable(provider) }
        return data
    }
}

enum RemoteConversationFailure: LocalizedError {
    case notPrepared, accountUnavailable, claudeKeychainAccessRequired
    case credentialsUnavailable(AgentKind)
    case credentialTransfer, preparationTimedOut, toolsUnavailable

    static let keychainAccessCause = "remoteHost.claudeKeychainAccessRequired"

    var launchFailure: SessionLaunchFailure {
        SessionLaunchFailure(origin: .preflight, summary: localizedDescription,
            knownCause: self.isKeychainAccessRequired ? Self.keychainAccessCause : "remoteHost.accountPreparation")
    }

    private var isKeychainAccessRequired: Bool {
        if case .claudeKeychainAccessRequired = self { return true }
        return false
    }

    var errorDescription: String? {
        switch self {
        case .notPrepared: return L10n.string("The remote chat is not ready. Try opening it again.")
        case .accountUnavailable:
            return L10n.string("The selected login is no longer available on this Mac. Choose a login in Agents & Accounts, then try again.")
        case .claudeKeychainAccessRequired:
            return L10n.string("Threading needs permission to copy your Claude login from this Mac’s Keychain.\n\nOpen Privacy Settings and enable Live usage from your Claude login if it is off. Click Allow… if shown, then choose Always Allow in the macOS prompt. Return here and try again.")
        case .credentialsUnavailable(let provider):
            switch provider {
            case .claude:
                return L10n.string("The selected Claude login could not be read. Reconnect it in Agents & Accounts, then try again.")
            case .codex:
                return L10n.string("The selected Codex login has no readable auth.json file. Reconnect it in Agents & Accounts to save a login that can be copied, then try again.")
            case .grok, .openCode, .cursor:
                return L10n.format("The selected %@ login could not be read.", provider.displayName)
            }
        case .credentialTransfer: return L10n.string("The login could not be stored securely on the remote host. Check that the remote account can write to its home folder, then try again.")
        case .preparationTimedOut: return L10n.string("Preparing the remote chat timed out. Check the host and try again.")
        case .toolsUnavailable: return L10n.string("The remote host needs a working connection back to Threading for chat tools and permission requests.")
        }
    }
}
