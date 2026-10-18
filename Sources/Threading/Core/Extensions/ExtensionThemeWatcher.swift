import Foundation

/// Watches one enabled theme-contributing package and reports edits after a short quiet period.
/// A path-based FSEvents stream survives atomic file replacement. The shared stream registers
/// off the main actor and reports once after registration, so edits during startup are re-read.
/// Every package event is relevant: ExtensionManager re-inspects the small theme data set and
/// compares the resulting contribution. Validation remains ExtensionManager's responsibility.
final class ExtensionThemeWatcher: Sendable {
    private let stream: FileSystemEventStream

    init(
        root: URL,
        backend: (any FileSystemEventStreamBackend)? = nil,
        onChange: @escaping @MainActor @Sendable () -> Void
    ) {
        stream = FileSystemEventStream(
            paths: [root.path],
            latency: ExtensionThemeWatchDefaults.latency,
            coalesce: ExtensionThemeWatchDefaults.coalesce,
            isRelevant: { _, _ in true },
            onChange: onChange,
            backend: backend
        )
    }

    func start() { stream.start() }

    func stop() { stream.stop() }
}

enum ExtensionThemeWatchDefaults {
    static let latency: CFTimeInterval = 0.2
    static let coalesce: TimeInterval = 0.35
}
