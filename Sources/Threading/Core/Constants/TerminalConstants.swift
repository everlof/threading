import Foundation
import AppKit

// MARK: - Terminal Defaults

enum TerminalDefaults {
    static let columns = 80
    static let rows = 24
    static let scrollbackLines = 10_000
    static let defaultShell = "/bin/bash"
    static let defaultFont = "SF Mono"
    static let defaultFontSize: CGFloat = 13
    static let terminalType = "xterm-256color"

    /// Advertised to child processes so they emit colour. SwiftTerm renders 24-bit colour, and
    /// this is how a terminal declares it (iTerm2, Terminal.app and Alacritty all set it). It
    /// must be set explicitly rather than inherited: a GUI-launched app gets the launchd
    /// environment, which — unlike an interactive shell — carries no `COLORTERM`, so without
    /// this Claude Code and other tools fall back to monochrome.
    static let colorTerm = "truecolor"

    /// What Return sends to a PTY. Named because it is being *typed on the user's behalf* — by
    /// `SessionContextHandoff`, when a comment is sent rather than parked — and a bare `"\r"`
    /// at a call site reads like a line ending rather than like pressing a key.
    static let submitSequence = "\r"

    /// What Escape sends to a PTY, which every one of these TUIs reads as "stop this turn".
    ///
    /// Named for `submitSequence`'s reason and typed under a stricter rule, because this is the
    /// one keystroke Threading presses while the user is asleep. Only a curfew sends it, only
    /// into a terminal whose runtime claims `AgentCapabilities.escapeInterruptsTerminalTurn` and
    /// whose tracker reports a turn actually in flight, and never twice inside
    /// `CurfewDefaults.reinterruptSpacing`. The spacing is not politeness: a second Escape at an
    /// *idle* Claude Code prompt interrupts nothing and opens its rewind chooser, so the next
    /// thing typed lands in a list of checkpoints instead of in the conversation.
    static let interruptSequence = "\u{1b}"

    /// How long a turn waits after a pasted file path before Return is typed for it.
    ///
    /// Claude Code and Codex resolve a pasted image path asynchronously — they read the file
    /// and mint their own attachment — so a Return sent in the same runloop turn risks
    /// submitting the prompt while the picture is still arriving, and the agent would answer a
    /// comment about an image it was never given. The value is a guess at the safe side of that
    /// race, not a measurement: it is long enough to clear a local file read and short enough
    /// that the send still reads as immediate. Raise it if a sent comment ever arrives bare.
    static let pastedTurnSubmitDelay: TimeInterval = 0.35
}

// MARK: - Window Defaults

enum WindowDefaults {
    static let minWidth: CGFloat = 400
    static let minHeight: CGFloat = 300
    static let defaultWidth: CGFloat = 800
    static let defaultHeight: CGFloat = 600
    static let titleBarHeight: CGFloat = 22
}

// MARK: - Environment Keys

enum EnvironmentKeys {
    static let term = "TERM"
    static let colorTerm = "COLORTERM"

    /// `<foreground>;<background>`, as ANSI colour indices — rxvt's convention for telling a
    /// program whether it is drawing on paper or on ink. See `TerminalTheme.colorFGBG`.
    static let colorFGBG = "COLORFGBG"

    /// Says "the stream you are writing to is not a colour terminal", whatever it is set to.
    /// Inside a session that stream is a PTY Threading draws, so an inherited value describes
    /// wherever the *app* was started from and is never true of a session. Cleared rather than
    /// overwritten: absence is the only way to say "colour is fine".
    static let noColor = "NO_COLOR"

    /// The same claim, but only when spelled `0` — any other value is the user *asking* for
    /// colour and is left alone.
    static let colorVetoes = ["CLICOLOR", "FORCE_COLOR"]

    /// The other half of "nothing is watching this": a caller that cannot page sets these to a
    /// program that does not page. A session *can* page, so the claim is dropped there — and
    /// only there. On the headless path it is true, and `AgentEnvironment.launchEnvironment`
    /// leaves it alone.
    static let pagers = ["PAGER", "GIT_PAGER", "GH_PAGER"]

    /// How that claim is spelled. Anything else is a pager the user chose, which is theirs.
    static let nonPager = "cat"

