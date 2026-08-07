# Window Chrome

The toolbar, the pane headers, why the sidebar is a plain split item — and the takeover, where
a theme draws the frame itself.

In **native dress** (every theme that states no chrome) this
boundary is app-owned exactly where it should be: the full-height sidebar ground, split rule,
headers, and toolbar item views are themed; `NSWindow`, traffic lights, resizing, sheets, and
full-screen integration remain AppKit's. This file long recorded "replacing the window frame
would remove behavior, not system-coloured application chrome" — that judgement still holds
*as a default*, and it is why the takeover below is an **opt-in a theme states**
(`WindowChromeStyle`, 2026-08) rather than a rewrite: the System theme and every existing theme
keep the native frame untouched, and the removed behaviours are re-provided deliberately, one
by one, where the takeover is worn. See [The takeover](#the-takeover-a-theme-that-draws-the-frame).

Part of the [CLAUDE.md](../../CLAUDE.md) index.

The window uses `.fullSizeContentView` with a transparent, hidden title bar, so the sidebar
runs the full height and the traffic lights float over it. The window title stays `Threading`,
since it is only surfaced where macOS names the window (Mission Control, the Window menu).

**The titlebar's double-click is ours, because those two flags together take AppKit's away.**
Measured across all four combinations of `.fullSizeContentView` and `titlebarAppearsTransparent`
in a window otherwise identical to this one, a click 22pt below the top edge hit-tests to
`NSTitlebarView` in three of them and to the **content view** in the fourth — which is this
window's pair. Zoom-on-double-click is implemented in the titlebar that click no longer reaches,
so the strip beside the traffic lights swallowed the gesture and did nothing with it: the one
window on the Mac that would not fill the screen when double-clicked. Neither flag is negotiable,
so `TitlebarActionWindow` performs the gesture itself.

It does so from `mouseDown` on the **window**, which AppKit calls only for a click no view
claimed — a double-click on a toolbar item, a traffic light, or anything a pane hangs under the
strip has already been handled and never arrives, so there is nothing to hit-test and nothing to
steal. The strip is `contentLayoutRect`, not a constant: what the platform held back for the
titlebar already accounts for the toolbar and the style it is drawn in. What the gesture *does*
is read from `AppleActionOnDoubleClick` rather than assumed, because the point of restoring it is
that this window behaves like every other one — including for someone who set it to Minimize or
turned it off, where a window that zoomed anyway would be the worse bug. `TitlebarDoubleClickTests`
pins the platform behaviour beside the fix, in the way `PaneHeaderTests` pins its own: if AppKit
ever hit-tests that strip to the titlebar again, the test says so and the class can go.

### A pane cannot be taller than its window

**A pane's content states a *required* minimum on the window itself.** A window with a content
view controller takes its minimum content size from that view's fit, so a column taller than the
pane does not overflow, scroll, or clip — it makes the **window** taller, and it does so with the
top edge held, which is to say downwards, off the bottom of the screen.

That is not a theoretical hazard, and the composer is where it was found. Its usage panel drew
one bar per rate-limit window plus one per metered model, and both lists are the provider's to
lengthen: measured on an unshown 420pt-tall window, five bars grew it to 561pt and twelve grew it
to 932. Past the screen's height the second half of the bug arrives from AppKit rather than from
here — `constrainFrameRect(_:to:)` pins an over-tall window's top edge back to the top of the
visible frame **every time it is moved**, so the window snaps to the top of the screen and resists
being dragged down. It was reported as two bugs ("the window grows off the bottom", "it jumps to
the top when I drag it") and was one.

The fix was a fitting pass that handed the panel whatever height the rest of the column had left.
**The panel is gone now** and so is the pass: the account's reading is one line inside the prompt
box's own footer, with the detail on its tooltip, so nothing in the composer grows with what a
provider reports. What is left is bounded by construction — a chip row, a box capped at
`Design.Size.inputMaxHeight`, and a one-line import offer under it — which is the stronger
version of the same rule: a pane that *cannot* grow without bound needs nothing to yield.

`ComposerWindowFitTests` keeps both halves: that the composer leaves the window the height it was
given, down to `WindowDefaults.minHeight`, and AppKit's `constrainFrameRect` behaviour, so if the
platform ever stops yanking the window the reason for the rule is gone with it.

**The toolbar holds only controls that act on the window itself, and everything else belongs
to the pane it describes.** `NSToolbar` positions its items relative to the *window*, which is
what makes it right for exactly two things: the sidebar toggle, which acts on the split rather
than on either side of it, and the selection-history pair (`<` `>`, ⌃⌘←/⌃⌘→), which retraces
the window's page selection — both stay beside the traffic lights in both collapse states. It
is wrong for everything else that used to live there: the page tab, the `+`, the usage pill
and the session's actions all name or act on the *content pane*, so at a fixed window x they
drift away from it the moment a divider moves.

Anything that joins the toolbar joins a measurement too, and now two: `windowControlsTrailingEdge`
answers where the window's own controls end (the **trailing-most** of the candidates, with
`PaneHeaderDefaults.assumedWindowControlsWidth` as the pre-layout fallback), and both
`updateHeaderInset` and `updateSidebarMinimumThickness` are that one answer applied to the two
panes. An item added without extending the candidate list puts the pane header's tab under the
new control — and lets the sidebar's divider cut through it.

**The sidebar's minimum width is those controls, not a number.** `SidebarDefaults.minWidth` is
what the *list* needs (icon, indented name, the row's two trailing buttons); the column actually
stops where the toolbar does, because the toolbar positions its items against the window and they
therefore stay put while the divider moves. At the 180pt list floor the divider ran through the
forward chevron — measured off the running window's accessibility frames, that chevron ends 198pt
from the window's leading edge — leaving half a button hanging over the terminal. So
`updateSidebarMinimumThickness` raises the split item's minimum to that edge plus
`Spacing.medium`, on the run-loop turn after setup and again on any split resize; it is
idempotent, and it can only ever raise the constant. Below that width there is no useful size
left, and there does not need to be: a divider pushed past the minimum shuts the column, so the
sizes are "as narrow as its controls" and then "gone" — see
[Dragging a pane shut](#dragging-a-pane-shut), which is where that push is turned into an
answer, and why `canCollapse` alone does not buy it.

A split item's minimum is a *required* constraint and therefore also a floor on the window's
width, so this costs the window the ~28pt the sidebar gained (see `DisplayPaneDefaults.slimmestWidth`
for the other end of that trade).

**The column has no ceiling of its own.** `sidebarItem.maximumThickness` is
`NSSplitViewItem.unspecifiedDimension`: a fixed 400 stopped the divider in open space with the
window nowhere near full, which reads as a broken drag rather than as a decision, and there is
nothing at 400 that the column stops being useful past. What it may take is what the terminal
can spare, and the terminal states that itself in `MainWindowDefaults.minContentWidth` — one
rule instead of two. `SidebarDefaults.maxWidth` survives as the ceiling on widths the *app*
proposes: a restored width, or an extension navigator's `preferredWidth`. How wide the user may
drag is a different question from how wide the app may open it unasked.

**And the width survives a relaunch.** The window's frame is autosaved, so a restart used to
bring the arranged window back with the column reset to 240. `SidebarWidth` records it on divider
movement and `restoreSidebarWidth` puts it back, both through `PreferenceStore` and for the same
reasons as `DisplayPaneWidth` — it is a choice made with a divider, and a hosted test must not
write it into the developer's own preferences. Two orderings are load-bearing: the restore runs
in the same run-loop turn that claims the floor, and `recordsSidebarWidth` stays false until it
has, or launch's default layout would overwrite the stored width one turn before it was read.

`NSTrackingSeparatorToolbarItem` hid that for years, and stopped the day the sidebar became a
plain split item: measured on macOS 26 across all three split-item kinds, it follows the divider
only when the pane beside it has `.sidebar` behaviour. Dragging the divider wider then slid the
sidebar out from under the tab and left it floating over the list.

So those controls moved into `TerminalContainerViewController`'s own header strip
(`setupHeader`, `PaneHeaderDefaults`), which cannot drift because it *is* the pane — no divider
is crossed and there is nothing to track. Two things this settles that measuring never could:
the header follows a **collapse** as readily as a drag, and it stops where the pane stops, so
the display panel's own strip lines up with it rather than sitting under a window-wide row.

The header's leading control is the **page tab** (`MainWindowController.pageTabView`): one
chip naming the current page — session, composer, or settings. Deliberately one, not a strip:
a page here swaps the whole workspace, so a row of them would be a second session switcher
duplicating the sidebar (see `sessions.md`, "Why Sessions Are Not Tabs"). It is the same
`ThemedTabItemView` the pane strips build from, inked from the backdrop, bounded by
`SessionTitleDefaults.minWidth/maxWidth`.

Before those actions sits a second, smaller group: **Open in** — the visible checkout handed to
the editor, terminal or Finder used last, with a chevron that picks another. It is a separate
group on purpose. The four buttons after it act on *this pane*; this one leaves for another app,
and six identical squares in a row would have said they were the same kind of thing. It is also
the only control in the strip carrying colour, because it wears the target app's own icon —
see [`external-apps.md`](external-apps.md).

The session actions at its trailing edge are one grouped control: **Context**, the renderer
switch, **Shell**, and **Panel**. Context does not maintain a toolbar-specific action list; it
calls `ProjectSidebarViewController.populateSessionActions`, the same builder as the row's hover
and right-click menus. The renderer button is the short path through the same
`SessionCoordinator.setUsesNativeUI` transition as that menu's Interface choices, and changes
its glyph and accessible name to describe the surface it will switch *to*.

The strip sits **under** the toolbar rather than in the titlebar. A view in the titlebar strip
is behind AppKit's own titlebar container, which is what this project's earlier hand-rolled
header ran into — it had to track the sidebar's collapse state and shift sideways to dodge the
traffic lights. Below the safe area there is nothing to dodge.

The style stays `.unifiedCompact`: the large `.unified` style sizes the system sidebar toggle
for a 15pt window title, dwarfing the quiet controls in the header below it.

Nothing may pin to `view.topAnchor` in either pane, or it lands under the toolbar — a bug this
project has already had once, where it hid the terminal's first rows. The sidebar pins to
`safeAreaLayoutGuide`; everything in the content pane pins to
`TerminalContainerViewController.contentTopAnchor`, which is the header's bottom, so the header
is the only place that knows how tall it is.

**A surface that covers the window has the same rule, and learned it the same way.** The media
inspector and the expanded comparison pinned themselves to `contentView`'s own top, which under
a full-size content view is the top of the *window*: their headers opened beneath the traffic
lights, title and controls both, and a picture said so where no assertion did. `InWindowOverlay`
is now the one place that decides where "over the window" starts, and the answer is per dress:
in native dress the safe area, toolbar included; in a takeover the app's own band, which carries
that window's close, minimize and zoom, plus the frame the theme draws around it. A modal that
covers the way out of the window is not a modal. `WindowChromeHostViewController` states the area
as a layout guide (`InWindowOverlayHosting`) rather than a number, written as two `>=` and a
low-priority pull upward so it answers `max` of the two edges *live* — a theme flipped while a
surface is open moves it instead of leaving it pinned to the dress it opened in.
`WindowChromeTakeoverTests` asserts one installed surface across the exchange.

**What the surface cannot cover, the scrim under it dims.** The strip it clears is not empty: in
native dress it holds the app's own header band, and left fully lit that band stacked directly on
the inspector's header with a hairline between them — a picture of the running app showed two rows
of chrome that read as one window rather than as something opened in front of it. So
`InWindowOverlay` installs a wash beneath the surface, over a *second* guide
(`overlayScrimArea`): everything below whatever draws this window's own buttons. In native dress
those are AppKit's, above the content view entirely, so the wash takes the whole of it, band
included; in a takeover they are the app's title band, so it starts under it and dims the command
row and workspace below. Dimming a way out of the window is fine. Swallowing the click that takes
it is the same bug as covering it, one step subtler — the wash eats every click it lies over, and
that click is the dismissal.

**A collapsed pane's divider is hidden, because at the window's edge it is not a seam but a bar.**
`NSSplitViewController` keeps a collapsed item's divider so it can be dragged back open — right
in the middle of a window, wrong at its edge, which is where both of this window's collapsible
panes live. The display panel starts collapsed (`displayItem.isCollapsed = true`), so its
divider sat hard against the window's **trailing** edge; the sidebar's lands on the leading one
the moment it is toggled shut. Measured off the running window that seam is `Design.Radius.border`
thick in the theme's rule ink — two to three points of RGB (16, 16, 16) down the full height,
byte for byte the same ink as the sidebar's own divider, and provably drawn rather than shadowed
(it stayed exactly that value over a bright wallpaper and a dark one). It also does not stop at
the corner: a straight dark bar ran through the window's rounded corners, which is how it was
reported — the top-right "isn't really rounded, it's cut off and turns black".

`SidebarSplitViewController.splitView(_:shouldHideDividerAt:)` hides any divider whose neighbour
is collapsed. *Hidden*, not merely undrawn: a divider that is only unpainted still takes its
thickness out of the layout, and the window's own background shows through the gap — the same
bar in the system's colour instead of the theme's. Neither pane loses a way back, because
neither is opened by dragging. `WindowEdgeTests` asserts it where the bug lived, on the pixels
of a real unshown window, and was checked against a stubbed-out fix to confirm the seam
reappears without it.

`SidebarSplitViewController` overrides `toggleSidebar(_:)` to route through its own
`setCollapsed(_:on:)`. The stock implementation collapses but does not restore here, which left
no way back to the sidebar. Overriding it fixes the toolbar button and the View menu together,
since both route through that one method.

### How a pane moves

**One route, stated once.** `PaneTransition` (`UI/Design`) is the single statement of how a
workspace pane comes and goes: the standard duration and curve, implicit animation for the
geometry laid out against the change, and a completion that runs one main-loop turn after
AppKit's own — because AppKit's completion fires before the split view commits its final model
frames, which is a lesson this window had already paid for. The sidebar and the display panel
run it through `SidebarSplitViewController.setCollapsed`; the shell drawer runs its height
constant through the same `run`. Before this, each pane moved its own way — the sidebar slid
from the toolbar and snapped at the divider, the panel always snapped, the drawer jumped — and
"how a pane moves" had been restated, differently, three times.

Two resolutions live inside the route rather than at every call site. **A window nobody can
see gets the final state at once**: AppKit has been measured withholding an off-screen window's
resize notifications and animation completions (`toggleSidebar`'s inset fallback exists for
exactly that), and the completions here carry real work — the panel's restored width, the
drawer's hidden band — so an unshown window skips the motion, which is also what keeps the
hosted fixtures deterministic. And **a session switch is not a gesture**: it swaps the whole
workspace at once, so `syncDisplayPane` and the drawer's session swap pass `animated: false`
— a pane sliding beside an instant page change would animate a change of subject as if it were
a change of state.

The panel's reveal keeps its width choreography on this route: the stored width is read while
the pane is still shut, the reveal animates the item out, and the completion makes the width
the divider's own answer through `applyDisplayPaneWidth` — the only holder that survives the
next layout pass — with `isRestoringDisplayPaneWidth` now held for exactly the transition
instead of a guessed two turns.

### How a sidebar row arrives, leaves and moves

**The list is told what changed, not rebuilt.** Every structural change to the projects and
sessions used to be `reloadData` plus a pass re-expanding everything: a session started or
archived, a project added, an agent finishing and reordering the list under Recent Activity —
all of it a blink, with every row handed back to the reuse pool and re-created in place. That is
the "jaggy" the sidebar was reported as. `ProjectSidebarViewController.reload` now diffs the
tree it is showing against the one the store describes and hands `NSOutlineView` the rows that
arrived, left and moved.

Three pieces make that possible, and the first is the one that is easy to miss:

- **Identity survives the rebuild.** The tree is rebuilt from the store on every structural
  change, and the outline identifies a row by *the object it was handed* — so a rebuild that
  replaces every node replaces every row, whatever it is called. `SidebarNodeKey` gives each
  node an identity the rebuild preserves (a repository by its identity on disk, not its name; a
  branch heading by project and branch) and `SidebarOutlineUpdate.adopt` hands the rebuild's
  content to the node already on screen wherever that identity survived. Without it there is
  nothing to animate, nothing for a name to morph *from*, and no expansion to keep.
- **The shape is the signature.** `SidebarTreeShape` replaced the structure string that could
  only answer "did anything move?". Answering *what* moved is the same walk, and a rename still
  compares equal and still takes the in-place row refresh.
- **The steps are ordered by phase**: every removal, then every move, then every insertion.
  Only that ordering makes the one change that names a row twice work — a session leaving a
  branch heading for the project above it is a removal *there* and an insertion *here*, and the
  row must not have to exist in both places at once. `SidebarOutlineUpdate.steps` never
  describes the children of a row it re-inserts: the outline reads that subtree from the data
  source, which is already showing the new tree.

**`.effectFade`, and nothing else**, measured against this list. `.slideUp`/`.slideDown` park
the arriving row at the very top of the view for the whole animation and snap it into place at
the end; `.effectGap` holds it invisible and pops it in. The fade is the only option that moves
the row it names. The rows *below* slide either way — AppKit animates them as a `position`
animation on their layers, which is the motion the eye actually follows — and the expansion of a
row that just arrived runs through `animator().expandItem` so its children come with it.

Unlike [a pane](#how-a-pane-moves), this does **not** stand down for a window nobody can see.
That rule exists because a pane's completion carries real work and AppKit withholds it
off-screen; nothing here waits on a completion, row animations were measured running *and
settling* in an unshown window, and standing down would leave every hosted fixture asserting a
motion the app does not perform. Reduce Motion still collapses the duration to zero and drops
the fade — the update stays incremental, because a reduced sidebar should not blink either.

**Animation is testable here, and `SidebarRowAnimationTests` tests it.** A row animation leaves
two marks: the arriving row's `alphaValue` ramps from zero, and each displaced row keeps a
`position` animation whose *presentation* is still behind the frame it has already been given.
Two things the fixture must get right — the outline has to have been **drawn** once or it has no
row views at all (and, once drawn, the displacement animates on the layer rather than on the
frame, so `frame` alone reports the destination), and nothing may be drawn **between** the change
and the assertion, since the change lands in microseconds and the motion lasts a fifth of a
second. Lag alone is not proof: a layer whose frame was set with no animation also reads as
behind until the next commit, so the animation object is what separates a row that is moving
from one that has just been put down.

### Dragging a pane shut

**The overshoot is the gesture.** Past its floor a pane stops dead under the pointer, which
keeps going; that gap is the only record of how hard the divider was pushed, because no frame
moved.

In the running app, a dragged divider had **never** shut this column — not "stopped working",
never, on the report of the person dragging it. Every collapse it had ever done came from the
toolbar, the View menu, or a test calling `setPosition`. AppKit is not flatly refusing, either:
driven through the same tracking loop in a fixture it collapses a `canCollapse` pane at *half
the pane's floor* (floor 207pt — released at 120 the column stayed, at 90 it shut), so the
machinery exists and something about the real window keeps it from firing. Worth knowing, not
worth depending on: that threshold sits a hundred points past a column that has visibly stopped,
travelled blind, which is not a gesture anyone would find.

`SidebarSplitViewController.shutPaneIfPushedPast` shuts a pane once the pointer is released
past the floor by `PaneTransition.dragShutsPane`'s answer — near enough to the stop that the
push is one movement. **Both of the divider's neighbours are candidates**: the sidebar is
pushed leftward past its floor, the display panel rightward past its own, and the middle pane
cannot collapse, so a push toward it answers nothing. The threshold is the shared
`PaneTransition.shutOvershoot`, **capped at half the pane's floor**: the panel's floor is its
48pt chrome, and the uncapped overshoot past that lies 12pt outside the window — a release the
pointer cannot reach when the window's edge meets the screen's. The shut itself is deferred one
turn of the run loop, because the release is still unwinding the divider's tracking loop and a
collapse begun inside that unwind applies its final state without its motion — the one shut in
the window that snapped while every other one slid. AppKit's rule stays underneath: if it ever
does fire, a longer push is still a push.

The shell drawer takes the same push at its own divider. Its height constraint clamps at the
floor while the pointer keeps going, so the container keeps the unclamped running total during
the drag and asks the same `dragShutsPane` on release — see [`sessions.md`](sessions.md) for
the drawer's half of it.

The drag itself stays AppKit's. `ThemedSplitView.mouseDown` calls `super`, which does not return
until its tracking loop has pulled the mouse-up — there are no gesture recognizers on this split
view, checked at runtime — and then reports the divider and where the release landed. The
release point is read from `NSApp.currentEvent`, the event that ended the loop, rather than
`NSEvent.mouseLocation`: they agree in the app, and only the first can be driven from a test.
That override is the one entry in `config/theme-boundary.json` for this file — the interactive
rule is right that a view answering `mouseDown` is usually a control, and this one routes no
activation of its own.

Which mechanism runs matters when reading tests. `setPosition(_:ofDividerAt:)` and `isCollapsed`
take the item's Auto Layout path and cannot see an overshoot at all, so a test written against
them passes over a gesture that is broken — which is exactly what happened here.
`testPushingTheDividerPastTheSidebarShutsIt` and `testStoppingAtTheSidebarsFloorLeavesItOpen`
drive the real tracking loop by queueing events on the window before entering it.

Double-click is gone for good and is not worth restoring:
`splitView(_:shouldCollapseSubview:forDoubleClickOnDividerAt:)` is deprecated since macOS 10.15
with "this delegate method is never called".

**A pane shut at its divider never reaches `toggleSidebar`**, so the toolbar's toggle is lit
from `splitViewDidResize` (`updatePaneToggleSelection`) rather than only from the action. That
is deliberately the two `isSelected` lines and not the full control pass, which reads the
session store and would do so on every tick of a drag.

**The sidebar is a plain split item, not `NSSplitViewItem(sidebarWithViewController:)`**, and
that single line is the whole of its silhouette. On macOS 26 the sidebar *behaviour* draws the
pane as a floating inset panel — rounded, held off the window's edges by a margin, with the
content pane visible around it — and there is no property to decline it (`allowsFullHeightLayout`
and `titlebarSeparatorStyle` both leave the inset). That is the platform's look for a panel over
a document, and the wrong shape for a structural column beside a terminal: the margin left the
toolbar's tab and controls reading as loose parts, and the terminal's colour ran underneath the
sidebar it is meant to sit next to. So the pane is ours — flush to the window's edges, full
height under the transparent titlebar, the split view's rule as the only seam. That rule is the
theme's, in weight as well as ink — `ThemedSplitView` overrides `dividerThickness` so the seam
between two panes matches the rules drawn inside them (see [`themes.md`](themes.md)); AppKit's
`.thin` divider is a fixed point,
which under a heavy-ruling style was the one hairline in a window of 2pt rules.

Three things the behaviour supplied and now have to be stated, each found by losing it:

- **The ground.** `ProjectSidebarViewController.applySidebarSurface` installs a
  `SidebarBackdropView`, which decides for itself what the column is: the platform's own
  `.sidebar` material under the identity theme — the half of the lost behaviour that was worth
  replacing by hand — and an opaque `Surface.background` fill under a style, where frost would
  sample the desktop through a palette the theme never chose.
- **The width.** `SidebarDefaults.holdingPriority` is one step above the default, or a window
  resize widens the sidebar along with the terminal. The behaviour arranged this for itself.
- **The table's own material.** `outlineView.style` is `.inset`, not `.sourceList`: the two draw
  the same rows and the same selection capsule, and `.sourceList` adds a vibrant background *of
  its own*. Stacked inside a matching material it was invisible; over an opaque ground it became
  the sidebar's whole appearance, sampling the desktop through the window. Proven by filling the
  ground with flat red — everything the list covered stayed grey-blue.

The sidebar's scroll view also sets `automaticallyAdjustsContentInsets = false`. It is pinned to
the safe area already, so AppKit was insetting it a second time for the same titlebar — and on
macOS 26 that also installs a scroll-edge-effect `NSVisualEffectView` *inside* the scroll view,
which `ThemeBoundaryAudit` correctly refuses. One pane, one answer about its own insets.

**The sidebar's top band carries the brand; its bottom band carries global utilities.** The header
band (`PaneHeaderView`, pinned to the safe area under the transparent titlebar) holds
`SidebarBrandView` at its leading edge — the Threading mark, drawn live and stitched in once
per launch, beside the app's name in a `MorphingTitleLabel`, or whatever the current theme's
`SidebarStyle.Brand` states instead (see [`themes.md`](themes.md)) — and the list's two
controls at its trailing edge: the `+` that adds a project (its two-way menu on the press,
the platform's menu gesture) and the arrangement control. The band long held *no* app-name
label on the argument that it should carry only controls that act on the list; the brand
earned the slot when the sidebar's top-left became a themed surface — it is the one thing a
chrome can sign. Adding a project moved up from the footer with it, into the slot every
source-list app puts its `+`. The footer stack holds **Settings**, icon *and* word, at the leading
margin, with conditional app-wide workspace utilities directly above it. **Current Theme** is the
first such utility and appears only while a built-in theme MCP tool is enabled; it opens the
living theme document in the trailing panel rather than entering settings mode. In settings mode
the list's controls hide with the list they act on, but the band and the brand stay — a header
that vanished took the logo with it — and the settings section list starts below the band rather
than at the safe area.

**Both sidebar bands measure their margins from the pane, not from the platform's safe area.**
`PaneHeaderView`/`PaneFooterView` default to `layoutGuide(for: .safeArea(cornerAdaptation:))`,
which is right for a band whose ink can meet the window's curve — and wrong for these two, for a
reason the name hides: measured inside a real window on macOS 26, that region holds the whole
**window-controls width** clear (≈81pt at the leading edge of a `.fullSizeContentView` window
with a toolbar), for the band's entire height, whether or not the traffic lights are anywhere
near it. The sidebar's bands begin *below* the titlebar, so both were paying an allowance
neither needed: the brand started under the toolbar's sidebar toggle and Settings sat two steps
inboard of every row between them, and one column read as three. `PaneBandMargin.paneEdge` says
to measure from the band's own edges instead; `PaneHeaderTests` pins the platform measurement
that makes it necessary, so if the OS ever stops reserving that width the reason is gone with it.

The brand row is also the mark's pointer target. `SidebarBrandView` tracks the whole row — a
24pt logo is too small to ask a pointer to find deliberately — and drives `ThreadingMarkView`:
a held lift on enter, and on press a turn of exactly one strand-step, which the mark's six-fold
symmetry makes free (the model value never moves, so nothing is left rotated). The press is the
whole action: the brand names the window and opens nothing, which is why the row stays
`.staticText` and carries a documented `interactiveComponent` exception in
`config/theme-boundary.json` rather than becoming a `ThemedControl` with a focus ring and an
accessibility action for a press that does nothing.

Sidebar rows deliberately leave `NSTableCellView.textField` unset. Assigning it lets the table
restyle the label on selection, which tints an unemphasized source-list row with the accent
colour; the filled selection shape is the only cue wanted. Each row view's `applyTextColors`
owns the colours instead, inverting only for `.emphasized`.

**`.emphasized` means "the window is in front", not "the sidebar has focus"** — AppKit's own
answer is the second one, and this window takes focus away on every click, which is what made the
sidebar's selection need a second click to look like one. The rule is not the sidebar's: every
list in the app holds its rows to its window's key state through `ListSelectionStrength`, and the
rows read `isEmphasized` and draw. See [`design-system.md`](design-system.md), *a list's selection
follows its window*.

A session row's trailing edge is one fixed-size slot holding the status indicator and the
`⋯` actions button overlaid, crossfaded on hover via `alphaValue` rather than `isHidden` —
a stack view detaches hidden arranged views, so toggling visibility would re-lay out the row
under the pointer.

## The takeover: a theme that draws the frame

A theme stating a `WindowChromeStyle` (a `chrome:` block on its variant — the second and last
regional block after `SidebarStyle`, following all of its rules) opts the main window out of its
native frame. `WindowChromeCoordinator`, owned by `MainWindowController` and observing
`AppThemeDidChange`, performs the exchange in both directions, live. **Windows 98**
(`retro-98`) was the first user; **Mac OS 9 Platinum** (`platinum-9`) adds split window boxes,
a hidden application icon, and striped centred-title texture; **BeOS R5** (`beos-r5`) adds a
partial-width leading title tab and the period's Close/Zoom-only window furniture through the
same regional model; **OPENSTEP 4.2** (`openstep-42`) adds ordered bookends so Miniaturize can
lead while Close trails, plus its own one-bit control figures; **IRIX Indigo Magic**
(`irix-indigo-magic`) combines a dithered italic title with a leading Window-menu operation and
trailing Minimize/Maximize boxes; **Amiga Workbench 3.1** (`amiga-workbench-31`) adds the
Intuition gadget alphabet and the real Depth operation beside Zoom.
The mechanism and its authorable vocabulary are the feature; stock themes are worked examples.

**The masks.** Native is what `createWindow` always made:
`[.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]`. Takeover keeps every
bit AppKit can still serve behind a frameless window —
`[.closable, .miniaturizable, .resizable]` — so edge-resize, the Dock genie, and `performClose`
semantics stay AppKit's. Only `.titled` (traffic lights, rounded corners, toolbar mount) and
`.fullSizeContentView` (meaningless without a titlebar) leave.

**Flip ordering is load-bearing.** The toolbar detaches *before* `.titled` leaves and returns
only *after* it is back — an attached `NSToolbar` on an untitled window is an AppKit exception.
The mask assignment can nudge the frame and drops key status, so both are captured before and
re-asserted after (`makeKeyAndOrderFront` only for a window actually visible — a hosted test's
unshown window must not be ordered on screen by a theme change). `.fullScreenPrimary` is
inserted on entry (a frameless window is not fullscreen-capable on its own) and the prior
collection behaviour restored on exit. A window *inside* fullscreen never has its mask touched:
the change is parked and completed from `windowDidExitFullScreen`, because a mid-fullscreen
mask flip detaches the window from its space. A takeover theme active at launch is honoured at
**creation** — `AppThemeLibrary.restore()` runs before `MainWindowController` exists, so the
window is born frameless and nothing flips.

**What is re-provided, and where.** `TitlebarActionWindow` answers `canBecomeKey`/`canBecomeMain`
unconditionally (a frameless `NSWindow` refuses both); its double-click machinery goes inert by
geometry (frameless `contentLayoutRect` covers the whole content) and the gesture moves to the
band. `WindowTitleBandView` re-states the titlebar's obligations one for one: a press drags the
window (`performDrag`), a double-click performs `TitlebarDoubleClick.preferredAction`, the band
dims through its inactive gradient when the window resigns key, and the title follows
`window.title` by observation. The band also interprets theme-stated button placement,
application-icon visibility, title slant, and active/inactive texture; it contains no stock-theme ID
branches. It also interprets a full-width or leading-tab shape, authored tab width, and the
ordered visible-button set. `split` gives Close its classic-Mac leading exception; `bookends`
instead preserves authored order by leading with the first visible operation and trailing the
rest. A leading tab owns a fixed-width layout guide: title and buttons
centre within the yellow tab while its remaining top shoulder stays transparent. The frame
draws the rectangular application body below it, and `WindowChromeCoordinator` makes the
window backing nonopaque only for that shape so the system shadow follows the silhouette.
`WindowChromeButton` (window menu/close/minimize/zoom/depth) calls the **semantic**
operations — `zoom(nil)`, `miniaturize(nil)`, `orderBack(nil)`, delegate-consulted `close()` — because the
`perform*` forms animate a standard button a frameless window does not have and refuse outright
(measured; the buttons were dead until this). The zoom button follows `window.isZoomed` and
draws/names itself Restore while zoomed. `WindowChromeFrameView` draws the border, and
draws nothing at all in native dress, where the terminal-palette backdrop showing through the
titlebar strip is load-bearing.

**Nothing holds a frameless window on the screen.** `constrainFrameRect(_:to:)` — where AppKit
keeps a frame inside the screen's `visibleFrame` — returns its argument untouched the moment
`.titled` leaves the mask. Measured against a 1728×1084 visible frame: a titled window asked for
`{{0, -2302}, {1728, 3386}}` is given `{{0, 0}, {1728, 1084}}`; the same window frameless keeps
every point of it. A saved frame arrives through the one door that is never policed for *any*
window — `setFrameUsingName` does not call `constrainFrameRect` at all — so a frame written once
oversized is restored verbatim on every launch after it. That shipped: the window came back 3386
points tall on a 1084-point screen with its composer 2302 points below the bottom of the display,
and came back that way again after a relaunch. It was reported as a window stuck too tall that
would not resize, which is what it looks like from outside — dragging the top edge down does
shrink it, but the bottom edge is off screen and the composer never returns, and the frameless
window has no clamp to put it back. Nothing in the panes held it *down*: `MainWindowSizingTests`
builds the real controller and drags it to `WindowDefaults.minHeight`. So
`TitlebarActionWindow.constrainFrameRect` performs AppKit's own two steps for the untitled case —
size into `visibleFrame`, then move inside it (`MainWindowFrame.held`) — and `applyInitialFrame`
holds the restored frame the same way. Fullscreen is excepted: AppKit sizes a fullscreen window
to the screen's *full* frame, menu bar included, and holding that inside `visibleFrame` would
shrink a window the platform had just sized on purpose. The held frame is asserted **equal** to
what AppKit gives a titled window across the same rectangles, so the two cannot drift.

**What wrote 3386 was found the next day, reported as "opening one session throws the window
off the screen".** The attachments pane's preview stated an image's *fitted height* — unbounded —
on a `.defaultHigh` (750) constraint, and AppKit reads a window's minimum size out of every
constraint it finds at `windowSizeStayPut` (500) and above. Opening a session whose panel
previewed a full-page screenshot therefore resized the window to the picture, and while that
session stayed selected every layout pass re-asserted the demand — which with the clamp above is
also why the window then *snapped back* wherever the user dragged it: layout regrew it downward
from its top edge, the clamp held the giant frame inside `visibleFrame` again, and the two met at
"pinned to the top of the screen, immovable". Both of the pane's content-derived heights now sit
below 500 (`SessionAttachmentsDefaults.previewHeightPriority` / `listHeightPriority`), and
`SessionAttachmentsLayoutTests` hosts the pane in a real (unshown) window and asserts a
4000-point screenshot cannot move it — measured, the old priority grows that fixture to 3396.
The pane's own detached fixtures passed throughout, because a detached fixture's frame is
`required` while a hosted window's size merely *stays put*. The rule this leaves behind: **a
constraint whose constant is derived from content may not carry a priority above 500 anywhere in
the window's own layout tree** — above 500 it is not a preference inside a pane, it is the pane
resizing the window. The clamp stays: it is what makes the next writer's mistake recoverable
rather than permanent.

**A pixel-art glyph is not a vector glyph with antialiasing disabled.** Windows 95/98 drew its
caption figures from Marlett (`0` Minimize, `1` Maximize, `2` Restore, `r` Close) inside a 16×14
button on the default 18px caption band. The Windows family therefore carries explicit one-bit
artwork: a 6×2 sill, a 9px framed window with a 2px title rail, and the Close mark's 2px stepped
diagonals. The first implementation derived a roughly 7×7 canvas from the generic 18×16 slot;
it was technically pixel-snapped but visibly too small and too light. Other retro families keep
their own one-bit alphabets rather than borrowing Marlett, and every raised hard-retro button
moves its figure one pixel with the face when pressed.

Workbench's Depth role remains opt-in. It sends the current window behind its peers and is not
folded into Minimize, so a custom theme can state the original stacking operation without
changing the standard three-button default inherited by older documents.

The Window-menu role is not an `NSMenu` exception inside the frame. It presents semantic
`ThemedMenuItem` values through `ThemedMenuPresenter`, keeping every pixel app-owned and making
the operations menu follow custom themes exactly like the window that opened it.

**The content root is permanent.** `WindowChromeHostViewController` is the window's
`contentViewController` in *both* dress states — assigning a content controller resizes the
window (`applyInitialFrame`), so the root must never be swapped mid-flip. In native dress the
title and command bands are hidden at zero height and the frame inset is zero, which is geometrically identical to
the workspace being the root; `WindowChromeComponentTests` pins that. This also moves the
chrome tree inside `ThemeBoundaryAudit`'s reach, which is the point: an app-drawn frame is
app-owned surface.

**The measurements answer differently.** In takeover nothing floats over the panes — no
traffic lights, no toolbar — so `windowControlsTrailingEdge()` answers 0, the header inset is
the plain `PaneHeaderDefaults.inset` in both sidebar states, and the sidebar's floor falls back
to `SidebarDefaults.minWidth`. The zero safe area becomes steady state: the content header's
999-priority constraint and its 40pt floor (written as a launch transient) now size the strip
permanently, and `WindowChromeTakeoverTests` states it so it stops being luck. The window's own
controls (sidebar toggle, history pair) rehome into `WindowCommandBandView`, a button-face row
below the title bar, as fresh `ThemedIconButton`s inked from `InkSource.chrome`. The title band
therefore carries only app icon/title and caption buttons, matching the structural distinction
the native toolbar previously supplied and avoiding a toolbar button's required 28pt height
conflicting with the caption row's compact height. The controller's weak references re-point so
`updateToolbarControlStates()` never learns which dress is worn. `PaneBandMargin.paneEdge`'s
corner-adapted clearance is left alone in v1: harmless over-inset under square corners.

**Scope.** Main window only. The Component Gallery and Onboarding windows keep native chrome
under every theme; `ThemedAlertPanel`/`ThemedPopover` were already frameless and app-drawn.
Fullscreen under takeover keeps the band visible (it lives in the content tree; auto-reveal is
titlebar machinery a frameless window does not have).
