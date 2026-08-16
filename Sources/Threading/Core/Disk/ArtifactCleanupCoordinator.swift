import Foundation

enum ArtifactPersistenceRecovery: Equatable, Sendable {
    case notNeeded
    case restored
    case stillBlocked
}

struct ArtifactCleanupProgress: Equatable, Sendable {
    enum Phase: Equatable, Sendable {
        case removing
        case completed
    }

    let phase: Phase
    let totalCount: Int
    let completedCount: Int
    let removedCount: Int
    let refusedCount: Int
    let failedCount: Int
    let reclaimedBytes: Int64
    let currentName: String?
    let persistenceRecovery: ArtifactPersistenceRecovery

    var fraction: Double {
        guard totalCount > 0 else { return 1 }
        return min(1, max(0, Double(completedCount) / Double(totalCount)))
    }
}

struct ArtifactCleanupOutcome: Equatable, Sendable {
    let requestedCount: Int
    let removed: [ReclaimableArtifact]
    let refusedCount: Int
    let failedCount: Int
    let persistenceRecovery: ArtifactPersistenceRecovery

    var reclaimedBytes: Int64 { removed.reduce(0) { $0 + $1.byteCount } }
}

/// Serialises every approved build-artifact removal in the process.
///
/// Both the agent proposal and Storage settings used to start independent directory walks. They
/// could delete the same path concurrently, report contradictory totals, and offer no progress
/// while a many-gigabyte tree was being traversed. This coordinator owns one operation, removes
/// one vetted artifact at a time off the main actor, and publishes the same bounded progress to
/// every surface.
@MainActor
final class ArtifactCleanupCoordinator {

    static let shared = ArtifactCleanupCoordinator()

    private let removeArtifact: @Sendable (ReclaimableArtifact) -> ArtifactRemovalOutcome
    private let recoverPersistence: @MainActor () -> ArtifactPersistenceRecovery
    private let notificationCenter: NotificationCenter
    private var operation: Task<Void, Never>?

    var isRunning: Bool { operation != nil }

    init(
        removeArtifact: @escaping @Sendable (ReclaimableArtifact) -> ArtifactRemovalOutcome = {
            ArtifactScanner.removeWithOutcome($0)
        },
        recoverPersistence: @escaping @MainActor () -> ArtifactPersistenceRecovery = {
            guard ProjectStore.shared.persistenceBlockReason == .storageExhausted else {
                return .notNeeded
            }
            return ProjectStore.shared.recoverFromStorageExhaustion()
                ? .restored
                : .stillBlocked
        },
        notificationCenter: NotificationCenter = .default
    ) {
        self.removeArtifact = removeArtifact
        self.recoverPersistence = recoverPersistence
        self.notificationCenter = notificationCenter
    }

    /// Starts one removal pass. False means another approved cleanup already owns the lane.
    @discardableResult
    func remove(
        _ artifacts: [ReclaimableArtifact],
        completion: @escaping @MainActor (ArtifactCleanupOutcome) -> Void
    ) -> Bool {
        guard operation == nil else { return false }

        var seen: Set<String> = []
        let unique = artifacts.filter {
            seen.insert($0.url.standardizedFileURL.path).inserted
        }
        guard !unique.isEmpty else {
            completion(ArtifactCleanupOutcome(
                requestedCount: 0,
                removed: [],
                refusedCount: 0,
                failedCount: 0,
                persistenceRecovery: .notNeeded
            ))
            return true
        }

        publish(ArtifactCleanupProgress(
            phase: .removing,
            totalCount: unique.count,
            completedCount: 0,
            removedCount: 0,
            refusedCount: 0,
            failedCount: 0,
            reclaimedBytes: 0,
            currentName: unique.first?.url.lastPathComponent,
            persistenceRecovery: .notNeeded
        ))

        operation = Task { [weak self] in
            guard let self else { return }

            var removed: [ReclaimableArtifact] = []
            var refused = 0
            var failed = 0
            var reclaimedBytes: Int64 = 0

            for (index, artifact) in unique.enumerated() {
                let removeArtifact = self.removeArtifact
                let result = await Task.detached(priority: .userInitiated) {
                    removeArtifact(artifact)
                }.value

                switch result {
                case .removed:
                    removed.append(artifact)
                    reclaimedBytes += artifact.byteCount
                case .refused: refused += 1
                case .failed: failed += 1
                }

                self.publish(ArtifactCleanupProgress(
                    phase: .removing,
                    totalCount: unique.count,
                    completedCount: index + 1,
                    removedCount: removed.count,
                    refusedCount: refused,
                    failedCount: failed,
                    reclaimedBytes: reclaimedBytes,
                    currentName: unique.indices.contains(index + 1)
                        ? unique[index + 1].url.lastPathComponent
                        : nil,
                    persistenceRecovery: .notNeeded
                ))
            }

            let recovery = self.recoverPersistence()
            let outcome = ArtifactCleanupOutcome(
                requestedCount: unique.count,
                removed: removed,
                refusedCount: refused,
                failedCount: failed,
                persistenceRecovery: recovery
            )
            self.publish(ArtifactCleanupProgress(
                phase: .completed,
                totalCount: unique.count,
                completedCount: unique.count,
                removedCount: removed.count,
                refusedCount: refused,
                failedCount: failed,
                reclaimedBytes: outcome.reclaimedBytes,
                currentName: nil,
                persistenceRecovery: recovery
            ))

            self.operation = nil
            completion(outcome)
        }
        return true
    }

    private func publish(_ progress: ArtifactCleanupProgress) {
        notificationCenter.post(ArtifactCleanupDidChange(progress: progress))
    }
}
