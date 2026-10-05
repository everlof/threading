import AppKit

// MARK: - Theme Wording

/// What the theme in force says in the places a theme may speak (`ThemeWords`), with the app's
/// own copy as the answer whenever it says nothing.
///
/// Read at the moment the words are used — a turn starting, a composer emptying, a row filling
/// in — rather than pushed, because each is already re-read at exactly those moments: a theme
/// switch changes the next turn's word and the next empty composer's invitation, and the theme
/// sweep re-derives the rows still showing an untitled session.
@MainActor
enum ThemeWording {

    /// The list a working word is dealt from: the theme's own, cleaned, or the app's.
    static var workingWords: [String] {
        let stated = words?.working
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty } ?? []
        return stated.isEmpty ? WorkingWords.all : stated
    }

    /// The theme's invitation for an empty new-session composer, or nil for the app's own.
    static var composerPlaceholder: String? {
        composerPlaceholder(for: NSApp.effectiveAppearance)
    }

    static func composerPlaceholder(for appearance: NSAppearance) -> String? {
        let stated = words(for: appearance)?.composerPlaceholder?.trimmingCharacters(in: .whitespacesAndNewlines)
        return stated?.isEmpty == false ? stated : nil
    }

    /// The theme's name for a session nothing has named yet, or nil for "New Session".
    static var untitledSessionName: String? {
        untitledSessionName(for: NSApp.effectiveAppearance)
    }

    static func untitledSessionName(for appearance: NSAppearance) -> String? {
        let stated = words(for: appearance)?.untitledSession?.trimmingCharacters(in: .whitespacesAndNewlines)
        return stated?.isEmpty == false ? stated : nil
    }

    private static var words: ThemeWords? { words(for: NSApp.effectiveAppearance) }

    private static func words(for appearance: NSAppearance) -> ThemeWords? {
        let theme = AppThemePalette.current
        guard !theme.isSystem else { return nil }
        return theme.variant(for: appearance)?.words
    }
}
