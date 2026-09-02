import AppKit

// MARK: - The palette

/// The theme the design system draws with, inside a plugin.
///
/// The application resolves this from `AppThemeLibrary` and a user's recorded choice. A plugin has
/// neither, so the host hands its theme over at load time and again whenever it changes. The type
/// is the application's own `AppTheme`, compiled from the same file, so nothing is approximated on
/// the way across: a plugin's `Design.Surface.ground` is the colour the window is painted with,
/// not a copy of it that drifts.
///
/// Deliberately the same shape as the application's `AppThemePalette`, because the design system's
/// own sources are compiled against it unmodified. See
/// [`native-extension-tier.md`](../../../../docs/feature-drafts/native-extension-tier.md).
enum AppThemePalette {

    private static let storage = NSLock()
    nonisolated(unsafe) private static var theme: AppTheme = AppThemeStyles.threading

    /// The theme in force. Read on AppKit's drawing callbacks, so it is guarded rather than
    /// isolated, exactly as the application's own palette is.
    static var current: AppTheme {
        storage.lock(); defer { storage.unlock() }
        return theme
    }

    /// Called by the host when a plugin loads, and again on every theme change.
    static func install(_ theme: AppTheme) {
        storage.lock(); Self.theme = theme; storage.unlock()
        NotificationCenter.default.post(AppThemeDidChange(themeID: theme.id))
    }

    /// A colour that resolves through the *current* theme each time it is drawn, so a plugin's
    /// views follow a theme change for the same reason the application's do.
    static func color(_ role: AppThemeRole) -> NSColor {
        NSColor(name: NSColor.Name("threading.plugin.\(role.rawValue)")) { appearance in
            current.resolved(role, appearance: appearance)
        }
    }
}

/// Posted when the host installs a different theme, so the design system's own refresh machinery
/// re-applies the colours a `CALayer` froze into a `CGColor`. Declared here rather than symlinked
/// because the application's copy lives beside `AppThemeLibrary`, which reads stores a plugin has
/// no business touching.
struct AppThemeDidChange: AppEvent {
    static let name = Notification.Name("AppThemeDidChange")
    let themeID: AppThemeID
}

// MARK: - The five settings

/// The preferences the design system reads, as a plugin sees them.
///
/// `DesignSettings` already names exactly five values and is compiled from the application's own
/// file. This supplies them without a `UserDefaults` the plugin has no business reading: the host
/// installs what the user chose.
struct AppSettings {

    nonisolated(unsafe) static var appTextSize: AppTextSize = .standard
    nonisolated(unsafe) static var chromeFontFamily: String?
    nonisolated(unsafe) static var conversationFontFamily: String?
    nonisolated(unsafe) static var promptReturnKey: PromptReturnKey = .matchesComposer

    static let shared = AppSettings()
    init() {}
    var chatNameMorphStyle: ChatNameMorphStyle { AppSettings.morphStyle }
    nonisolated(unsafe) static var morphStyle: ChatNameMorphStyle = .shapeMorph
}

/// The application's four text sizes. The scale is the load-bearing half — a plugin that read a
/// different number would lay its text out at a size the rest of the window is not using.
enum AppTextSize: String, CaseIterable {
    case compact, standard, large, extraLarge
    var scale: CGFloat {
        switch self {
        case .compact: 0.90
        case .standard: 1
        case .large: 1.15
        case .extraLarge: 1.30
        }
    }
}

enum PromptReturnKey: String, CaseIterable {
    case matchesComposer, sends, startsNewLine
}

enum ChatNameMorphStyle: String, CaseIterable {
    case shapeMorph, crossfade, slideUp, slideDown, scale, bounce, drop, flip, blur, scramble, typewriter
}

// MARK: - Services the host owns

/// Skin artwork for the themes that ship one.
///
/// The application resolves these from a store on disk that it writes and prunes. A plugin has no
/// business managing that store, so the host installs a resolver instead — and a plugin that runs
/// without one simply gets the drawn fallback each style already defines for a missing asset.
enum ThemeAssetStore {
    nonisolated(unsafe) static var resolve: (@Sendable (String, AppThemeID) -> NSImage?)?
    static func image(named assetName: String, for themeID: AppThemeID) -> NSImage? {
        resolve?(assetName, themeID)
    }
}

/// The terminal themes on offer.
///
/// `TerminalTheme` reaches for this to list the user's custom schemes alongside the stock ones.
/// A plugin sees the stock list unless the host installs the full one.
final class ThemeManager: @unchecked Sendable {
    static let shared = ThemeManager()
    var allThemes: [TerminalTheme] = TerminalTheme.builtInThemes
}

/// The catalogue of app themes, as a plugin sees it.
///
/// The application keeps the user's standing choice in a preference store and posts a change when
/// it moves. A plugin follows rather than chooses: the host installs the theme, and this reports
/// what was installed so the shared sources can ask the question they already ask.
enum AppThemeLibrary {
    static var current: AppTheme { AppThemePalette.current }
    static func theme(withID id: AppThemeID) -> AppTheme? {
        AppThemeStyles.all.first { $0.id == id }
    }
    static func apply(_ theme: AppTheme) { AppThemePalette.install(theme) }
}

/// Where a user's recorded choice is read from.
///
/// A plugin reads the host's answer and records nothing of its own, so this is the standard suite
/// rather than the application's redirected store. See `themes.md` for the line between a
/// behavioural setting and a recorded choice, which is why the application cannot simply use this.
enum PreferenceStore {
    static let shared = UserDefaults.standard
}

/// What the usage history expects to happen to a window.
///
/// The forecast itself is computed by the application from a journal a plugin cannot see; only the
/// *shape* of the answer is needed here, because the design system formats it. Declared rather
/// than symlinked because the computation lives beside the journal.
enum UsageForecast {
    enum Outcome {
        case unknown
        case withinBudget
        case exhausting(at: Date, early: TimeInterval)
    }
}

/// Sidebar artwork contributed by an installed extension.
///
/// A plugin draws with the themes the host installed; it does not host extensions of its own, so
/// there is nothing to look up and the styles fall back to what they draw without an asset.
final class ExtensionAppearanceRegistry: @unchecked Sendable {
    static let shared = ExtensionAppearanceRegistry()
    func sidebarAsset(named name: String, forThemeID id: AppThemeID) -> NSImage? { nil }
}

/// The pane header's silhouette, as the components read it.
///
/// The application declares this beside the controller that lays the strip out; both members
/// resolve through types the kit already has, so this states the same two answers rather than
/// copying two numbers that could drift.
enum PaneHeaderDefaults {
    static var height: CGFloat { PaneHeaderView.bandHeight }
    static let inset: CGFloat = Design.Spacing.medium
}
