import Foundation

/// One family of app themes, as every picker files them.
///
/// A theme picker is a list of nearly thirty rows, and a flat list of thirty names says nothing
/// about why any of them are near each other. A section says it once, over the rows it
/// introduces — which is also what lets those rows stop repeating it in their own titles: the
/// custom ones used to carry `— Custom` and the contributed ones the name of the extension that
/// shipped them, the longest thing on the line and identical down the whole group.
///
/// Grouping here costs no navigation. A `ThemedMenuEntry.header` is not a submenu, so a theme is
/// still one press away — see [`docs/architecture/themes.md`](../../../../docs/architecture/themes.md).
public struct AppThemeSection {

    /// The head drawn over the section's rows, or nil for a group that carries none.
    ///
    /// Presentation-ready, not a key: a section may be named after the extension that ships its
    /// themes, and an extension called "Custom" must not come out of a string table as
    /// something else. The stock families localize their own titles where they are stated.
    public let title: String?

    public let themes: [AppTheme]

    public init(_ title: String, _ themes: [AppTheme]) {
        self.title = title
        self.themes = themes
    }

    /// A group that carries no head.
    public init(_ themes: [AppTheme]) {
        self.title = nil
        self.themes = themes
    }
}
