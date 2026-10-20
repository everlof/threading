import Foundation

struct ManagedAgentInstallation: Codable, Equatable, Sendable {
    let version: String
    let directory: String
    let executable: String
    let archiveIntegrity: String
}

struct ManagedAgentReceipt: Codable, Equatable, Sendable {
    var schemaVersion = 1
    var active: ManagedAgentInstallation
    var previous: ManagedAgentInstallation?
}

struct AgentRuntimeSelection: Equatable, Sendable {
    let executable: String
    let version: String?
    let managed: Bool
}

/// Disk work belongs to refresh/install workers. Launch planning only reads this bounded cache.
/// Selection preferences are separate from provider account homes and from installation receipts.
final class ManagedAgentRuntimeStore: @unchecked Sendable {
    static let local = ManagedAgentRuntimeStore(root: defaultRoot, preferences: PreferenceStore.shared)
    static let selectionKey = "AgentTools.externalExecutables"
    static let projectPATHKey = "AgentTools.projectPATH"
    static let stableShell = "/bin/sh"

    let root: URL
    private let preferences: UserDefaults
    private let lock = NSLock()
    private let diskLock = NSRecursiveLock()
    private var receipts: [AgentKind: ManagedAgentReceipt] = [:]
    private var failures: [AgentKind: String] = [:]
    private var projectPATH = ManagedAgentCatalog.systemPATH
    private var installing = false

    init(root: URL, preferences: UserDefaults) {
        self.root = root.standardizedFileURL.resolvingSymlinksInPath()
        self.preferences = preferences
        let cached = preferences.string(forKey: Self.projectPATHKey)
        let inherited = ProcessInfo.processInfo.environment[EnvironmentKeys.path]
        projectPATH = [cached, inherited].compactMap { $0 }.first(where: Self.isValidPATH)
            ?? ManagedAgentCatalog.systemPATH
    }

