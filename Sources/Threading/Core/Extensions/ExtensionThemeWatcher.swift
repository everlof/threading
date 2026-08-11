import Foundation

/// Watches one enabled, theme-contributing package for writes to the data its themes are made
/// of, and reports them coalesced on the main queue.
///
/// This is what turns a contributed theme from a snapshot into a *living document*: an
/// extension that rewrites its own theme JSON — a chrome following the weather, the time of
/// day, a build's state — or an author iterating on a style with the app open, is noticed
/// here and re-inspected by `ExtensionManager.refreshContributedThemes` through exactly the
/// gates install ran. The watcher itself decides nothing about validity; it only says "the
/// package's theme data moved".
///
/// FSEvents rather than per-file dispatch sources, for the reason `GitCheckoutWatcher` chose
/// it: editors and extensions replace files rather than rewriting them in place, and a vnode
/// watch dies with the inode it was opened on while a path-based stream keeps reporting. The
/// whole package root is watched and events are *not* filtered by name — a package is small,
/// re-inspection is a few disk reads, and the refresh already compares results and drops a
/// no-op — so a filter would only be a list of paths to forget to update. The debounce is the
/// same trailing-edge idea as the git watcher's: a JSON writer is mid-write on the first
/// event, and the interesting moment is the quiet after it.
final class ExtensionThemeWatcher: @unchecked Sendable {

    // MARK: - Properties

    private let root: String
    private let onChange: @MainActor @Sendable () -> Void

    private var stream: FSEventStreamRef?
    private var coalesceItem: DispatchWorkItem?

    private let queue = DispatchQueue(label: "codes.threading.extension-theme-watch", qos: .utility)

    // MARK: - Initialization

    init(root: URL, onChange: @escaping @MainActor @Sendable () -> Void) {
        self.root = root.path
        self.onChange = onChange
    }

    deinit {
        stop()
    }

    // MARK: - Public Methods

    /// Begins watching. Idempotent, so a reconcile pass that keeps a package does not open a
    /// second stream for it.
    func start() {
        guard stream == nil else { return }

        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: { pointer in
                guard let pointer else { return nil }
                return UnsafeRawPointer(
                    Unmanaged<ExtensionThemeWatcher>.fromOpaque(pointer).retain().toOpaque()
                )
            },
            release: { pointer in
                guard let pointer else { return }
                Unmanaged<ExtensionThemeWatcher>.fromOpaque(pointer).release()
            },
            copyDescription: nil
        )

        let callback: FSEventStreamCallback = { _, info, _, _, _, _ in
            guard let info else { return }
            Unmanaged<ExtensionThemeWatcher>.fromOpaque(info)
                .takeUnretainedValue()
                .scheduleFromWatchQueue()
        }

        guard let stream = FSEventStreamCreate(
            kCFAllocatorDefault,
            callback,
            &context,
            [root] as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            ExtensionThemeWatchDefaults.latency,
            UInt32(kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagNoDefer)
        ) else {
            ThreadingLogger.extensions.error(
                "Theme watch stream could not be created for \(self.root, privacy: .private(mask: .hash))"
            )
            return
        }

        FSEventStreamSetDispatchQueue(stream, queue)
        FSEventStreamStart(stream)
        self.stream = stream
    }

    /// Stops watching and drops any coalesced notification still pending.
    func stop() {
        coalesceItem?.cancel()
        coalesceItem = nil

        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
    }

    // MARK: - Private Methods

    private func scheduleFromWatchQueue() {
        DispatchQueue.main.async { [weak self] in
            self?.scheduleNotification()
        }
    }

    /// The trailing edge of a burst — one refresh after the writer goes quiet, not one per
    /// write it made getting there.
    private func scheduleNotification() {
        coalesceItem?.cancel()

        let item = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.coalesceItem = nil
            MainActor.assumeIsolated { self.onChange() }
        }
        coalesceItem = item
        DispatchQueue.main.asyncAfter(
            deadline: .now() + ExtensionThemeWatchDefaults.coalesce,
            execute: item
        )
    }
}

// MARK: - Defaults

enum ExtensionThemeWatchDefaults {
    /// FSEvents' own batching window.
    static let latency: CFTimeInterval = 0.2
    /// The quiet a writer must hold before a re-inspection runs — long enough that a JSON
    /// document and the assets beside it land as one refresh, short enough that iterating on
    /// a theme with the app open still feels live.
    static let coalesce: TimeInterval = 0.35
}