    static let lang = "LANG"
    static let path = "PATH"
    static let home = "HOME"
    static let shell = "SHELL"
    static let columns = "COLUMNS"
    static let lines = "LINES"
}

// MARK: - Menu Identifiers

enum MenuIdentifiers {
    static let mainMenu = "MainMenu"
    static var projectMenu: String { L10n.string("Project") }
    static var editMenu: String { L10n.string("Edit") }
    static var viewMenu: String { L10n.string("View") }
    static var windowMenu: String { L10n.string("Window") }
    static var helpMenu: String { L10n.string("Help") }
}

// MARK: - Process Tree Defaults

enum SessionInfoDefaults {
    /// How often the info panel re-reads while it is on screen.
    ///
    /// Processes and ports raise no filesystem event, so the panel has to ask again rather than
    /// be told. Two seconds is short enough that a server started in the terminal appears about
    /// as fast as the eye moves to the pane, and long enough that the walk costs nothing
    /// noticeable — and it is also the window each CPU percentage is measured over.
    static let refreshInterval: TimeInterval = 2.0
}

// MARK: - AI Defaults

enum AIDefaults {
    static let maxOutputLength = 50_000
    static let requestTimeout: TimeInterval = 30
    static let ollamaDefaultURL = "http://localhost:11434"
    static let ollamaDefaultModel = "llama3"
    static let claudeDefaultModel = "claude-sonnet-4-20250514"
    static let openaiDefaultModel = "gpt-4"
}

// MARK: - Display Pane Defaults

enum DisplayPaneDefaults {
    /// Narrower than this is not a width anyone chose: a value below it in the stored geometry
    /// is read as "never set". Not the split item's minimum — see `slimmestWidth`.
    static let minWidth: CGFloat = 200

    /// The floor for a panel opening for the first time. What the panel is *for* — an image, a
    /// rendered report, a comparison — stops being legible below about this.
    static let defaultWidth: CGFloat = 440

    /// A first open takes this share of the window rather than one fixed number, clamped
    /// between `defaultWidth` and `widestOpening`. A panel that is a third of a 1600pt window is
    /// the same panel as a third of a 1200pt one; 440pt of either is two different panels, and
    /// on a large display it reads as a sliver stuck to the edge. Once the divider has been
    /// dragged, that width is the answer and this is not consulted again.
    static let openingFraction: CGFloat = 0.32

    /// The most a panel opens itself to. Past this it is taking the window rather than sharing
    /// it — and the user can still drag it wider.
    static let widestOpening: CGFloat = 620

    /// The footer's content dropdown floor, matching the Git Review overflow so the two panes'
    /// menus read as one control.
    static let contentMenuWidth: CGFloat = 190

    /// The panel's hard floor: its own chrome and nothing more.
    ///
    /// `NSSplitViewItem.minimumThickness` is a **required** constraint, and a window laid out
    /// with Auto Layout cannot be resized below what its required constraints ask for — so a
    /// pane minimum is also a *window* minimum. Measured: the window's minimum content width was
    /// 572pt with the panel shut and 773pt with it open at a 200pt minimum. `display_image`
    /// opens the panel, so showing a picture quietly cost 200pt of how small the window was
    /// allowed to be, which is not a price a panel gets to charge.
    ///
    /// At the pane's own chrome width the panel costs the window nothing it was not already
    /// paying, and a divider dragged past it still snaps the panel shut (`canCollapse`). The
    /// 200pt is still where it opens; it is simply no longer where the *window* stops.
    ///
    /// Stated as the parts rather than as the number they came to, because the parts are what
    /// moves it: the header's two trailing controls — `+` and the panel's own toggle — and the
    /// margin the row keeps from the pane's edge. The tab strip is not in the sum; it scrolls,
    /// and yields its whole width here (see `DisplayPaneController.setupConstraints`).
    ///
    /// Both are `.toolbar` icon buttons on the *session* header's margin, because the toggle is
    /// one control drawn in two headers and must not move between them (`DisplayPanelToggle`).
    /// That is 22pt more floor than the pane's own smaller buttons cost, and therefore 22pt of
    /// window minimum — the price of the corner control being the same button either way.
    @MainActor
    static var slimmestWidth: CGFloat {
        PaneHeaderDefaults.inset
            + Design.Size.toolbarButtonWidth
            + controlGap
            + Design.Size.toolbarButtonWidth
            + controlGap * 2
    }

