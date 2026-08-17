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

The visual source of truth for each takeover is its manifest in
[`docs/references/chrome/`](../references/chrome/README.md). In particular, `aqua-cheetah` and
`aqua-tiger` are not aliases: Cheetah owns the four-row `aqua_pinstripes` glass rib while Tiger
adds the `brushed_metal` band texture, and each keeps its own component coverage so later evidence
about menus, fields, scrollbars, or alerts cannot silently rewrite the other target.

That archive is also the chrome conformance harness. Manifest-declared reproductions are rendered
by focused XCTest fixtures through the production `WindowChromeButton`, `ThemedScrollView`, and
other design-system components, then displayed beside the native-scale historical crops. A broad
`component_fixture` is deliberately review-only; only an `exact_reconstruction` with recorded
tolerance, method, and review date can advance a component to `verified`. The first shared sweep
covers caption controls and two-axis scrollbars across every historical takeover, and later
component families use the same contract rather than adding one-off screenshots.

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

### A control may not remove itself as part of its own press

The display panel's toggle is one control with two homes — the session header's group while the
panel is shut, the panel's own corner while it is open, at the same point of the window either way
(`DisplayPanelToggle`). It shipped as *two* buttons, each hidden for as long as the other was on
screen, and the gesture died: the toggle worked once and then ignored every further click until the
pointer moved off it and back. Hover kept working throughout, which is what made it look like a
drawing bug rather than an event one.

**AppKit sends every click after the first of a click chain to the view that took the first one.**
A chain is the run of clicks a person makes without moving the pointer far enough — or waiting long
enough — to break it, and it is what makes double-clicks reach one view. Measured in an isolated
150-line harness, with real posted clicks:

| arrangement | who received clicks 1…6 |
|---|---|
| the outgoing button `isHidden` (what shipped) | click 1 to the button; **clicks 2–6 to nobody** |
| the outgoing button left attached | all six to the same button |
| one button, moved between the two homes | all six to the same button |

The replacement standing at the identical point never sees them: the chain is not re-hit-tested, and
a chain whose view has left the hierarchy is dropped on the floor. `NSStackView` makes this easy to
walk into, because `detachesHiddenViews` is true by default — hiding an arranged subview removes it
from the view hierarchy outright.

So the two homes hold **one view** between them: the group hands it over, the panel's corner keeps a
same-sized slot for it, and `hostGround` tells it which ground it is standing on so it inks for the
chrome in the panel and for the terminal's backdrop in the header. `updatePaneToggleSelection` does
the move on every tick of a divider drag, and both directions are no-ops when the toggle is already
home.

The rule generalises past this control: **anything whose press changes which views exist under the
pointer has to leave the pressed view in place.** `ThemedIconButton` already carries the other half
of that lesson — its `releaseWatch` monitor exists because a row rebuilt between a press and its
release takes the release with it, which is the `⋯` that "needs three or four presses". Same
platform rule, one event earlier.

`DisplayPanelTogglePressTests` pins the property rather than the plumbing: pressing the toggle
leaves the same view under the pointer, at the same point, in both directions, and the window never
holds two views offering the switch.

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
is wrong for everything else that used to live there: the page's name, the usage pill
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
The stored value is snapshotted before that turn is queued. It is launch input; re-reading the
shared preference after yielding lets a late resize from another window replace the value being
restored with default geometry.

`NSTrackingSeparatorToolbarItem` hid that for years, and stopped the day the sidebar became a
plain split item: measured on macOS 26 across all three split-item kinds, it follows the divider
only when the pane beside it has `.sidebar` behaviour. Dragging the divider wider then slid the
sidebar out from under the tab and left it floating over the list.

So those controls moved into `TerminalContainerViewController`'s own header strip
(`setupHeader`, `PaneHeaderDefaults`), which cannot drift because it *is* the pane — no divider
is crossed and there is nothing to track. Two things this settles that measuring never could:
the header follows a **collapse** as readily as a drag, and it stops where the pane stops, so
the display panel's own strip lines up with it rather than sitting under a window-wide row.

