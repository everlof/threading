import AppIntents
import Foundation

/// **End** in the Mirror Live Activity.
///
/// A `LiveActivityIntent` runs in the app's process even when the button is in the widget
/// extension, so this is the one that acts. The extension declares the same type, with the same
/// name and parameters (`Targets/ThreadingGlance/MirrorEndIntent.swift`), only so its button can
/// name it; keep the two in step.
struct MirrorEndIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "End Mirror"
    static let isDiscoverable = false

    @Parameter(title: "Mirror")
    var mirrorID: String

    @Parameter(title: "Mac")
    var hostID: String

    init() {}

    init(mirrorID: String, hostID: String) {
        self.mirrorID = mirrorID
        self.hostID = hostID
    }

    /// Installed by `MobileMirrorController` as the app starts.
    @MainActor static var handler: ((String, String) async -> Void)?

    func perform() async throws -> some IntentResult {
        await Self.run(mirrorID: mirrorID, hostID: hostID)
        return .result()
    }

    @MainActor private static func run(mirrorID: String, hostID: String) async {
        await handler?(mirrorID, hostID)
    }
}
