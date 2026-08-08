import Foundation
import ThreadingExtensionKit

/// The app data visible at the extension boundary.
///
/// Keeping this behind a provider makes the host transport independent of ProjectStore and
/// AgentRuntime. It is also the test seam for proving that paths and credentials never cross
/// the boundary.
@MainActor
protocol ExtensionHostSnapshotProviding: AnyObject {
    func projectSnapshots() -> [ExtensionProjectSnapshot]
    func sessionSnapshots() -> [ExtensionSessionSnapshot]
    func providerSnapshots() -> [ExtensionProviderSnapshot]
    func accountSnapshots() -> [ExtensionAccountSnapshot]
}

/// Produces one host-filtered runtime reading for an exact Threading session.
///
/// The provider owns process discovery. The broker never accepts a PID from the extension, so
/// this cannot be widened into arbitrary process-table access.
@MainActor
protocol ExtensionSessionRuntimeSnapshotProviding: AnyObject {
    func sessionRuntimeSnapshot(
        for sessionID: String,
        completion: @escaping @MainActor (ExtensionSessionRuntimeSnapshot) -> Void
    )
}

extension ExtensionHostSnapshotProviding {
    func providerSnapshots() -> [ExtensionProviderSnapshot] { [] }
    func accountSnapshots() -> [ExtensionAccountSnapshot] { [] }
}

@MainActor
final class LiveExtensionHostSnapshotProvider:
    ExtensionHostSnapshotProviding,
    ExtensionSessionRuntimeSnapshotProviding
{
    /// The shell drawer belongs to the main window rather than AgentRuntime. The composition
    /// root supplies this resolver without exposing the window or controller to the broker.
    var shellRootProvider: ((SessionID) -> pid_t?)?

    private var runtimeReaders: [SessionID: SessionInfoReader] = [:]

    func projectSnapshots() -> [ExtensionProjectSnapshot] {
        ProjectStore.shared.projects.map { project in
            ExtensionProjectSnapshot(
                id: project.id.uuidString.lowercased(),
                displayName: project.name,
                repository: repositorySnapshot(for: project.folderPath)
            )
        }
    }

    func sessionSnapshots() -> [ExtensionSessionSnapshot] {
        let snapshots = ProjectStore.shared.projects.flatMap { project in
            project.sessions.map { session in
                ExtensionSessionSnapshot(
                    id: session.id.uuidString.lowercased(),
                    projectID: project.id.uuidString.lowercased(),
                    providerID: session.kind.rawValue,
                    accountID: "\(session.kind.rawValue):\(session.accountHandle.name)",
                    displayTitle: session.displayTitle,
                    activity: extensionActivity(
                        AgentRuntime.shared.activity(sessionID: session.id)
                    ),
                    branch: session.branch,
                    isSideChat: session.isSideChat,
                    isArchived: session.isArchived,
                    usesNativeUI: session.usesNativeUI
                )
            }
        }
        let liveIDs = Set(snapshots.compactMap { SessionID(uuidString: $0.id) })
        runtimeReaders = runtimeReaders.filter { liveIDs.contains($0.key) }
        return snapshots
    }

    func providerSnapshots() -> [ExtensionProviderSnapshot] {
        AgentKind.allCases.map { provider in
            ExtensionProviderSnapshot(
                id: provider.rawValue,
                displayName: provider.displayName,
                image: .hostAsset(ExtensionIdentityAssetID.provider(provider.rawValue))
            )
        }
    }

    func accountSnapshots() -> [ExtensionAccountSnapshot] {
        AgentKind.allCases.flatMap { provider in
            AgentAccountDiscovery.accounts(for: provider).map { account in
                ExtensionAccountSnapshot(
                    id: account.id.rawValue,
                    providerID: provider.rawValue,
                    displayName: account.displayName,
                    isDefault: account.isDefault,
                    hasUserSelectedImage: account.emoji != nil,
                    image: AccountBadge.chip(for: account).map { _ in
                        .hostAsset(ExtensionIdentityAssetID.account(account.id.rawValue))
                    }
                )
            }
        }
    }

    func sessionRuntimeSnapshot(
        for rawSessionID: String,
        completion: @escaping @MainActor (ExtensionSessionRuntimeSnapshot) -> Void
    ) {
        guard let sessionID = SessionID(uuidString: rawSessionID) else {
            completion(.init(sessionID: rawSessionID, processGroups: [], portGroups: []))
            return
        }

        let agentRoot: pid_t?
        if let terminal = AgentRuntime.shared.controller(for: sessionID)?.session.shellPid,
           terminal > 0 {
            agentRoot = terminal
        } else {
            agentRoot = AgentRuntime.shared.conversation(for: sessionID)?
                .stream.rootProcessIdentifier
        }
        let shellRoot = shellRootProvider?(sessionID)
        let reader = runtimeReaders[sessionID] ?? {
            let reader = SessionInfoReader()
            runtimeReaders[sessionID] = reader
            return reader
        }()

        reader.read(agentRoot: agentRoot, shellRoot: shellRoot) { snapshot in
            completion(Self.extensionRuntimeSnapshot(
                sessionID: rawSessionID,
                snapshot: snapshot
            ))
        }
    }

    private func repositorySnapshot(for path: String) -> ExtensionRepositorySnapshot? {
        guard GitInfo.repositoryRoot(for: path) != nil else { return nil }
        let remote = GitInfo.remoteOriginURL(for: path)
            .flatMap(ExtensionRepositoryIdentity.init(remote:))
        return ExtensionRepositorySnapshot(
            remoteHost: remote?.host,
            repositoryPath: remote?.path,
            branch: GitInfo.currentBranch(for: path),
            headRevision: GitInfo.headRevision(for: path)
        )
    }

    private func extensionActivity(_ activity: SessionActivity) -> ExtensionSessionActivity {
        switch activity {
        case .dormant: return .dormant
        case .idle: return .idle
        case .working: return .working
        // One state to extensions, deliberately. `ExtensionSessionActivity` is a published
        // vocabulary an installed extension already switches on, and splitting it would hand
        // every one of them a value it has no branch for. All three mean "this session is not
        // going to move on its own" — a limited session included, since an extension cannot
        // lift a rate limit any more than it can answer a question.
        case .awaitingUser, .needsAttention, .limitReached: return .needsAttention
        }
    }

    static func extensionRuntimeSnapshot(
        sessionID: String,
        snapshot: SessionInfoSnapshot
    ) -> ExtensionSessionRuntimeSnapshot {
        var processBudget = ExtensionSessionRuntimeLimits.maximumProcesses
        let processGroups = snapshot.processGroups.compactMap {
            group -> ExtensionSessionRuntimeProcessGroup? in
            guard processBudget > 0 else { return nil }
            let processes = Array(group.processes.prefix(processBudget)).map { process in
                ExtensionSessionRuntimeProcess(
                    processIdentifier: process.pid,
                    command: bounded(
                        process.command,
                        count: ExtensionSessionRuntimeLimits.maximumCommandLength
                    ),
                    memoryBytes: process.memoryBytes,
                    cpuPercent: process.cpuPercent
                )
            }
            processBudget -= processes.count
            guard !processes.isEmpty else { return nil }
            return ExtensionSessionRuntimeProcessGroup(
                origin: extensionOrigin(group.origin),
                processes: processes
            )
        }

        var portBudget = ExtensionSessionRuntimeLimits.maximumPorts
        let portGroups = snapshot.portGroups.compactMap {
            group -> ExtensionSessionRuntimePortGroup? in
            guard portBudget > 0 else { return nil }
            let ports = Array(group.ports.prefix(portBudget)).map { port in
                ExtensionSessionRuntimePort(
                    port: port.port,
                    processIdentifier: port.pid,
                    command: bounded(
                        port.command,
                        count: ExtensionSessionRuntimeLimits.maximumCommandLength
                    ),
                    address: bounded(
                        port.address,
                        count: ExtensionSessionRuntimeLimits.maximumAddressLength
                    ),
                    isIPv6: port.isIPv6,
                    interface: extensionInterface(port.interface),
                    isReachableViaLocalhost: port.interface.isReachableViaLocalhost
                )
            }
            portBudget -= ports.count
            guard !ports.isEmpty else { return nil }
            return ExtensionSessionRuntimePortGroup(
                origin: extensionOrigin(group.origin),
                ports: ports
            )
        }

        return ExtensionSessionRuntimeSnapshot(
            sessionID: sessionID,
            processGroups: processGroups,
            portGroups: portGroups
        )
    }

    private static func bounded(_ value: String, count: Int) -> String {
        String(value.prefix(count))
    }

    private static func extensionOrigin(
        _ origin: SessionInfoOrigin
    ) -> ExtensionSessionRuntimeOrigin {
        switch origin {
        case .agent: return .agent
        case .shell: return .shell
        }
    }

    private static func extensionInterface(
        _ interface: PortInterface
    ) -> ExtensionSessionRuntimePortInterface {
        switch interface {
        case .allInterfaces: return .allInterfaces
        case .localhost: return .localhost
        case .address: return .specificAddress
        }
    }
}