    /// How hard the panel holds the width the divider was dragged to.
    ///
    /// `NSSplitViewController` positions its items with a constraint at the item's holding
    /// priority, and an ordinary view's content hugging is `defaultLow` — the *same* 250. A tie
    /// is what the panel had: drag it wider and on mouse-up the solver was free to prefer the
    /// labels' natural width, so the pane sprang back to whatever its content happened to want.
    /// One step above that settles it, and leaves the panel below the priority at which its own
    /// content resists being squeezed — the pane still stops at `minWidth`, it just no longer
    /// undoes the drag. The terminal keeps the default and so absorbs a window resize.
    static let holdingPriority = NSLayoutConstraint.Priority(
        NSLayoutConstraint.Priority.defaultLow.rawValue + 10
    )
    static let padding: CGFloat = 8

    /// The small square controls *inside* the pane — the footer's `⋯`, which sits with a caption
    /// rather than in the window's chrome. The header row's two are not this size: `+` and the
    /// panel's toggle are `.toolbar` icon buttons, because the session header across the split
    /// draws the same toggle and the two must land on one point (`DisplayPanelToggle`).
    static let buttonSize: CGFloat = 20

    /// The air between two of the header row's own controls — tighter than `padding`, which is
    /// what the row keeps from the pane's edge. One constant so `+`, the close and the strip
    /// beside them are spaced by the same hand.
    static let controlGap: CGFloat = 4
    static let titleFontSize: CGFloat = 11
    static let captionFontSize: CGFloat = 10

    /// The pane's one header row is its tabs and the `+` beside them: there was a titled header
    /// above the strip once, and it spent two rows of a narrow pane saying the name of the tab
    /// twice. The row's *height* is no longer stated here — `ThemedTabStripView.bandHeight`
    /// owns the strip band, one silhouette for every pane that draws tabs.
    static let tabChipMaxWidth: CGFloat = 180

    /// The "+" menu's floor, shared by every host that offers one.
    static let newTabMenuMinimumWidth: CGFloat = 160

    /// Agent-created content and browser tabs are capped independently so neither repeated
    /// rendering nor tab-opening can grow an unbounded strip or retain unbounded web processes.
    static let maximumContentTabs = 8
    static let maximumBrowserTabs = 8
}

// MARK: - Codex Discovery Defaults

enum CodexDiscoveryDefaults {
    static let rolloutPrefix = "rollout-"
    static let rolloutExtension = "jsonl"
    static let sessionMetaType = "session_meta"
    static let sessionIndexFile = "session_index.jsonl"

    /// Bound for Codex's one-record-per-thread title index. The real index is a few hundred
    /// kilobytes for thousands of conversations; this leaves ample growth without letting a
    /// corrupt file turn one title refresh into an unbounded read.
    static let sessionIndexScanLimit = 64 * 1024 * 1024

    /// Event recording a turn the user typed, as opposed to the copy replayed into the
    /// conversation behind the CLI's instruction blocks.
    static let userMessageType = "user_message"

    /// Codex writes the rollout file shortly after launch, so discovery retries briefly.
    static let pollInterval: TimeInterval = 0.25
    static let maxAttempts = 40

    /// Tolerance for the gap between our launch timestamp and the file's creation date.
    static let clockSlack: TimeInterval = 5.0

    /// The `session_meta` record is the first line, so only a prefix needs reading.
    static let headerReadLimit = 64 * 1024
}

// MARK: - OpenCode Discovery Defaults

enum OpenCodeDiscoveryDefaults {
    static let sessionIDPrefix = "ses_"
    static let sessionListLimit = 20
    static let pollInterval: TimeInterval = 0.5
    static let maxAttempts = 20
    static let commandTimeout: TimeInterval = 5
    static let maximumSessionListBytes = 512 * 1024

    /// OpenCode records creation timestamps at millisecond precision. Swift's launch timestamp
    /// has finer precision and may therefore compare fractionally later even when both reads
    /// occurred in the same millisecond; ten milliseconds covers only that quantization.
    static let clockSlack: TimeInterval = 0.01
}

