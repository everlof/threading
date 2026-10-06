import AppKit
import CoreText

/// Installed themes and inspected resources, independent of executable enablement.
/// Inventory and live edits replace contribution values; status-only notifications do not
/// rebuild them. Artwork decodes on demand into a two-theme cache. Font metadata stays visible
/// in pickers while registrations follow runtime, selected-theme and explicit-family demand.
/// CoreText process registrations are live; NSFontManager's cached enumeration is not.
@MainActor
final class ExtensionAppearanceRegistry {

    static let shared = ExtensionAppearanceRegistry()

    struct Contribution: Equatable {
        let extensionIdentifier: String
        let extensionName: String
        let themes: [AppTheme]
        let fontURLs: [URL]
        let fontFamilies: [URL: [String]]
        let fontPostScriptNames: [URL: [String]]
        let runtimeEnabled: Bool
        /// PNG bytes per theme, already decode-gated and shape-checked by
        /// `ExtensionBundleLoader`. Kept as bytes so a contribution stays `Equatable` and the
        /// wholesale diff below still recognises an unchanged package.
        let iconMarks: [AppThemeID: Data]

        /// PNG bytes per theme for the sidebar's logo and background, keyed by the asset name
        /// the theme document references — the package-relative path as written. The same
        /// bytes-not-images reasoning as `iconMarks`, and read at the same moment: inspection,
        /// before any extension code runs.
        let sidebarAssets: [AppThemeID: [String: Data]]

        init(
            extensionIdentifier: String,
            extensionName: String,
            themes: [AppTheme],
            fontURLs: [URL],
            fontFamilies: [URL: [String]] = [:],
            fontPostScriptNames: [URL: [String]] = [:],
            runtimeEnabled: Bool = true,
            iconMarks: [AppThemeID: Data] = [:],
            sidebarAssets: [AppThemeID: [String: Data]] = [:]
        ) {
            self.extensionIdentifier = extensionIdentifier
            self.extensionName = extensionName
            self.themes = themes
            self.fontURLs = fontURLs
            self.fontFamilies = fontFamilies
            self.fontPostScriptNames = fontPostScriptNames
            self.runtimeEnabled = runtimeEnabled
            self.iconMarks = iconMarks
            self.sidebarAssets = sidebarAssets
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

    /// Cached inspection metadata only; the remote rendition worker reads the selected files.
    func phoneFontURLs(families: [String]) -> [URL] {
        let wanted = Set(families)
        return Array(Set(contributions.flatMap { contribution in
            contribution.fontURLs.filter { url in
                activeFontURLs.contains(url)
                    && contribution.fontFamilies[url]?.contains(where: wanted.contains) == true
            }
        }).sorted { $0.path < $1.path }.prefix(ThemeFontStore.maximumFonts))
    }
    private var decodedMarks: [AppThemeID: NSImage] = [:]
    private var decodedSidebarAssets: [AppThemeID: [String: NSImage]] = [:]
    private var decodedThemeOrder: [AppThemeID] = []
    private var demandedTheme: AppTheme?

    var availableFontFamilies: Set<String> {
        Set(contributions.flatMap { $0.fontFamilies.values.flatMap { $0 } })
    }

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
        retainDecodedResources(for: id)
        if let cached = decodedMarks[id] { return cached }
        guard let data = contributions.compactMap({ $0.iconMarks[id] }).first,
              let image = NSImage(data: data) else { return nil }
        decodedMarks[id] = image
        return image
    }

    /// A sidebar asset a contributed theme's document references, by the name it wrote.
    ///
    /// Memoized like `iconMark`, and for the same reason: the sidebar redraws on every theme
    /// change, and decoding a background PNG per redraw is work the diff already proved
    /// unnecessary. Nil for a name the package never shipped — the caller degrades to the
    /// default treatment, never to an error.
    func sidebarAsset(named name: String, forThemeID id: AppThemeID) -> NSImage? {
        retainDecodedResources(for: id)
        if let cached = decodedSidebarAssets[id]?[name] { return cached }
        guard let data = sidebarAssetData(named: name, forThemeID: id),
              let image = NSImage(data: data) else { return nil }
        decodedSidebarAssets[id, default: [:]][name] = image
        return image
    }

