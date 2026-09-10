import AppKit
import ThreadingExtensionKit

/// Builds the host-owned view for an extension's custom surface, for every host that shows one.
///
/// The main window's hook and the sidebar backdrop both need this, and they must agree: the same
/// bounded, package-contained shader source lookup, the same signal answers, the same refusal
/// logging. What differs per host is the cadence ceiling — a contract may state one below the
/// SDK's 60 — and that is the one thing a caller passes in. Nothing an extension supplied
/// reaches the view except the validated specification and its shader text.
@MainActor
enum ExtensionCustomSurfaceRenderer {

    static func render(
        _ surface: ExtensionCustomSurface,
        extensionIdentifier: String,
        maximumFramesPerSecond: Int = ExtensionMetalSurface.maximumFramesPerSecond,
        signalProvider: @escaping ExtensionMetalSurfaceView.SignalProvider = {
            ExtensionHostSignals.value($0)
        }
    ) -> NSView? {
        switch surface {
        case let .metal(specification):
            guard let source = ExtensionManager.shared.customSurfaceSource(
                relativePath: specification.shaderResource,
                extensionIdentifier: extensionIdentifier
            ) else {
                return nil
            }
            do {
                return try ExtensionMetalSurfaceView(
                    specification: specification,
                    source: source,
                    maximumFramesPerSecond: maximumFramesPerSecond,
                    signalProvider: signalProvider
                )
            } catch {
                ThreadingLogger.extensions.error(
                    "Could not render Metal surface from \(extensionIdentifier, privacy: .public): \(error.localizedDescription, privacy: .private(mask: .hash))"
                )
                return nil
            }
        }
    }
}
