import Foundation

/// A storage scan finished, or its cached findings changed.
struct ArtifactScanDidChange: AppEvent {
    static let name = Notification.Name("artifactScanDidChange")
}

/// One bounded update from the single cleanup operation allowed to run at a time.
struct ArtifactCleanupDidChange: AppEvent {
    static let name = Notification.Name("artifactCleanupDidChange")

    let progress: ArtifactCleanupProgress
}
