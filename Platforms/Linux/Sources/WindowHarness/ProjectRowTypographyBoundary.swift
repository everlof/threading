import AppKit

enum L10n {
    static func string(_ value: String) -> String { value }
    static func format(_ key: String, _ arguments: CVarArg...,
                       locale: Locale = .current) -> String {
        String(format: string(key), locale: locale, arguments: arguments)
    }
}

/// The native project row is shared with macOS. Its title roles resolve through the
/// Linux MorphingTitleLabel adapter; the numeric count retains its own fixed font.
@MainActor
enum ProjectRowLinuxTypography {
    static var countFont: NSFont {
        NSFont.monospacedDigitSystemFont(ofSize: SidebarRowDefaults.countFontSize, weight: .regular)
    }
}