    /// The raw bytes behind a sidebar asset, for duplicating a contributed theme into the
    /// custom tier — the copy has to own its assets, or uninstalling the extension would strip
    /// the sidebar off a theme the user now owns.
    func sidebarAssetData(named name: String, forThemeID id: AppThemeID) -> Data? {
        contributions.compactMap({ $0.sidebarAssets[id]?[name] }).first
    }

    func replace(contributions newContributions: [Contribution]) {
        guard newContributions != contributions else { return }
        // Values, not ids: a live-reloaded or updated package keeps a theme's identity while
        // changing what it says, and a diff that only watched ids left the app wearing the
        // old colours until the next manual theme switch.
        let previousThemes = themes
        let previousFonts = activeFontURLs

        let previousMarks = contributions.map(\.iconMarks)
        let previousSidebarAssets = contributions.map(\.sidebarAssets)
        contributions = newContributions
        updateFontRegistrations()
        decodedMarks = [:]
        decodedSidebarAssets = [:]
        decodedThemeOrder = []

        // A package can change a theme's artwork without changing its identity — an update is
        // the ordinary way that happens — so the icon (and the sidebar wearing its assets) has
        // to be redrawn on a diff the theme-id comparison below cannot see.
        if contributions.map(\.iconMarks) != previousMarks
            || contributions.map(\.sidebarAssets) != previousSidebarAssets {
            NotificationCenter.default.post(
                AppThemeDidChange(themeID: AppThemeLibrary.current.id)
            )
        }

        if themes != previousThemes {
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

    /// Catalogue entries are inert. Only the chosen appearance, running extensions and explicit
    /// font choices retain registrations. Inspection already supplied these family names.
    func prepareResources(for theme: AppTheme) {
        demandedTheme = theme
        updateFontRegistrations()
    }

    private func updateFontRegistrations() {
        let theme = demandedTheme
        var families = Set([AppSettings.chromeFontFamily, AppSettings.conversationFontFamily,
                            ProfileStorage.shared.defaultProfile.fontName].compactMap { $0 })
        for variant in theme?.variants.values.map({ $0 }) ?? [] {
            families.formUnion([variant.material.fontFamily, variant.material.buttonStyle.fontFamily,
                                variant.material.headingStyle?.fontFamily, variant.sidebar?.brand?.title?.fontFamily,
                                variant.welcome?.greeting?.style?.fontFamily, variant.welcome?.caption?.style?.fontFamily]
                .compactMap { $0 })
            families.formUnion(variant.material.fontFallbacks)
        }
        let desired = Set(contributions.flatMap { contribution in
            if contribution.runtimeEnabled || contribution.themes.contains(where: { $0.id == theme?.id }) {
                return contribution.fontURLs
            }
            return contribution.fontURLs.filter { url in
                contribution.fontFamilies[url]?.contains(where: families.contains) == true
                    || contribution.fontPostScriptNames[url]?.contains(where: families.contains) == true
            }
        })
        for url in activeFontURLs.subtracting(desired) {
            deactivateFont(url)
            activeFontURLs.remove(url)
        }
        for url in desired.subtracting(activeFontURLs) where activateFont(url) {
            activeFontURLs.insert(url)
        }
    }

    private func retainDecodedResources(for id: AppThemeID) {
        decodedThemeOrder.removeAll { $0 == id }
        decodedThemeOrder.append(id)
        while decodedThemeOrder.count > 2 {
            let removed = decodedThemeOrder.removeFirst()
            decodedMarks[removed] = nil
            decodedSidebarAssets[removed] = nil
        }
    }
}
