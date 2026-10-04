import AppKit

// MARK: - Event

/// The installed-CLI answer changed for at least one runtime.
struct AgentCLIAvailabilityDidChange: AppEvent {
    static let name = Notification.Name("ThreadingAgentCLIAvailabilityDidChange")
}

// MARK: - Install Recipe

/// How each runtime's official CLI gets onto a Mac, in one place: the onboarding page, the
/// install sheet, the composer's refusal and the launch-failure screen all say the same thing.
///
/// The commands are each provider's own published installer. Three of them are npm packages,
/// which is the detail a fresh Mac trips on: without Node.js there is no `npm`, and an
/// "Install" that fails with a second `command not found` is worse than one that says up front
/// what it needs.
struct AgentCLIInstallRecipe: Equatable, Sendable {

    enum Requirement: Equatable, Sendable {
        /// `curl` ships with macOS; nothing to check.
        case none
        /// The package manager that comes with Node.js.
        case nodePackageManager
    }

    let kind: AgentKind
    /// The exact shell source the install sheet runs, and the text **Copy** puts on the
    /// pasteboard.
    let command: String
    let requirement: Requirement
    /// Where the native installers put the binary. When the install succeeds but the login
    /// shell still cannot find it, this is the evidence that the PATH, not the install, is what
    /// needs fixing.
    let userBinaryName: String?

    static func recipe(for kind: AgentKind) -> AgentCLIInstallRecipe {
        switch kind {
        case .claude:
            return AgentCLIInstallRecipe(
                kind: kind,
                command: "curl -fsSL https://claude.ai/install.sh | bash",
                requirement: .none,
                userBinaryName: AgentDefaults.claudeExecutable
            )
        case .codex:
            return AgentCLIInstallRecipe(
                kind: kind,
                command: "npm install -g @openai/codex",
                requirement: .nodePackageManager,
                userBinaryName: nil
            )
        case .grok:
            return AgentCLIInstallRecipe(
                kind: kind,
                command: "npm install -g @xai-official/grok",
                requirement: .nodePackageManager,
                userBinaryName: nil
            )
        case .openCode:
            return AgentCLIInstallRecipe(
                kind: kind,
                command: "npm install -g opencode-ai",
                requirement: .nodePackageManager,
                userBinaryName: nil
            )
        case .cursor:
            return AgentCLIInstallRecipe(
                kind: kind,
                command: "curl https://cursor.com/install -fsS | bash",
                requirement: .none,
                userBinaryName: AgentDefaults.cursorExecutable
            )
        }
    }
}

// MARK: - Agent CLI Availability

/// Which agent CLIs the launching login shell can actually find, shared by every surface that
/// has to decide something before a launch.
///
/// Before this, the onboarding page asked once and kept the answer to itself, so the rest of the
/// app learnt a CLI was missing the expensive way: the composer defaulted to Claude Code on a Mac
/// without it, a session row was created, and the first thing the user saw was a launch-failure
/// screen whose primary action — Try Again — could not succeed. Now the composer opens on an
/// installed runtime, refuses a send to a missing one before a row exists, and the failure
/// screen and onboarding offer the install itself.
///
/// **One shell, not one per CLI.** The probe asks the login shell for its `PATH` once
/// (`AgentCLIProbe.loginShellPATH`, the launcher's shell and profile) and resolves every
/// executable against that answer, so a heavy profile is paid once per refresh rather than six
/// times. Refreshes run off the main actor, coalesce while one is in flight, and are throttled
/// on app activation — coming back from a Terminal where something was just installed is
/// exactly when the answer is worth having.
///
/// **Unknown is not missing.** Until a probe has answered, every runtime is `.unknown` and every
/// caller behaves exactly as it did before this type existed. A refusal is only ever made on a
/// `.missing` the probe actually returned.
@MainActor
final class AgentCLIAvailability {

    enum State: Equatable, Sendable {
        case unknown
        case installed(path: String)
        case missing
    }

    /// What one probe found, as a value so it crosses back from the worker whole.
    struct Snapshot: Equatable, Sendable {
        var paths: [AgentKind: String] = [:]
        var hasNodePackageManager = false
        /// Kinds whose native installer's binary exists in `~/.local/bin` while the login shell
        /// cannot find it — installed, but not on PATH.
        var installedOffPath: Set<AgentKind> = []
    }

    /// Given the login shell to ask, what it can find. Nil when the shell itself could not answer.
    typealias Probe = @Sendable (_ shell: String) -> Snapshot?

    // MARK: - Properties

    /// A hosted test never sources the developer's shell profile: its probe answers nothing,
    /// so every runtime stays `unknown` and every caller behaves as it did before this existed.
    static let shared = AgentCLIAvailability(
        probe: { shell in
            NSClassFromString("XCTestCase") == nil
                ? AgentCLIAvailability.loginShellProbe(shell: shell)
                : nil
        }
    )

    private(set) var snapshot: Snapshot?
    private let probe: Probe
    private let shell: @MainActor () -> String
    private let activationThrottle: TimeInterval
    private var isProbing = false
    private var wantsAnotherProbe = false
    private var lastProbeStartedAt: Date?
    private var waiters: [@MainActor () -> Void] = []
    private let appEvents = AppEventObservations()
    private var isObservingActivation = false

    // MARK: - Initialization

