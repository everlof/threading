import AppKit

public enum SidebarRowDefaults {
    /// Preserve a readable location fragment even beside a long branch.
    public static let worktreePathMinimumFraction: CGFloat = 0.3

    public static let projectFontSize: CGFloat = 13
    public static let headingFontSize: CGFloat = 11
    public static let sessionFontSize: CGFloat = 12
    public static let countFontSize: CGFloat = 11

    /// Hugging low enough that a stack unambiguously stretches this view over its siblings.
    public static let stretchableHugging = NSLayoutConstraint.Priority(rawValue: 1)

    /// Marks a session forked from the one it is nested under.
    public static let sideChatSymbol = "arrow.triangle.branch"
    public static var sideChatAccessibilityLabel: String { L10n.string("Side chat") }

    /// Marks a session held ahead of the ordinary sidebar order.
    public static let pinnedSymbol = "pin.fill"
    public static var pinnedAccessibilityLabel: String { L10n.string("Pinned") }

    /// Revealed on hover, opening the row's actions.
    public static let actionSymbol = "ellipsis"
    /// Revealed on hover beside the `⋯`, filing the session away in one press.
    ///
    /// Archiving is the one row action reached often enough to be worth a button of its own;
    /// it stays in the menu too, so the two surfaces cannot drift.
    public static let archiveSymbol = "archivebox"
    public static var archiveAccessibilityLabel: String { L10n.string("Archive session") }
    /// The `+` on a project row's hover, opening its new-session choices.
    public static let createSymbol = "plus"
    /// Revealed on hover over a branch heading, opening the grouping options.
    public static let settingsSymbol = "gearshape"
    /// Applied to secondary text when inverted on an emphasized selection.
    public static let secondaryTextAlpha: CGFloat = 0.7

    // The three below were 7, 5 and 8 — none of them on `Design.Spacing`'s scale, which is
    // deliberately small (4/6/10/12) precisely so a row cannot drift a point away from every
    // other row in the app. They were each measured against this one list rather than chosen,
    // which is how the `⋯` came to sit at a different inset from the `×` beside it in the
    // toolbar. On the scale now, at the nearest step in each case.
    /// Resolved metrics also consumed by the Linux navigator's mounted bitmap rows.
    static let geometry = NavigatorRowGeometry(
        leadingInset: Design.Spacing.tight,
        iconSlotWidth: 16,
        contentGap: Design.Spacing.small
    )
    public static let horizontalSpacing: CGFloat = geometry.contentGap
    /// The outline view places the cell almost flush against the disclosure chevron, so the
    /// gap between them is owned here.
    public static let leadingInset: CGFloat = geometry.leadingInset
    public static let trailingInset: CGFloat = Design.Spacing.small

    /// The same two gutters at `SidebarDefaults.tightDensityWidth` — see `SidebarDensity`. One
    /// step on the scale rather than none: a row still holds its content off both edges, and the
    /// space between the chevron and the icon, and between the trailing mark and the seam, is
    /// what a narrow column can most afford to lend the title.
    public static let tightLeadingInset: CGFloat = Design.Spacing.hairline
    public static let tightTrailingInset: CGFloat = Design.Spacing.hairline
    public static let iconSize: CGFloat = 13
    /// Wider than `iconSize` so a 12pt emoji, whose glyph outgrows its font size, is not
    /// clipped at the slot's edges.
    public static let iconSlotWidth: CGFloat = geometry.iconSlotWidth

    /// One trailing column: the width of a row's status mark, and of each hover control beside it.
    ///
    /// The same target as every other nested icon button, rather than the 16 it used to be: a
    /// row's `⋯` and a tab's `×` are one control, and sizing this one where it was used is what
    /// made them differ. See `ThemedIconButton.Target.inline`.
    public static let trailingSlotSize: CGFloat = Design.Size.inlineButtonTarget
    /// Gap between the `+` and `⋯` when a project row shows both on hover.
    public static let hoverButtonSpacing: CGFloat = 2

    /// Expanded width of a *session* row's trailing slot: the `⋯`/archive pair, which takes the
    /// row's edge — archive outermost, in the same column the status mark occupies at rest.
    ///
    /// The pair and the status *crossfade in place* rather than standing side by side. That is
    /// what keeps this one geometry for every state: the archive button sits on the list's
    /// trailing margin on an idle row, a working one, and the row that raises
    /// `SessionLoadingState.presentation` the moment it is clicked — nothing steps aside and
    /// nothing steps back, because nothing *moves*; the marks trade visibility inside a column
    /// that never does. Activity is not erased by the swap where it matters most: the selected
    /// row — the one whose spinner lives under the pointer that just clicked it — wears its
    /// activity as the row's own beam ring, and every row's hover card still names its state.
    ///
    /// At rest the row reserves only `trailingSlotSize` for the status. It pays this full width
    /// while the buttons are visible, when yielding that title space describes what is actually
    /// on screen rather than taxing every truncated title for controls nobody can see.
    public static let sessionTrailingSlotWidth: CGFloat = trailingSlotSize * 2 + hoverButtonSpacing

    /// Expanded width of a *project* row's trailing slot: the `+ ⋯` pair, which takes the row's
    /// edge because the count it replaces is not durable state the way a session's status is.
    ///
    /// Stated as the pair's full width rather than one button's, so both buttons lie inside the
    /// slot. A button pinned to the slot's edge and allowed to overhang it draws perfectly and
    /// cannot be clicked at all: `NSView.hitTest` stops at the container's bounds, which is the
    /// same class of bug as the `⋯` the status dot used to swallow.
    public static let projectTrailingSlotWidth: CGFloat = trailingSlotSize * 2 + hoverButtonSpacing

    /// The selection and hover capsule's inset at the column's opening width.
    ///
    /// Measured off the source list's own shape, which this list drew inside for as long as it
    /// let AppKit fill a selected row: `.inset` hangs a plain `NSView` in the row at exactly
    /// (10, 0, width - 20, height) with an 8pt corner. The list now draws that shape itself in
    /// every theme (`SidebarHoverRowView.drawSelection`), so the number is a starting point
    /// rather than a constraint — see `tightHoverHighlightInsetX`.
    public static let hoverHighlightInsetX: CGFloat = 10

    /// The same capsule at the narrowest column — see `SidebarDensity`.
    ///
    /// The one metric here that is not about fitting more title in: at the width the column
    /// stops at, ten points of ground between a selected row and the seam beside it reads as a
    /// gap rather than as a margin. It closes with the drag like every other gutter, and stops
    /// one step above the row gutters inside it so the capsule never meets its own content.
    public static let tightHoverHighlightInsetX: CGFloat = Design.Spacing.small
    public static let hoverHighlightInsetY: CGFloat = 1
    /// The capsule's corner under the **System** theme alone, which has no `Design.Radius` of
    /// its own to state one — every other theme does, and takes it. See
    /// `SidebarHoverRowView.highlightRadius`.
    ///
    /// 8pt because that is what AppKit rounds its own source-list selection by: read off the
    /// view `.inset` hangs in a selected row, rather than eyeballed from a screenshot the way
    /// the 5 that stood here was.
    public static let systemHoverHighlightRadius: CGFloat = 8
    public static let hoverHighlightAlpha: CGFloat = 0.06
}
