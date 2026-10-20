import AppKit

// MARK: - Event

/// The installed-CLI answer changed for at least one runtime.
struct AgentCLIAvailabilityDidChange: AppEvent {
    static let name = Notification.Name("ThreadingAgentCLIAvailabilityDidChange")
}

// MARK: - Agent CLI Availability

/// The selected local client executables, shared by onboarding, settings and launch refusals.
/// The application runtime store supplies exact managed or explicitly external paths. A single
/// bounded login-shell probe supplies project-tool PATH independently of client selection.
/// Refreshes run off main, coalesce while in flight and run again after installation or selection.
/// Unknown remains distinct from missing until the first filesystem probe has answered.
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
        true // Managed artifacts include their runtime; a global npm is never required.
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

    /// Rechecks selected installations and refreshes project-tool PATH. Coalesces: a request while a probe is running schedules
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
        if let store = AgentLocalLaunch.store {
            store.refresh(shell: shell)
            var snapshot = Snapshot()
            for kind in AgentKind.allCases {
                let path = store.selection(for: kind).executable
                if FileManager.default.isExecutableFile(atPath: path) { snapshot.paths[kind] = path }
            }
            return snapshot
        }
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
            } else {
                let binary = kind.executableName
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
