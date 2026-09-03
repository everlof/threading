import Foundation
import ThreadingPluginKit

/// Where native plugins live, and who is allowed to be one.
///
/// This is the trusted tier described in
/// [`plugins.md`](../../../../docs/architecture/plugins.md): a bundle
/// Threading `dlopen`s into its own process, with full AppKit and no sandbox. It exists beside the
/// safe WebAssembly tier rather than replacing it, and the install review has to say plainly which
/// one a thing is.
///
/// It lives in the UI layer rather than in Application on purpose, and the module boundary said
/// so before I did: a catalogue whose whole job is to hand back `NSView`-returning objects deals in
/// presentation, and `Threading/Application` may import only lower-level, view-free contracts.
///
/// **The operating system enforces nothing here.** Threading ships hardened runtime carrying
/// `com.apple.security.cs.disable-library-validation`, so `dlopen` will map a bundle signed by any
/// team, or none. Every check is `PluginLoader`'s, and the user's recorded decision below is the
/// whole policy.
@MainActor
enum NativePluginCatalog {

    /// Whether an installed plugin may run, which is the user's decision rather than a list of
    /// teams we happen to trust.
    ///
    /// It was an allowlist holding Threading's own signing team and nothing else, which meant the
    /// tier was closed by construction: we could ship plugins and nobody else could, and a platform
    /// only its author can build on is not one. Removing the check outright was the other wrong
    /// answer — the app ships `disable-library-validation`, so a bundle in the plugins folder runs
    /// in this process with AppKit, the user's files and every TCC grant Threading holds. Dropping
    /// a file would have been code execution.
    ///
    /// So the gate changed rather than went: the signature must still validate, and then the user
    /// has to have agreed to run *this build* of *this plugin*. The answer is recorded and
    /// revocable, which is the same shape the device-log tap uses for the same reason.
    static var approvals: NativePluginApprovalStore { .shared }

