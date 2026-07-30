# MCP Server and Display Panel

How an agent reaches the GUI it runs inside, and the panel it draws into.

Part of the [CLAUDE.md](../../CLAUDE.md) index.

Threading hosts an MCP server and registers it with each Claude or Codex session it launches,
which is how an agent reaches the GUI it is running inside. The terminal stays the input
surface; the display panel becomes the output surface for anything the terminal renders badly.

The transport is HTTP over a loopback port (`NWListener`, no dependency, no entitlement — the
app is unsandboxed already). stdio was the alternative and is worse here: it spawns a child
that would then have to find its way back to the running app, when the app is already alive
and already owns the routing table.

**Session routing is the whole design.** `MCPSessionRegistry` mints a per-session token and
`AgentLauncher` passes a URL embedding it through Claude's `--mcp-config` file or Codex's
one-run `mcp_servers` overrides, so a tool call arrives already attributed — the URL *is* the
identity. `AgentSession.id` is the key, not
`agentSessionID`, which is nil for Codex until discovery.

One tool uses that routing as a data boundary rather than merely a destination.
`conversation_history` exists for a session created by **Continue with Claude/Codex** and reads
only the frozen handoff named by that destination session's id. Its argument is just an opaque
page cursor: the caller cannot supply a project, source session or filesystem path. The app
resolves lineage on the main actor, parses the snapshot off it, and returns a provider-neutral
page of visible dialogue and bounded tool context; private thinking is omitted. A `next_cursor`
continues large histories, and the response says when `TranscriptReplay` had to use its bounded
replay window. The tool lives in the default-enabled **Conversation handoff** catalog group;
turning that group off also removes the Continue menu because the destination could no longer
receive its context.

Three deliberate choices in the launch line:

- **The display tool is pre-approved** with `--allowedTools mcp__threading__*` for Claude and a
  tool-specific `approval_mode="approve"` override for Codex, or every image raises a
  permission prompt and the feature costs more attention than it saves. Other tools are
  unaffected.
- **No `--strict-mcp-config`**, which would suppress the user's own MCP servers for every
  session Threading launches — a far larger change than adding one.
- **The `instructions` field of the `initialize` response** carries the "you have a panel,
  prefer it over describing a file" guidance. Capability alone does not change behaviour: an
  agent in a terminal has no reason to believe anything it emits can be seen as an image.
  Both clients consume those server instructions, so a separate system-prompt flag is not
  needed.

Tool results are **plain text, with one exception**. A display tool has already drawn its image,
so the result costs a sentence rather than an image's worth of tokens — and it sidesteps the
undocumented question of what Claude Code does with an image returned from a tool.
`browser_screenshot` is the exception, because visual inspection is the tool's whole purpose: it
returns a standard MCP image block as well as caching and optionally displaying the PNG. See
[`agent-browser.md`](agent-browser.md).

## Display Panel

`DisplayContent.Body` is an enum, so the panel shows either a `ThemedImagePreview` or a
`WKWebView` and the `⋯` menu offers only the actions that fit — an image and a document share
almost nothing worth acting on.

**The picture is a control.** An image the agent just produced is the thing the user most wants
to open properly, and Quick Look is where macOS already keeps zoom, rotate, share, Open With and
full screen. Every route lands on the same `performPrimaryAction`: click to focus and Space or
Return, a double-click, the trackpad's own Quick Look gesture, VoiceOver's press, and the `⋯`
menu's first item — the menu because it is the one affordance that *advertises* what can be
done, and a gesture nobody tries is not a feature. Double-click rather than single, unlike the
prompt's attachment thumbnails: a 40pt chip is not something anyone is reading, a pane-filling
picture is. `QuickLookPresenter` owns the panel's data for both call sites, because
`QLPreviewPanel.dataSource` is non-retaining and the panel is one system window.

Four things were measured rather than assumed, each having first been wrong:

