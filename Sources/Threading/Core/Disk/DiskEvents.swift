import Foundation

/// A storage scan finished, or its cached findings changed.
struct ArtifactScanDidChange: AppEvent {
    static let name = Notification.Name("artifactScanDidChange")
}