    /// `~/Library/Application Support/Threading/Plugins`. Bundles are dropped in by hand today;
    /// an install flow is a later slice and needs its own review copy.
    static var directory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Threading", isDirectory: true)
            .appendingPathComponent("Plugins", isDirectory: true)
    }

    /// The plugins Threading ships inside itself.
    ///
    /// Trusted by *location* rather than by a decision: code inside the app bundle is sealed by the
    /// app's own signature, so altering it invalidates the app the operating system already
    /// checked. That is a stronger guarantee than anything a prompt could add, and it is the reason
    /// a first-party pane can ship as a plugin without the user installing anything. It is not a
    /// privilege either: it is what any app gets for the plugins inside its own bundle, and a
    /// plugin of ours installed the ordinary way is refused until approved.
    static func bundledPlugins() -> [URL] {
        guard let plugIns = Bundle.main.builtInPlugInsURL else { return [] }
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: plugIns,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants]
        )) ?? []
        return contents.filter { $0.pathExtension == "bundle" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    /// A bundled plugin by its own identifier.
    ///
    /// By identifier rather than by file name, and general rather than one-per-plugin. The first
    /// version of this matched the literal string `DeviceLogsPlugin`, which is the shape that rots:
    /// today it resolves a URL, and the next thing hung off it is a behaviour only the first-party
    /// plugin gets. A host that needs a particular plugin names it the way anyone would — by the
    /// identifier in its `Info.plist`.
    static func bundledPlugin(identifier: String) -> URL? {
        bundledPlugins().first { url in
            Bundle(url: url)?.bundleIdentifier == identifier
        }
    }

    /// The identifier of the Device Logs plugin Threading ships.
    ///
    /// The host still names one plugin, because `device_log_prepare` reveals *that* pane and a
    /// tool has to mean something specific. That is the remaining first-party coupling in this
    /// tier, and it is a constant rather than a mechanism: nothing here treats the plugin it names
    /// differently from any other, and a third-party plugin reached the same way would work.
    static let deviceLogsIdentifier = "codes.threading.plugin.devicelogs"

    static var deviceLogsBundle: URL? { bundledPlugin(identifier: deviceLogsIdentifier) }

    /// Whether a bundle is one of ours, and so already covered by the app's signature.
    private static func isBundled(_ url: URL) -> Bool {
        url.resolvingSymlinksInPath().path
            .hasPrefix(Bundle.main.bundleURL.resolvingSymlinksInPath().path + "/")
    }

    /// Every bundle in the directory, in a stable order. Both returned bundles and inspected
    /// directory entries are capped: a plugins folder is externally writable, so `limit` alone
    /// is not a bound when it is applied after `contentsOfDirectory` has materialized everything.
    static func installedBundles(limit: Int = 32) -> [URL] {
        let requestedLimit = min(max(0, limit), 32)
        guard requestedLimit > 0,
              let enumerator = FileManager.default.enumerator(
            at: directory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants]
        ) else { return [] }

        var contents: [URL] = []
        contents.reserveCapacity(requestedLimit)
        var inspected = 0
        while inspected < 256, let entry = enumerator.nextObject() as? URL {
            inspected += 1
            if entry.pathExtension == "bundle" { contents.append(entry) }
        }
        return contents
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
            .prefix(requestedLimit)
            .map { $0 }
    }

    /// Load one bundle under the current policy. Every refusal is returned rather than thrown away,
    /// because "the plugin did not appear" is not a diagnosis.
    static func load(_ bundle: URL) -> Result<ThreadingNativePlugin, PluginLoadFailure> {
        do {
            // A bundled plugin is part of the app: altering it invalidates the signature the
            // operating system already checked, so there is nothing left for a decision to add.
            guard !isBundled(bundle) else {
                return .success(try PluginLoader.sealedByHostBundle().load(bundleAt: bundle))
            }
            // Anything else is somebody's code, and running it is the user's call. The loader
            // owns the order — readable, then validly signed, then approved, then mapped — which
            // it did not when this method sequenced those steps itself. Getting the first two the
            // wrong way round reported every absent plugin as `signature_invalid`, which is the
            // failure this tier's named refusals exist to prevent.
            return .success(
                try PluginLoader.signatureAndDecision().load(bundleAt: bundle) { identity in
                    approvals.decision(for: identity) == true
                }
            )
        } catch let failure as PluginLoadFailure {
            return .failure(failure)
        } catch {
            return .failure(.unreadableBundle(path: bundle.path))
        }
    }

    /// Whether the ground the plugin will draw on is dark.
    ///
    /// Read from the theme's own ground rather than from `NSAppearance`, because a Threading theme
    /// is not an aqua/darkAqua pair — an authored light theme under a dark system appearance, and
    /// the reverse, both exist. A colour that will not convert is reported as light rather than
    /// guessed at.
    private static func isDarkGround() -> Bool {
        guard let rgb = Design.Surface.ground.usingColorSpace(.sRGB) else { return false }
        return rgb.brightnessComponent < 0.5
    }

    /// The contract generation this build speaks, for a failure surface to quote.
    static var apiVersion: Int { ThreadingPluginAPI.version }

    /// The host's current appearance, as the narrow value a plugin is given.
    ///
    /// Two layers, and the second is the one that matters. The seven tokens are the floor, for a
    /// plugin that links nothing; `encodedTheme` carries the whole theme, and a plugin linking
    /// `ThreadingDesignKit` resolves every role, radius, bevel and font from it exactly as the
    /// application does. See `plugins.md`.
    static func theme() -> PluginTheme {
        PluginTheme(
            background: Design.Surface.ground,
            surface: Design.Surface.panel,
            text: Design.Text.label,
            secondaryText: Design.Text.secondary,
            accent: Design.Status.warning,
            monospacedFont: Design.Typography.compactCode(),
            rowHeight: Design.Spacing.large,
            isDark: isDarkGround(),
            // A plugin linking ThreadingDesignKit resolves every value itself from this, rather
            // than from the seven tokens above. `try?` because a theme that will not encode is a
            // reason to fall back to the tokens, not a reason to refuse to show the pane.
            encodedTheme: try? JSONEncoder().encode(AppThemePalette.current)
        )
    }
}