- **A split item's `holdingPriority` ties with its content's hugging**, and both are 250. That
  tie is what let a dragged panel spring back on mouse-up: the divider's new width and the
  labels' preferred width were equally important, so the solver was free to prefer the labels.
  The panel is the one pane the user positions deliberately, so it holds ten points above that
  (`DisplayPaneDefaults.holdingPriority`) and the terminal keeps the default, which is also what
  makes the terminal absorb a window resize. The `NSImageView` note below is the same bug from
  the other end, fixed by flooring the content instead — one pane's worth of content cannot be
  floored one view at a time, which is why the priority moved.
- **`NSSplitView.setPosition` does nothing** under `NSSplitViewController`, which lays its
  items out with Auto Layout. `setPosition(915, ofDividerAt: 1)` left the pane at its 260pt
  minimum. Width is set with a temporary constraint, released once honoured so the divider
  stays draggable.
- **`NSImageView`'s intrinsic content size is the image's own size**, so left alone it drives
  the split view and a 900px image opens a 900pt panel. Flooring both content priorities stopped
  that from *winning* but left the size in the layout, and still answering for `fittingSize` —
  so the picture kept lending the pane an opinion about its width. `ThemedImagePreview` states
  `noIntrinsicMetric` instead: the opinion is removed rather than out-prioritised, and the image
  scales into whatever the pane is given.
- **A split item's `minimumThickness` is a *required* constraint, and a window laid out with
  Auto Layout cannot be resized below what its required constraints ask for** — so a pane
  minimum is also a window minimum. Measured: the window's minimum content width was 572pt with
  the panel shut and 773pt with it open at a 200pt minimum, and `display_image` opens the panel,
  so showing a picture quietly cost the user 200pt of how small their window could be. The item
  now holds only `DisplayPaneDefaults.slimmestWidth` — the pane's own chrome, which the window
  was paying for anyway. The 200pt is still where the panel *opens* (applied as a width on
  reveal, and the floor a stored width is clamped to); it is no longer where the window stops.

  The caption and the placeholder were floored to `.fittingSizeCompression - 1` for the same
  reason, and the **tab strip** was the last thing in the pane still charging it: a strip that
  scrolls rather than shrinks is not a measurement of anything, but at compression resistance
  240 it answered `fittingSize` — which resolves at 50 — with the full width of its tabs. The
  pane's fitting width was therefore its widest tab plus its chrome (228pt with one tab open,
  against a 48pt floor), so the panel's real minimum moved with the *name* of the page open in
  it. `ThemedTabStripView` now yields below the fitting threshold like the two labels beside it.
- **A height computed from a width has to be recomputed when the width changes.** The compare
  tab's canvas took `preferredHeight(forWidth:)` once, as a constant, from `view.bounds.width`
  while the body was being built — before the pane had laid out at all on a first show. The box
  then held that height for life: dragging the divider refitted the images inside a canvas that
  never moved, which read as a compare tab that could not be resized.
  `CompareViewController.viewDidLayout` updates the constraint, and skips the write when the
  value has not changed, since assigning a constant dirties the view and would otherwise lay the
  pane out forever.
- **The width observer fired during the uncollapse layout**, recording the transient 260pt
  minimum as the user's width and then restoring *that*. `isRestoringDisplayPaneWidth`
  suppresses recording for the reveal, and the target width is read before uncollapsing.

The web view **allows network** and blocks only navigation. A CSP would be theatre: the agent
already has a shell, so anything it could exfiltrate through a page it could exfiltrate more
easily with `curl`. Blocking link navigation is a usability fix — a 380pt browser with no
back button is a trap — not a security control. Links go to `NSWorkspace` instead.

Documents load with `baseURL: nil`, giving an opaque origin: CDN scripts still load (measured),
but the page cannot read local files or same-origin data. A `color-scheme` meta is prepended
only when the document does not mention one, so unstyled HTML picks up WebKit's dark canvas
beside a dark terminal instead of flashing white.

WKWebView works in the unbundled `swift build` binary — worth knowing, since needing an
`.app` bundle for the web content process would have forced the project to Xcode-only builds.

