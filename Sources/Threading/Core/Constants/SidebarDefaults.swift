import AppKit

// MARK: - Sidebar Defaults

public enum SidebarDefaults {
    /// What the *list* needs: an icon, an indented name, and the row's two trailing buttons.
    ///
    /// Not where the column actually stops. The window controls float over the sidebar at a
    /// fixed x, so the real floor is where they end — claimed at runtime by
    /// `MainWindowController.updateSidebarMinimumThickness`, which can only ever raise this.
    public static let minWidth: CGFloat = 180

    /// The legacy product-side width ceiling. **Not a limit on the divider, saved user geometry,
    /// or extension hints**: the split item sets no maximum, the restore path trusts the saved
    /// divider, and extensions publish their own public range. Keeping this value documents the
    /// former product cap for callers which still need that scale; applying it to the split item
    /// stopped the divider dead in open space, which read as a broken drag rather than a decision.
    public static let maxWidth: CGFloat = 400
    public static let defaultWidth: CGFloat = 240

    /// Shared brand slot for the Mac theme art and Linux sidebar mark.
    public static let brandLogoSide: CGFloat = 24

    public static let rowHeight: CGFloat = 28
    /// Every sidebar dropdown's floor, so the short menus read as the same control as the
    /// long ones.
    public static let menuWidth: CGFloat = 190
    /// Project rows are a single line — the branch shows in a hover popover, not beneath the
    /// name — so one compact height covers them all.
    public static let projectCompactRowHeight: CGFloat = 30
    /// A repository root above its checkouts, and the archive heading, get extra height,
    /// which reads as space between groups.
    public static let headingRowHeight: CGFloat = 32
    public static let indentationPerLevel: CGFloat = 14

    /// Where the repository roots the user folded away are remembered, by repository identity.
    /// A `PreferenceStore` key, not a `.standard` one — it records a user's choice.
    public static let collapsedRepositoriesKey = "sidebarCollapsedRepositories"

    /// The column width at and above which the list gives nothing up — the width the app opens
    /// itself to. Below it every gutter in `SidebarDensity` closes in step with the drag.
    public static let relaxedDensityWidth: CGFloat = defaultWidth

    /// The width at which the list has given up everything it will, when nothing has said
    /// otherwise: `minWidth`, the floor stated on the split item before the window controls are
    /// measured.
    ///
    /// **The app does not use this number.** `MainWindowController.updateSidebarMinimumThickness`
    /// raises the real floor to clear the toolbar buttons floating over the column — about 208pt
    /// — and the first version of the band ran to this value anyway, so the narrowest column a
    /// drag could reach was barely half way down it: the depth step bottomed out at 11 rather
    /// than 6, and two of the four reclaimable trailing points were never taken. A band whose
    /// tight end lies past the last reachable width is a set of values nobody ever sees. So the
    /// window controller hands the sidebar the floor it actually enforces
    /// (`ProjectSidebarViewController.densityFloor`) and this is the fallback for a list with no
    /// window controller over it — the extensions navigator, a test fixture.
    public static let tightDensityWidth: CGFloat = minWidth

    /// `indentationPerLevel` at the floor. Still a step the eye reads as a level — a session
    /// under a branch under a project keeps two visible steps — while returning 16pt of title to
    /// the deepest rows, which are the ones that truncate first. Type carries the rest of the
    /// depth: emphasized projects, caption headings, regular sessions.
    public static let tightIndentationPerLevel: CGFloat = 6

    /// How much of the padding the `.inset` style keeps *outside* the cells goes back to the
    /// content at the floor — see `ThemedOutlineView.trailingCellReclaim`.
    ///
    /// Measured, and bounded by the selection capsule rather than chosen: the style holds 16pt
    /// past every cell's trailing edge, and the capsule this list draws closes to
    /// `SidebarRowDefaults.tightHoverHighlightInsetX` (6) at the same end of the band. Content
    /// may move out into that band but must stay inside the shape a selected row fills, so 8pt
    /// is what there is to take — it leaves the cell ending 8pt from the column's edge, two
    /// points clear of the capsule. The two close together, so the clearance falls from six
    /// points to two and never below. `SidebarWidthDensityTests` holds that margin at both ends,
    /// because the number above is only safe as long as it does.
    public static let tightTrailingCellReclaim: CGFloat = 8

