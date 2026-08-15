import AppKit

/// A control whose frame carries padding around its visible ink — a plain `ThemedButton` holds
/// room for its hover surface, a `ThemedIconButton` for its click target. Layout that wants the
/// *ink* at a stated inset has to know how deep that padding is, or every container repeats the
/// subtraction with a number it does not own: the sidebar footer read as unevenly inset for as
/// long as its two buttons were placed by their frames, and a section rule gained another six
/// points beside every menu row. Equal frame margins and gaps are not equal visual ones.
///
/// Both axes are required deliberately. A new padded control cannot compile after declaring
/// only the edge case its first caller happened to need, leaving the same geometry bug for the
/// first vertical stack that reuses it.
@MainActor
protocol OpticalInsetProviding {
    /// Horizontal distance from the frame's edge to the visible content inside it.
    var opticalHorizontalInset: CGFloat { get }

    /// Vertical distance from either frame edge to the visible content when a container gives
    /// the control `frameHeight`. It is a function because a row may promote a control above its
    /// intrinsic height while its title or glyph keeps the same measure.
    func opticalVerticalInset(forFrameHeight frameHeight: CGFloat) -> CGFloat
}

/// The vertical half of aligning by ink: a control that draws its own text and promises that
/// `firstBaselineAnchor` reports the line that text is actually set on — which for a view that
/// draws in `draw(_:)` is a promise, not a given, because `NSView`'s default baseline is its
/// frame edge. Conforming without overriding `firstBaselineOffsetFromTop` hands Auto Layout a
/// lie the compiler cannot see; the conformance and the override travel together.
@MainActor
protocol TextBaselineProviding: NSView {}

/// The rule a pane band answers text alignment with, stated once for the header and the
/// footer.
///
/// A band centres its controls — their plates and glyphs set the band's rhythm, and moving a
/// control off centre to serve its title would tilt every hover surface in the chrome. But
/// *loose text* in a band exists only to be read with the control beside it, and centring two
/// point sizes never puts them on one baseline: the DEV build mark sat a point above the
/// Settings title it reads with, and the attachments scope caption the same above its toggle.
/// So the first control that states a text baseline anchors the band's line, stays centred,
/// and every bare label sits on that line instead of on its own centre. A band with no such
/// control centres everything, as before.
@MainActor
enum PaneBandTextAlignment {
    /// The view whose title line the band's loose text sits on, if the band has one.
    static func anchor(among views: [NSView]) -> NSView? {
        views.first { $0 is TextBaselineProviding }
    }

    /// Whether `view` is loose text that joins the anchor's line rather than centring itself.
    /// A single-line label is text by construction; composite views and controls keep the
    /// band's centre.
    static func joins(_ view: NSView, anchoredBy anchor: NSView) -> Bool {
        view !== anchor && view is NSTextField
    }
}
