import Foundation

/// The user's preferences, as the design system sees them.
///
/// `UI/Design/` reads exactly five values from the application's settings, and these are all of
/// them. Naming them here is what stops the design system reaching for a singleton it happens to
/// be compiled beside: everything else in this directory already describes appearance without
/// knowing what an application, a project or a session is.
///
/// This is the first step of extracting `ThreadingDesignKit` so a native plugin can link the real
/// components rather than approximate them. `AppSettings` is the only thing in `UI/Design/` that a
/// framework could not take with it; see
/// [`native-extension-tier.md`](../../../../docs/feature-drafts/native-extension-tier.md).
@MainActor
protocol DesignSettingsReading {
    var appTextSize: AppTextSize { get }
    var chromeFontFamily: String? { get }
    var conversationFontFamily: String? { get }
    var promptReturnKey: PromptReturnKey { get }
    var chatNameMorphStyle: ChatNameMorphStyle { get }
}

/// Where `UI/Design/` reads its preferences from.
@MainActor
enum DesignSettings {

    /// Replaceable so a gallery story, a render test or a plugin host can state its own
    /// preferences instead of inheriting the developer's. Feature code never writes this.
    ///
    /// A hosted test writes to the real application's `UserDefaults`, so a test that needs a
    /// particular text size or font should install a value here rather than record a choice the
    /// developer's next launch would inherit. See [`themes.md`](../../../../docs/architecture/themes.md).
    static var current: DesignSettingsReading = ApplicationDesignSettings()

    /// Run `body` with `settings` in force, restoring the previous provider afterwards.
    static func withSettings<T>(_ settings: DesignSettingsReading, perform body: () throws -> T) rethrows -> T {
        let previous = current
        current = settings
        defer { current = previous }
        return try body()
    }
}

/// The application's own answer, reading exactly what `UI/Design/` read before this seam existed.
///
/// Which store each value comes from is preserved deliberately. The four `nonisolated static`
/// accessors read `.standard`; `chatNameMorphStyle` reads the shared instance's own store, which a
/// hosted test redirects. `themes.md` draws that line between a behavioural setting and a recorded
/// user choice, and this change is a decoupling rather than a behaviour change.
@MainActor
struct ApplicationDesignSettings: DesignSettingsReading {
    var appTextSize: AppTextSize { AppSettings.appTextSize }
    var chromeFontFamily: String? { AppSettings.chromeFontFamily }
    var conversationFontFamily: String? { AppSettings.conversationFontFamily }
    var promptReturnKey: PromptReturnKey { AppSettings.promptReturnKey }
    var chatNameMorphStyle: ChatNameMorphStyle { AppSettings.shared.chatNameMorphStyle }
}
