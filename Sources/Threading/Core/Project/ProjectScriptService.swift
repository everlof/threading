import Foundation

struct ProjectScriptsDidChange: AppEvent {
    static let name = Notification.Name("projectScriptsDidChange")
}

/// Keeps the command registry aligned with the checkout currently represented by the window.
///
/// It watches only the repository root containing `.threading.json`. A write reloads bounded
/// metadata and never invokes a script. Switching from a logical project to a managed session
/// changes the root to that session's execution worktree before any commands are resolved.
@MainActor
final class ProjectScriptService {
    static let shared = ProjectScriptService()

    private let registry: CommandRegistry
    private var watcher: ProjectScriptConfigurationWatcher?
    private var requestedExecutionDirectory: URL?
    private var activeExecutionDirectory: URL?
    private(set) var activeCatalog: ProjectScriptCatalog?

    init(registry: CommandRegistry = .shared) {
        self.registry = registry
    }

    func activate(executionDirectory: URL?) {
        guard let executionDirectory else {
            guard activeCatalog != nil || watcher != nil else { return }
            watcher?.stop()
            watcher = nil
            requestedExecutionDirectory = nil
            activeExecutionDirectory = nil
            activeCatalog = nil
            registry.replaceProjectScripts([])
            NotificationCenter.default.post(ProjectScriptsDidChange())
            return
        }

        // Store notifications are intentionally broader than script identity. Most calls name
        // the same literal path, so reject them before the filesystem-backed symlink resolution.
        let requested = executionDirectory.standardizedFileURL
        guard requested != requestedExecutionDirectory else { return }
        let standardized = requested.resolvingSymlinksInPath()
        if standardized == activeExecutionDirectory {
            requestedExecutionDirectory = requested
            return
        }
        let root = GitInfo.worktreeLocation(for: standardized.path)?.root
            ?? standardized
        if activeCatalog?.repositoryRoot == root {
            requestedExecutionDirectory = requested
            activeExecutionDirectory = standardized
            return
        }

        watcher?.stop()
        requestedExecutionDirectory = requested
        activeExecutionDirectory = standardized
        watcher = ProjectScriptConfigurationWatcher(repositoryRoot: root) { [weak self] in
            self?.reload()
        }
        watcher?.start()
        activeCatalog = ProjectScriptConfigurationLoader.load(repositoryRoot: root)
        registry.replaceProjectScripts(activeCatalog?.scripts ?? [])
        NotificationCenter.default.post(ProjectScriptsDidChange())
    }

    /// Re-reads the active file without changing roots. Exposed for tests and for a caller that
    /// knows a checkout identity changed in place; normal file edits arrive through FSEvents.
    func reload() {
        guard let root = activeCatalog?.repositoryRoot else { return }
        let catalog = ProjectScriptConfigurationLoader.load(repositoryRoot: root)
        guard catalog != activeCatalog else { return }
        activeCatalog = catalog
        registry.replaceProjectScripts(catalog.scripts)
        NotificationCenter.default.post(ProjectScriptsDidChange())
    }

    func availability(commandID: String) -> ProjectScriptAvailability {
        guard let command = registry.command(id: commandID),
              case .projectScript(let scriptID) = command.origin,
              let catalog = activeCatalog,
              let script = catalog.scripts.first(where: { $0.id == scriptID }) else {
            return .unavailable(L10n.string(
                "This script is no longer available in the active checkout."
            ))
        }
        return ProjectScriptConfigurationLoader.resolve(
            script,
            repositoryRoot: catalog.repositoryRoot
        )
    }
}

/// Path-based rather than inode-based: editors replace JSON files atomically, so the watch must
/// survive the old inode disappearing. Filtering happens before the main-queue hop, and changes
/// are coalesced so a save produces one bounded parse.
final class ProjectScriptConfigurationWatcher: Sendable {
    private enum Defaults {
        static let latency: CFTimeInterval = 0.2
        static let coalesce: TimeInterval = 0.35
    }

    private let events: FileSystemEventStream

    init(
        repositoryRoot: URL,
        backend: (any FileSystemEventStreamBackend)? = nil,
        onChange: @escaping @MainActor @Sendable () -> Void
    ) {
        let root = repositoryRoot.standardizedFileURL.path
        let configurationPath = repositoryRoot
            .appendingPathComponent(ProjectScriptDefaults.configurationFileName)
            .standardizedFileURL.path
        events = FileSystemEventStream(
            paths: [root],
            latency: Defaults.latency,
            coalesce: Defaults.coalesce,
            isRelevant: { paths, flags in
                paths.indices.contains { index in
                    Self.isRelevant(
                        path: paths[index],
                        flags: index < flags.count ? flags[index] : 0,
                        configurationPath: configurationPath
                    )
                }
            },
            onChange: onChange,
            backend: backend
        )
    }

    func start() { events.start() }
    func stop() { events.stop() }

    static func isRelevant(
        path: String,
        flags: FSEventStreamEventFlags,
        configurationPath: String
    ) -> Bool {
        let unreliable = FSEventStreamEventFlags(
            kFSEventStreamEventFlagMustScanSubDirs | kFSEventStreamEventFlagRootChanged
        )
        return flags & unreliable != 0
            || URL(fileURLWithPath: path).standardizedFileURL.path == configurationPath
    }
}
