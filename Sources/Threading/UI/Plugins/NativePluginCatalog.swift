import Foundation
import ThreadingPluginKit

/// Where native plugins live, and who is allowed to be one.
///
/// This is the trusted tier described in
/// [`native-extension-tier.md`](../../../../docs/feature-drafts/native-extension-tier.md): a bundle
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
    static var allowedTeams: Set<String> = ["SMQ3E8Y57T"]

    /// `~/Library/Application Support/Threading/Plugins`. Bundles are dropped in by hand today;
    /// an install flow is a later slice and needs its own review copy.
    static var directory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Threading", isDirectory: true)
            .appendingPathComponent("Plugins", isDirectory: true)
    }

    /// Every bundle in the directory, in a stable order. Enumeration is shallow and bounded: a
    /// plugins folder is externally sized, and this runs at launch.
    static func installedBundles(limit: Int = 32) -> [URL] {
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants]
        )) ?? []
        return contents
            .filter { $0.pathExtension == "bundle" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
            .prefix(limit)
            .map { $0 }
    }

    /// Load one bundle under the current policy. Every refusal is returned rather than thrown away,
    /// because "the plugin did not appear" is not a diagnosis.
    static func load(_ bundle: URL) -> Result<ThreadingNativePlugin, PluginLoadFailure> {
        do {
            return .success(try PluginLoader(allowedTeams: allowedTeams).load(bundleAt: bundle))
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
    /// Tokens today. Once `ThreadingDesignKit` exists a plugin links the real components and this
    /// shrinks to whatever they cannot resolve for themselves — see the extraction plan in
    /// `native-extension-tier.md`.
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