    static var defaultRoot: URL {
        let environment = ProcessInfo.processInfo.environment
        if let scenarioHome = environment["THREADING_UI_SCENARIO_HOME"] {
            return URL(fileURLWithPath: scenarioHome).appendingPathComponent("AgentTools")
        }
        if NSClassFromString("XCTestCase") != nil {
            return URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("Threading-AgentTools-\(ProcessInfo.processInfo.processIdentifier)")
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Threading/AgentTools")
    }

    func isManaged(_ kind: AgentKind) -> Bool { externalPath(for: kind) == nil }

    func externalPath(for kind: AgentKind) -> String? {
        lock.withLock {
            let paths = preferences.dictionary(forKey: Self.selectionKey) as? [String: String] ?? [:]
            guard let path = paths[kind.rawValue], path.hasPrefix("/"), !path.contains("\0") else { return nil }
            return path
        }
    }

    func selectExternal(_ path: String?, for kind: AgentKind) {
        lock.withLock {
            var paths = preferences.dictionary(forKey: Self.selectionKey) as? [String: String] ?? [:]
            paths[kind.rawValue] = path
            preferences.set(paths, forKey: Self.selectionKey)
        }
    }

    func receipt(for kind: AgentKind) -> ManagedAgentReceipt? {
        lock.withLock { receipts[kind] }
    }

    func failure(for kind: AgentKind) -> String? { lock.withLock { failures[kind] } }

    func selection(for kind: AgentKind) -> AgentRuntimeSelection {
        if let external = externalPath(for: kind) {
            return AgentRuntimeSelection(executable: external, version: nil, managed: false)
        }
        let active = receipt(for: kind)?.active
        // An absent or refused receipt deliberately resolves to a missing PRIVATE path. A
        // schedule or early launch must never silently pick a different program from PATH.
        let executable = active.map { executableURL($0, kind: kind).path }
            ?? providerRoot(kind).appendingPathComponent("not-installed/\(kind.executableName)").path
        return AgentRuntimeSelection(executable: executable, version: active?.version, managed: true)
    }

    var effectivePATH: String { lock.withLock { projectPATH } }

    func beginInstallation() -> Bool {
        lock.withLock {
            guard !installing else { return false }
            installing = true
            return true
        }
    }

    func endInstallation() { lock.withLock { installing = false } }

    func refresh(shell: String) {
        if let path = AgentCLIProbe.loginShellPATH(shell: shell), Self.isValidPATH(path) {
            lock.withLock {
                projectPATH = path
                preferences.set(path, forKey: Self.projectPATHKey)
            }
        }
        loadReceipts()
    }

    private static func isValidPATH(_ path: String) -> Bool {
        !path.isEmpty && !path.contains("\0") && path.utf8.count <= 32 * 1024
    }

    func loadReceipts() {
        diskLock.lock()
        defer { diskLock.unlock() }
        var loaded: [AgentKind: ManagedAgentReceipt] = [:]
        var errors: [AgentKind: String] = [:]
        for kind in AgentKind.allCases {
            do {
                if let receipt = try readReceipt(for: kind) { loaded[kind] = receipt }
            } catch { errors[kind] = error.localizedDescription }
        }
        lock.withLock {
            receipts = loaded
            failures = errors
        }
    }

    func providerRoot(_ kind: AgentKind) -> URL { root.appendingPathComponent(kind.rawValue) }
    func executableURL(_ installation: ManagedAgentInstallation, kind: AgentKind) -> URL {
        providerRoot(kind).appendingPathComponent(installation.directory)
            .appendingPathComponent(installation.executable)
    }

    func readReceipt(for kind: AgentKind) throws -> ManagedAgentReceipt? {
        diskLock.lock()
        defer { diskLock.unlock() }
        let url = providerRoot(kind).appendingPathComponent("active.json")
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let attributes = try url.resourceValues(forKeys: [.fileSizeKey, .isSymbolicLinkKey])
        guard attributes.isSymbolicLink != true,
              (attributes.fileSize ?? Int.max) <= ManagedAgentCatalog.receiptMaximumBytes else {
            throw ManagedAgentError.invalidReceipt
        }
        let receipt = try JSONDecoder().decode(ManagedAgentReceipt.self, from: Data(contentsOf: url))
        guard receipt.schemaVersion == 1 else { throw ManagedAgentError.invalidReceipt }
        for installation in [receipt.active, receipt.previous].compactMap({ $0 }) {
            guard UUID(uuidString: installation.directory) != nil,
                  Self.isRelativePath(installation.executable),
                  !installation.version.isEmpty,
                  installation.version.utf8.count <= 100 else { throw ManagedAgentError.invalidReceipt }
            let directory = providerRoot(kind).appendingPathComponent(installation.directory)
            let executable = executableURL(installation, kind: kind)
            guard directory.resolvingSymlinksInPath() == directory.standardizedFileURL,
                  executable.resolvingSymlinksInPath().path.hasPrefix(directory.path + "/") else {
                throw ManagedAgentError.invalidReceipt
            }
        }
        return receipt
    }

    func activate(_ installation: ManagedAgentInstallation, for kind: AgentKind) throws {
        diskLock.lock()
        defer { diskLock.unlock() }
        // A verified reinstall is also the recovery path for a damaged receipt.
        let old = try? readReceipt(for: kind)
        let receipt = ManagedAgentReceipt(active: installation, previous: old?.active)
        try write(receipt, for: kind)
        selectExternal(nil, for: kind)
    }

    func rollback(_ kind: AgentKind) throws {
        diskLock.lock()
        defer { diskLock.unlock() }
        guard let old = try readReceipt(for: kind), let previous = old.previous else {
            throw ManagedAgentError.noPreviousVersion
        }
        try ManagedAgentInstaller.verifyExecutable(
            executableURL(previous, kind: kind), version: previous.version, kind: kind
        )
        try write(ManagedAgentReceipt(active: previous, previous: old.active), for: kind)
        selectExternal(nil, for: kind)
    }

    private func write(_ receipt: ManagedAgentReceipt, for kind: AgentKind) throws {
        let directory = providerRoot(kind)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let encoded = try JSONEncoder().encode(receipt)
        try encoded.write(to: directory.appendingPathComponent("active.json"), options: .atomic)
        lock.withLock {
            receipts[kind] = receipt
            failures[kind] = nil
        }
    }

    static func isRelativePath(_ path: String) -> Bool {
        !path.isEmpty && !path.hasPrefix("/") && !path.contains("\0")
            && !path.split(separator: "/", omittingEmptySubsequences: false).contains("..")
    }

    /// Only the actual command word is replaced. An opening prompt, flag value, or account
    /// directory named "claude" is data and can never select a different executable.
    func resolve(_ command: ShellCommand) -> (command: ShellCommand, environment: [String: String]) {
        guard let word = command.executableWord,
              let kind = AgentKind.allCases.first(where: { $0.executableName == word }) else {
            return (command, [:])
        }
        let selected = selection(for: kind)
        let flags = selected.managed ? Self.managedArguments(for: kind) : []
        let resolved = command.replacingExecutable(with: selected.executable, arguments: flags)
        var environment = selected.managed ? Self.managedEnvironment(for: kind) : [:]
        if selected.managed, let helper = companionDirectory(for: kind, selection: selected) {
            environment[EnvironmentKeys.path] = helper + ":" + effectivePATH
        }
        return (resolved, environment)
    }

    private func companionDirectory(for kind: AgentKind, selection: AgentRuntimeSelection) -> String? {
        switch kind {
        case .codex:
            // The official npm launcher adds this directory for the packaged ripgrep helper.
            return URL(fileURLWithPath: selection.executable).deletingLastPathComponent()
                .deletingLastPathComponent().appendingPathComponent("codex-path").path
        case .claude, .grok, .openCode, .cursor: return nil
        }
    }

    static func managedEnvironment(for kind: AgentKind) -> [String: String] {
        switch kind {
        case .claude: return ["DISABLE_AUTOUPDATER": "1", "DISABLE_UPDATES": "1"]
        case .codex: return [:] // CodexLaunchCommand already disables its startup update check.
        case .grok: return ["GROK_DISABLE_AUTOUPDATER": "1"]
        case .openCode: return ["OPENCODE_DISABLE_AUTOUPDATE": "true"]
        case .cursor: return [:] // The pinned client exposes an argv switch, not an env setting.
        }
    }

    static func managedArguments(for kind: AgentKind) -> [String] {
        switch kind {
        case .cursor: return ["--disable-auto-update"]
        case .claude, .codex, .grok, .openCode: return []
        }
    }

    func plan(command: ShellCommand, in directory: String, resumeState: ResumeState,
              environmentOverrides: [String: String] = [:],
              credentials: AgentCredentialEnvironment = .none) -> AgentLaunchPlan {
        let resolved = resolve(command)
        var environment = environmentOverrides
        environment[EnvironmentKeys.path] = effectivePATH
        environment.merge(resolved.environment) { _, managed in managed }
        return AgentLaunchPlan(
            executable: Self.stableShell,
            arguments: ["-c", ShellCommand.executing(resolved.command, in: directory).source],
            resumeState: resumeState,
            environmentOverrides: environment,
            credentialEnvironment: credentials
        )
    }
}

enum ManagedAgentError: LocalizedError, Equatable {
    case busy, invalidReceipt, invalidArchive, checksumMismatch, noPreviousVersion, retentionLimit
    case downloadFailed(Int), verificationFailed(String)

    var errorDescription: String? {
        switch self {
        case .busy: return L10n.string("Another agent installation is in progress.")
        case .invalidReceipt: return L10n.string("The saved agent installation is invalid. Reinstall this client.")
        case .invalidArchive: return L10n.string("The agent archive contains an unsupported entry.")
        case .checksumMismatch: return L10n.string("The download did not match the approved checksum.")
        case .noPreviousVersion: return L10n.string("There is no previous installation to restore.")
        case .retentionLimit:
            return L10n.string("Eight installations are retained. Quit agents using older versions, then use Show Installation Folder to remove unused versions before installing again.")
        case .downloadFailed(let status): return L10n.format("The agent download failed (HTTP %@).", String(status))
        case .verificationFailed(let detail): return L10n.format("The agent could not be verified: %@", detail)
        }
    }
}
