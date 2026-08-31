import AppKit

// MARK: - Sidebar Density

/// How tightly the sidebar draws itself at the width its column currently has.
///
/// The column is a drag away from any width between `SidebarDefaults.tightDensityWidth` and
/// whatever the terminal can spare, and the list's fixed geometry was measured against the width
/// it opens at. Dragged narrow, that geometry spends the same points on gutters and depth steps
/// while the only thing anyone reads — the title — is what gives way, so a session two levels
/// deep truncates to a few characters with 30pt of structural space beside it.
///
/// The answer is a fraction rather than a second layout: nothing switches at a threshold, the
/// gutters and the depth step simply close in step with the drag. The fraction is 0 at
/// `relaxedDensityWidth` and 1 at the narrowest the column goes, and every metric is that
/// fraction of the way from its relaxed value to its tight one, rounded to whole points so text
/// stays on the pixel grid.
///
/// **The value is what it draws, and nothing else.** The fraction behind it is an input, not
/// state: two widths that round to the same numbers *are* the same density and compare
/// equal, which is what lets a live divider drag skip every pass that would move nothing. Storing
/// the raw fraction alongside made 209pt and 209.4pt different values that drew identically, and
/// restamped every row on screen for each of them.
///
/// **The band ends where the drag does.** The fraction is 1 at the narrowest width the split
/// view actually allows, which is a runtime measurement rather than the constant below it — see
/// `init(width:floor:)`.
///
/// **This is not the compact tree.** `NativeSidebarPipelineOptions.compactTree` is a choice about what the
/// list says with depth at *any* width, and it flattens the tree outright; this is the same tree
/// fitted to the column it has. They compose: in the compact tree the depth step is already gone,
/// so a narrow column tightens only the row gutters. That tree's own edge does not move — see
/// `SidebarDefaults.compactCellLeading`, which is already the chevron's width.
struct SidebarDensity: Equatable {

    // MARK: - Properties

    /// The outline's per-level step. Read by the ordinary indented tree; the compact tree has
    /// already given its depth away.
    let indentationPerLevel: CGFloat

    /// A row's leading gutter: the gap between the disclosure chevron and the row's icon.
    let rowLeadingInset: CGFloat

    /// A row's trailing gutter: the gap between its status mark or hover actions and the seam
    /// the sidebar ends at.
    let rowTrailingInset: CGFloat

    /// How much of the `.inset` style's own trailing padding the cells take back — the larger
    /// half of that gap, and not the row's to give: see `SidebarDefaults.tightTrailingCellReclaim`.
    let trailingCellReclaim: CGFloat

    /// How far the capsule a selected or hovered row is filled with stands off the column's two
    /// edges — the outermost thing the list draws, and the only metric here that closes for how
    /// the column *looks* rather than for what the title can hold.
    ///
    /// The list draws that shape itself in every theme, which is what makes this the sidebar's
    /// to fit: under **System** it used to be AppKit's, a plain view hung in the row at a fixed
    /// 10pt whatever the column was doing. It bounds `trailingCellReclaim`, since content moving
    /// out into the style's trailing band must stay inside the shape a selected row fills.
    let selectionInsetX: CGFloat

    // MARK: - Initialization

    /// The list at the width it opens to: every metric at its measured value.
    static let relaxed = SidebarDensity(compaction: 0)

    /// `compaction` outside 0...1 is clamped, so a column wider than it opens at and one pushed
    /// past its floor both draw the density at that end rather than extrapolating past it.
    init(compaction: CGFloat) {
        let fraction = min(max(compaction, 0), 1)

        func fitted(_ relaxed: CGFloat, _ tight: CGFloat) -> CGFloat {
            (relaxed + (tight - relaxed) * fraction).rounded()
        }

        indentationPerLevel = fitted(
            SidebarDefaults.indentationPerLevel,
            SidebarDefaults.tightIndentationPerLevel
        )
        rowLeadingInset = fitted(
            SidebarRowDefaults.leadingInset,
            SidebarRowDefaults.tightLeadingInset
        )
        rowTrailingInset = fitted(
            SidebarRowDefaults.trailingInset,
            SidebarRowDefaults.tightTrailingInset
        )
        trailingCellReclaim = fitted(0, SidebarDefaults.tightTrailingCellReclaim)
        selectionInsetX = fitted(
            SidebarRowDefaults.hoverHighlightInsetX,
            SidebarRowDefaults.tightHoverHighlightInsetX
        )
    }

    /// The density a column of this width draws at, given the narrowest it can be dragged to.
    ///
    /// **The floor is an input because the split view's is measured, not stated.** It is raised
    /// at runtime to clear the window controls floating over the column
    /// (`MainWindowController.updateSidebarMinimumThickness`), which puts it some 28pt above
    /// `SidebarDefaults.tightDensityWidth` — and a band ending below the last reachable width
    /// spends only part of itself: the column stopped at 208pt while the arithmetic was still
    /// halfway between the two ends, which is the whole of why the tightest list nobody could
    /// get to looked like the list at 240. A floor at or above the opening width leaves every
    /// metric relaxed, which is the right answer for a column that cannot be narrowed at all.
    init(width: CGFloat, floor: CGFloat = SidebarDefaults.tightDensityWidth) {
        let band = SidebarDefaults.relaxedDensityWidth - floor
        guard band > 0 else {
            self.init(compaction: 0)
            return
        }
        self.init(compaction: (SidebarDefaults.relaxedDensityWidth - width) / band)
    }
}

// MARK: - Sidebar Density Adopting

/// A sidebar view that holds its own gutters and can restate them without being rebuilt.
///
/// The rows are the half of the density AppKit does not own: the outline places the cell and the
/// chevron, and everything inside the cell is the row's. A conforming view keeps the two
/// constraints the density moves rather than baking the constants in, so a width change is a
/// constant assignment on the rows currently on screen — not a reload.
///
/// Both halves of a row conform: the cell for its content gutters, and the row view under it for
/// the capsule it draws a selection and a hover into.
@MainActor
protocol SidebarDensityAdopting: AnyObject {
    func applySidebarDensity(_ density: SidebarDensity)
}
