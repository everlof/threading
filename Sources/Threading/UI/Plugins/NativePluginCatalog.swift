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
/// team, or none. Every check is `PluginLoader`'s, and the allowlist below is the whole policy.
@MainActor
enum NativePluginCatalog {

    /// The shipping policy, kept separate from the mutable test seam so a test can always restore
    /// the real configuration instead of guessing what it was.
    static let defaultAllowedTeams: Set<String> = ["SMQ3E8Y57T"]

    /// Teams whose plugins may be loaded.
    ///
    /// A tier that runs unsandboxed code in this process opens by refusing, not by trusting, so
    /// this is an allowlist and nothing else gets in. `PluginLoader` used to read an *empty* set as
    /// "accept anything" — the opposite of what this comment claimed — which meant the shipping
    /// default would have mapped any bundle dropped into the folder. It now refuses, and running
    /// anything has to be asked for by name.
    ///
    /// The one entry is Threading's own signing team, which is what the first-party Device Logs
    /// plugin is signed with. A third-party tier needs a review flow and its own decision; this is
    /// not it.
    static var allowedTeams = defaultAllowedTeams

    /// `~/Library/Application Support/Threading/Plugins`. Bundles are dropped in by hand today;
    /// an install flow is a later slice and needs its own review copy.
    static var directory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Threading", isDirectory: true)
            .appendingPathComponent("Plugins", isDirectory: true)
    }

    /// The plugins Threading ships inside itself.
    ///
    /// Trusted by *location* rather than by allowlist: code inside the app bundle is sealed by the
    /// app's own signature, so altering it invalidates the app the operating system already
    /// checked. That is a stronger guarantee than a team identifier, and it is the reason a
    /// first-party pane can ship as a plugin without the user installing anything.
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

    /// The one Threading's own Device Logs pane lives in.
    static var deviceLogsBundle: URL? {
        bundledPlugins().first { $0.deletingPathExtension().lastPathComponent == "DeviceLogsPlugin" }
    }

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
            // A bundled plugin is part of the app, so the allowlist has nothing to add: it was
            // validated with the app itself. An installed one faces the full check.
            let loader = isBundled(bundle)
                ? PluginLoader.acceptingAnyTeam()
                : PluginLoader(allowedTeams: allowedTeams)
            return .success(try loader.load(bundleAt: bundle))
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
