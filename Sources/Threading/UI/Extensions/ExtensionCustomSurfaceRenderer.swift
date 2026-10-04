import AppKit
import ThreadingExtensionKit

/// Builds the host-owned view for an extension's custom surface, for every host that shows one.
///
/// The main window's hook and the backdrop planes all need this, and they must agree: the same
/// bounded, package-contained shader source lookup, the same signal answers, the same texture
/// loading, the same refusal logging. What differs per host is the cadence ceiling — a contract
/// may state one below the SDK's 60 — and that is the one thing a caller passes in. Nothing an
/// extension supplied reaches the view except the validated specification, its shader text and
/// the decoded pixels of the one picture it named.
@MainActor
enum ExtensionCustomSurfaceRenderer {

    /// Reads and decodes a surface's package picture off the main actor, then hands the pixels
    /// to `completion` on it. A seam so a test can supply pixels without an installed package.
    typealias TextureLoader = @MainActor (
        _ relativePath: String,
        _ extensionIdentifier: String,
        _ completion: @escaping @MainActor @Sendable (ExtensionSurfaceTexturePixels?) -> Void
    ) -> Void

    static func render(
        _ surface: ExtensionCustomSurface,
        extensionIdentifier: String,
        maximumFramesPerSecond: Int = ExtensionMetalSurface.maximumFramesPerSecond,
        signalProvider: @escaping ExtensionMetalSurfaceView.SignalProvider = { signal, context in
            ExtensionHostSignals.value(signal, in: context)
        },
        textureLoader: TextureLoader = loadPackageTexture
    ) -> NSView? {
        switch surface {
        case let .metal(specification):
            guard let source = ExtensionManager.shared.customSurfaceSource(
                relativePath: specification.shaderResource,
                extensionIdentifier: extensionIdentifier
            ) else {
                return nil
            }
            let view: ExtensionMetalSurfaceView
            do {
                view = try ExtensionMetalSurfaceView(
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
            if let texture = specification.texture {
                attachTexture(
                    texture,
                    to: view,
                    extensionIdentifier: extensionIdentifier,
                    loader: textureLoader
                )
            }
            return view
        }
    }

    /// Starts the picture's load and installs it when it lands. The surface draws from the
    /// first frame on its transparent placeholder; a picture that cannot be read is logged and
    /// the surface keeps drawing without it, rather than the whole hook being skipped for a
    /// resource that only colours it.
    static func attachTexture(
        _ relativePath: String,
        to view: ExtensionMetalSurfaceView,
        extensionIdentifier: String,
        loader: TextureLoader
    ) {
        loader(relativePath, extensionIdentifier) { [weak view] pixels in
            guard let view else { return }
            guard let pixels, view.installTexture(pixels) else {
                ThreadingLogger.extensions.error(
                    "Could not load the Metal surface texture from \(extensionIdentifier, privacy: .public); drawing without it"
                )
                return
            }
        }
    }

    /// The production loader: the package's bounded image read and the decode on a worker,
    /// the process generation rechecked before the pixels are handed back.
    static func loadPackageTexture(
        _ relativePath: String,
        _ extensionIdentifier: String,
        _ completion: @escaping @MainActor @Sendable (ExtensionSurfaceTexturePixels?) -> Void
    ) {
        ExtensionManager.shared.prepareCustomSurfaceTexture(
            relativePath: relativePath,
            extensionIdentifier: extensionIdentifier,
            prepare: { ExtensionSurfaceTexturePixels.prepared(fromImageData: $0) },
            completion: completion
        )
    }
}
