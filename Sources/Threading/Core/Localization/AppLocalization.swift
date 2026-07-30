import Foundation

/// The application's localization boundary.
///
/// English source copy remains the key and the fallback value. That keeps call sites readable,
/// lets an incomplete new translation fall back one string at a time, and gives extensions the
/// same key/fallback convention as the host.
enum L10n {

    static func string(
        _ key: String,
        table: String? = nil,
        bundle: Bundle = .main
    ) -> String {
        bundle.localizedString(forKey: key, value: key, table: table)
    }

    static func format(
        _ key: String,
        _ arguments: CVarArg...,
        table: String? = nil,
        bundle: Bundle = .main,
        locale: Locale = .current
    ) -> String {
        String(
            format: string(key, table: table, bundle: bundle),
            locale: locale,
            arguments: arguments
        )
    }

    /// The host's preference order in stable BCP-47 form, used by extension locale negotiation.
    static var preferredLanguages: [String] {
        let appLanguages = Bundle.main.preferredLocalizations
        return appLanguages.isEmpty ? Locale.preferredLanguages : appLanguages
    }

    static var localeIdentifier: String {
        Locale.current.identifier
    }
}
