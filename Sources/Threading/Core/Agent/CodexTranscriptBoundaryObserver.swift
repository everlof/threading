import Foundation

/// Watches one live Codex rollout for lifecycle records that may arrive after the terminal's
/// final repaint.
///
/// The rollout is append-only while Codex owns it, so the file-system write is the authoritative
/// wake-up. Terminal output remains a useful low-latency hint, but it cannot be the only trigger:
/// `task_complete` is commonly appended after the last bytes the PTY will ever produce.
///
/// One observer belongs to one running Codex terminal process. FSEvents performs no periodic
/// work, reports only changes below the rollout's parent directory, and the exact-path filter
/// drops sibling session traffic on its utility queue before crossing to the main actor.
final class CodexTranscriptBoundaryObserver: @unchecked Sendable {

    // MARK: - Properties

    private let transcriptPath: String
    private let watchedDirectory: String
    private let onChange: @MainActor @Sendable () -> Void

    private var stream: FSEventStreamRef?
    private let queue = DispatchQueue(
        label: "codes.threading.codex-rollout-watch",
        qos: .utility
    )

    // MARK: - Initialization

    init(
        url: URL,
        onChange: @escaping @MainActor @Sendable () -> Void
    ) {
        transcriptPath = url.standardizedFileURL.path
        watchedDirectory = url.deletingLastPathComponent().standardizedFileURL.path
        self.onChange = onChange
    }

    deinit {
        stop()
    }

    // MARK: - Public Methods

    /// Begins watching and schedules one initial read after the stream is armed.
    ///
    /// The initial read closes the registration race: a boundary appended after the caller
    /// resolved the URL but before FSEvents began delivering is already present when it runs.
    @discardableResult
    func start() -> Bool {
        guard stream == nil else { return true }

        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: { pointer in
                guard let pointer else { return nil }
                return UnsafeRawPointer(
                    Unmanaged<CodexTranscriptBoundaryObserver>
                        .fromOpaque(pointer)
                        .retain()
                        .toOpaque()
                )
            },
            release: { pointer in
                guard let pointer else { return }
                Unmanaged<CodexTranscriptBoundaryObserver>.fromOpaque(pointer).release()
            },
            copyDescription: nil
        )

        let callback: FSEventStreamCallback = { _, info, count, rawPaths, rawFlags, _ in
            guard let info else { return }
            let observer = Unmanaged<CodexTranscriptBoundaryObserver>
                .fromOpaque(info)
                .takeUnretainedValue()
            let paths = unsafeBitCast(rawPaths, to: NSArray.self) as? [String] ?? []
            let flags = (0..<count).map { rawFlags[$0] }
            observer.handle(paths: paths, flags: flags)
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
            [watchedDirectory] as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            CodexTurnBoundaryDefaults.observationLatency,
            flags
        ) else {
            return false
        }

        FSEventStreamSetDispatchQueue(stream, queue)
        guard FSEventStreamStart(stream) else {
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
            return false
        }
        self.stream = stream

        Task { @MainActor [weak self] in
            self?.onChange()
        }
        return true
    }

    /// Stops synchronously so a discarded terminal cannot publish a late boundary.
    func stop() {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
    }

    // MARK: - Event Filtering

    /// Runs on the observer's utility queue and crosses actors only for a relevant batch.
    private func handle(paths: [String], flags: [FSEventStreamEventFlags]) {
        let relevant = paths.indices.contains { index in
            Self.isRelevant(
                path: paths[index],
                flags: index < flags.count ? flags[index] : 0,
                transcriptPath: transcriptPath,
                watchedDirectory: watchedDirectory
            )
        }
        guard relevant else { return }

        Task { @MainActor [weak self] in
            self?.onChange()
        }
    }

    /// Kept internal for focused tests: sibling rollouts can be busy, while only this exact file
    /// is allowed to spend a transcript read. A dropped-event/root-change report is broader and
    /// therefore conservatively refreshes when it names the watched directory.
    static func isRelevant(
        path: String,
        flags: FSEventStreamEventFlags,
        transcriptPath: String,
        watchedDirectory: String
    ) -> Bool {
        let path = URL(fileURLWithPath: path).standardizedFileURL.path
        let transcriptPath = URL(fileURLWithPath: transcriptPath).standardizedFileURL.path
        let watchedDirectory = URL(fileURLWithPath: watchedDirectory).standardizedFileURL.path

        let unreliable = FSEventStreamEventFlags(
            kFSEventStreamEventFlagMustScanSubDirs
                | kFSEventStreamEventFlagUserDropped
                | kFSEventStreamEventFlagKernelDropped
                | kFSEventStreamEventFlagEventIdsWrapped
                | kFSEventStreamEventFlagRootChanged
        )
        if flags & unreliable != 0 {
            return path == watchedDirectory || path == transcriptPath
        }

        guard path == transcriptPath else { return false }
        let changes = FSEventStreamEventFlags(
            kFSEventStreamEventFlagItemCreated
                | kFSEventStreamEventFlagItemRemoved
                | kFSEventStreamEventFlagItemRenamed
                | kFSEventStreamEventFlagItemModified
        )
        return flags == 0 || flags & changes != 0
    }
}