// MARK: - Grok Discovery Defaults

enum GrokDiscoveryDefaults {
    static let sessionListLimit = 50
    static let pollInterval: TimeInterval = 0.5
    static let maxAttempts = 20
    static let commandTimeout: TimeInterval = 5
    static let maximumSessionListBytes = 512 * 1024
}

// MARK: - Terminal Padding

/// Inset between the terminal and the edges of its pane.
///
/// Slightly larger on the leading edge, which sits against the sidebar divider.
enum TerminalPadding {
    static let top: CGFloat = 6
    static let bottom: CGFloat = 4
    static let leading: CGFloat = 10
    static let trailing: CGFloat = 6
}

// MARK: - Project Store Defaults

enum ProjectStoreDefaults {
    /// Window over which rapid updates are merged into one write.
    static let saveCoalescingInterval: TimeInterval = 2.0
}

// MARK: - Sidebar Defaults

enum SidebarDefaults {
    /// What the *list* needs: an icon, an indented name, and the row's two trailing buttons.
    ///
    /// Not where the column actually stops. The window controls float over the sidebar at a
    /// fixed x, so the real floor is where they end — claimed at runtime by
    /// `MainWindowController.updateSidebarMinimumThickness`, which can only ever raise this.
    static let minWidth: CGFloat = 180

    /// The widest the app opens the column *itself* — restoring a stored width, or honouring an
    /// extension's preferred one. **Not a limit on the divider**: the split item sets no maximum,
    /// so a drag runs until the terminal reaches its own floor. A number here stopped the divider
    /// dead in open space, which reads as a broken drag rather than as a decision.
    static let maxWidth: CGFloat = 400
    static let defaultWidth: CGFloat = 240

    static let rowHeight: CGFloat = 28
    /// Every sidebar dropdown's floor, so the short menus read as the same control as the
    /// long ones.
    static let menuWidth: CGFloat = 190
    /// Project rows are a single line — the branch shows in a hover popover, not beneath the
    /// name — so one compact height covers them all.
    static let projectCompactRowHeight: CGFloat = 30
    /// Group headings (a repository above its checkouts, the archive) get extra height,
    /// which reads as space between groups.
    static let headingRowHeight: CGFloat = 32
    static let indentationPerLevel: CGFloat = 14

    /// The column width at and above which the list gives nothing up — the width the app opens
    /// itself to. Below it every gutter in `SidebarDensity` closes in step with the drag.
    static let relaxedDensityWidth: CGFloat = defaultWidth

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
    static let tightDensityWidth: CGFloat = minWidth

    /// `indentationPerLevel` at the floor. Still a step the eye reads as a level — a session
    /// under a branch under a project keeps two visible steps — while returning 16pt of title to
    /// the deepest rows, which are the ones that truncate first. Type carries the rest of the
    /// depth: emphasized projects, caption headings, regular sessions.
    static let tightIndentationPerLevel: CGFloat = 6

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
    static let tightTrailingCellReclaim: CGFloat = 8

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
    static let compactCellLeading: CGFloat = SidebarRowDefaults.iconSlotWidth

    /// Where the compact tree's disclosure chevrons sit, all depths alike.
    static let compactMarkerLeading: CGFloat = Design.Spacing.hairline

    /// The extra height a group-opening row takes in the compact tree, standing in for the
    /// indentation that no longer says where one project ends and the next begins. Centred
    /// content splits it above and below, the same way `headingRowHeight` already reads as
    /// space between groups.
    static let compactGroupSpacing: CGFloat = Design.Spacing.inset

    /// How far below a compact group row's top edge its rule is drawn — inside the added
    /// spacing, nearer the group it closes than the title it introduces.
    static let compactGroupRuleOffset: CGFloat = Design.Spacing.tight

    /// 1pt rather than the theme's rule weight, the same choice `Design.Chat.turnDividerHeight`
    /// makes for the same reason: this separates rows inside one pane, and a border's weight
    /// would read as a box around the group rather than a fold between two.
    static let compactGroupRuleHeight: CGFloat = 1

    /// Breathing room between the header band's hairline and the first row — applied as the
    /// navigator's own `contentBreathing`, inside the well's fill, never as a layout gap
    /// above the scroll view: outside the well the pane's ground shows, and a strip of it
    /// below the header's rule reads as the band bleeding through its border.
    static let contentTopInset: CGFloat = 4