enum ExtensionIdentityAssetID {
    private static let providerPrefix = "identity.provider."
    private static let accountPrefix = "identity.account."

    static func provider(_ providerID: String) -> String {
        providerPrefix + providerID
    }

    static func account(_ accountID: String) -> String {
        accountPrefix + accountID
    }

    static func providerID(from assetID: String) -> String? {
        guard assetID.hasPrefix(providerPrefix) else { return nil }
        return String(assetID.dropFirst(providerPrefix.count))
    }

    static func accountID(from assetID: String) -> String? {
        guard assetID.hasPrefix(accountPrefix) else { return nil }
        return String(assetID.dropFirst(accountPrefix.count))
    }
}

/// Credential-free identity extracted from common git remote spellings.
struct ExtensionRepositoryIdentity: Equatable {
    let host: String
    let path: String

    init(host: String, path: String) {
        self.host = host
        self.path = path
    }

    init?(remote: String) {
        let trimmed = remote.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.hasPrefix("/"), !trimmed.hasPrefix(".") else {
            return nil
        }

        if let url = URL(string: trimmed),
           let scheme = url.scheme?.lowercased(),
           ["http", "https", "ssh", "git"].contains(scheme),
           let host = url.host, !host.isEmpty {
            guard let path = Self.cleanPath(url.path) else { return nil }
            self.host = host.lowercased()
            self.path = path
            return
        }

        // SCP-style syntax: git@github.com:owner/repository.git
        guard let colon = trimmed.firstIndex(of: ":") else { return nil }
        let authority = trimmed[..<colon]
        let rawPath = trimmed[trimmed.index(after: colon)...]
        let host = authority.split(separator: "@").last.map(String.init) ?? ""
        guard !host.isEmpty, !host.contains("/"),
              let path = Self.cleanPath(String(rawPath)) else { return nil }
        self.host = host.lowercased()
        self.path = path
    }

    private static func cleanPath(_ rawPath: String) -> String? {
        var path = rawPath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if path.hasSuffix(".git") {
            path.removeLast(4)
        }
        guard !path.isEmpty,
              !path.split(separator: "/").contains(".."),
              !path.contains("?"),
              !path.contains("#") else { return nil }
        return path
    }
}
