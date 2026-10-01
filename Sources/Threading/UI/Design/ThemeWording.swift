import AppKit

// MARK: - Theme Wording

/// What the theme in force says in the two places a theme may speak (`ThemeWords`), with the
/// app's own copy as the answer whenever it says nothing.
///
/// Read at the moment the words are used — a turn starting, a composer emptying — rather than
/// pushed, because both are already re-read at exactly those moments: a theme switch changes the
/// next turn's word and the next empty composer's invitation, and nothing on screen mid-turn.
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
        let stated = words?.composerPlaceholder?.trimmingCharacters(in: .whitespacesAndNewlines)
        return stated?.isEmpty == false ? stated : nil
    }

    private static var words: ThemeWords? {
        let theme = AppThemePalette.current
        guard !theme.isSystem else { return nil }
        return theme.variant(for: NSApp.effectiveAppearance)?.words
    }
}
