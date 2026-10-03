import ThreadingMarkdownKit
import Foundation

/// Rare theme changes enqueue one tiny atomic write. No source or user history leaves the app.
@MainActor
final class MarkdownQuickLookThemePublisher {
    private let observations = AppEventObservations()
    private var publication: Task<Void, Never>?

    func start() {
        guard ProcessInfo.processInfo.environment["THREADING_UI_SCENARIO_HOME"] == nil else { return }
        observations.observe(AppThemeDidChange.self) { [weak self] _ in self?.publish(coalescing: true) }
        publish(coalescing: false)
    }

    private func publish(coalescing: Bool) {
        let snapshot = MarkdownQuickLookTheme.snapshot()
        publication?.cancel()
        publication = Task {
            do {
                if coalescing { try await Task.sleep(for: .milliseconds(180)) }
                guard !Task.isCancelled else { return }
                try await MarkdownPreviewWorker.shared.publish(snapshot)
            } catch is CancellationError {
            } catch {
                ThreadingLogger.theme.warning("Quick Look theme snapshot could not be saved")
            }
        }
    }
}
