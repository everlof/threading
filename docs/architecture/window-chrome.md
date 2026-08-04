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

`SidebarSplitViewController` overrides `toggleSidebar(_:)` to set `isCollapsed` directly.
The stock implementation collapses but does not restore here, which left no way back to the
sidebar. Overriding it fixes the toolbar button and the View menu together, since both route
through that one method.

### Dragging a pane shut

**The overshoot is the gesture.** Past its floor a pane stops dead under the pointer, which
keeps going; that gap is the only record of how hard the divider was pushed, because no frame
moved.

In the running app, a dragged divider has **never** shut this column — not "stopped working",
never, on the report of the person dragging it. Every collapse it has ever done came from the
toolbar, the View menu, or a test calling `setPosition`. AppKit is not flatly refusing, either:
driven through the same tracking loop in a fixture it collapses a `canCollapse` pane at *half
the pane's floor* (floor 207pt — released at 120 the column stayed, at 90 it shut), so the
machinery exists and something about the real window keeps it from firing. Worth knowing, not
worth depending on: that threshold sits a hundred points past a column that has visibly stopped,
travelled blind, which is not a gesture anyone would find.

`SidebarSplitViewController.shutPaneIfPushedPast` shuts the pane once the pointer is released
`SidebarDefaults.shutOvershoot` past the floor — near enough to the stop that the push is one
movement. AppKit's rule stays underneath: if it ever does fire, a longer push is still a push.

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
owns the colours instead, inverting only for `.emphasized` (selected while the sidebar has
focus).

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
a hidden application icon, and striped centred-title texture through the same regional model.
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
application-icon visibility, and active/inactive texture; it contains no stock-theme ID
branches. `WindowChromeButton` (close/minimize/zoom) calls the **semantic**
operations — `zoom(nil)`, `miniaturize(nil)`, delegate-consulted `close()` — because the
`perform*` forms animate a standard button a frameless window does not have and refuse outright
(measured; the buttons were dead until this). The zoom button follows `window.isZoomed` and
draws/names itself Restore while zoomed. `WindowChromeFrameView` draws the border, and
draws nothing at all in native dress, where the terminal-palette backdrop showing through the
titlebar strip is load-bearing.

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
