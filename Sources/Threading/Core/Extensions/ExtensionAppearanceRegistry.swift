import AppKit
import CoreText

/// The themes and fonts enabled extensions contribute to the app's own appearance.
///
/// Mirrors `ExtensionSettingsRegistry`: derived state, replaced wholesale from the manager's
/// enabled-and-valid packages whenever inventory or enablement changes, never mutated
/// incrementally — so install, enable, disable, update and uninstall all converge through one
/// idempotent diff. Everything here is data the host read at inspection time; no extension
/// code has to be running (or even startable) for its themes and fonts to be in force, which
/// is what lets `AppThemeLibrary.restore()` resolve a contributed theme before the first
/// window exists.
///
/// Fonts are registered **process-scoped** through `CTFontManager`, and both halves of that
/// were probed rather than assumed (2026-07-27, font-probe.swift): a process registration is
/// visible to the descriptor matching `Design.Typography.inFamily` does — live, in both
/// directions, so disabling an extension makes a theme naming its font degrade one rung
/// exactly like any uninstalled family — while `NSFontManager.availableFontFamilies` snapshots
/// on first access and never sees it, which is why every enumeration for pickers goes through
/// `Design.Typography.availableFamilies` instead.
@MainActor
final class ExtensionAppearanceRegistry {

    static let shared = ExtensionAppearanceRegistry()

    struct Contribution: Equatable {
        let extensionIdentifier: String
        let extensionName: String
        let themes: [AppTheme]
        let fontURLs: [URL]
        /// PNG bytes per theme, already decode-gated and shape-checked by
        /// `ExtensionBundleLoader`. Kept as bytes so a contribution stays `Equatable` and the
        /// wholesale diff below still recognises an unchanged package.
        let iconMarks: [AppThemeID: Data]

        init(
            extensionIdentifier: String,
            extensionName: String,
            themes: [AppTheme],
            fontURLs: [URL],
            iconMarks: [AppThemeID: Data] = [:]
        ) {
            self.extensionIdentifier = extensionIdentifier
            self.extensionName = extensionName
            self.themes = themes
            self.fontURLs = fontURLs
            self.iconMarks = iconMarks
        }
    }

    /// The CoreText calls behind a seam, because a unit test asserting the diffing must not
    /// actually mutate the test process's font registry.
    var activateFont: (URL) -> Bool = { url in
        CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
    }
    var deactivateFont: (URL) -> Void = { url in
        // Unregistering by URL can fail once the package directory moved (an update swaps it
        // aside); the stale registration then lives until relaunch, which is inert — the URLs
        // set keeps the bookkeeping honest either way.
        CTFontManagerUnregisterFontsForURL(url as CFURL, .process, nil)
    }

    private(set) var contributions: [Contribution] = []
    private(set) var activeFontURLs: Set<URL> = []
    private var decodedMarks: [AppThemeID: NSImage] = [:]

    var themes: [AppTheme] { contributions.flatMap(\.themes) }

    func contributorName(forThemeID id: AppThemeID) -> String? {
        contributions.first { $0.themes.contains { $0.id == id } }?.extensionName
    }

    /// The app-icon mark a contributed theme ships, if it ships one.
    ///
    /// Decoded here rather than at inspection because the bytes are what the diff compares, and
    /// memoized because the Dock icon is redrawn on every theme change and every appearance
    /// flip. The cache is dropped whenever contributions are replaced — an updated package that
    /// keeps its theme's identity and changes its artwork is exactly the case a keyed-by-id
    /// cache would get wrong.
    func iconMark(forThemeID id: AppThemeID) -> NSImage? {
        if let cached = decodedMarks[id] { return cached }
        guard let data = contributions.compactMap({ $0.iconMarks[id] }).first,
              let image = NSImage(data: data) else { return nil }
        decodedMarks[id] = image
        return image
    }

    func replace(contributions newContributions: [Contribution]) {
        let previousThemeIDs = themes.map(\.id)
        let previousFonts = activeFontURLs

        let desiredFonts = Set(newContributions.flatMap(\.fontURLs))
        for url in previousFonts.subtracting(desiredFonts) {
            deactivateFont(url)
            activeFontURLs.remove(url)
        }
        for url in desiredFonts.subtracting(previousFonts) where activateFont(url) {
            activeFontURLs.insert(url)
        }

        let previousMarks = contributions.map(\.iconMarks)
        contributions = newContributions
        decodedMarks = [:]

        // A package can change a theme's artwork without changing its identity — an update is
        // the ordinary way that happens — so the icon has to be redrawn on a diff the theme-id
        // comparison below cannot see.
        if contributions.map(\.iconMarks) != previousMarks {
            NotificationCenter.default.post(
                AppThemeDidChange(themeID: AppThemeLibrary.current.id)
            )
        }

        if themes.map(\.id) != previousThemeIDs {
            AppThemeLibrary.contributedThemesDidChange()
        }
        if activeFontURLs != previousFonts {
            // A family arriving or leaving changes what every recorded role resolves to, and a
            // font change already has one answer in this app: the ordinary theme sweep, the
            // same event `startObservingFontOverrides` reuses rather than teaching a dozen
            // consumers a second one.
            AppThemeRefresh.repaintEverything()
            NotificationCenter.default.post(
                AppThemeDidChange(themeID: AppThemeLibrary.current.id)
            )
        }
    }
}