    /// The header's arrangement control — the platform's "use groups" glyph, which is the
    /// closest thing the menu behind it (grouping, then sorting) has to one name.
    static let arrangementSymbol = "square.grid.3x1.below.line.grid.1x2"

    /// The scratchpad. A notepad rather than a folder glyph, because the row it stands for is
    /// deliberately the one thing in the list that is not a checkout.
    static let scratchpadSymbol = "note.text"

    /// The footer's silence gate says the current answer in its mark as well as its surface.
    /// The filled on-state keeps the toggle legible as a control; the speaker/slashed-speaker
    /// pair makes the sound state itself legible without having to infer what the frame means.
    static let soundsAudibleSymbol = "speaker.wave.2"
    static let soundsSilencedSymbol = "speaker.slash"

    static func silenceSymbol(isSilenced: Bool) -> String {
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
    static let holdingPriority = NSLayoutConstraint.Priority(
        NSLayoutConstraint.Priority.defaultLow.rawValue + 10
    )

    static let renameFieldWidth: CGFloat = 260
    /// The same height every other single-line field draws — see `Design.Size.fieldHeight`.
    static let renameFieldHeight: CGFloat = Design.Size.fieldHeight

    /// Hint shown in the list area while no project has been added.
    static let emptyTitleFontSize: CGFloat = 13
    static let emptySubtitleFontSize: CGFloat = 11
    static let emptyStateSpacing: CGFloat = 4
    static let emptyStateInset: CGFloat = 20
}

// MARK: - Sidebar Strings

enum SidebarStrings {
    static var emptyTitle: String { L10n.string("No Projects") }
    static var emptySubtitle: String {
        L10n.string("Drop a folder here, or click + above.")
    }
    static var arrangementOptions: String { L10n.string("Grouping and Sorting") }

    /// The silence gate's name, stable in both states: the button reports *which* state it is
    /// in through its accessibility value, the way every toggle does, so the title stays the
    /// one thing the control is. The tooltip below is the half that describes the state.
    static var silenceSounds: String { L10n.string("Silence Sounds") }
    static var silenceSoundsHint: String {
        L10n.string("Silence every sound Threading makes")
    }
    static var silencedHint: String {
        L10n.string("Sounds are silenced — banners and marks are unaffected")
    }
}

// MARK: - Sidebar Row Defaults

enum SidebarRowDefaults {
    static let projectFontSize: CGFloat = 13
    static let headingFontSize: CGFloat = 11
    static let sessionFontSize: CGFloat = 12
    static let countFontSize: CGFloat = 11

    /// Hugging low enough that a stack unambiguously stretches this view over its siblings.
    static let stretchableHugging = NSLayoutConstraint.Priority(rawValue: 1)

    /// Marks a session forked from the one it is nested under.
    static let sideChatSymbol = "arrow.triangle.branch"
    static var sideChatAccessibilityLabel: String { L10n.string("Side chat") }

    /// Marks a session held ahead of the ordinary sidebar order.
    static let pinnedSymbol = "pin.fill"
    static var pinnedAccessibilityLabel: String { L10n.string("Pinned") }

    /// Revealed on hover, opening the row's actions.
    static let actionSymbol = "ellipsis"
    /// Revealed on hover beside the `⋯`, filing the session away in one press.
    ///
    /// Archiving is the one row action reached often enough to be worth a button of its own;
    /// it stays in the menu too, so the two surfaces cannot drift.
    static let archiveSymbol = "archivebox"
    static var archiveAccessibilityLabel: String { L10n.string("Archive session") }
    /// The `+` on a project row's hover, opening its new-session choices.
    static let createSymbol = "plus"
    /// Revealed on hover over a branch heading, opening the grouping options.
    static let settingsSymbol = "gearshape"
    /// Applied to secondary text when inverted on an emphasized selection.
    static let secondaryTextAlpha: CGFloat = 0.7

