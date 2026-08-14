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