The header's leading control is the **page's name** (`MainWindowController.pageTitleView`):
a mark, the current workspace page — session or composer — and the `⋯` that acts on it.
Deliberately one name, not a strip: a page here swaps the whole workspace, so a row of tabs
would be a second session switcher duplicating the sidebar (see `sessions.md`, "Why Sessions
Are Not Tabs"). It is inked from the backdrop and capped by `SessionTitleDefaults.maxWidth`.

**It was a tab, and every part of that grammar promised something the window does not do.**
A single chip drawn as a *selected tab* says it is one of a set with the rest just out of view;
the `+` beside it completed the promise, and did not keep it — pressed, it started a session
that took this page's place rather than joining it. The × had the same problem from the other
end, reading as "close this document" for a gesture that only empties the pane while the
session keeps running. So `PageTitleView` draws no plate at rest, carries no × and no `+`:
plain text on the pane's own ground, with a quiet plate appearing under the pointer because the
name *is* still pressable (it reveals its row in the sidebar, which is the question a page name
raises once the list has scrolled elsewhere). The actions did not go anywhere — ⌘N still starts
a session, the sidebar's per-project `+` still makes one in place, and ⌘W still clears the pane.
What went is three affordances that misdescribed them.

**The `⋯` sits against the name, not in the group at the far end.** Everything trailing in this
row answers "what is on screen" — an editor to leave for, an account's budget, four surfaces to
show or hide — while this menu acts on the page the header just named. Held at the other end of
a wide pane it read as a fifth pane toggle, with the thing it acts on 1,200pt away. It is the
same button and the same builder as before (`showSessionContextMenu`, which calls the sidebar
row's `sessionActionEntries`), and `MainWindowController.sessionContextToolbarButton` still
points at it so one state pass enables or stands down every control in the row.

**Settings is a mode, not a page.** It temporarily replaces the workspace and its sidebar,
and only one category can be visible; selecting another category replaces the same surface. A
closable category tab therefore promised multiple settings documents, made × mean “leave the
mode,” and repeated the category already named in both the sidebar and page heading. While the
mode is active the header instead shows a plain **Settings** label and an ordinary **Done**
button. Done, ⌘W, the ⌘, Settings command, and the sidebar's Settings button all take the same
return path, restoring the session or composer the mode covered.

**The label and Done sit at opposite ends of the row**, not side by side. The label takes the
leading slot the page's name would have had, which is where this row says what you are looking at;
Done goes to the trailing edge, after the pane's own controls, because leaving the mode changes
what is on screen and that is what everything trailing answers. Shipped beside the label it was
the only bordered button in the chrome and had nothing on either side of it to belong to — a
sheet's commit button left behind in a header, floating a third of the way across an otherwise
empty strip. The two views are one state: `setSettingsModeChrome(visible:)` shows and hides both,
because a caller that remembered only one would leave a Done button over a session's name.

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
is the only place that knows how tall it is. That height includes the active theme's pane-rule
weight *after* the tab's equal top and bottom margins; the row centres in the area above the rule,
and the component remeasures a live theme switch. A heavy rule is a boundary, not four points
taken from the lower margin.

The same boundary applies to Find. The old terminal placeholder attached a full-width bar to
`window.contentView.topAnchor`; in a `.fullSizeContentView` window that anchor is the titlebar,
so ⌘F covered traffic lights and window-owned controls while still being unable to search the
terminal buffer. Find now routes only to a visible surface with a real implementation: Browser
or Git Review. Each inserts the shared themed bar inside its own safe-area layout and moves its
own body below it. A surface with no search implementation does not enable the command.

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

**And the divider that comes back is not painted, because AppKit never asks for it.** The other
half of the same edge: a pane revealed from collapsed arrives at a strip that has been standing
inside the pane beside it, and nothing repaints it. Measured on a three-pane split, the reveal
resizes the panes and posts `didResizeSubviewsNotification` sixteen times through the transition
while `drawDivider(in:)` is not called once and `needsDisplay` stays false — so the strip keeps
the neighbouring pane's ground, and on a page whose panel and session pane are the same colour
the panel opened with **no visible edge at all**. It was reported as "the panel is invisible
until the first hover", which is the fingerprint rather than a second bug: pointing at a seam
invalidates it by hand (`activeDividerIndex`), so the first hover painted a seam that then
stayed painted. Nothing was wrong with the ink or the paint path; nothing had asked them to run.
`ThemedSplitView.repaintMovedSeams()` invalidates the seams from the notification it already
observes for the hover strips, which is the same geometry change for the same reason one line
later.

`SidebarSplitViewController` overrides `toggleSidebar(_:)` to route through its own
`setCollapsed(_:on:)`. The stock implementation collapses but does not restore here, which left
no way back to the sidebar. Overriding it fixes the toolbar button and the View menu together,
since both route through that one method.

**The panel's toggle asks for a session, because the panel's tabs belong to one.**
`view.displayPanel` is declared session-scoped, so the View menu already refused on a page with
no session while the toolbar's toggle did not: pressed on the start page under a project it
revealed a panel whose placeholder is the only thing it can ever show and whose `+` does
nothing, and which `syncDisplayPane` shuts again on the very next selection. The toggle now
follows the command's own scope. It stays live while a panel is *open*, whatever page is on
screen, because the app-wide theme document deliberately keeps one open with no session
selected — a control that cannot shut what it opened would be the worse bug.

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
the pane is still shut, then `geometryChanges` makes that width the divider's own answer inside
the same animation group that reveals the item. That is the only holder that survives the next
layout pass, and it avoids a reveal to the chrome floor followed by a second transition to the
remembered width. `isRestoringDisplayPaneWidth` is held for exactly that one transition instead
of a guessed two turns.

**The terminal's pixel frame moves; its character grid does not chase the animation.** A split
animation beside a full-screen Codex or Claude TUI used to turn each intermediate width into an
emulator reflow, PTY resize, SIGWINCH and process repaint. For a visible animated pane,
`MainWindowController` brackets the motion with
`EmojiFixedTerminalView.beginDeferringFrameGridChanges()` / `endDeferringFrameGridChanges()`.
The terminal remembers only the final natural grid and applies it once after the split settles.
The hold nests when the user reverses the pane before the first motion completes, and a remote
grid remains authoritative if phone control begins in the middle. Immediate, off-screen and
session-switch routes still resize once without a hold.

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
off-screen; the structural update waits on no completion, and standing down would replace the
incremental update with a visible blink when the sidebar returns. Reduce Motion still collapses
the duration to zero and drops the fade — the update stays incremental, because a reduced sidebar
should not blink either. On macOS 26 an unshown outline can retire `.effectFade` without restoring
the inserted row's model alpha from zero, and its animation-group completion is withheld there too.
One batched callback per structural pass normalizes the inserted identities one frame after the
measured duration; per-key tokens keep an older pass from cutting short a newer insertion of the
same row. Removing the fade or reusing its view can therefore no longer make an arrived row vanish.

**Animation is testable here, and `SidebarRowAnimationTests` tests it.** A row animation leaves
two marks: the arriving row's `alphaValue` ramps from zero, and each displaced row keeps a
`position` animation whose *presentation* is still behind the frame it has already been given.
Two things the fixture must get right — the outline has to have been **drawn** once or it has no
row views at all (and, once drawn, the displacement animates on the layer rather than on the
frame, so `frame` alone reports the destination), and nothing may be drawn **between** the change
and the assertion, since the change lands in microseconds and the motion lasts a fifth of a
second. Lag alone is not proof: a layer whose frame was set with no animation also reads as
behind until the next commit, so the animation object is what separates a row that is moving
from one that has just been put down. The fade assertion reads `NSView.alphaValue` at both ends:
zero while AppKit is presenting the arrival, and the durable one after the normalization beat.

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
That override is the one entry in `scripts/config/theme-boundary.json` for this file — the interactive
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
theme's in weight and starts from its rule ink; when that ink falls below the seam's visibility
floor — including System light on its own chrome ground — `ThemedSplitView` steps up to the
theme's border, and only where that is swallowed too does it measure neutral ink from the ground.
It overrides `dividerThickness` so the seam between two panes matches the rules drawn inside them
(see [`themes.md`](themes.md)); AppKit's `.thin` divider is a fixed point,
which under a heavy-ruling style was the one hairline in a window of 2pt rules.

**The ladder is measured the whole way down, and asks nothing about who owns the ground.** It
used to: a swallowed rule took the theme's border on the chrome and a neutral over a terminal
palette. Under System dark those grounds are the same `#1E1E1E` — the theme's `ground` role *is*
that palette's background — so the seam stood at (52, 52, 53) on a page with no session and
(98, 98, 98) the moment a session painted the window, over pixels that had not changed, beside a
sidebar whose own footer rule is (51, 51, 53). Selecting a session was enough to switch between
them, which is how it was reported. Two things were wrong. Ownership cannot answer a question
about visibility — and the first branch already keeps a theme's own hue over a foreign palette
wherever it reads there. And the neutral was taken whole: `WindowBackdrop.ink.rule` is the derived
*border* under a second name, 30% of whichever of black and white reads on the ground, so the
seam carried three times the ink of the theme's border and six times its rule. It now takes the
least of that tone which still clears the floor, bisected, never quieter than the theme's own rule
and never louder than the derived neutral — with Increase Contrast keeping the neutral whole.
`WindowBackdrop.isChromeGround` went with the branch; `Ground` stays an enum so the chrome case
still resolves its dynamic system role when read rather than at the swap.

**The seam also answers the pointer.** Wherever a press would begin dragging it, the divider
draws in the accent — the one control ready to act, and an extra hint beside the resize cursor
for a grab target that is otherwise the quietest line in the window; the shell drawer's strip
already made the same promise with its hover wash. "Wherever a press would attach" is asked of
`NSSplitView.hitTest` — the platform's own claim on the points around a divider, the same one
that turns the press into a drag and flips the cursor — rather than restated as a constant that
would drift the day AppKit widens its own. Measured, that claim runs about two points to either
side of a hairline. The seam stays lit for the whole of a drag (the overshoot past a pane's
floor generates an exit while the hand is still on the divider), goes out where the backdrop
would swallow the accent by stepping to the measured neutral instead, and never lights beside a
collapsed pane, whose hidden divider is not a target. `AppThemeTests`' pointer sweep asserts the
hint against `hitTest`'s answer point by point, so the two cannot disagree.

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
the platform's menu gesture) and the arrangement control. The column is shut from the
toolbar's toggle or ⌃⌘S rather than from a close of its own; the panel at the other edge of
the window carries one, and why the two differ is in
[`mcp-and-display.md`](mcp-and-display.md). The band long held *no* app-name
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
24pt logo is too small to ask a pointer to find deliberately — and drives `ThreadingMarkView`.
At rest it remains the crisp continuous vector. Hover crossfades it into the Weave particle
presentation: independently tinted points run around the canonical shield and inward on its six
canonical strands, so the flourish cannot drift from the application's silhouette. Leaving stops
the cadence and removes every repeating animation; nothing runs at rest. A deliberate dwell adds
a perspective pitch-and-yaw turn to the whole sampled box while Weave continues inside its local
coordinates — the object rotates in place rather than its dots orbiting around the centre. Press sends an
outer-to-core pulse through those points and turns the whole mark exactly one strand-step, which
the mark's six-fold symmetry makes free (the model value never moves, so nothing is left rotated).
The press is the whole action: the brand names the window and opens nothing, which is why the row stays
`.staticText` and carries a documented `interactiveComponent` exception in
`scripts/config/theme-boundary.json` rather than becoming a `ThemedControl` with a focus ring and an
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

A session row carries a filled pin after its title when the session is pinned, so a durable state
that already outranks every sidebar sort is not communicated only by position. The mark remains
outside extension-replaceable content and re-inks against an emphasized selection. Its trailing
edge overlays the status indicator and hover actions in one slot, crossfading via `alphaValue`;
the slot expands before the two actions appear and contracts after they leave, so invisible
controls do not permanently tax every title while visible targets never overhang their hit-tested
parent.

### The compact tree

**An opt-in trade: the indentation for a narrower column** (`AppSettings.compactsSidebarTree`,
off by default). Every row starts at `SidebarDefaults.compactCellLeading`, the disclosure
chevrons drop into a fixed gutter before that edge, and where one top-level group ends and the
next begins is said vertically — each root row adds `compactGroupSpacing` above itself, and a
1pt rule (`SidebarHoverRowView.showsGroupRule`, in the selection capsule's own horizontal
silhouette) marks every group but the first, whose upstairs neighbour is the header band's own
hairline. Type keeps carrying the levels the way it already does — emphasized projects,
caption headings, regular sessions. The rule is deliberately only between *top-level* groups:
one line weight, one meaning, and lines inside a project would turn the column into graph
paper.

Three decisions worth knowing before touching it:

- **The flattening re-places frames rather than zeroing `indentationPerLevel`.**
  `ThemedOutlineView.flattenedIndentation` asks `super` for the normal indented cell and
  marker frames and moves them — cell to the shared edge keeping its right side, marker to
  the gutter. Zeroing the indentation is the obvious route, and it leaves AppKit computing
  both frames from degenerate geometry nobody documents; the override keeps every input
  AppKit computes from exactly as it was. Deep rows also win back the trailing width their
  indentation used to spend.
- **Density is presentation, not shape, so it cannot ride `reload()`.** The tree builder
  never reads the setting and the nodes are untouched, which means the shape signature
  compares equal and `reload()` answers with a content refresh that moves no frame.
  `applyTreeDensity` takes its own route — the wholesale `applyStructure` pass — and the
  sidebar carries its one `AppSettingsDidChange` observer for it, value-guarded, where every
  tree-*shaping* setting still arrives as `ProjectsDidChange`.
- **Every root takes the group spacing, first included.** The first root needs none — nothing
  stands above it — but heights here may depend only on node kind, never on position: a root
  moving to or from the top during a diffed update must not change height mid-move. The rule
  is the one position-dependent bit, and it rides the row *view*, stamped at `didAdd` and
  re-stamped by `refreshGroupRules()` after every structural pass, because a moved row keeps
  its view.

`SidebarCompactTreeTests` holds all of it against the built row views — the shared edge, the
gutter, the heights, the rules, the live flip in both directions — plus light/dark renders
of the whole column at both densities, which is where the spacing and the rule are actually
reviewed, and the record of the trade the option makes.

### The list is fitted to the column it has

The compact tree is a *choice*; this is what happens without one. The list's geometry was
measured against the width the app opens to, and the divider goes considerably narrower — where
the same points are still spent on gutters and depth steps while the title, the only thing anyone
reads in a sidebar, is what gives way. A session two levels deep truncated to a few characters
with 30pt of structure beside it.

`SidebarDensity` closes that with a fraction rather than a second layout. Nothing switches at a
threshold: 0 at `SidebarDefaults.relaxedDensityWidth` (the width the app opens itself to), 1 at
the narrowest the split view allows, and each metric that far from its relaxed value to its tight
one — the outline's per-level step 14 → 6, a row's leading and trailing gutters 4 → 2 and 6 → 2,
8pt of the `.inset` style's own trailing padding handed back to the cells, and the selection
capsule closing from 10pt off each edge to 6. At the floor that is 30pt back for a session under a
branch heading.

**The floor is the split view's, and it is measured.** The band ran down to
`SidebarDefaults.tightDensityWidth` (180) while `updateSidebarMinimumThickness` was raising the
real minimum to clear the window controls floating over the column — about 208pt. So the tightest
list was a set of values no drag could reach: at the narrowest the app allowed, the depth step
drew 11 rather than 6 and two of the reclaimable trailing points were never taken, which is what
"the most compact sidebar still has so much inset per level" turned out to be. The window
controller now hands the sidebar the floor it enforces
(`ProjectSidebarViewController.densityFloor`, restated wherever that minimum is), and a toolbar
item added later moves both together. The constant remains the fallback for a list with no window
controller over it — the extensions navigator, a test fixture.

**The trailing side is mostly not the row's.** Measured at every width on macOS 26: the chevron
starts 12pt in and the cell follows it, so the leading side wastes nothing — but the style keeps
**16pt past every cell's trailing edge**, against a row gutter of six. That band is where the
space is, and what bounds it is the shape this list draws over it: a pin or `⋯` moved out past the
selection capsule would ride the edge of its own accent fill. So
`ThemedOutlineView.trailingCellReclaim` widens the cells by a stated number of points and never
past the row's edge, and the sidebar states 8 at the tight end — the cell ending 8pt in, two
points clear of a capsule that has closed to 6. The two close *together*, so the clearance falls
from six points to two and never inverts; `SidebarWidthDensityTests` walks the band and asserts
it, because the numbers are only safe while that holds. The mark itself moves out by the reclaim
plus what the row's own gutter can give: that gutter is measured to the button's ink and clamped
so the slot never overhangs the cell that hit-tests it, so the two do not simply add.

**The capsule is the list's own shape now, System included.** It was AppKit's there — `.inset`
hangs a plain `NSView` in a selected row at exactly (10, 0, width - 20, height) with an 8pt
corner, whatever the divider is doing, so the one thing the narrowest column most wanted back was
the one thing that could not move. `SidebarHoverRowView.drawSelection` no longer defers to
`super`; it fills `highlightPath` under every theme and only the *colour* still asks which theme
is in force (`Design.Surface.selectionFill` / `selectionFillUnemphasized`, the system's own
selection colours under System). Three things make that safe: overriding without calling `super`
is what stops AppKit inserting its capsule view at all, so there is never a second shape under
ours; hover and selection were already one silhouette and now are under System too, which
`SidebarRowHighlightTests` sweeps; and the corner under System is the 8 read off AppKit's own
view rather than the 5 that had been eyeballed. What it gives up is the vibrant blend on that one
fill.

Five things are load-bearing:

- **The value is what it draws.** Everything is rounded to whole points and the raw fraction is
  *not* stored, so two widths that draw identically compare equal. The first version kept the
  fraction as a stored property; 209pt and 209.4pt were then different densities with identical
  geometry, and every layout pass in a drag restamped every row on screen for no visible change.
- **A width change is O(rows on screen), never a reload.** `indentationPerLevel` and
  `flattenedIndentation` are read when a row is *built* and never re-read: measured on macOS 26, a
  change followed by `layoutSubtreeIfNeeded`, `tile()` or `noteHeightOfRows` leaves every mounted
  cell and chevron where it was, while `frameOfCell` already answers the new place.
  `reloadData(forRowIndexes:)` moves the cell and leaves the chevron behind. Only full
  `reloadData()` does both — and a wholesale rebuild per frame of a drag is not payable. So
  `ThemedOutlineView.refitIndentedRows()` applies the placement itself, over
  `enumerateAvailableRowViews`, and the rows' own gutters are constraint constants restated
  through `SidebarDensityAdopting`. Rows built later read the same geometry themselves, and the
  dequeue stamps every cell leaving the reuse pool with the current density.
- **Only the horizontal half is taken.** `frameOfCell`/`frameOfOutlineCell` answer in the
  *table's* coordinates; a cell and a chevron live in their row view's, where content sits at
  y 0. Assigning either frame whole drops every row's content by its own offset down the list —
  the render showed one clipped project row and nothing beneath it. Indentation is horizontal.
- **The trailing gutter stops at the row's own edge.** It is measured to the button's ink, so the
  slot is pulled out by the padding around the glyph; a gutter narrower than that padding would
  push the slot past the row, where it draws perfectly and cannot be clicked at all (`hitTest`
  stops at the bounds). Each row clamps at zero rather than letting the tight end overhang.
- **How far the style's band may be spent is the host's to say, not the outline's.** What bounds
  it is the silhouette the host draws over that band, so `trailingCellReclaim` takes a stated
  number of points and only ever widens; the sidebar picks 4 against its own capsule inset, and a
  list that drew a different selection would answer differently.

The compact tree's own edge does **not** narrow. `compactCellLeading` is already the chevron's
width — AppKit draws that mark 13pt at `compactMarkerLeading`, so the gutter ends one point after
the mark it holds. A tighter edge drew the chevron over the icon beside it; the two densities
compose by the compact tree taking only the row gutters.

`SidebarWidthDensityTests` holds the arithmetic and the built rows: the band's two ends and the
fraction between them, the depth and gutter a narrow column gives back, the style's padding it
takes and the capsule that bounds it, that the rows already on screen are moved rather than
rebuilt, that a row arriving after the drag is drawn for the column that exists, that the whole
band walked down and back lands exactly where it started, and light/dark renders of the column at
both ends with a pinned session selected — which is where how much a narrow sidebar actually wins,
and how the mark sits inside its own capsule, are reviewed.

## The takeover: a theme that draws the frame

A theme stating a `WindowChromeStyle` (a `chrome:` block on its variant — the second and last
regional block after `SidebarStyle`, following all of its rules) opts the main window out of its
native frame. `WindowChromeCoordinator`, owned by `MainWindowController` and observing
`AppThemeDidChange`, performs the exchange in both directions, live. **Windows 98**
(`retro-98`) was the first user; **Mac OS 9 Platinum** (`platinum-9`) adds split window boxes,
a hidden application icon, and striped centred-title texture; **Mac OS X 10.0 Aqua**
(`aqua-cheetah`) branches from that classic lineage with a four-row silver glass rib, leading
traffic-light gems, and a separate gel control language; **BeOS R5** (`beos-r5`) adds a
partial-width leading title tab and the period's Close/Zoom-only window furniture through the
same regional model; **OPENSTEP 4.2** (`openstep-42`) adds ordered bookends so Miniaturize can
lead while Close trails, plus its own one-bit control figures; **IRIX Indigo Magic**
(`irix-indigo-magic`) combines a dithered italic title with a leading Window-menu operation and
trailing Minimize/Maximize boxes; **Amiga Workbench 3.1** (`amiga-workbench-31`) adds the
Intuition gadget alphabet and the real Depth operation beside Zoom; **TUI** (`tui`) is the
first takeover that reproduces *nothing* — see [An authored takeover](#an-authored-takeover).
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
ordered visible-button set. `leading` keeps Aqua's complete traffic-light cluster at the start;
`split` gives Close its classic-Mac leading exception; `bookends`
instead preserves authored order by leading with the first visible operation and trailing the
rest. A leading tab owns a fixed-width layout guide: title and buttons
centre within the yellow tab while its remaining top shoulder stays transparent. The frame
draws the rectangular application body below it, and `WindowChromeCoordinator` makes the
window backing nonopaque only for that shape so the system shadow follows the silhouette.
The same transparent-backing path is used when `chrome.frame.corner_radius` is nonzero: the
permanent content root receives the radius and clips the workspace, while `WindowChromeFrameView`
clears and strokes the matching rounded outline. `chrome.frame.antialiases_corners` controls
whether that outline has smooth coverage or a one-bit stepped turn; older documents default to
smooth, and a zero radius remains the backwards-compatible square default.

**The backing is stated at birth as well as at the flip.** A shaped theme active at launch never
runs `enterTakeover` — `createWindow` builds the window frameless already and the coordinator
only reads that mask back — so for as long as the surface was set from the exchange alone, a
window born shaped kept the opaque backing and painted the part of its rectangle the frame had
just cleared. Measured under Tiger, launched with the theme on: the seven-point corner cleared
and stroked correctly, and the window's own backing filled the quarter behind it, so every corner
wore a white wedge inside a square outline; the same launch under BeOS left the shoulders beside
the title tab filled. It reads as a drawing bug in the corner and is not one — nothing above the
backing is wrong. The coordinator's initializer therefore captures `isOpaque`/`backgroundColor`
and applies the takeover surface when it finds itself already frameless, which is also what makes
a later theme change out of takeover hand the native frame the surface the window started with.

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
999-priority constraint and its component-owned, theme-dependent floor (written as a launch
transient) now size the strip permanently, and `WindowChromeTakeoverTests` states it so it stops
being luck. The window's own
controls (sidebar toggle, history pair) rehome into `WindowCommandBandView`, a button-face row
below the title bar, as fresh `ThemedIconButton`s inked from `InkSource.chrome`. The row is laid
out by `PaneHeaderView` (`margin: .paneEdge`), not by a stack of its own: the band's height, its
edge-to-edge rule, the twelve-point ink-aligned margin and the item spacing are the pane bands'
one statement of band geometry. The band re-derived them once, with a four-point inset that sat
the sidebar toggle's active box in the window's corner while every band below started its ink
twelve points in — `WindowChromeComponentTests/testCommandBandLaysItsControlsOutAsAPaneBand`
pins the column so the drift cannot return. The title band
therefore carries only app icon/title and caption buttons, matching the structural distinction
the native toolbar previously supplied and avoiding a toolbar button's required 28pt height
conflicting with the caption row's compact height. The controller's weak references re-point so
`updateToolbarControlStates()` never learns which dress is worn. `PaneBandMargin.paneEdge`'s
corner-adapted clearance is left alone in v1: harmless over-inset under square corners.

**Scope.** Main window only. The Component Gallery, Onboarding and detached browser windows keep
native chrome under every theme — the last for the same reason as the first two, and because a
takeover there would need its own `TitlebarActionWindow` plus a full app-drawn content root
(band, drag handle, close button, overlay hosting) rather than a flag; `ThemedAlertPanel`/`ThemedPopover` were already frameless and app-drawn.
Fullscreen under takeover keeps the band visible (it lives in the content tree; auto-reveal is
titlebar machinery a frameless window does not have).

### An authored takeover

**TUI (`tui`) reproduces no system, and that is the point of it.** Every other takeover here is
a reconstruction: there is a release, a screenshot, a measured band height, and a manifest in
`docs/references/chrome/` saying how close we are. This one is drawn in the idiom the
full-screen terminal programs share — a box in rule characters, a header row closed by a seam,
one accent, a grid nothing sits off — and it belongs to none of them. Which makes it the
honest test of the claim this file has been making since the takeover shipped: that the
vocabulary is the feature and the period themes are worked examples. It cost **two** new
values and no new branch.

The caption is a status line, not an empty title bar: a leading `≡` cell opens the semantic
window-operations menu, the immediate minimize/zoom/close cells finish the opposite edge, and
the title and figures take the palette's one accent while the enclosing rule stays structural.
When the window resigns key, both the caption ink and its seam dim together.

- **`Texture.Kind.rule`** draws one point along the band's *bottom* edge and ignores `spacing`.
  It is the odd one out of the texture family — the other four fill the band, and this one
  ends it — but it belongs there rather than in `Shape`, because it is ink over the fill and it
  answers the key state like every other texture. Ending the band is what a flat chrome needs
  and no gradient family ever did: with the band and the panes the same colour, the seam *is*
  the header row's silhouette. It is also this family's only inactive cue, so the theme states
  both textures and dims the seam with the title.
- **`Plate.reverseVideo`** is nothing at rest and the cell inverted under the pointer. It is
  the one plate that decides its own *figure* colour: `GlyphInk` names a colour to paint with,
  and an inverted cell's figure is the band's ground coming through the ink, which is not a
  colour anyone can name in advance. So `WindowChromeButton` reads it off the plate after the
  ink switch rather than adding a `GlyphInk` case that only one plate could ever use. Press
  keeps those two exact inks and seats the filled face one pixel inward; alpha would make a
  keyed terminal cell look disabled rather than depressed.

The caption alphabet is hairline throughout, and that is the whole visual difference from the
desktop-era families above it. Those drew their marks with a two-pixel pen because the figures
sat on raised hardware and a thin line vanished into the bevel. A terminal has one pen. The
first pass borrowed Marlett's stems and produced a cluster visibly heavier than the title
beside it — correct shapes, wrong voice.

`bevel: nil` is load-bearing rather than an omission: it is what routes `WindowChromeFrameView`
to its single one-point seat instead of the raised two-ring edge, which is the entire
difference between a drawn box and a moulded one. The frame keeps a small corner radius as its
one concession to the platform, but states `antialiases_corners: false`: its silhouette turns
in deliberate one-bit steps rather than AppKit's generic coverage ramp.

That seat keeps the theme's `border` ink wherever it already registers against the ground, so
TUI's title seam, control rules, straight frame runs, and stepped corner remain one drawing.
Only an authored border below the frame's measured visibility floor is raised to the generic
tertiary-ink fallback; replacing every flat frame unconditionally made TUI's straight edge much
brighter than the corner it turned through, which read as a hook at the join.

**Its archive entry records every component as `not_applicable`, not `missing`.** The ledger's
job is to say what evidence exists, and "none, by construction" has to be an answer it can
give, or the honest case starts looking like the neglected one. An authored chrome may never
carry `measured` or `verified` coverage — both mean "compared against a preserved original" —
so what holds it instead is the shared catalogue sweeps and the whole-window render, plus two
focused tests: that the band draws its seam on the bottom edge (pixels, not the resolved
style — "the theme states a rule" and "the band draws one, there" are different claims), and
that the caption cell actually swaps its two colours under the pointer.

## 2026-08-05 — caption anatomy is one table, and the takeover catalogue is one list

**`WindowChromeCaptionAnatomy` (`UI/Design/WindowChromeAnatomy.swift`).** `WindowChromeButton`
had grown a per-family switch for each thing a caption family could vary — slot size, plate
recipe, antialiasing, glyph ink, press behaviour, alphabet, cluster spacing — six switches over
the same enum, so a new family cost an edit in every one of them (plus the two wire-vocabulary
listings) and a fix to one switch was invisible to its siblings. Every per-family decision is
now a row in one table read by one interpreter: the button's `draw` no longer knows which
family it is drawing, and the band reads its button-cluster spacing from the same row, so
"Aqua's gems keep the period gap" stopped being an `== .aqua` inside the band.

The consolidation immediately caught the bug class it exists to prevent. The old glyph dispatch
was an else-chain, and an *unhovered* Aqua button fell off its end into the generic vector
alphabet: resting Cheetah gems wore dark generic figures — the green one a square "zoom frame" —
that 10.0 never had, while the comment beside the chain said hover-only. `glyphsRequireHover`
is now a stated fact on the row, checked wherever the row is drawn.

The native 10.0 crop also fixes what “Cheetah glass” means at 1x: a neutral charcoal rim and
two-row lower shadow, a narrow upper reflection, a lower-centre radial bloom, and no figure in
the resting state. Its title material is not Platinum's hard gray line every other pixel;
`aqua_pinstripes` is a distinct, serializable texture recipe over a vertical silver gradient.
Keeping both facts in production vocabulary prevents the conformance fixture from becoming a
one-off painted screenshot.

**Artwork is data, for every family.** Windows 98's Marlett reconstruction proved the shape —
readable one-bit bitmaps the component tests pin exactly — while Platinum, BeOS, OPENSTEP, IRIX
and Amiga each kept a private `dot()`/`frame()` painter whose figures existed only as
arithmetic, plus five separate copies of the "two offset windows" Restore figure.
`WindowChromeCaptionArtwork` states every family over one legend (`#` ink, `o` white, `+`
control face, `.` clear — the multi-ink cells are Intuition's alone), rendered by one
rasteriser with the Win98 origin math. The two local `ring()` copies the frame and the BeOS
tab each carried became `WindowChromeBevelEdge`, the window-edge sibling of
`ThemedSurface.drawBevelled`. The whole refactor was held to **byte-identical caption renders**
for every family except the two Aqua materials, whose only change is the fall-through fix
above.

**The takeover catalogue is derived, never restated.** `AppThemeStyles.takeovers` is
`all.filter(takesOverWindowChrome)` and is the only registry: the Component Gallery's chrome
story and the `WindowChromeComponentTests` sweeps iterate it. The gallery had already drifted —
Aqua and Tiger were missing from its hand-built band list — in the short life of the third
hand-maintained copy. A new takeover theme now appears in the gallery, the caption and
whole-window render sweeps, and the catalogue assertions by being added to
`AppThemeStyles.all`.

**What the sweeps now hold every family to**, where before it was Win98-only or nothing: the
caption slot seats inside the authored band height; the band changes pixels when its window
resigns key; a family whose plates are cut from the band dims them with it; a family stating a
pressed offset visibly moves its figure. Each is driven by the anatomy table, so a claim a row
makes is a claim the sweep checks — and a new family is swept by existing.

**Recorded follow-ups.** The slot size and Aqua's gel tints are the two measured values in the
table a custom theme cannot yet author; promoting them to `WindowChromeStyle` fields is the
next vocabulary step, alongside a `glyph_artwork` block that would let a custom family state
bitmaps over the same legend instead of borrowing a shipped alphabet. The scroller and chooser
anatomies deserve the same table treatment (`ThemedScroller` still switches per period in
several places); that work is in flight separately and should take this file's shape when it
lands.

## A classic skin is artwork, never behaviour

`classic_player` is another row in `WindowChromeCaptionAnatomy`, not a Winamp-shaped window
controller. Its stock bitmap alphabet is clean-room. When `WindowChromeAppearance` resolves a
custom theme carrying `titleBar.classicSkin`, the same band and button components swap in the
normalized local sheet; a dangling asset resolves to nil and the stock drawing remains usable.

The stock band now states `caption_rails`, the raised three-row furniture on either side of its
centred title. The texture interpreter derives both rail endpoints from the live caption-button
stacks and title frame; it is not keyed to Classic Player and remains available to authored
themes. The clean-room palette supplies its pale face over violet gunmetal. A resolved imported
skin bypasses the stock gradient and texture together, so source artwork never acquires an extra
set of rails drawn over its baked title bar.

Classic `TITLEBAR.BMP` source coordinates are top-left and the AppKit source rectangles are
bottom-left, so both the band and caption component perform one explicit Y conversion. The
275×14 active band begins at `(27, 0)`, the inactive band at `(27, 15)`, and the four 9×9 button
state pairs occupy the format's fixed cells. The renderer preserves 238 pixels at the leading
edge and 37 at the trailing edge, then stretches a two-pixel groove sample between them. That
keeps the window operations pinned to the source hardware while letting the content window keep
its ordinary resize contract.

The archive reader never extracts paths. It bounds archive size, entry count, each expanded
entry, and total declared expansion before allocation; rejects encryption, Zip64, and unknown
compression; reads only the last case-insensitive `TITLEBAR.BMP`/PNG basename; inflates in
memory; checks the central-directory CRC; and validates dimensions with ImageIO before decoding
and normalizing the result. `PLEDIT`, transport, equalizer, playlist, cursor, and executable
content are ignored. This is why drag-and-drop can share exactly the same importer as the open
panel without becoming a second security path.