    // The three below were 7, 5 and 8 — none of them on `Design.Spacing`'s scale, which is
    // deliberately small (4/6/10/12) precisely so a row cannot drift a point away from every
    // other row in the app. They were each measured against this one list rather than chosen,
    // which is how the `⋯` came to sit at a different inset from the `×` beside it in the
    // toolbar. On the scale now, at the nearest step in each case.
    static let horizontalSpacing: CGFloat = Design.Spacing.small
    /// The outline view places the cell almost flush against the disclosure chevron, so the
    /// gap between them is owned here.
    static let leadingInset: CGFloat = Design.Spacing.tight
    static let trailingInset: CGFloat = Design.Spacing.small

    /// The same two gutters at `SidebarDefaults.tightDensityWidth` — see `SidebarDensity`. One
    /// step on the scale rather than none: a row still holds its content off both edges, and the
    /// space between the chevron and the icon, and between the trailing mark and the seam, is
    /// what a narrow column can most afford to lend the title.
    static let tightLeadingInset: CGFloat = Design.Spacing.hairline
    static let tightTrailingInset: CGFloat = Design.Spacing.hairline
    static let iconSize: CGFloat = 13
    /// Wider than `iconSize` so a 12pt emoji, whose glyph outgrows its font size, is not
    /// clipped at the slot's edges.
    static let iconSlotWidth: CGFloat = 16

    /// One trailing column: the width of a row's status mark, and of each hover control beside it.
    ///
    /// The same target as every other nested icon button, rather than the 16 it used to be: a
    /// row's `⋯` and a tab's `×` are one control, and sizing this one where it was used is what
    /// made them differ. See `ThemedIconButton.Target.inline`.
    static let trailingSlotSize: CGFloat = Design.Size.inlineButtonTarget
    /// Gap between the `+` and `⋯` when a project row shows both on hover.
    static let hoverButtonSpacing: CGFloat = 2

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
    static let sessionTrailingSlotWidth: CGFloat = trailingSlotSize * 2 + hoverButtonSpacing

    /// Expanded width of a *project* row's trailing slot: the `+ ⋯` pair, which takes the row's
    /// edge because the count it replaces is not durable state the way a session's status is.
    ///
    /// Stated as the pair's full width rather than one button's, so both buttons lie inside the
    /// slot. A button pinned to the slot's edge and allowed to overhang it draws perfectly and
    /// cannot be clicked at all: `NSView.hitTest` stops at the container's bounds, which is the
    /// same class of bug as the `⋯` the status dot used to swallow.
    static let projectTrailingSlotWidth: CGFloat = trailingSlotSize * 2 + hoverButtonSpacing

    /// The selection and hover capsule's inset at the column's opening width.
    ///
    /// Measured off the source list's own shape, which this list drew inside for as long as it
    /// let AppKit fill a selected row: `.inset` hangs a plain `NSView` in the row at exactly
    /// (10, 0, width - 20, height) with an 8pt corner. The list now draws that shape itself in
    /// every theme (`SidebarHoverRowView.drawSelection`), so the number is a starting point
    /// rather than a constraint — see `tightHoverHighlightInsetX`.
    static let hoverHighlightInsetX: CGFloat = 10

    /// The same capsule at the narrowest column — see `SidebarDensity`.
    ///
    /// The one metric here that is not about fitting more title in: at the width the column
    /// stops at, ten points of ground between a selected row and the seam beside it reads as a
    /// gap rather than as a margin. It closes with the drag like every other gutter, and stops
    /// one step above the row gutters inside it so the capsule never meets its own content.
    static let tightHoverHighlightInsetX: CGFloat = Design.Spacing.small
    static let hoverHighlightInsetY: CGFloat = 1
    /// The capsule's corner under the **System** theme alone, which has no `Design.Radius` of
    /// its own to state one — every other theme does, and takes it. See
    /// `SidebarHoverRowView.highlightRadius`.
    ///
    /// 8pt because that is what AppKit rounds its own source-list selection by: read off the
    /// view `.inset` hangs in a selected row, rather than eyeballed from a screenshot the way
    /// the 5 that stood here was.
    static let systemHoverHighlightRadius: CGFloat = 8
    static let hoverHighlightAlpha: CGFloat = 0.06
}

enum ProjectTerminalDefaults {
    /// Process cwd is the fallback for shells that do not emit OSC 7 directory reports.
    static let directoryRefreshInterval: TimeInterval = 1
}