**`display_compare_files` is one tool, not two.** The agent hands over two paths
(`old_path`/`new_path`, absolute or project-relative, optional per-side titles) and the *bytes*
decide the presentation: two images open the interactive `ImageCompareView` (wipe, fade,
difference, side by side), two text files render as a native diff via
`git diff --no-index` parsed by `GitDiffParser`, and a mixed or binary-but-not-image pair
fails the call in prose rather than opening a tab that apologises. Classification is
`CompareFileClassifier`: git's NUL sniff for binary, then `CGImageSource` — a header decode,
not a full image load — for "is it an image", so the extension is never trusted (`--no-index`
exits 1 to say "the files differ", which is why `GitProcess.run` grew `acceptedExitCodes`).
The tab is `DisplayTab.Body.compare` hosting `CompareViewController` — the review tab's
live-view-controller shape, third time round — with the same deferred rule: nothing is read
until the tab is shown, including after relaunch (paths, titles and mode persist on
`PersistedTab`). Asking about the same pair again reuses that pair's tab and re-reads it,
because a repeat almost always means the agent just rewrote one side; a turn ending re-reads a
visible compare tab for the same reason. The user's own route in is the `+` menu's "Compare
Files…", which is an open panel asked for exactly two files.

`MCPServer` calls its handler on the main queue, because neither `ProjectStore`, `AgentRuntime`
nor AppKit is thread-safe. Everything arriving off the network hops before touching them.

The listener must be ready before any launch, since a launch reads the port — so
`AppDelegate` defers `restoreSelectedSession()` to the `start` callback. That callback fires
whether the listener came up or not: a failed server costs sessions their panel, not their
launch (`mcpFlags` returns "" and the command line is unchanged).

**Tab order belongs to the user's hand.** The strip is `ThemedTabStripView` (the design
system's, shared with every tab host) and tabs reorder by drag or by the chip's
secondary-click menu, persisted in list order. `panel_list_tabs` reports strip order, so an
index an agent memorised can go stale the same way it already could when a tab closed — the
`id` is the stable name, and `panel_activate_tab` by id is the reliable spelling. The
extension contract anticipated this: `tabOrder` has been `hostOwnedBehavior` since the
catalogue first named it.

**Tabs move between hosts, and the agent contract holds still.** `TabTransferCoordinator`
(window-owned — only the window sees both hosts) reparents the same `PaneTab` between the
panel and the drawer: detach without teardown, adopt, both sides persist their own slice.
Movement is bounded by what the destination could *restore* after a relaunch (`canAdopt`), so
a moved tab is never one the layout later forgets — which is why shells and browsers travel
and the singleton surfaces stay panel-side. `panel_list_tabs` / `panel_activate_tab` remain
display-panel-scoped: a tab moved out disappears from them exactly as a user-closed one does,
and the existing "the user changed it while you were away" prose covers it. `browser_*` tools
keep working wherever the browser lives — `DisplayPaneController.browser(for:)` falls back to
the drawer host (`browserFallback`) when the panel holds none.

Two entrances, one move: the chip's **"Move to …"** menu items, and **dragging the chip onto
the other strip's band**. The strip asks the window on every pointer sample
(`externalDropTarget`, window coordinates), dims the traveller while a drop would land
(`Design.Opacity.dragAway`), and reports the drop (`onDropOut`) and then the drag's end
(`onDragEnded`); the window resolves both entrances through the same
`dragDestination`/`moveTab` path, with the drop's slot named by the destination strip's own
midpoint rule (`insertionIndex(forWindowPoint:)`). A *closed* destination **springs open**
the moment a movable chip leaves its home band (`springDestinationOpen` — springing on
leaving, not on grabbing, is what keeps a plain reorder from flinging the other pane open),
the destination strip washes as a drop target (`isDropTarget`), and a drag that settles
without its drop puts everything back (`dragDidSettle`). The menu remains the gesture's
pointerless twin, per the design system's rule.
