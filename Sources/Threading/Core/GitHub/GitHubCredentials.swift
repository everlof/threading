import Foundation

enum GitHubDefaults {
    static let apiHost = "api.github.com"
    static let webHost = "github.com"
    static let requestTimeout: TimeInterval = 30
    static let credentialProbeTimeout: TimeInterval = 10
    static let maximumCredentialProbeBytes = 64 * 1024
    static let apiVersion = "2022-11-28"
    static let acceptHeader = "application/vnd.github+json"
    static let userAgent = "Threading-GitHub/1"
    /// A failed probe is retried after this long, so installing or logging into `gh` does not
    /// require an app restart to be noticed.
    static let failedProbeRetryInterval: TimeInterval = 300
}

/// One GitHub credential and where it came from.
///
/// The tier travels to extensions (`ExtensionGitHubCredentialTier` carries the same raw
/// values), because "GitHub answered 404" means different things under different tiers — a
/// private repository under `anonymous` is fixed in Settings, the same answer under `app` is
/// a commit that genuinely is not there.
struct GitHubCredential: Equatable, Sendable {
    enum Tier: String, CaseIterable, Codable, Sendable {
        case app
        case ghCLI = "gh-cli"
        case gitCredential = "git-credential"
        case anonymous
    }

    let tier: Tier
    /// Nil only for `.anonymous`.
    let token: String?

    static let anonymous = GitHubCredential(tier: .anonymous, token: nil)
}

/// A resolvable source of one credential tier.
///
/// Sources cache what they learn: each probe is a subprocess or a network round trip, and the
/// answer only changes when the user acts (logs into `gh`, revokes a token). `invalidate()` is
/// the escape hatch for exactly that action — GitHub answering 401 for a cached token is proof
/// the cache is stale, not a reason to keep serving it.
protocol GitHubTokenSourcing: Actor {
    func token() async -> String?
    func invalidate()
}

/// Reads the `gh` CLI's active token by asking `gh` itself.
///
/// `gh auth token` is the supported door: modern gh keeps the token in the system Keychain, so
/// reading `~/.config/gh/hosts.yml` finds nothing on most machines. The probe runs through the
/// user's login shell because a GUI app does not inherit the interactive `PATH` and gh lives
/// wherever the user's package manager put it — the same reasoning as `AgentLauncher`.
actor GhCLITokenSource: GitHubTokenSourcing {
    private let probe: @Sendable (String) -> String?
    private let shellPath: String
    private var cached: String?
    private var failedAt: Date?

    init(
        shellPath: String,
        probe: @escaping @Sendable (String) -> String? = GhCLITokenSource.runProbe
    ) {
        self.shellPath = shellPath
        self.probe = probe
    }

    func token() async -> String? {
        if let cached { return cached }
        if let failedAt,
           Date().timeIntervalSince(failedAt) < GitHubDefaults.failedProbeRetryInterval {
            return nil
        }
        let value = probe(shellPath)
        if let value {
            cached = value
            failedAt = nil
        } else {
            failedAt = Date()
        }
        return value
    }

    func invalidate() {
        cached = nil
        failedAt = nil
    }

    private static let runProbe: @Sendable (String) -> String? = { shell in
        LoginShellProbe.run(
            "gh auth token --hostname \(GitHubDefaults.webHost)",
            shell: shell
        ).flatMap { output in
            let token = output.trimmingCharacters(in: .whitespacesAndNewlines)
            return token.isEmpty ? nil : token
        }
    }
}

