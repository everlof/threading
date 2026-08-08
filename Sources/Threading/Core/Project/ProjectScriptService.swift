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
            activeExecutionDirectory = nil
            activeCatalog = nil
            registry.replaceProjectScripts([])
            NotificationCenter.default.post(ProjectScriptsDidChange())
            return
        }

        let standardized = executionDirectory.standardizedFileURL.resolvingSymlinksInPath()
        guard standardized != activeExecutionDirectory else { return }
        let root = GitInfo.worktreeLocation(for: standardized.path)?.root
            ?? standardized
        if activeCatalog?.repositoryRoot == root {
            activeExecutionDirectory = standardized
            return
        }

        watcher?.stop()
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
final class ProjectScriptConfigurationWatcher: @unchecked Sendable {
    private let root: String
    private let configurationPath: String
    private let onChange: @MainActor @Sendable () -> Void
    private let queue = DispatchQueue(label: "codes.threading.project-script-watch", qos: .utility)

    private var stream: FSEventStreamRef?
    private var coalesceItem: DispatchWorkItem?

    init(repositoryRoot: URL, onChange: @escaping @MainActor @Sendable () -> Void) {
        root = repositoryRoot.standardizedFileURL.path
        configurationPath = repositoryRoot
            .appendingPathComponent(ProjectScriptDefaults.configurationFileName)
            .standardizedFileURL.path
        self.onChange = onChange
    }

    deinit { stop() }

    func start() {
        guard stream == nil else { return }

        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: { pointer in
                guard let pointer else { return nil }
                return UnsafeRawPointer(
                    Unmanaged<ProjectScriptConfigurationWatcher>
                        .fromOpaque(pointer).retain().toOpaque()
                )
            },
            release: { pointer in
                guard let pointer else { return }
                Unmanaged<ProjectScriptConfigurationWatcher>.fromOpaque(pointer).release()
            },
            copyDescription: nil
        )

        let callback: FSEventStreamCallback = { _, info, count, rawPaths, rawFlags, _ in
            guard let info else { return }
            let watcher = Unmanaged<ProjectScriptConfigurationWatcher>
                .fromOpaque(info).takeUnretainedValue()
            let paths = unsafeBitCast(rawPaths, to: NSArray.self) as? [String] ?? []
            let flags = (0..<count).map { rawFlags[$0] }
            watcher.handle(paths: paths, flags: flags)
        }

        let flags = UInt32(
            kFSEventStreamCreateFlagUseCFTypes
                | kFSEventStreamCreateFlagFileEvents
                | kFSEventStreamCreateFlagNoDefer
        )
        guard let stream = FSEventStreamCreate(
            kCFAllocatorDefault,
            callback,
            &context,
            [root] as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            0.2,
            flags
        ) else { return }

        FSEventStreamSetDispatchQueue(stream, queue)
        FSEventStreamStart(stream)
        self.stream = stream
    }

    func stop() {
        coalesceItem?.cancel()
        coalesceItem = nil
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
    }

    private func handle(paths: [String], flags: [FSEventStreamEventFlags]) {
        guard paths.indices.contains(where: { index in
            Self.isRelevant(
                path: paths[index],
                flags: index < flags.count ? flags[index] : 0,
                configurationPath: configurationPath
            )
        }) else { return }

        DispatchQueue.main.async { [weak self] in self?.scheduleNotification() }
    }

    private func scheduleNotification() {
        coalesceItem?.cancel()
        let item = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.coalesceItem = nil
            MainActor.assumeIsolated { self.onChange() }
        }
        coalesceItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: item)
    }

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
