# Window Chrome

The toolbar, the pane headers, and why the sidebar is a plain split item.

Part of the [CLAUDE.md](../../CLAUDE.md) index.

The window uses `.fullSizeContentView` with a transparent, hidden title bar, so the sidebar
runs the full height and the traffic lights float over it. The window title stays `Skalman`,
since it is only surfaced where macOS names the window (Mission Control, the Window menu).

**The toolbar holds one item, and everything else belongs to the pane it describes.**
`NSToolbar` positions its items relative to the *window*, which is what makes it right for the
sidebar toggle — that control acts on the split rather than on either side of it, and it stays
beside the traffic lights in both collapse states — and wrong for everything else that used to
live there. The page tab, the `+`, the usage pill and the session's actions all name or act on
the *content pane*, so at a fixed window x they drift away from it the moment a divider moves.

`NSTrackingSeparatorToolbarItem` hid that for years, and stopped the day the sidebar became a
plain split item: measured on macOS 26 across all three split-item kinds, it follows the divider
only when the pane beside it has `.sidebar` behaviour. Dragging the divider wider then slid the
sidebar out from under the tab and left it floating over the list.

So those controls moved into `TerminalContainerViewController`'s own header strip
(`setupHeader`, `PaneHeaderDefaults`), which cannot drift because it *is* the pane — no divider
is crossed and there is nothing to track. Two things this settles that measuring never could:
the header follows a **collapse** as readily as a drag, and it stops where the pane stops, so
the display panel's own strip lines up with it rather than sitting under a window-wide row.

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

`SidebarSplitViewController` overrides `toggleSidebar(_:)` to set `isCollapsed` directly.
The stock implementation collapses but does not restore here, which left no way back to the
sidebar. Overriding it fixes the toolbar button and the View menu together, since both route
through that one method.

**The sidebar is a plain split item, not `NSSplitViewItem(sidebarWithViewController:)`**, and
that single line is the whole of its silhouette. On macOS 26 the sidebar *behaviour* draws the
pane as a floating inset panel — rounded, held off the window's edges by a margin, with the
content pane visible around it — and there is no property to decline it (`allowsFullHeightLayout`
and `titlebarSeparatorStyle` both leave the inset). That is the platform's look for a panel over
a document, and the wrong shape for a structural column beside a terminal: the margin left the
toolbar's tab and controls reading as loose parts, and the terminal's colour ran underneath the
sidebar it is meant to sit next to. So the pane is ours — flush to the window's edges, full
height under the transparent titlebar, the split view's hairline as the only seam.

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

Sidebar rows deliberately leave `NSTableCellView.textField` unset. Assigning it lets the table
restyle the label on selection, which tints an unemphasized source-list row with the accent
colour; the filled selection shape is the only cue wanted. Each row view's `applyTextColors`
owns the colours instead, inverting only for `.emphasized` (selected while the sidebar has
focus).

A session row's trailing edge is one fixed-size slot holding the status indicator and the
`⋯` actions button overlaid, crossfaded on hover via `alphaValue` rather than `isHidden` —
a stack view detaches hidden arranged views, so toggling visibility would re-lay out the row
under the pointer.
