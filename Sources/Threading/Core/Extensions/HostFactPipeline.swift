import Foundation

/// Owns the live navigator fact registry and starts its publisher after the first visible window.
///
/// Constructing the pipeline is intentionally cheap. The initial model projection crosses one
/// main-queue turn so neither the first frame nor the startup-profile path pays for an
/// extension-only snapshot.
@MainActor
final class HostFactPipeline {
    typealias Scheduler = (@escaping @MainActor @Sendable () -> Void) -> Void

    private enum StartState {
        case idle
        case scheduled
        case waitingForModelChange
        case started
    }

    let registry: ExtensionFactRegistry

    private let publisher: HostFactPublisher
    private let schedule: Scheduler
    private let retryObservations: AppEventObservations
    private var startState: StartState = .idle
    private var isObservingRetry = false

    init(
        registry: ExtensionFactRegistry = ExtensionFactRegistry(),
        publisherDependencies: HostFactPublisher.Dependencies,
        schedule: @escaping Scheduler = { operation in
            DispatchQueue.main.async { operation() }
        }
    ) {
        self.registry = registry
        publisher = HostFactPublisher(
            registry: registry,
            dependencies: publisherDependencies
        )
        self.schedule = schedule
        retryObservations = AppEventObservations(
            center: publisherDependencies.notificationCenter
        )
    }

    func startAfterFirstWindowVisible() {
        scheduleStartIfIdle()
    }

    private func scheduleStartIfIdle() {
        guard startState == .idle else { return }
        startState = .scheduled
        schedule { [weak self] in
            guard let self else { return }
            do {
                try publisher.start()
                startState = .started
                retryObservations.removeAll()
                isObservingRetry = false
            } catch {
                startState = .waitingForModelChange
                observeModelRepairIfNeeded()
                ThreadingLogger.extensions.error(
                    "Could not start host navigator facts: \(error.localizedDescription, privacy: .private(mask: .hash))"
                )
            }
        }
    }

    private func observeModelRepairIfNeeded() {
        guard !isObservingRetry else { return }
        isObservingRetry = true
        retryObservations.observe(ProjectsDidChange.self) { [weak self] _ in
            guard let self, startState == .waitingForModelChange else { return }
            retryObservations.removeAll()
            isObservingRetry = false
            startState = .idle
            scheduleStartIfIdle()
        }
    }
}
