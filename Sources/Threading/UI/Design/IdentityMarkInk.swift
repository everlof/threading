import AppKit

// MARK: - Identity Mark Ink

/// The one owner of how identity marks are inked under the theme in force
/// (`AppTheme.Material.identityMarks`): a project's generated tile, an agent's brand mark in a
/// session row and an account's initial chip.
///
/// Natural is every theme's answer so far — a hashed hue per project and account, an agent's own
/// brand colour. A theme whose world is one colour (a phosphor terminal, a newsprint page) states
/// `tinted`, and every *generated* mark is drawn in its accent instead. A picture the person chose
/// — a project icon, an account photo, an account colour picked in Settings — keeps its own
/// pixels: the theme recolours the app's defaults, never a person's choice. Marks are still told
/// apart by their shape: the initial, the agent's silhouette.
@MainActor
enum IdentityMarkInk {

    /// How far the accent is held back for a tinted tile's fill, so the lettering in full accent
    /// still reads on it.
    static let tileFillAlpha: CGFloat = 0.18

    /// Whether the theme in force inks identity marks in its accent, for `appearance`.
    static func isTinted(for appearance: NSAppearance) -> Bool {
        AppThemePalette.current.material(for: appearance).identityMarks == .tinted
    }

    /// The ink a tinted mark is drawn in.
    static var ink: NSColor { Design.Surface.accent }

    /// A tinted tile's or chip's fill: the accent held back over whatever it sits on.
    static var tileFill: NSColor { Design.Surface.accent.withAlphaComponent(tileFillAlpha) }
}