    init(
        probe: @escaping Probe,
        shell: @escaping @MainActor () -> String = { AgentLauncher.loginShellPath },
        activationThrottle: TimeInterval = AgentCLIAvailabilityDefaults.activationThrottle
    ) {
        self.probe = probe
        self.shell = shell
        self.activationThrottle = activationThrottle
    }

    // MARK: - Public Methods

    func state(for kind: AgentKind) -> State {
        guard let snapshot else { return .unknown }
        return snapshot.paths[kind].map(State.installed(path:)) ?? .missing
    }

    /// Only a probe's own answer can make this true.
    func isKnownMissing(_ kind: AgentKind) -> Bool {
        state(for: kind) == .missing
    }

    var installedKinds: [AgentKind] {
        AgentKind.allCases.filter { snapshot?.paths[$0] != nil }
    }

    /// Whether this runtime's installer can run at all on this Mac right now.
    func canRunInstaller(for kind: AgentKind) -> Bool {
        switch AgentCLIInstallRecipe.recipe(for: kind).requirement {
        case .none: return true
        case .nodePackageManager: return snapshot?.hasNodePackageManager ?? true
        }
    }

    func isInstalledOffPath(_ kind: AgentKind) -> Bool {
        snapshot?.installedOffPath.contains(kind) == true
    }

    /// The runtime a fresh draft should open on. The user's choice stands whenever it can launch
    /// — or whenever nobody knows yet. Only a choice the probe proved missing, on a Mac where
    /// another runtime is installed, gives way, and it gives way to the first installed runtime
    /// in the product's own order.
    func preferredRuntime(given choice: AgentKind) -> AgentKind {
        guard isKnownMissing(choice), let installed = installedKinds.first else { return choice }
        return installed
    }

    /// Re-reads the login shell's PATH. Coalesces: a request while a probe is running schedules
    /// exactly one more, so an install that finishes mid-probe is never answered from before it.
    func refresh(completion: (@MainActor () -> Void)? = nil) {
        if let completion { waiters.append(completion) }
        guard !isProbing else {
            wantsAnotherProbe = true
            return
        }
        isProbing = true
        lastProbeStartedAt = Date()
        let probe = self.probe
        let shell = self.shell()
        Task { [weak self] in
            let found = await Task.detached(priority: .utility) { probe(shell) }.value
            self?.finish(found)
        }
    }

    /// Starts listening for app activation. Idempotent; the first call also probes.
    func startMonitoring() {
        guard !isObservingActivation else { return }
        isObservingActivation = true
        appEvents.observe(NSApplication.didBecomeActiveNotification) { [weak self] in
            self?.refreshAfterActivation()
        }
        refresh()
    }

    /// For tests: states an answer without a shell.
    func setSnapshotForTesting(_ snapshot: Snapshot?) {
        self.snapshot = snapshot
    }

    // MARK: - Private Methods

    private func refreshAfterActivation() {
        if let lastProbeStartedAt,
           Date().timeIntervalSince(lastProbeStartedAt) < activationThrottle {
            return
        }
        refresh()
    }

    private func finish(_ found: Snapshot?) {
        isProbing = false
        // A probe that could not read the shell at all says nothing about the CLIs; the last
        // real answer (or `unknown`) stands rather than turning every runtime into "missing".
        if let found, found != snapshot {
            snapshot = found
            NotificationCenter.default.post(AgentCLIAvailabilityDidChange())
        }
        if wantsAnotherProbe {
            wantsAnotherProbe = false
            refresh()
            return
        }
        let settled = waiters
        waiters.removeAll()
        settled.forEach { $0() }
    }

    /// The production probe: one login shell for the PATH, then a file check per executable.
    nonisolated static func loginShellProbe(shell: String) -> Snapshot? {
        guard let path = AgentCLIProbe.loginShellPATH(shell: shell) else { return nil }
        return snapshot(
            onPath: path,
            home: FileManager.default.homeDirectoryForCurrentUser,
            isExecutable: FileManager.default.isExecutableFile(atPath:)
        )
    }

    /// The pure half of the probe.
    nonisolated static func snapshot(
        onPath path: String,
        home: URL,
        isExecutable: (String) -> Bool
    ) -> Snapshot {
        var result = Snapshot()
        for kind in AgentKind.allCases {
            if let found = AgentCLIProbe.locate(kind.executableName, on: path, isExecutable: isExecutable) {
                result.paths[kind] = found
            } else if let binary = AgentCLIInstallRecipe.recipe(for: kind).userBinaryName {
                let candidate = home
                    .appendingPathComponent(AgentCLIAvailabilityDefaults.userBinaryDirectory)
                    .appendingPathComponent(binary)
                    .path
                if isExecutable(candidate) { result.installedOffPath.insert(kind) }
            }
        }
        result.hasNodePackageManager = AgentCLIProbe.locate(
            AgentCLIAvailabilityDefaults.nodePackageManager,
            on: path,
            isExecutable: isExecutable
        ) != nil
        return result
    }
}

// MARK: - Defaults

enum AgentCLIAvailabilityDefaults {
    /// Activation is frequent; a profile-sourcing shell is not free. Twenty seconds keeps
    /// "came back from installing in Terminal" immediate without a probe per ⌘-Tab.
    static let activationThrottle: TimeInterval = 20
    static let nodePackageManager = "npm"
    static let userBinaryDirectory = ".local/bin"
}