/// Reads whatever the user's configured git credential helper holds for github.com.
///
/// This is the layer below `gh`: osxkeychain, Git Credential Manager, or gh's own helper all
/// answer the same `git credential fill` protocol, so it catches users who authenticated git
/// without ever installing gh. Prompting is explicitly disabled — a background probe must
/// fail quietly, never summon an askpass dialog.
actor GitCredentialHelperSource: GitHubTokenSourcing {
    private let probe: @Sendable (String) -> String?
    private let shellPath: String
    private var cached: String?
    private var failedAt: Date?

    init(
        shellPath: String,
        probe: @escaping @Sendable (String) -> String? = GitCredentialHelperSource.runProbe
    ) {
        self.shellPath = shellPath
        self.probe = probe
    }

    func token() async -> String? {
        if let cached { return cached }
        if let failedAt,
           Date().timeIntervalSince(failedAt) < GitHubDefaults.failedProbeRetryInterval {
            return nil
        }
        let value = probe(shellPath)
        if let value {
            cached = value
            failedAt = nil
        } else {
            failedAt = Date()
        }
        return value
    }

    func invalidate() {
        cached = nil
        failedAt = nil
    }

    private static let runProbe: @Sendable (String) -> String? = { shell in
        let command = "printf 'protocol=https\\nhost=\(GitHubDefaults.webHost)\\n\\n'"
            + " | GIT_TERMINAL_PROMPT=0 GIT_ASKPASS=/usr/bin/false GCM_INTERACTIVE=never"
            + " git credential fill 2>/dev/null"
        guard let output = LoginShellProbe.run(command, shell: shell) else { return nil }
        return password(fromCredentialFill: output)
    }

    /// The `key=value` protocol git's helpers speak; only `password` is the credential.
    static func password(fromCredentialFill output: String) -> String? {
        for line in output.split(separator: "\n") {
            guard let separator = line.firstIndex(of: "=") else { continue }
            if line[..<separator] == "password" {
                let token = String(line[line.index(after: separator)...])
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                return token.isEmpty ? nil : token
            }
        }
        return nil
    }
}

/// Runs one probe command through the user's login shell and returns its stdout.
///
/// Same shape as `AccountEmailProbe`: `-l -c` for the interactive `PATH`, stderr discarded,
/// output read before waiting so a full pipe cannot deadlock the child.
enum LoginShellProbe {
    static func run(_ command: String, shell: String) -> String? {
        let result: BoundedChildResult
        do {
            result = try BoundedChildProcess.run(
                executable: shell,
                arguments: ["-l", "-c", command],
                timeout: GitHubDefaults.credentialProbeTimeout,
                maximumOutputBytes: GitHubDefaults.maximumCredentialProbeBytes,
                output: .standardOutput
            )
        } catch {
            ThreadingLogger.github.error(
                "Login-shell probe could not start: \(error.localizedDescription, privacy: .private(mask: .hash))"
            )
            return nil
        }
        guard result.termination == .exited(0), !result.outputWasTruncated else { return nil }
        return String(data: result.output, encoding: .utf8)
    }
}

/// Resolves the GitHub credentials to try, most authoritative first.
///
/// The order is a policy, not an accident: an explicit app connection is what the user set up
/// for exactly this purpose; `gh` is ambient but deliberate ("I logged into gh"); a git
/// credential helper is ambient and incidental; anonymous always exists. Consumers try each in
/// turn — a 404 under one tier is answered by the next, because a GitHub App sees only the
/// repositories it was installed on while a `gh` token sees everything the user sees.
final class GitHubCredentialResolver: Sendable {
    private let appConnection: GitHubAppTokenProviding
    private let ghSource: any GitHubTokenSourcing
    private let gitSource: any GitHubTokenSourcing

    init(
        appConnection: GitHubAppTokenProviding,
        ghSource: any GitHubTokenSourcing,
        gitSource: any GitHubTokenSourcing
    ) {
        self.appConnection = appConnection
        self.ghSource = ghSource
        self.gitSource = gitSource
    }

    @MainActor
    static func live() -> GitHubCredentialResolver {
        let shell = AgentLauncher.loginShellPath
        return GitHubCredentialResolver(
            appConnection: GitHubAppConnection.shared,
            ghSource: GhCLITokenSource(shellPath: shell),
            gitSource: GitCredentialHelperSource(shellPath: shell)
        )
    }

    /// Every currently resolvable credential, ending in `.anonymous`.
    func orderedCredentials() async -> [GitHubCredential] {
        var credentials: [GitHubCredential] = []
        if let token = await appConnection.freshAccessToken() {
            credentials.append(GitHubCredential(tier: .app, token: token))
        }
        if let token = await ghSource.token() {
            credentials.append(GitHubCredential(tier: .ghCLI, token: token))
        }
        if let token = await gitSource.token() {
            credentials.append(GitHubCredential(tier: .gitCredential, token: token))
        }
        credentials.append(.anonymous)
        return credentials
    }

    /// Called when GitHub answered 401 for a tier's token: the cache is provably stale.
    func invalidate(_ tier: GitHubCredential.Tier) async {
        switch tier {
        case .app:
            await appConnection.noteRejectedAccessToken()
        case .ghCLI:
            await ghSource.invalidate()
        case .gitCredential:
            await gitSource.invalidate()
        case .anonymous:
            break
        }
    }
}
