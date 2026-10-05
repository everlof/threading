import AppKit
@testable import Threading

/// Everything process-wide an extension test can change in the hosted app, captured on
/// creation and put back exactly by `restore()`.
///
/// A hosted test shares the app's singletons, and two routes write them without the test
/// asking: every `ExtensionManager` — a fixture's own included — replaces the shared settings
/// registry from its initializer and the appearance registry on each enablement change, and
/// applying a theme moves the current theme, the stored choice and `NSApp.appearance`. A later
/// class then inherits a settings section, a theme or a font registration it never set up.
///
/// While a guard is held the appearance registry's CoreText hooks are bookkeeping-only, so a
/// fixture that empties the registry cannot unregister a font a later test measures with, and
/// putting the contributions back cannot register one twice.
@MainActor
final class HostedExtensionStateGuard {
    private let settings: ExtensionSettingsRegistry.Snapshot
    private let contributions: [ExtensionAppearanceRegistry.Contribution]
    private let activateFont: (URL) -> Bool
    private let deactivateFont: (URL) -> Void
    private let theme: AppTheme
    private let storedThemeID: String?
    private let appAppearance: NSAppearance?

    private static let storedThemeKey = "appThemeID"

    init() {
        let appearanceRegistry = ExtensionAppearanceRegistry.shared
        settings = ExtensionSettingsRegistry.shared.snapshot
        contributions = appearanceRegistry.contributions
        activateFont = appearanceRegistry.activateFont
        deactivateFont = appearanceRegistry.deactivateFont
        theme = AppThemeLibrary.current
        storedThemeID = PreferenceStore.shared.string(forKey: Self.storedThemeKey)
        appAppearance = NSApp.appearance
        appearanceRegistry.activateFont = { _ in true }
        appearanceRegistry.deactivateFont = { _ in }
    }

    /// Registries first — removing a fixture's contributed theme may fall back and record the
    /// fallback — then the stored choice, the theme value and the app appearance, and the real
    /// CoreText hooks last, so nothing in between touches the font system.
    func restore() {
        let appearanceRegistry = ExtensionAppearanceRegistry.shared
        appearanceRegistry.replace(contributions: contributions)
        ExtensionSettingsRegistry.shared.restore(settings)
        if let storedThemeID {
            PreferenceStore.shared.set(storedThemeID, forKey: Self.storedThemeKey)
        } else {
            PreferenceStore.shared.removeObject(forKey: Self.storedThemeKey)
        }
        if AppThemeLibrary.current != theme {
            AppThemeLibrary.installResolved(theme)
        }
        appearanceRegistry.prepareResources(for: theme)
        NSApp.appearance = appAppearance
        appearanceRegistry.activateFont = activateFont
        appearanceRegistry.deactivateFont = deactivateFont
    }
}