    /// The compact tree's one content edge, measured from the column's leading side.
    ///
    /// Wide enough that the disclosure chevron — kept, because collapsing a project is the
    /// affordance the indentation was paying for — fits in a fixed gutter before it, and equal
    /// to `SidebarRowDefaults.iconSlotWidth` so the gutter reads as the same column the row
    /// icons align down.
    ///
    /// **This one does not narrow with the column** (`SidebarDensity`), and the chevron is why:
    /// AppKit draws it 13pt wide at `compactMarkerLeading`, so the gutter already ends one point
    /// after the mark it holds. There is no space here to lend the title — a tighter edge would
    /// draw the chevron over the icon beside it.
    public static let compactCellLeading: CGFloat = SidebarRowDefaults.iconSlotWidth

    /// Where the compact tree's disclosure chevrons sit, all depths alike.
    public static let compactMarkerLeading: CGFloat = Design.Spacing.hairline

    /// How far before a disclosure chevron a press still folds its row — see
    /// `ThemedOutlineView.disclosureHitOutsets`. A top-level chevron in the indented tree sits
    /// 12pt in from the column's edge, and that strip used to select the row; this hands all of
    /// it to the chevron. The trailing side is the row's own leading gutter
    /// (`SidebarDensity.rowLeadingInset`), which ends where the icon or title begins.
    public static let disclosureLeadingHitOutset: CGFloat = Design.Spacing.inset

    /// The extra height a group-opening row takes in the compact tree, standing in for the
    /// indentation that no longer says where one project ends and the next begins. Centred
    /// content splits it above and below, the same way `headingRowHeight` already reads as
    /// space between groups.
    public static let compactGroupSpacing: CGFloat = Design.Spacing.inset

    /// How far below a compact group row's top edge its rule is drawn — inside the added
    /// spacing, nearer the group it closes than the title it introduces.
    public static let compactGroupRuleOffset: CGFloat = Design.Spacing.tight

    /// 1pt rather than the theme's rule weight, the same choice `Design.Chat.turnDividerHeight`
    /// makes for the same reason: this separates rows inside one pane, and a border's weight
    /// would read as a box around the group rather than a fold between two.
    public static let compactGroupRuleHeight: CGFloat = 1

    /// Breathing room between the header band's hairline and the first row — applied as the
    /// navigator's own `contentBreathing`, inside the well's fill, never as a layout gap
    /// above the scroll view: outside the well the pane's ground shows, and a strip of it
    /// below the header's rule reads as the band bleeding through its border.
    public static let contentTopInset: CGFloat = 4

    /// The header's arrangement control — the platform's "use groups" glyph, which is the
    /// closest thing the menu behind it (grouping, then sorting) has to one name.
    public static let arrangementSymbol = "square.grid.3x1.below.line.grid.1x2"

    /// The scratchpad. A notepad rather than a folder glyph, because the row it stands for is
    /// deliberately the one thing in the list that is not a checkout.
    public static let scratchpadSymbol = "note.text"

    /// The footer's silence gate says the current answer in its mark as well as its surface.
    /// The filled on-state keeps the toggle legible as a control; the speaker/slashed-speaker
    /// pair makes the sound state itself legible without having to infer what the frame means.
    public static let soundsAudibleSymbol = "speaker.wave.2"
    public static let soundsSilencedSymbol = "speaker.slash"

    public static func silenceSymbol(isSilenced: Bool) -> String {
        isSilenced ? soundsSilencedSymbol : soundsAudibleSymbol
    }

    /// How hard the sidebar holds its width against a window resize.
    ///
    /// The sidebar behaviour arranged this for itself; a plain split item does not, and without
    /// it both panes grew when the window did — a sidebar that widens with the window is a
    /// sidebar the user has to keep putting back. One step above the default settles it in
    /// favour of the terminal, which is the pane that should absorb the change. The same
    /// reasoning and the same step as `DisplayPaneDefaults.holdingPriority`, at the other end
    /// of the window.
    public static let holdingPriority = NSLayoutConstraint.Priority(
        NSLayoutConstraint.Priority.defaultLow.rawValue + 10
    )

    public static let renameFieldWidth: CGFloat = 260
    /// The same height every other single-line field draws — see `Design.Size.fieldHeight`.
    public static let renameFieldHeight: CGFloat = Design.Size.fieldHeight

    /// Hint shown in the list area while no project has been added.
    public static let emptyTitleFontSize: CGFloat = 13
    public static let emptySubtitleFontSize: CGFloat = 11
    public static let emptyStateSpacing: CGFloat = 4
    public static let emptyStateInset: CGFloat = 20
}
